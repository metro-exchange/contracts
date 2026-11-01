// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {CommissionVault} from "../contracts/CommissionVault.sol";
import {ICommissionVault} from "../contracts/interfaces/ICommissionVault.sol";
import {MockUSDC} from "./CommissionVault.t.sol";

contract CommissionVaultMigrationSimulationTest is Test {
    MockUSDC public usdc;
    CommissionVault public oldVault;

    address public operator = makeAddr("operator");
    address public guardian = makeAddr("guardian");
    address public distributor = makeAddr("distributor");
    address public treasury = makeAddr("treasury");
    address public affiliate1 = makeAddr("affiliate1");
    address public affiliate2 = makeAddr("affiliate2");

    uint256 constant MAX_CODE_DELTA = 1000e6;
    uint256 constant MAX_BATCH_DELTA = 10000e6;
    uint256 constant TIMELOCK = 24 hours;

    function setUp() public {
        usdc = new MockUSDC();
        oldVault = _deployVault(false);
    }

    function _deployVault(bool isMigrationTarget) internal returns (CommissionVault) {
        return new CommissionVault(
            address(usdc), distributor, operator, guardian, MAX_CODE_DELTA, MAX_BATCH_DELTA, isMigrationTarget, TIMELOCK, TIMELOCK
        );
    }

    function _settle(CommissionVault vault, string memory code, address addr, uint256 cumulative) internal {
        // Settlement no longer binds a payout; bind the code first, then settle the amount.
        if (vault.payoutAddress(keccak256(bytes(code))) == address(0)) {
            vault.ownerRegisterCode(code, addr);
        }
        string[] memory codes = new string[](1);
        codes[0] = code;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = cumulative;
        vm.prank(operator);
        vault.proposeSettlement(codes, amounts);
        vm.warp(block.timestamp + TIMELOCK);
        vault.activateSettlement();
    }

    function _codes1(string memory code) internal pure returns (string[] memory codes) {
        codes = new string[](1);
        codes[0] = code;
    }

    function test_migration_fullDrainThenSeedPreservesBindings() public {
        _settle(oldVault, "codeA", affiliate1, 60e6);
        _settle(oldVault, "codeB", affiliate2, 50e6);
        _settle(oldVault, "codeA", affiliate1, 100e6);

        usdc.mint(address(oldVault), 160e6);

        vm.prank(affiliate1);
        oldVault.claim("codeA");
        assertEq(oldVault.totalClaimed(), 100e6);
        assertLt(oldVault.totalClaimed(), oldVault.totalOwed());

        oldVault.ownerDistribute(_codes1("codeB"));
        assertEq(oldVault.totalClaimed(), oldVault.totalOwed());

        uint256 remaining = usdc.balanceOf(address(oldVault));
        assertEq(remaining, 10e6);
        oldVault.rescueToken(address(usdc), treasury, remaining);
        assertEq(usdc.balanceOf(address(oldVault)), 0);

        vm.prank(guardian);
        oldVault.pause();
        vm.prank(affiliate1);
        vm.expectRevert(ICommissionVault.Paused.selector);
        oldVault.registerCode("codeC");
        vm.prank(affiliate2);
        vm.expectRevert(ICommissionVault.Paused.selector);
        oldVault.claim("codeB");

        bytes32 hA = keccak256(bytes("codeA"));
        bytes32 hB = keccak256(bytes("codeB"));

        CommissionVault newVault = _deployVault(true);
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = hA;
        hashes[1] = hB;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = oldVault.cumulativeAmount(hA);
        amounts[1] = oldVault.cumulativeAmount(hB);
        address[] memory payouts = new address[](2);
        payouts[0] = oldVault.payoutAddress(hA);
        payouts[1] = oldVault.payoutAddress(hB);
        newVault.seedClaimed(hashes, amounts, payouts);

        assertEq(newVault.payoutAddress(hA), affiliate1);
        assertEq(newVault.payoutAddress(hB), affiliate2);
        assertEq(newVault.cumulativeAmount(hA), 100e6);
        assertEq(newVault.claimed(hA), 100e6);
        assertEq(newVault.cumulativeAmount(hB), 50e6);
        assertEq(newVault.claimed(hB), 50e6);
        assertEq(newVault.requiredReserve(), 0);

        vm.prank(affiliate1);
        vm.expectRevert(ICommissionVault.AlreadyRegistered.selector);
        newVault.registerCode("codeA");

        newVault.finalizeMigration();
        _settle(newVault, "codeA", affiliate1, 130e6);
        assertEq(newVault.getClaimable("codeA"), 30e6);
        assertEq(newVault.payoutAddress(hA), affiliate1);
        assertEq(newVault.getClaimable("codeB"), 0);
    }

    function test_migration_snapshotNotFrozenUntilCancelAndPause() public {
        string[] memory codes = new string[](1);
        codes[0] = "codeA";
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e6;
        vm.prank(operator);
        oldVault.proposeSettlement(codes, amounts);

        assertTrue(oldVault.pendingActivationTime() != 0);

        vm.prank(guardian);
        oldVault.cancelSettlement();
        assertEq(oldVault.pendingActivationTime(), 0);

        vm.prank(guardian);
        oldVault.pause();
        assertTrue(oldVault.paused());
    }
}
