// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {CommissionVault} from "../contracts/CommissionVault.sol";
import {ICommissionVault} from "../contracts/interfaces/ICommissionVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// Tests for the backend-triggered threshold payout (ENG-2384): distributeEligible
/// pays every listed code that reached minClaimAmount to its own registered payout
/// address; unbound / pending-change / zero-owed / below-threshold codes are
/// silently skipped so one bad code never breaks the batch.
contract CommissionVaultDistributeEligibleTest is Test {
    CommissionVault public vault;
    MockUSDC public usdc;

    address public owner = address(this);
    address public operator = makeAddr("operator");
    address public guardian = makeAddr("guardian");
    address public distributor = makeAddr("distributor");

    address public affiliate1 = makeAddr("affiliate1");
    address public affiliate2 = makeAddr("affiliate2");
    address public affiliate3 = makeAddr("affiliate3");
    address public newPayout = makeAddr("newPayout");

    uint256 constant MAX_CODE_DELTA = 1000e6;
    uint256 constant MAX_BATCH_DELTA = 10000e6;
    uint256 constant SETTLEMENT_TIMELOCK = 24 hours;
    uint256 constant PAYOUT_TIMELOCK = 24 hours;
    uint256 constant MIN_CLAIM = 50e6;

    string constant CODE_A = "CODE_A"; // 100e6 owed — above threshold
    string constant CODE_B = "CODE_B"; // 60e6 owed — above threshold
    string constant CODE_C = "CODE_C"; // 30e6 owed — below threshold
    bytes32 CODE_A_HASH = keccak256(bytes(CODE_A));
    bytes32 CODE_C_HASH = keccak256(bytes(CODE_C));

    function setUp() public {
        usdc = new MockUSDC();
        vault = new CommissionVault(
            address(usdc),
            distributor,
            operator,
            guardian,
            MAX_CODE_DELTA,
            MAX_BATCH_DELTA,
            false,
            SETTLEMENT_TIMELOCK,
            PAYOUT_TIMELOCK
        );
        vault.setMinClaimAmount(MIN_CLAIM);
        _settle(CODE_A, affiliate1, 100e6);
        _settle(CODE_B, affiliate2, 60e6);
        _settle(CODE_C, affiliate3, 30e6);
        usdc.mint(address(vault), 190e6);
    }

    // ── Helpers ─────────────────────────────────────────────

    function _settle(string memory code, address addr, uint256 amount) internal {
        string[] memory codes = new string[](1);
        codes[0] = code;
        address[] memory addrs = new address[](1);
        addrs[0] = addr;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        vm.prank(operator);
        vault.proposeSettlement(codes, addrs, amounts);
        vm.warp(block.timestamp + vault.settlementTimelock());
        vault.activateSettlement();
    }

    function _one(string memory code) internal pure returns (string[] memory codes) {
        codes = new string[](1);
        codes[0] = code;
    }

    // ── Auth ────────────────────────────────────────────────

    function test_operatorCanCall() public {
        vm.prank(operator);
        vault.distributeEligible(_one(CODE_A));
        assertEq(usdc.balanceOf(affiliate1), 100e6);
    }

    function test_guardianCanCall() public {
        // caller is an indexed event arg the indexer reads — assert it reflects the guardian.
        vm.expectEmit(true, false, false, true);
        emit ICommissionVault.EligibleDistribution(guardian, 1, 100e6, 0);
        vm.prank(guardian);
        vault.distributeEligible(_one(CODE_A));
        assertEq(usdc.balanceOf(affiliate1), 100e6);
    }

    function test_ownerCanCall() public {
        vm.expectEmit(true, false, false, true);
        emit ICommissionVault.EligibleDistribution(owner, 1, 100e6, 0);
        vault.distributeEligible(_one(CODE_A));
        assertEq(usdc.balanceOf(affiliate1), 100e6);
    }

    function test_strangerReverts() public {
        vm.prank(affiliate1);
        vm.expectRevert("Not authorized");
        vault.distributeEligible(_one(CODE_A));
    }

    function test_distributorCannotCall() public {
        vm.prank(distributor);
        vm.expectRevert("Not authorized");
        vault.distributeEligible(_one(CODE_A));
    }

    // ── Threshold ───────────────────────────────────────────

    function test_skipsBelowMinClaim() public {
        vm.prank(operator);
        vault.distributeEligible(_one(CODE_C));
        assertEq(usdc.balanceOf(affiliate3), 0);
        assertEq(vault.claimed(CODE_C_HASH), 0);
    }

    function test_paysExactlyAtMinClaim() public {
        _settle("CODE_D", newPayout, MIN_CLAIM);
        usdc.mint(address(vault), MIN_CLAIM);
        vm.prank(operator);
        vault.distributeEligible(_one("CODE_D"));
        assertEq(usdc.balanceOf(newPayout), MIN_CLAIM);
    }

    function test_paysBelowMinWhenMinClaimZero() public {
        vault.setMinClaimAmount(0);
        vm.prank(operator);
        vault.distributeEligible(_one(CODE_C));
        assertEq(usdc.balanceOf(affiliate3), 30e6);
    }

    // ── Skips ───────────────────────────────────────────────

    function test_skipsUnboundCode() public {
        string[] memory codes = new string[](2);
        codes[0] = CODE_A;
        codes[1] = "NEVER_BOUND";
        vm.prank(operator);
        vault.distributeEligible(codes);
        assertEq(usdc.balanceOf(affiliate1), 100e6);
    }

    function test_skipsZeroOwed() public {
        vm.prank(affiliate1);
        vault.claim(CODE_A);
        vm.prank(operator);
        vault.distributeEligible(_one(CODE_A));
        // No double-pay.
        assertEq(usdc.balanceOf(affiliate1), 100e6);
    }

    function test_skipsCodeWithPendingChange_thenPaysNewAddressAfterActivation() public {
        vault.ownerSetPayoutAddress(CODE_A, newPayout);

        vm.prank(operator);
        vault.distributeEligible(_one(CODE_A));
        assertEq(usdc.balanceOf(affiliate1), 0);
        assertEq(usdc.balanceOf(newPayout), 0);

        vm.warp(block.timestamp + PAYOUT_TIMELOCK);
        vault.activatePayoutChange(CODE_A);
        vm.prank(operator);
        vault.distributeEligible(_one(CODE_A));
        assertEq(usdc.balanceOf(newPayout), 100e6);
        assertEq(usdc.balanceOf(affiliate1), 0);
    }

    function test_duplicateCodeInBatchPaysOnce() public {
        string[] memory codes = new string[](2);
        codes[0] = CODE_A;
        codes[1] = CODE_A;
        vm.prank(operator);
        vault.distributeEligible(codes);
        assertEq(usdc.balanceOf(affiliate1), 100e6);
        assertEq(vault.claimed(CODE_A_HASH), 100e6);
    }

    // ── Events ──────────────────────────────────────────────

    function test_emitsCommissionClaimedPerPaidCode() public {
        vm.expectEmit(true, true, false, true);
        emit ICommissionVault.CommissionClaimed(CODE_A_HASH, affiliate1, 100e6, 100e6);
        vm.prank(operator);
        vault.distributeEligible(_one(CODE_A));
    }

    function test_emitsEligibleDistributionSummary() public {
        // A + B paid, C (below min) + NEVER_BOUND skipped.
        string[] memory codes = new string[](4);
        codes[0] = CODE_A;
        codes[1] = CODE_B;
        codes[2] = CODE_C;
        codes[3] = "NEVER_BOUND";
        vm.expectEmit(true, false, false, true);
        emit ICommissionVault.EligibleDistribution(operator, 2, 160e6, 2);
        vm.prank(operator);
        vault.distributeEligible(codes);

        // Only the eligible codes moved funds; skipped ones stay untouched.
        assertEq(usdc.balanceOf(affiliate1), 100e6);
        assertEq(usdc.balanceOf(affiliate2), 60e6);
        assertEq(usdc.balanceOf(affiliate3), 0);
        assertEq(vault.claimed(CODE_C_HASH), 0);
    }

    function test_allSkippedStillEmitsSummary() public {
        string[] memory codes = new string[](2);
        codes[0] = CODE_C;
        codes[1] = "NEVER_BOUND";
        vm.expectEmit(true, false, false, true);
        emit ICommissionVault.EligibleDistribution(operator, 0, 0, 2);
        vm.prank(operator);
        vault.distributeEligible(codes);
    }

    // ── Accounting ──────────────────────────────────────────

    function test_totalClaimedAccounting() public {
        uint256 before = vault.totalClaimed();
        string[] memory codes = new string[](2);
        codes[0] = CODE_A;
        codes[1] = CODE_B;
        vm.prank(operator);
        vault.distributeEligible(codes);
        assertEq(vault.totalClaimed(), before + 160e6);
        // totalOwed untouched — payouts only move the claimed side.
        assertEq(vault.totalOwed(), 190e6);
    }

    // ── Reverts ─────────────────────────────────────────────

    function test_revertsWhenPaused() public {
        vm.prank(guardian);
        vault.pause();
        vm.prank(operator);
        vm.expectRevert("Paused");
        vault.distributeEligible(_one(CODE_A));
    }

    function test_revertsEmptyBatch() public {
        string[] memory codes = new string[](0);
        vm.prank(operator);
        vm.expectRevert("Empty batch");
        vault.distributeEligible(codes);
    }

    function test_revertsBatchTooLarge() public {
        string[] memory codes = new string[](201);
        for (uint256 i = 0; i < 201; i++) {
            codes[i] = CODE_A;
        }
        vm.prank(operator);
        vm.expectRevert("Batch too large");
        vault.distributeEligible(codes);
    }

    function test_underfundedVaultRevertsWholeBatch() public {
        // Vault holds 190e6; make owed exceed balance by settling a new code
        // without funding it.
        _settle("CODE_E", newPayout, 500e6);
        string[] memory codes = new string[](2);
        codes[0] = "CODE_E";
        codes[1] = CODE_A;
        vm.prank(operator);
        vm.expectRevert();
        vault.distributeEligible(codes);
        // Revert rolled everything back — nobody got paid.
        assertEq(usdc.balanceOf(newPayout), 0);
        assertEq(usdc.balanceOf(affiliate1), 0);
    }
}
