// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {CommissionVault} from "../contracts/CommissionVault.sol";
import {ICommissionVault} from "../contracts/interfaces/ICommissionVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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

contract CommissionVaultTest is Test {
    using stdStorage for StdStorage;

    CommissionVault public vault;
    MockUSDC public usdc;

    address public owner = address(this);
    address public operator = makeAddr("operator");
    address public guardian = makeAddr("guardian");
    address public distributor = makeAddr("distributor");

    address public affiliate1 = makeAddr("affiliate1");
    address public affiliate2 = makeAddr("affiliate2");
    address public affiliate3 = makeAddr("affiliate3");

    uint256 constant MAX_CODE_DELTA = 1000e6;
    uint256 constant MAX_BATCH_DELTA = 10000e6;
    uint256 constant TIMELOCK = 24 hours;
    uint256 constant PAYOUT_TIMELOCK = 24 hours;

    function setUp() public {
        usdc = new MockUSDC();
        vault = new CommissionVault(
            address(usdc), distributor, operator, guardian, MAX_CODE_DELTA, MAX_BATCH_DELTA, false, TIMELOCK, PAYOUT_TIMELOCK
        );
    }

    // ── Helpers ─────────────────────────────────────────────

    function _proposeAndActivate(string[] memory codes, uint256[] memory amounts) internal {
        vm.prank(operator);
        vault.proposeSettlement(codes, amounts);
        vm.warp(block.timestamp + vault.settlementTimelock());
        vault.activateSettlement();
    }

    function _singleSettlement(string memory code, address addr, uint256 amount) internal {
        // Settlement no longer binds a payout, so bind the code first (as its owner or
        // the admin would) and then settle only the amount.
        if (vault.payoutAddress(keccak256(bytes(code))) == address(0)) {
            vault.ownerRegisterCode(code, addr);
        }
        string[] memory codes = new string[](1);
        codes[0] = code;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        _proposeAndActivate(codes, amounts);
    }

    function _craftUnboundValueBearingCode(bytes32 codeHash, uint256 amount) internal {
        stdstore.target(address(vault)).sig("cumulativeAmount(bytes32)").with_key(codeHash).checked_write(amount);
    }

    // ── Constructor ─────────────────────────────────────────

    function test_constructor_setsRoles() public view {
        assertEq(vault.owner(), owner);
        assertEq(vault.operator(), operator);
        assertEq(vault.guardian(), guardian);
        assertEq(vault.distributor(), distributor);
        assertEq(address(vault.usdc()), address(usdc));
        assertEq(vault.maxCodeDelta(), MAX_CODE_DELTA);
        assertEq(vault.maxBatchDelta(), MAX_BATCH_DELTA);
        assertTrue(vault.migrationFinalized());
    }

    function test_constructor_migrationTarget() public {
        CommissionVault v2 = new CommissionVault(
            address(usdc), distributor, operator, guardian, MAX_CODE_DELTA, MAX_BATCH_DELTA, true, TIMELOCK, PAYOUT_TIMELOCK
        );
        assertFalse(v2.migrationFinalized());
    }

    function test_constructor_revertsOnZeroUsdc() public {
        vm.expectRevert(ICommissionVault.ZeroUSDC.selector);
        new CommissionVault(
            address(0), distributor, operator, guardian, MAX_CODE_DELTA, MAX_BATCH_DELTA, false, TIMELOCK, PAYOUT_TIMELOCK
        );
    }

    function test_constructor_revertsOnZeroDistributor() public {
        vm.expectRevert(ICommissionVault.ZeroDistributor.selector);
        new CommissionVault(
            address(usdc), address(0), operator, guardian, MAX_CODE_DELTA, MAX_BATCH_DELTA, false, TIMELOCK, PAYOUT_TIMELOCK
        );
    }

    function test_constructor_revertsOnZeroOperator() public {
        vm.expectRevert(ICommissionVault.ZeroOperator.selector);
        new CommissionVault(
            address(usdc), distributor, address(0), guardian, MAX_CODE_DELTA, MAX_BATCH_DELTA, false, TIMELOCK, PAYOUT_TIMELOCK
        );
    }

    function test_constructor_revertsOnZeroGuardian() public {
        vm.expectRevert(ICommissionVault.ZeroGuardian.selector);
        new CommissionVault(
            address(usdc), distributor, operator, address(0), MAX_CODE_DELTA, MAX_BATCH_DELTA, false, TIMELOCK, PAYOUT_TIMELOCK
        );
    }

    function test_constructor_revertsOnZeroMaxCodeDelta() public {
        vm.expectRevert(ICommissionVault.ZeroMaxCodeDelta.selector);
        new CommissionVault(address(usdc), distributor, operator, guardian, 0, MAX_BATCH_DELTA, false, TIMELOCK, PAYOUT_TIMELOCK);
    }

    function test_constructor_revertsOnZeroMaxBatchDelta() public {
        vm.expectRevert(ICommissionVault.ZeroMaxBatchDelta.selector);
        new CommissionVault(address(usdc), distributor, operator, guardian, MAX_CODE_DELTA, 0, false, TIMELOCK, PAYOUT_TIMELOCK);
    }

    function test_constructor_setsSettlementTimelock() public view {
        assertEq(vault.settlementTimelock(), TIMELOCK);
    }

    function test_constructor_revertsOnTimelockTooShort() public {
        vm.expectRevert(ICommissionVault.TimelockTooShort.selector);
        new CommissionVault(address(usdc), distributor, operator, guardian, MAX_CODE_DELTA, MAX_BATCH_DELTA, false, 59, PAYOUT_TIMELOCK);
    }

    function test_constructor_acceptsMinTimelock() public {
        CommissionVault shortVault = new CommissionVault(
            address(usdc), distributor, operator, guardian, MAX_CODE_DELTA, MAX_BATCH_DELTA, false, 60, PAYOUT_TIMELOCK
        );
        assertEq(shortVault.settlementTimelock(), 60);
    }

    // ── proposeSettlement ───────────────────────────────────

    function test_proposeSettlement_happyPath() public {
        string[] memory codes = new string[](2);
        codes[0] = "CODE_A";
        codes[1] = "CODE_B";
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e6;
        amounts[1] = 50e6;

        vm.prank(operator);
        vault.proposeSettlement(codes, amounts);

        assertGt(vault.pendingActivationTime(), block.timestamp);
    }

    function test_proposeSettlement_emitsEvent() public {
        string[] memory codes = new string[](1);
        codes[0] = "CODE_A";
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e6;

        vm.expectEmit(false, false, false, true);
        emit ICommissionVault.SettlementProposed(block.timestamp + vault.settlementTimelock(), 1, 100e6);

        vm.prank(operator);
        vault.proposeSettlement(codes, amounts);
    }

    function test_proposeSettlement_revertsIfNotOperator() public {
        string[] memory codes = new string[](1);
        codes[0] = "CODE_A";
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e6;

        vm.expectRevert(ICommissionVault.NotOperator.selector);
        vault.proposeSettlement(codes, amounts);
    }

    function test_proposeSettlement_revertsOnEmptyBatch() public {
        string[] memory codes = new string[](0);
        uint256[] memory amounts = new uint256[](0);

        vm.prank(operator);
        vm.expectRevert(ICommissionVault.EmptyBatch.selector);
        vault.proposeSettlement(codes, amounts);
    }

    function test_proposeSettlement_revertsOnLengthMismatch() public {
        string[] memory codes = new string[](2);
        codes[0] = "A";
        codes[1] = "B";
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e6;

        vm.prank(operator);
        vm.expectRevert(ICommissionVault.LengthMismatch.selector);
        vault.proposeSettlement(codes, amounts);
    }

    function test_proposeSettlement_revertsIfPendingExists() public {
        string[] memory codes = new string[](1);
        codes[0] = "CODE_A";
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e6;

        vm.prank(operator);
        vault.proposeSettlement(codes, amounts);

        vm.prank(operator);
        vm.expectRevert(ICommissionVault.PendingSettlementExists.selector);
        vault.proposeSettlement(codes, amounts);
    }

    function test_proposeSettlement_revertsOnExceedsMaxCodeDelta() public {
        string[] memory codes = new string[](1);
        codes[0] = "CODE_A";
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = MAX_CODE_DELTA + 1;

        vm.prank(operator);
        vm.expectRevert(ICommissionVault.ExceedsMaxCodeDelta.selector);
        vault.proposeSettlement(codes, amounts);
    }

    function test_proposeSettlement_revertsOnExceedsMaxBatchDelta() public {
        // Use 11 codes each at MAX_CODE_DELTA to exceed MAX_BATCH_DELTA
        // MAX_CODE_DELTA = 1000e6, MAX_BATCH_DELTA = 10000e6, so 11 codes = 11000e6 > 10000e6
        uint256 count = 11;
        string[] memory codes = new string[](count);
        uint256[] memory amounts = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            codes[i] = string(abi.encodePacked("CODE_", vm.toString(i)));
            amounts[i] = MAX_CODE_DELTA;
        }

        vm.prank(operator);
        vm.expectRevert(ICommissionVault.ExceedsMaxBatchDelta.selector);
        vault.proposeSettlement(codes, amounts);
    }

    function test_proposeSettlement_cannotDecreaseAmount() public {
        _singleSettlement("CODE_A", affiliate1, 100e6);

        string[] memory codes = new string[](1);
        codes[0] = "CODE_A";
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 50e6; // less than current 100e6

        vm.prank(operator);
        vm.expectRevert(ICommissionVault.CannotDecreaseAmount.selector);
        vault.proposeSettlement(codes, amounts);
    }

    function test_proposeSettlement_revertsWhenPaused() public {
        vm.prank(guardian);
        vault.pause();

        string[] memory codes = new string[](1);
        codes[0] = "CODE_A";
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e6;

        vm.prank(operator);
        vm.expectRevert(ICommissionVault.Paused.selector);
        vault.proposeSettlement(codes, amounts);
    }

    function test_proposeSettlement_revert_duplicateCode() public {
        string[] memory codes = new string[](2);
        codes[0] = "CODE_A";
        codes[1] = "CODE_A";
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e6;
        amounts[1] = 200e6;

        vm.prank(operator);
        vm.expectRevert(ICommissionVault.DuplicateCodeInBatch.selector);
        vault.proposeSettlement(codes, amounts);
    }

    // ── activateSettlement ──────────────────────────────────

    function test_activateSettlement_happyPath() public {
        string[] memory codes = new string[](2);
        codes[0] = "CODE_A";
        codes[1] = "CODE_B";
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e6;
        amounts[1] = 50e6;

        vault.ownerRegisterCode("CODE_A", affiliate1);
        vault.ownerRegisterCode("CODE_B", affiliate2);
        _proposeAndActivate(codes, amounts);

        assertEq(vault.totalOwed(), 150e6);
        assertEq(vault.pendingActivationTime(), 0);

        (address addr, uint256 cumul, uint256 clmd) = vault.getEntitlement("CODE_A");
        assertEq(addr, affiliate1);
        assertEq(cumul, 100e6);
        assertEq(clmd, 0);

        (addr, cumul, clmd) = vault.getEntitlement("CODE_B");
        assertEq(addr, affiliate2);
        assertEq(cumul, 50e6);
        assertEq(clmd, 0);
    }

    function test_activateSettlement_anyoneCanCall() public {
        string[] memory codes = new string[](1);
        codes[0] = "CODE_A";
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e6;

        vm.prank(operator);
        vault.proposeSettlement(codes, amounts);
        vm.warp(block.timestamp + vault.settlementTimelock());

        // Random address can activate
        vm.prank(makeAddr("random"));
        vault.activateSettlement();

        assertEq(vault.totalOwed(), 100e6);
    }

    function test_activateSettlement_revertsBeforeTimelock() public {
        string[] memory codes = new string[](1);
        codes[0] = "CODE_A";
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e6;

        vm.prank(operator);
        vault.proposeSettlement(codes, amounts);

        vm.warp(block.timestamp + vault.settlementTimelock() - 1 hours);
        vm.expectRevert(ICommissionVault.TimelockNotExpired.selector);
        vault.activateSettlement();
    }

    function test_activateSettlement_revertsIfNoPending() public {
        vm.expectRevert(ICommissionVault.NoPendingSettlement.selector);
        vault.activateSettlement();
    }

    function test_activateSettlement_deltaTracking() public {
        // First settlement: CODE_A = 100e6
        _singleSettlement("CODE_A", affiliate1, 100e6);
        assertEq(vault.totalOwed(), 100e6);

        // Second settlement: CODE_A increases to 250e6 (delta = 150e6)
        _singleSettlement("CODE_A", affiliate1, 250e6);
        assertEq(vault.totalOwed(), 250e6);
    }

    function test_activateSettlement_emitsEntitlementUpdated() public {
        string[] memory codes = new string[](1);
        codes[0] = "CODE_A";
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e6;

        vault.ownerRegisterCode("CODE_A", affiliate1);
        vm.prank(operator);
        vault.proposeSettlement(codes, amounts);
        vm.warp(block.timestamp + vault.settlementTimelock());

        bytes32 codeHash = keccak256(bytes("CODE_A"));
        vm.expectEmit(true, false, false, true);
        emit ICommissionVault.EntitlementUpdated(codeHash, affiliate1, 100e6);

        vault.activateSettlement();
    }

    // ── cancelSettlement ────────────────────────────────────

    function test_cancelSettlement_clearsState() public {
        string[] memory codes = new string[](1);
        codes[0] = "CODE_A";
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e6;

        vm.prank(operator);
        vault.proposeSettlement(codes, amounts);

        vm.prank(guardian);
        vault.cancelSettlement();

        assertEq(vault.pendingActivationTime(), 0);
        assertEq(vault.totalOwed(), 0);

        // Can propose again after cancel
        vm.prank(operator);
        vault.proposeSettlement(codes, amounts);
    }

    function test_cancelSettlement_revertsIfNotGuardian() public {
        string[] memory codes = new string[](1);
        codes[0] = "CODE_A";
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e6;

        vm.prank(operator);
        vault.proposeSettlement(codes, amounts);

        vm.expectRevert(ICommissionVault.NotGuardian.selector);
        vault.cancelSettlement();
    }

    function test_cancelSettlement_revertsIfNoPending() public {
        vm.prank(guardian);
        vm.expectRevert(ICommissionVault.NoPendingSettlement.selector);
        vault.cancelSettlement();
    }

    // ── claim ───────────────────────────────────────────────

    function test_claim_happyPath() public {
        _singleSettlement("CODE_A", affiliate1, 100e6);
        usdc.mint(address(vault), 200e6);

        vm.prank(affiliate1);
        vault.claim("CODE_A");

        assertEq(usdc.balanceOf(affiliate1), 100e6);
        assertEq(vault.getClaimable("CODE_A"), 0);
        assertEq(vault.totalClaimed(), 100e6);
    }

    function test_claim_cumulativeModel() public {
        _singleSettlement("CODE_A", affiliate1, 100e6);
        usdc.mint(address(vault), 500e6);

        vm.prank(affiliate1);
        vault.claim("CODE_A");
        assertEq(usdc.balanceOf(affiliate1), 100e6);

        // Increase entitlement to 250e6
        _singleSettlement("CODE_A", affiliate1, 250e6);

        // Should only be able to claim the delta (150e6)
        assertEq(vault.getClaimable("CODE_A"), 150e6);

        vm.prank(affiliate1);
        vault.claim("CODE_A");
        assertEq(usdc.balanceOf(affiliate1), 250e6);
        assertEq(vault.totalClaimed(), 250e6);
    }

    function test_claim_revertsWrongSender() public {
        _singleSettlement("CODE_A", affiliate1, 100e6);
        usdc.mint(address(vault), 200e6);

        vm.prank(affiliate2);
        vm.expectRevert(ICommissionVault.WrongSender.selector);
        vault.claim("CODE_A");
    }

    function test_claim_revertsNothingToClaim() public {
        _singleSettlement("CODE_A", affiliate1, 100e6);
        usdc.mint(address(vault), 200e6);

        vm.prank(affiliate1);
        vault.claim("CODE_A");

        vm.prank(affiliate1);
        vm.expectRevert(ICommissionVault.NothingToClaim.selector);
        vault.claim("CODE_A");
    }

    function test_claim_revertsBelowMinimum() public {
        vault.setMinClaimAmount(50e6);

        _singleSettlement("CODE_A", affiliate1, 10e6);
        usdc.mint(address(vault), 200e6);

        vm.prank(affiliate1);
        vm.expectRevert(ICommissionVault.BelowMinimumClaim.selector);
        vault.claim("CODE_A");
    }

    function test_claim_revertsVaultUnderfunded() public {
        _singleSettlement("CODE_A", affiliate1, 100e6);
        // Don't fund the vault

        vm.prank(affiliate1);
        vm.expectRevert(ICommissionVault.VaultUnderfunded.selector);
        vault.claim("CODE_A");
    }

    function test_claim_emitsEvent() public {
        _singleSettlement("CODE_A", affiliate1, 100e6);
        usdc.mint(address(vault), 200e6);

        bytes32 codeHash = keccak256(bytes("CODE_A"));
        vm.expectEmit(true, true, false, true);
        emit ICommissionVault.CommissionClaimed(codeHash, affiliate1, 100e6, 100e6);

        vm.prank(affiliate1);
        vault.claim("CODE_A");
    }

    function test_claimDuringTimelock_usesActiveEntitlements() public {
        // Activate CODE_A = 100e6
        _singleSettlement("CODE_A", affiliate1, 100e6);
        usdc.mint(address(vault), 500e6);

        // Propose CODE_A = 200e6 (pending)
        string[] memory codes = new string[](1);
        codes[0] = "CODE_A";
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 200e6;

        vm.prank(operator);
        vault.proposeSettlement(codes, amounts);

        // During timelock: claim should use active (100e6), not pending (200e6)
        assertEq(vault.getClaimable("CODE_A"), 100e6);

        vm.prank(affiliate1);
        vault.claim("CODE_A");
        assertEq(usdc.balanceOf(affiliate1), 100e6);
    }

    function test_claim_revertsWhenPaused() public {
        _singleSettlement("CODE_A", affiliate1, 100e6);
        usdc.mint(address(vault), 200e6);

        vm.prank(guardian);
        vault.pause();

        vm.prank(affiliate1);
        vm.expectRevert(ICommissionVault.Paused.selector);
        vault.claim("CODE_A");
    }

    // ── getClaimable / getEntitlement ───────────────────────

    function test_getClaimable_returnsZeroForUnknownCode() public view {
        assertEq(vault.getClaimable("UNKNOWN"), 0);
    }

    function test_getEntitlement_returnsZerosForUnknownCode() public view {
        (address addr, uint256 cumul, uint256 clmd) = vault.getEntitlement("UNKNOWN");
        assertEq(addr, address(0));
        assertEq(cumul, 0);
        assertEq(clmd, 0);
    }

    // ── processIncoming ────────────────────────────────────

    function test_processIncoming_forwardsSurplus() public {
        _singleSettlement("CODE_A", affiliate1, 150e6);
        usdc.mint(address(vault), 500e6);

        vm.prank(operator);
        vault.processIncoming();

        assertEq(usdc.balanceOf(distributor), 350e6);
        assertEq(usdc.balanceOf(address(vault)), 150e6);
    }

    function test_processIncoming_noopWhenUnderfunded() public {
        _singleSettlement("CODE_A", affiliate1, 150e6);
        usdc.mint(address(vault), 100e6);

        vm.prank(operator);
        vault.processIncoming();

        // Nothing forwarded — vault is underfunded
        assertEq(usdc.balanceOf(distributor), 0);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
    }

    function test_processIncoming_accountsForClaims() public {
        _singleSettlement("CODE_A", affiliate1, 100e6);
        usdc.mint(address(vault), 500e6);

        // Claim first
        vm.prank(affiliate1);
        vault.claim("CODE_A");

        // Now processIncoming: totalOwed=100e6, totalClaimed=100e6, mustRetain=0
        vm.prank(operator);
        vault.processIncoming();

        // All remaining balance forwarded (500e6 - 100e6 claimed = 400e6 in vault → all surplus)
        assertEq(usdc.balanceOf(distributor), 400e6);
    }

    function test_processIncoming_blockedDuringMigration() public {
        CommissionVault v2 = new CommissionVault(
            address(usdc), distributor, operator, guardian, MAX_CODE_DELTA, MAX_BATCH_DELTA, true, TIMELOCK, PAYOUT_TIMELOCK
        );
        usdc.mint(address(v2), 1000e6);

        vm.prank(operator);
        vm.expectRevert(ICommissionVault.MigrationNotFinalized.selector);
        v2.processIncoming();
    }

    function test_processIncoming_revertsIfNotOperator() public {
        vm.expectRevert(ICommissionVault.NotOperator.selector);
        vault.processIncoming();
    }

    // ── pause / unpause ────────────────────────────────────

    function test_pause_onlyGuardian() public {
        vm.prank(guardian);
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_pause_revertsIfNotGuardian() public {
        vm.expectRevert(ICommissionVault.NotGuardian.selector);
        vault.pause();
    }

    function test_unpause_onlyOwner() public {
        vm.prank(guardian);
        vault.pause();
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_unpause_revertsIfNotOwner() public {
        vm.prank(guardian);
        vault.pause();
        vm.prank(operator);
        vm.expectRevert(ICommissionVault.NotOwner.selector);
        vault.unpause();
    }

    // ── Admin setters ──────────────────────────────────────

    function test_setOperator() public {
        address newOp = makeAddr("newOp");
        vault.setOperator(newOp);
        assertEq(vault.operator(), newOp);
    }

    function test_setOperator_revertsZero() public {
        vm.expectRevert(ICommissionVault.ZeroOperator.selector);
        vault.setOperator(address(0));
    }

    function test_setGuardian() public {
        address newG = makeAddr("newG");
        vault.setGuardian(newG);
        assertEq(vault.guardian(), newG);
    }

    function test_setDistributor() public {
        address newD = makeAddr("newD");
        vault.setDistributor(newD);
        assertEq(vault.distributor(), newD);
    }

    function test_setMinClaimAmount() public {
        vault.setMinClaimAmount(50e6);
        assertEq(vault.minClaimAmount(), 50e6);
    }

    function test_setMinClaimAmount_revertsAboveMax() public {
        vm.expectRevert(ICommissionVault.ExceedsMaxMinClaim.selector);
        vault.setMinClaimAmount(101e6);
    }

    function test_setMaxCodeDelta() public {
        vault.setMaxCodeDelta(5000e6);
        assertEq(vault.maxCodeDelta(), 5000e6);
    }

    function test_setMaxCodeDelta_revertsZero() public {
        vm.expectRevert(ICommissionVault.ZeroMaxCodeDelta.selector);
        vault.setMaxCodeDelta(0);
    }

    function test_setMaxBatchDelta() public {
        vault.setMaxBatchDelta(50000e6);
        assertEq(vault.maxBatchDelta(), 50000e6);
    }

    function test_setMaxBatchDelta_revertsZero() public {
        vm.expectRevert(ICommissionVault.ZeroMaxBatchDelta.selector);
        vault.setMaxBatchDelta(0);
    }

    // ── Migration ──────────────────────────────────────────

    function test_seedClaimed_happyPath() public {
        CommissionVault v2 = new CommissionVault(
            address(usdc), distributor, operator, guardian, MAX_CODE_DELTA, MAX_BATCH_DELTA, true, TIMELOCK, PAYOUT_TIMELOCK
        );

        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = keccak256(bytes("CODE_A"));
        hashes[1] = keccak256(bytes("CODE_B"));
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50e6;
        amounts[1] = 30e6;
        address[] memory payouts = new address[](2);
        payouts[0] = affiliate1;
        payouts[1] = affiliate2;

        v2.seedClaimed(hashes, amounts, payouts);
        assertEq(v2.totalClaimed(), 80e6);
        assertEq(v2.claimed(keccak256(bytes("CODE_A"))), 50e6);
        assertEq(v2.claimed(keccak256(bytes("CODE_B"))), 30e6);
        assertEq(v2.payoutAddress(keccak256(bytes("CODE_A"))), affiliate1);
        assertEq(v2.payoutAddress(keccak256(bytes("CODE_B"))), affiliate2);
        assertEq(v2.cumulativeAmount(keccak256(bytes("CODE_A"))), 50e6);
        assertEq(v2.requiredReserve(), 0);
    }

    function test_seedClaimed_bindsPayoutAndEmitsEvent() public {
        CommissionVault v2 = new CommissionVault(
            address(usdc), distributor, operator, guardian, MAX_CODE_DELTA, MAX_BATCH_DELTA, true, TIMELOCK, PAYOUT_TIMELOCK
        );

        bytes32 h = keccak256(bytes("CODE_A"));
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = h;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e6;
        address[] memory payouts = new address[](1);
        payouts[0] = affiliate1;

        vm.expectEmit(true, true, false, true);
        emit ICommissionVault.ClaimedSeeded(h, affiliate1, 100e6);
        v2.seedClaimed(hashes, amounts, payouts);
    }

    function test_seedClaimed_revertsOnZeroPayout() public {
        CommissionVault v2 = new CommissionVault(
            address(usdc), distributor, operator, guardian, MAX_CODE_DELTA, MAX_BATCH_DELTA, true, TIMELOCK, PAYOUT_TIMELOCK
        );

        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256(bytes("CODE_A"));
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e6;
        address[] memory payouts = new address[](1);
        payouts[0] = address(0);

        vm.expectRevert(ICommissionVault.ZeroPayout.selector);
        v2.seedClaimed(hashes, amounts, payouts);
    }

    function test_seedClaimed_revertsOnLengthMismatch() public {
        CommissionVault v2 = new CommissionVault(
            address(usdc), distributor, operator, guardian, MAX_CODE_DELTA, MAX_BATCH_DELTA, true, TIMELOCK, PAYOUT_TIMELOCK
        );

        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = keccak256(bytes("CODE_A"));
        hashes[1] = keccak256(bytes("CODE_B"));
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50e6;
        amounts[1] = 30e6;
        address[] memory payouts = new address[](1);
        payouts[0] = affiliate1;

        vm.expectRevert(ICommissionVault.LengthMismatch.selector);
        v2.seedClaimed(hashes, amounts, payouts);
    }

    function test_seedClaimed_seededCodeThenRegisterReverts() public {
        CommissionVault v2 = new CommissionVault(
            address(usdc), distributor, operator, guardian, MAX_CODE_DELTA, MAX_BATCH_DELTA, true, TIMELOCK, PAYOUT_TIMELOCK
        );

        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256(bytes("SEEDED"));
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e6;
        address[] memory payouts = new address[](1);
        payouts[0] = affiliate1;
        v2.seedClaimed(hashes, amounts, payouts);
        v2.finalizeMigration();

        vm.prank(affiliate2);
        vm.expectRevert(ICommissionVault.AlreadyRegistered.selector);
        v2.registerCode("SEEDED");
    }

    function test_seedClaimed_seededCodeThenSettlementCredits() public {
        CommissionVault v2 = new CommissionVault(
            address(usdc), distributor, operator, guardian, MAX_CODE_DELTA, MAX_BATCH_DELTA, true, TIMELOCK, PAYOUT_TIMELOCK
        );

        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256(bytes("REF"));
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e6;
        address[] memory payouts = new address[](1);
        payouts[0] = affiliate1;
        v2.seedClaimed(hashes, amounts, payouts);
        v2.finalizeMigration();

        string[] memory codes = new string[](1);
        codes[0] = "REF";
        uint256[] memory cumulative = new uint256[](1);
        cumulative[0] = 150e6;
        vm.prank(operator);
        v2.proposeSettlement(codes, cumulative);
        vm.warp(block.timestamp + TIMELOCK);
        v2.activateSettlement();

        assertEq(v2.getClaimable("REF"), 50e6);
        assertEq(v2.payoutAddress(keccak256(bytes("REF"))), affiliate1);
    }

    function test_seedClaimed_revertsAfterFinalized() public {
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256(bytes("CODE_A"));
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 50e6;
        address[] memory payouts = new address[](1);
        payouts[0] = affiliate1;

        vm.expectRevert(ICommissionVault.MigrationAlreadyFinalized.selector);
        vault.seedClaimed(hashes, amounts, payouts);
    }

    function test_seedClaimed_revertsOnZeroHash() public {
        CommissionVault v2 = new CommissionVault(
            address(usdc), distributor, operator, guardian, MAX_CODE_DELTA, MAX_BATCH_DELTA, true, TIMELOCK, PAYOUT_TIMELOCK
        );

        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = bytes32(0);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 50e6;
        address[] memory payouts = new address[](1);
        payouts[0] = affiliate1;

        vm.expectRevert(ICommissionVault.ZeroCodeHash.selector);
        v2.seedClaimed(hashes, amounts, payouts);
    }

    function test_seedClaimed_revertsOnAlreadySeeded() public {
        CommissionVault v2 = new CommissionVault(
            address(usdc), distributor, operator, guardian, MAX_CODE_DELTA, MAX_BATCH_DELTA, true, TIMELOCK, PAYOUT_TIMELOCK
        );

        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256(bytes("CODE_A"));
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 50e6;
        address[] memory payouts = new address[](1);
        payouts[0] = affiliate1;

        v2.seedClaimed(hashes, amounts, payouts);

        vm.expectRevert(ICommissionVault.AlreadyKnown.selector);
        v2.seedClaimed(hashes, amounts, payouts);
    }

    function test_migrateBalance() public {
        CommissionVault v2 = new CommissionVault(
            address(usdc), distributor, operator, guardian, MAX_CODE_DELTA, MAX_BATCH_DELTA, true, TIMELOCK, PAYOUT_TIMELOCK
        );

        address oldVault = makeAddr("oldVault");
        usdc.mint(oldVault, 1000e6);

        vm.prank(oldVault);
        usdc.approve(address(v2), 1000e6);

        v2.migrateBalance(oldVault, 500e6);
        assertEq(usdc.balanceOf(address(v2)), 500e6);
    }

    function test_migrateBalance_revertsAfterFinalized() public {
        vm.expectRevert(ICommissionVault.MigrationAlreadyFinalized.selector);
        vault.migrateBalance(makeAddr("old"), 100e6);
    }

    function test_finalizeMigration() public {
        CommissionVault v2 = new CommissionVault(
            address(usdc), distributor, operator, guardian, MAX_CODE_DELTA, MAX_BATCH_DELTA, true, TIMELOCK, PAYOUT_TIMELOCK
        );
        assertFalse(v2.migrationFinalized());

        v2.finalizeMigration();
        assertTrue(v2.migrationFinalized());
    }

    // ── Ownership transfer ─────────────────────────────────

    function test_transferOwnership_twoStep() public {
        address newOwner = makeAddr("newOwner");
        vault.transferOwnership(newOwner);
        assertEq(vault.pendingOwner(), newOwner);
        assertEq(vault.owner(), owner);

        vm.prank(newOwner);
        vault.acceptOwnership();
        assertEq(vault.owner(), newOwner);
        assertEq(vault.pendingOwner(), address(0));
    }

    function test_transferOwnership_revertsZeroAddress() public {
        vm.expectRevert(ICommissionVault.ZeroAddress.selector);
        vault.transferOwnership(address(0));
    }

    function test_transferOwnership_revertsAlreadyOwner() public {
        vm.expectRevert(ICommissionVault.AlreadyOwner.selector);
        vault.transferOwnership(owner);
    }

    function test_acceptOwnership_revertsWrongCaller() public {
        vault.transferOwnership(makeAddr("newOwner"));

        vm.prank(makeAddr("random"));
        vm.expectRevert(ICommissionVault.NotPendingOwner.selector);
        vault.acceptOwnership();
    }

    // ── rescueToken ────────────────────────────────────────

    function test_rescueToken_nonUsdc() public {
        MockUSDC other = new MockUSDC();
        other.mint(address(vault), 500e6);

        address recipient = makeAddr("recipient");
        vault.rescueToken(address(other), recipient, 500e6);
        assertEq(other.balanceOf(recipient), 500e6);
    }

    function test_rescueToken_usdcFullDrainAllowed() public {
        _singleSettlement("CODE_A", affiliate1, 100e6);
        usdc.mint(address(vault), 300e6);

        address recipient = makeAddr("recipient");
        vault.rescueToken(address(usdc), recipient, 300e6);
        assertEq(usdc.balanceOf(recipient), 300e6);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function test_processIncoming_stillSizesByReserve() public {
        _singleSettlement("CODE_A", affiliate1, 100e6);
        usdc.mint(address(vault), 300e6);

        vm.prank(operator);
        vault.processIncoming();

        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(usdc.balanceOf(distributor), 200e6);
    }

    function test_rescueToken_revertsIfNotOwner() public {
        vm.prank(operator);
        vm.expectRevert(ICommissionVault.NotOwner.selector);
        vault.rescueToken(address(usdc), makeAddr("x"), 1);
    }

    // ── Batch size limit ────────────────────────────────────

    function test_proposeSettlement_revertsBatchTooLarge() public {
        uint256 count = 201;
        string[] memory codes = new string[](count);
        uint256[] memory amounts = new uint256[](count);

        // Use very small amounts to stay within delta caps
        CommissionVault largeVault =
            new CommissionVault(address(usdc), distributor, operator, guardian, 1e6, 1000e6, false, TIMELOCK, PAYOUT_TIMELOCK);

        for (uint256 i = 0; i < count; i++) {
            codes[i] = string(abi.encodePacked("C", vm.toString(i)));
            amounts[i] = 1e6;
        }

        vm.prank(operator);
        vm.expectRevert(ICommissionVault.BatchTooLarge.selector);
        largeVault.proposeSettlement(codes, amounts);
    }

    function test_processIncoming_noRevertWhenClaimedExceedsOwed() public {
        // Deploy a migration vault where seedClaimed inflates totalClaimed > totalOwed
        CommissionVault migrationVault = new CommissionVault(
            address(usdc),
            distributor,
            operator,
            guardian,
            MAX_CODE_DELTA,
            MAX_BATCH_DELTA,
            true, // isMigrationTarget
            TIMELOCK, PAYOUT_TIMELOCK
        );

        // Fund and seed claims
        usdc.mint(address(migrationVault), 1000e6);
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256(bytes("code1"));
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500e6;
        address[] memory payouts = new address[](1);
        payouts[0] = affiliate1;
        migrationVault.seedClaimed(hashes, amounts, payouts);
        migrationVault.finalizeMigration();

        // totalClaimed = 500e6, totalOwed = 0 → mustRetain should be 0, not underflow
        // All 1000e6 is surplus and should be forwarded
        vm.prank(operator);
        migrationVault.processIncoming();

        // Distributor received the full balance as surplus
        assertEq(usdc.balanceOf(distributor), 1000e6);
        assertEq(usdc.balanceOf(address(migrationVault)), 0);
    }

    function test_rescueToken_duringMigrationWindow() public {
        // Deploy a new vault with isMigrationTarget = true
        CommissionVault migrationVault = new CommissionVault(
            address(usdc),
            distributor,
            operator,
            guardian,
            MAX_CODE_DELTA,
            MAX_BATCH_DELTA,
            true, // isMigrationTarget
            TIMELOCK, PAYOUT_TIMELOCK
        );

        // Fund it with USDC
        usdc.mint(address(migrationVault), 1000e6);

        // Seed claims (bumps totalClaimed without totalOwed)
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256(bytes("code1"));
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500e6;
        address[] memory payouts = new address[](1);
        payouts[0] = affiliate1;
        migrationVault.seedClaimed(hashes, amounts, payouts);

        // Now totalClaimed = 500e6, totalOwed = 0
        // rescueToken should not revert — should allow rescuing surplus
        migrationVault.rescueToken(address(usdc), address(this), 500e6);
    }

    function test_seedClaimed_keepsReserveAfterActivation() public {
        CommissionVault v2 = new CommissionVault(
            address(usdc), distributor, operator, guardian, MAX_CODE_DELTA, MAX_BATCH_DELTA, true, TIMELOCK, PAYOUT_TIMELOCK
        );

        // REF already claimed 100 in the old vault; OLD is fully paid and inactive.
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = keccak256(bytes("REF"));
        hashes[1] = keccak256(bytes("OLD"));
        uint256[] memory seeds = new uint256[](2);
        seeds[0] = 100e6;
        seeds[1] = 200e6;
        address[] memory payouts = new address[](2);
        payouts[0] = affiliate1;
        payouts[1] = affiliate2;
        v2.seedClaimed(hashes, seeds, payouts);

        // Vault is funded with exactly what REF will be owed going forward.
        usdc.mint(address(v2), 150e6);
        v2.finalizeMigration();

        // REF earns another 150 → cumulative 250 (100 historical + 150 new).
        string[] memory codes = new string[](1);
        codes[0] = "REF";
        uint256[] memory cumulative = new uint256[](1);
        cumulative[0] = 250e6;
        vm.prank(operator);
        v2.proposeSettlement(codes, cumulative);
        vm.warp(block.timestamp + TIMELOCK);
        v2.activateSettlement();

        // Routine surplus forwarding must NOT drain REF's reserved 150.
        vm.prank(operator);
        v2.processIncoming();
        assertEq(usdc.balanceOf(address(v2)), 150e6, "REF reserve swept");
        assertEq(usdc.balanceOf(distributor), 0, "owed funds forwarded as surplus");

        // REF can claim the full 150 delta.
        vm.prank(affiliate1);
        v2.claim("REF");
        assertEq(usdc.balanceOf(affiliate1), 150e6, "REF could not claim");
    }

    // ── registerCode ────────────────────────────────────────

    function test_registerCode_bindsPayoutToSender() public {
        vm.prank(affiliate1);
        vault.registerCode("mycode");

        assertEq(vault.payoutAddress(keccak256(bytes("mycode"))), affiliate1);
    }

    function test_registerCode_emitsEvent() public {
        bytes32 codeHash = keccak256(bytes("mycode"));
        vm.expectEmit(true, true, false, true);
        emit ICommissionVault.CodeRegistered(codeHash, "mycode", affiliate1);

        vm.prank(affiliate1);
        vault.registerCode("mycode");
    }

    function test_registerCode_revertsIfAlreadyRegistered() public {
        vm.prank(affiliate1);
        vault.registerCode("mycode");

        vm.prank(affiliate2);
        vm.expectRevert(ICommissionVault.AlreadyRegistered.selector);
        vault.registerCode("mycode");
    }

    function test_registerCode_revertsIfAlreadyBoundBySettlement() public {
        _singleSettlement("settled", affiliate1, 10e6);

        vm.prank(affiliate2);
        vm.expectRevert(ICommissionVault.AlreadyRegistered.selector);
        vault.registerCode("settled");
    }

    function test_registerCode_revertsWhenPaused() public {
        vm.prank(guardian);
        vault.pause();

        vm.prank(affiliate1);
        vm.expectRevert(ICommissionVault.Paused.selector);
        vault.registerCode("mycode");
    }

    function test_registerCode_revertsWhilePendingSettlement() public {
        // A settlement is proposed for a code nobody bound yet. Until it activates,
        // cumulativeAmount is still 0, so the "Code has value" guard alone would let a
        // front-runner self-register and steal the pending value. The pending guard
        // blocks that for the whole proposed-but-not-activated window.
        string[] memory codes = new string[](1);
        codes[0] = "orphan";
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10e6;
        vm.prank(operator);
        vault.proposeSettlement(codes, amounts);

        vm.prank(affiliate2);
        vm.expectRevert(ICommissionVault.SettlementPending.selector);
        vault.registerCode("orphan");

        vm.prank(affiliate2);
        vm.expectRevert(ICommissionVault.SettlementPending.selector);
        vault.registerCode("orphan", affiliate2);
    }

    function test_registerCode_thenChangePayoutWorksImmediately() public {
        vm.prank(affiliate1);
        vault.registerCode("mycode");

        vm.prank(affiliate1);
        vault.changePayoutAddress("mycode", affiliate2);

        assertEq(vault.payoutAddress(keccak256(bytes("mycode"))), affiliate2);
    }

    function test_registerCode_settlementDoesNotRebindSelfRegistration() public {
        vm.prank(affiliate1);
        vault.registerCode("mycode");

        // Settlement passes a different address — it is ignored; the self-registered
        // payout stands.
        _singleSettlement("mycode", affiliate2, 10e6);

        assertEq(vault.payoutAddress(keccak256(bytes("mycode"))), affiliate1);
    }

    function test_registerCode_thenClaimWorksAfterSettlement() public {
        vm.prank(affiliate1);
        vault.registerCode("mycode");

        _singleSettlement("mycode", affiliate1, 10e6);
        usdc.mint(address(vault), 100e6);

        vm.prank(affiliate1);
        vault.claim("mycode");

        assertEq(usdc.balanceOf(affiliate1), 10e6);
        assertEq(vault.getClaimable("mycode"), 0);
    }

    // ── registerCode with custom payout ─────────────────────

    function test_registerCode_customPayout_bindsToGivenAddress() public {
        vm.prank(affiliate1);
        vault.registerCode("mycode", affiliate2);

        // Bound to the supplied payout, NOT the sender.
        assertEq(vault.payoutAddress(keccak256(bytes("mycode"))), affiliate2);
    }

    function test_registerCode_customPayout_zeroFallsBackToSender() public {
        vm.prank(affiliate1);
        vault.registerCode("mycode", address(0));

        assertEq(vault.payoutAddress(keccak256(bytes("mycode"))), affiliate1);
    }

    function test_registerCode_customPayout_emitsBoundPayout() public {
        bytes32 codeHash = keccak256(bytes("mycode"));
        // Event's address field carries the BOUND payout (affiliate2), not the sender.
        vm.expectEmit(true, true, false, true);
        emit ICommissionVault.CodeRegistered(codeHash, "mycode", affiliate2);

        vm.prank(affiliate1);
        vault.registerCode("mycode", affiliate2);
    }

    function test_registerCode_customPayout_revertsIfAlreadyRegistered() public {
        vm.prank(affiliate1);
        vault.registerCode("mycode", affiliate2);

        vm.prank(affiliate3);
        vm.expectRevert(ICommissionVault.AlreadyRegistered.selector);
        vault.registerCode("mycode", affiliate1);
    }

    function test_registerCode_customPayout_revertsWhenPaused() public {
        vm.prank(guardian);
        vault.pause();

        vm.prank(affiliate1);
        vm.expectRevert(ICommissionVault.Paused.selector);
        vault.registerCode("mycode", affiliate2);
    }

    function test_registerCode_customPayout_onlyThatAddressCanClaim() public {
        vm.prank(affiliate1);
        vault.registerCode("mycode", affiliate2);

        _singleSettlement("mycode", affiliate2, 10e6);
        usdc.mint(address(vault), 100e6);

        vm.prank(affiliate1);
        vm.expectRevert(ICommissionVault.WrongSender.selector);
        vault.claim("mycode");

        vm.prank(affiliate2);
        vault.claim("mycode");
        assertEq(usdc.balanceOf(affiliate2), 10e6);
    }

    function test_registerCode_customPayout_settlementDoesNotRebind() public {
        vm.prank(affiliate1);
        vault.registerCode("mycode", affiliate2);

        _singleSettlement("mycode", affiliate3, 10e6);

        // The custom payout stands; settlement's address is ignored.
        assertEq(vault.payoutAddress(keccak256(bytes("mycode"))), affiliate2);
    }

    function test_registerCode_customPayout_ownerRecoveryRepoints() public {
        vm.prank(affiliate1);
        vault.registerCode("mycode", affiliate2);

        // Owner recovery (timelocked) can still redirect a custom-bound payout.
        vault.ownerSetPayoutAddress("mycode", affiliate3);
        vm.warp(block.timestamp + vault.payoutTimelock());
        vault.activatePayoutChange("mycode");

        assertEq(vault.payoutAddress(keccak256(bytes("mycode"))), affiliate3);
    }

    function test_registerCode_zeroFallback_emitsSender() public {
        bytes32 codeHash = keccak256(bytes("mycode"));
        // The zero-address fallback path must emit the sender as the bound payout.
        vm.expectEmit(true, true, false, true);
        emit ICommissionVault.CodeRegistered(codeHash, "mycode", affiliate1);

        vm.prank(affiliate1);
        vault.registerCode("mycode", address(0));
    }

    function test_registerCode_customPayout_onlyPayoutCanChangeAddress() public {
        vm.prank(affiliate1);
        vault.registerCode("mycode", affiliate2);

        // The registrant (affiliate1) is not the payout and cannot move it.
        vm.prank(affiliate1);
        vm.expectRevert(ICommissionVault.WrongSender.selector);
        vault.changePayoutAddress("mycode", affiliate3);

        // Only the bound custom payout (affiliate2) can.
        vm.prank(affiliate2);
        vault.changePayoutAddress("mycode", affiliate3);
        assertEq(vault.payoutAddress(keccak256(bytes("mycode"))), affiliate3);
    }

    function test_registerCode_revertsWhenValueBearingUnbound() public {
        bytes32 codeHash = keccak256(bytes("squatted"));
        _craftUnboundValueBearingCode(codeHash, 100e6);
        assertEq(vault.cumulativeAmount(codeHash), 100e6);
        assertEq(vault.payoutAddress(codeHash), address(0));

        vm.prank(affiliate1);
        vm.expectRevert(ICommissionVault.CodeHasValue.selector);
        vault.registerCode("squatted");

        vm.prank(affiliate1);
        vm.expectRevert(ICommissionVault.CodeHasValue.selector);
        vault.registerCode("squatted", affiliate2);
    }

    function test_settlement_cannotRebindRegisteredPayout() public {
        // Whoever registers a code on-chain owns its payout; a settlement cannot move
        // it. (Off-chain, a code can only earn once it is registered, so the legit
        // owner always binds before there is anything to claim.)
        vm.prank(affiliate1);
        vault.registerCode("public-code");

        _singleSettlement("public-code", affiliate2, 10e6);
        usdc.mint(address(vault), 100e6);

        assertEq(vault.payoutAddress(keccak256(bytes("public-code"))), affiliate1);

        vm.prank(affiliate2);
        vm.expectRevert(ICommissionVault.WrongSender.selector);
        vault.claim("public-code");

        vm.prank(affiliate1);
        vault.claim("public-code");
        assertEq(usdc.balanceOf(affiliate1), 10e6);
    }

    function test_activateSettlement_laterSettlementPreservesPayoutChange() public {
        _singleSettlement("mycode", affiliate1, 10e6);

        vm.prank(affiliate1);
        vault.changePayoutAddress("mycode", affiliate2);

        _singleSettlement("mycode", affiliate3, 20e6);

        assertEq(vault.payoutAddress(keccak256(bytes("mycode"))), affiliate2);
    }

    function test_activateSettlement_ignoresProposedAddress() public {
        vm.prank(affiliate1);
        vault.registerCode("mycode");

        // Operator proposes a settlement — it must not touch the payout on activation.
        string[] memory codes = new string[](1);
        codes[0] = "mycode";
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10e6;
        vm.prank(operator);
        vault.proposeSettlement(codes, amounts);

        vm.warp(block.timestamp + vault.settlementTimelock());
        vault.activateSettlement();

        assertEq(vault.payoutAddress(keccak256(bytes("mycode"))), affiliate1);
    }

    function test_activateSettlement_preservesRotation() public {
        vm.prank(affiliate1);
        vault.registerCode("mycode");

        string[] memory codes = new string[](1);
        codes[0] = "mycode";
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10e6;
        vm.prank(operator);
        vault.proposeSettlement(codes, amounts);

        // Payout rotated while the settlement is pending — the rotation stands.
        vm.prank(affiliate1);
        vault.changePayoutAddress("mycode", affiliate2);

        vm.warp(block.timestamp + vault.settlementTimelock());
        vault.activateSettlement();

        assertEq(vault.payoutAddress(keccak256(bytes("mycode"))), affiliate2);
    }

    function test_activateSettlement_preservesOwnerRecovery() public {
        vm.prank(affiliate1);
        vault.registerCode("mycode");

        // Owner recovers to affiliate2 (affiliate1's key lost/compromised).
        vault.ownerSetPayoutAddress("mycode", affiliate2);

        // Operator proposes a settlement after the recovery is queued.
        string[] memory codes = new string[](1);
        codes[0] = "mycode";
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10e6;
        vm.prank(operator);
        vault.proposeSettlement(codes, amounts);

        uint256 maxTimelock = vault.payoutTimelock() > vault.settlementTimelock()
            ? vault.payoutTimelock()
            : vault.settlementTimelock();
        vm.warp(block.timestamp + maxTimelock);

        vault.activatePayoutChange("mycode");
        vault.activateSettlement();

        // Recovery is authoritative: settlement ignores the stale affiliate1.
        assertEq(vault.payoutAddress(keccak256(bytes("mycode"))), affiliate2);
    }

    function test_activateSettlement_followsRecoveryThenRotation() public {
        vm.prank(affiliate1);
        vault.registerCode("mycode");

        vault.ownerSetPayoutAddress("mycode", affiliate2);

        string[] memory codes = new string[](1);
        codes[0] = "mycode";
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10e6;
        vm.prank(operator);
        vault.proposeSettlement(codes, amounts);

        vm.warp(block.timestamp + vault.payoutTimelock());
        vault.activatePayoutChange("mycode");

        // Recovered owner rotates again before the settlement activates.
        vm.prank(affiliate2);
        vault.changePayoutAddress("mycode", affiliate3);

        vm.warp(block.timestamp + vault.settlementTimelock());
        vault.activateSettlement();

        // The live payout stands through recovery and rotation; settlement never rebinds.
        assertEq(vault.payoutAddress(keccak256(bytes("mycode"))), affiliate3);
    }

    function test_ownerRegisterCode_bindsUnboundCode() public {
        bytes32 codeHash = keccak256(bytes("c"));
        vm.expectEmit(true, true, false, true);
        emit ICommissionVault.CodeRegistered(codeHash, "c", affiliate1);

        vault.ownerRegisterCode("c", affiliate1);
        assertEq(vault.payoutAddress(codeHash), affiliate1);
    }

    function test_ownerRegisterCode_revertsWhenAlreadyBound() public {
        vm.prank(affiliate1);
        vault.registerCode("c");

        vm.expectRevert(ICommissionVault.AlreadyRegistered.selector);
        vault.ownerRegisterCode("c", affiliate2);
    }

    function test_ownerRegisterCode_revertsOnZeroPayout() public {
        vm.expectRevert(ICommissionVault.ZeroPayout.selector);
        vault.ownerRegisterCode("c", address(0));
    }

    function test_ownerRegisterCode_revertsWhenNotOwner() public {
        vm.prank(affiliate1);
        vm.expectRevert(ICommissionVault.NotOwner.selector);
        vault.ownerRegisterCode("c", affiliate1);
    }

    function test_ownerRegisterCode_worksWhileSettlementPending() public {
        // Admin can bind a code even with a settlement in flight — settlement never
        // touches the payout, so the admin registration stands.
        string[] memory codes = new string[](1);
        codes[0] = "c";
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10e6;
        vm.prank(operator);
        vault.proposeSettlement(codes, amounts);

        vault.ownerRegisterCode("c", affiliate1);
        assertEq(vault.payoutAddress(keccak256(bytes("c"))), affiliate1);

        vm.warp(block.timestamp + vault.settlementTimelock());
        vault.activateSettlement();
        assertEq(vault.payoutAddress(keccak256(bytes("c"))), affiliate1);
    }

    function test_ownerRegisterCode_worksWhenPaused() public {
        vm.prank(guardian);
        vault.pause();

        vault.ownerRegisterCode("c", affiliate1);
        assertEq(vault.payoutAddress(keccak256(bytes("c"))), affiliate1);
    }

    // ── requiredReserve ────────────────────────────────────

    function test_requiredReserve_zeroWhenNothingOwed() public view {
        assertEq(vault.requiredReserve(), 0);
    }

    function test_requiredReserve_equalsUnclaimedOwed() public {
        _singleSettlement("CODE_A", affiliate1, 150e6);
        // totalOwed = 150e6, totalClaimed = 0
        assertEq(vault.requiredReserve(), 150e6);
    }

    function test_requiredReserve_dropsAfterClaim() public {
        _singleSettlement("CODE_A", affiliate1, 150e6);
        usdc.mint(address(vault), 150e6);

        vm.prank(affiliate1);
        vault.claim("CODE_A");

        // totalOwed = 150e6, totalClaimed = 150e6 → reserve 0
        assertEq(vault.requiredReserve(), 0);
    }

    function test_requiredReserve_zeroWhenClaimedExceedsOwed() public {
        // Migration seeding can leave totalClaimed > totalOwed; reserve must floor at 0.
        CommissionVault migrationVault = new CommissionVault(
            address(usdc), distributor, operator, guardian, MAX_CODE_DELTA, MAX_BATCH_DELTA, true, TIMELOCK, PAYOUT_TIMELOCK
        );
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256(bytes("CODE_A"));
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500e6;
        address[] memory payouts = new address[](1);
        payouts[0] = affiliate1;
        migrationVault.seedClaimed(hashes, amounts, payouts);
        migrationVault.finalizeMigration();

        assertEq(migrationVault.requiredReserve(), 0);
    }

    // ── requiredTopUp ──────────────────────────────────────

    function test_requiredTopUp_zeroWhenNoReserveNeeded() public view {
        // Nothing owed and empty vault → nothing to top up.
        assertEq(vault.requiredTopUp(), 0);
    }

    function test_requiredTopUp_fullReserveWhenEmpty() public {
        _singleSettlement("CODE_A", affiliate1, 150e6);
        // reserve 150e6, balance 0 → top up the whole reserve
        assertEq(vault.requiredTopUp(), 150e6);
    }

    function test_requiredTopUp_partialWhenUnderfunded() public {
        _singleSettlement("CODE_A", affiliate1, 150e6);
        usdc.mint(address(vault), 40e6);
        // reserve 150e6, balance 40e6 → shortfall 110e6
        assertEq(vault.requiredTopUp(), 110e6);
    }

    function test_requiredTopUp_zeroWhenExactlyFunded() public {
        _singleSettlement("CODE_A", affiliate1, 150e6);
        usdc.mint(address(vault), 150e6);
        // reserve 150e6, balance 150e6 → fully funded
        assertEq(vault.requiredTopUp(), 0);
    }

    function test_requiredTopUp_zeroWhenOverFunded() public {
        _singleSettlement("CODE_A", affiliate1, 150e6);
        usdc.mint(address(vault), 500e6);
        // reserve 150e6, balance 500e6 → surplus, no top up owed
        assertEq(vault.requiredTopUp(), 0);
    }
}
