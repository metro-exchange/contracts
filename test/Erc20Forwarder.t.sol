// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Erc20Forwarder} from "../contracts/Erc20Forwarder.sol";
import {IErc20Forwarder} from "../contracts/interfaces/IErc20Forwarder.sol";
import {FakeUSDC as MockUSDC} from "../contracts/FakeUSDC.sol";

/// @dev Rejects ETH so rescueETH hits its failure branch.
contract RevertingRecipient {
    receive() external payable {
        revert("no eth");
    }
}

contract Erc20ForwarderTest is Test {
    Erc20Forwarder public forwarder;
    MockUSDC public usdc;

    address public owner = address(this);
    address public recipient = makeAddr("recipient");
    address public stranger = makeAddr("stranger");

    function setUp() public {
        usdc = new MockUSDC();
        forwarder = new Erc20Forwarder(address(usdc), recipient, owner);
        forwarder.unpause();
    }

    // ── Constructor ────────────────────────────────────────────

    function test_constructor_setsState() public {
        Erc20Forwarder fresh = new Erc20Forwarder(address(usdc), recipient, owner);
        assertEq(address(fresh.token()), address(usdc));
        assertEq(fresh.recipient(), recipient);
        assertEq(fresh.owner(), owner);
        assertTrue(fresh.paused());
    }

    function test_constructor_startsPausedUntilOwnerUnpauses() public {
        Erc20Forwarder fresh = new Erc20Forwarder(address(usdc), recipient, owner);
        usdc.mint(address(fresh), 1000e6);

        vm.expectRevert("Paused");
        fresh.forward();

        fresh.unpause();
        fresh.forward();
        assertEq(usdc.balanceOf(recipient), 1000e6);
    }

    function test_constructor_revertsOnZeroToken() public {
        vm.expectRevert("Zero token");
        new Erc20Forwarder(address(0), recipient, owner);
    }

    function test_constructor_revertsOnZeroRecipient() public {
        vm.expectRevert("Zero recipient");
        new Erc20Forwarder(address(usdc), address(0), owner);
    }

    function test_constructor_revertsOnTokenWithoutCode() public {
        // Wrong-chain or typo'd token address: nothing deployed there.
        vm.expectRevert("Token has no code");
        new Erc20Forwarder(makeAddr("eoa"), recipient, owner);
    }

    function test_constructor_revertsOnPrecompile() public {
        // Precompiles answer any call with data but have no code.
        vm.expectRevert("Token has no code");
        new Erc20Forwarder(address(0x04), recipient, owner);
    }

    function test_constructor_revertsOnNonTokenContract() public {
        address notAToken = address(new RevertingRecipient());
        vm.expectRevert();
        new Erc20Forwarder(notAToken, recipient, owner);
    }

    function test_constructor_revertsOnRecipientEqToken() public {
        vm.expectRevert("Recipient is token");
        new Erc20Forwarder(address(usdc), address(usdc), owner);
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert("Zero owner");
        new Erc20Forwarder(address(usdc), recipient, address(0));
    }

    function test_constructor_ownerIsNotTheDeployer() public {
        address safe = makeAddr("safe");
        vm.prank(stranger);
        Erc20Forwarder deployed = new Erc20Forwarder(address(usdc), recipient, safe);
        assertEq(deployed.owner(), safe);
    }

    function test_constructor_emitsInitialState() public {
        vm.expectEmit(true, true, false, true);
        emit IErc20Forwarder.OwnershipTransferred(address(0), owner);
        vm.expectEmit(true, true, false, true);
        emit IErc20Forwarder.RecipientUpdated(address(0), recipient);
        vm.expectEmit(false, false, false, true);
        emit IErc20Forwarder.Paused(true);
        new Erc20Forwarder(address(usdc), recipient, owner);
    }

    // ── forward ────────────────────────────────────────────────

    function test_forward_happyPath() public {
        usdc.mint(address(forwarder), 1000e6);

        vm.expectEmit(true, true, false, true);
        emit IErc20Forwarder.Forwarded(address(usdc), recipient, 1000e6);

        forwarder.forward();

        assertEq(usdc.balanceOf(address(forwarder)), 0);
        assertEq(usdc.balanceOf(recipient), 1000e6);
    }

    function test_forward_isPermissionless() public {
        usdc.mint(address(forwarder), 1000e6);

        // Anyone can trigger the sweep; funds only ever reach the configured recipient.
        vm.prank(stranger);
        forwarder.forward();

        assertEq(usdc.balanceOf(recipient), 1000e6);
    }

    function test_forward_sendsToCurrentRecipientAfterChange() public {
        address next = makeAddr("nextRecipient");
        forwarder.setRecipient(next);
        usdc.mint(address(forwarder), 1000e6);

        forwarder.forward();

        assertEq(usdc.balanceOf(next), 1000e6);
        assertEq(usdc.balanceOf(recipient), 0);
    }

    function test_forward_revertsOnZeroBalance() public {
        vm.expectRevert("Nothing to forward");
        forwarder.forward();
    }

    function test_forward_revertsWhenPaused() public {
        usdc.mint(address(forwarder), 1000e6);
        forwarder.pause();

        vm.expectRevert("Paused");
        forwarder.forward();
    }

    // ── tryForward ─────────────────────────────────────────────

    function test_tryForward_sweepsAndReturnsAmount() public {
        usdc.mint(address(forwarder), 1000e6);

        vm.expectEmit(true, true, false, true);
        emit IErc20Forwarder.Forwarded(address(usdc), recipient, 1000e6);

        uint256 forwarded = forwarder.tryForward();

        assertEq(forwarded, 1000e6);
        assertEq(usdc.balanceOf(address(forwarder)), 0);
        assertEq(usdc.balanceOf(recipient), 1000e6);
    }

    function test_tryForward_isPermissionless() public {
        usdc.mint(address(forwarder), 1000e6);

        vm.prank(stranger);
        forwarder.tryForward();

        assertEq(usdc.balanceOf(recipient), 1000e6);
    }

    function test_tryForward_returnsZeroOnEmptyBalance() public {
        vm.recordLogs();
        uint256 forwarded = forwarder.tryForward();

        assertEq(forwarded, 0);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_tryForward_returnsZeroWhenPaused() public {
        usdc.mint(address(forwarder), 1000e6);
        forwarder.pause();

        vm.recordLogs();
        uint256 forwarded = forwarder.tryForward();

        assertEq(forwarded, 0);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(usdc.balanceOf(address(forwarder)), 1000e6);
        assertEq(usdc.balanceOf(recipient), 0);
    }

    // ── setRecipient ───────────────────────────────────────────

    function test_setRecipient_happyPath() public {
        address next = makeAddr("nextRecipient");

        vm.expectEmit(true, true, false, true);
        emit IErc20Forwarder.RecipientUpdated(recipient, next);

        forwarder.setRecipient(next);
        assertEq(forwarder.recipient(), next);
    }

    function test_setRecipient_revertsOnZero() public {
        vm.expectRevert("Zero recipient");
        forwarder.setRecipient(address(0));
    }

    function test_setRecipient_revertsOnSelf() public {
        vm.expectRevert("Recipient is self");
        forwarder.setRecipient(address(forwarder));
    }

    function test_setRecipient_revertsOnToken() public {
        vm.expectRevert("Recipient is token");
        forwarder.setRecipient(address(usdc));
    }

    function test_setRecipient_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert("Not owner");
        forwarder.setRecipient(makeAddr("nextRecipient"));
    }

    // ── pause / unpause ────────────────────────────────────────

    function test_pause_unpause_togglesWithEvents() public {
        vm.expectEmit(false, false, false, true);
        emit IErc20Forwarder.Paused(true);
        forwarder.pause();
        assertTrue(forwarder.paused());

        vm.expectEmit(false, false, false, true);
        emit IErc20Forwarder.Paused(false);
        forwarder.unpause();
        assertFalse(forwarder.paused());
    }

    function test_pause_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert("Not owner");
        forwarder.pause();
    }

    function test_unpause_revertsForNonOwner() public {
        forwarder.pause();
        vm.prank(stranger);
        vm.expectRevert("Not owner");
        forwarder.unpause();
    }

    // ── rescueToken ────────────────────────────────────────────

    function test_rescueToken_happyPath() public {
        usdc.mint(address(forwarder), 1000e6);

        vm.expectEmit(true, true, false, true);
        emit IErc20Forwarder.TokenRescued(address(usdc), owner, 400e6);

        forwarder.rescueToken(address(usdc), owner, 400e6);
        assertEq(usdc.balanceOf(owner), 400e6);
        assertEq(usdc.balanceOf(address(forwarder)), 600e6);
    }

    function test_rescueToken_recoversForeignToken() public {
        // A token other than the configured one lands here; owner can still drain it.
        MockUSDC other = new MockUSDC();
        other.mint(address(forwarder), 500e6);

        forwarder.rescueToken(address(other), owner, 500e6);
        assertEq(other.balanceOf(owner), 500e6);
        assertEq(other.balanceOf(address(forwarder)), 0);
    }

    function test_rescueToken_revertsOnZeroTo() public {
        vm.expectRevert("Zero address");
        forwarder.rescueToken(address(usdc), address(0), 1);
    }

    function test_rescueToken_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert("Not owner");
        forwarder.rescueToken(address(usdc), stranger, 1);
    }

    function test_rescueToken_worksWhilePaused() public {
        // Pause only gates forward(); the rescue path must stay open.
        usdc.mint(address(forwarder), 1000e6);
        forwarder.pause();

        forwarder.rescueToken(address(usdc), owner, 1000e6);
        assertEq(usdc.balanceOf(owner), 1000e6);
    }

    // ── rescueETH ──────────────────────────────────────────────

    function test_rescueETH_happyPath() public {
        vm.deal(address(forwarder), 5 ether);
        address payable to = payable(makeAddr("ethSink"));

        vm.expectEmit(true, false, false, true);
        emit IErc20Forwarder.EthRescued(to, 2 ether);

        forwarder.rescueETH(to, 2 ether);
        assertEq(to.balance, 2 ether);
        assertEq(address(forwarder).balance, 3 ether);
    }

    function test_rescueETH_revertsOnZeroTo() public {
        vm.deal(address(forwarder), 1 ether);
        vm.expectRevert("Zero address");
        forwarder.rescueETH(address(0), 1 ether);
    }

    function test_rescueETH_revertsForNonOwner() public {
        vm.deal(address(forwarder), 1 ether);
        vm.prank(stranger);
        vm.expectRevert("Not owner");
        forwarder.rescueETH(stranger, 1 ether);
    }

    function test_rescueETH_worksWhilePaused() public {
        vm.deal(address(forwarder), 1 ether);
        address payable to = payable(makeAddr("ethSink"));
        forwarder.pause();

        forwarder.rescueETH(to, 1 ether);
        assertEq(to.balance, 1 ether);
    }

    function test_rescueETH_revertsWhenRecipientRejects() public {
        vm.deal(address(forwarder), 1 ether);
        RevertingRecipient sink = new RevertingRecipient();

        vm.expectRevert("ETH transfer failed");
        forwarder.rescueETH(address(sink), 1 ether);
    }

    // ── 2-step ownership ───────────────────────────────────────

    function test_transferOwnership_proposesPending() public {
        address next = makeAddr("nextOwner");

        vm.expectEmit(true, true, false, true);
        emit IErc20Forwarder.OwnershipTransferProposed(owner, next);

        forwarder.transferOwnership(next);
        assertEq(forwarder.pendingOwner(), next);
        assertEq(forwarder.owner(), owner);
    }

    function test_transferOwnership_zeroCancelsPendingProposal() public {
        address typo = makeAddr("typo");
        forwarder.transferOwnership(typo);

        vm.expectEmit(true, true, false, true);
        emit IErc20Forwarder.OwnershipTransferProposed(owner, address(0));
        forwarder.transferOwnership(address(0));
        assertEq(forwarder.pendingOwner(), address(0));

        vm.prank(typo);
        vm.expectRevert("Not pending owner");
        forwarder.acceptOwnership();
    }

    function test_transferOwnership_revertsOnAlreadyOwner() public {
        vm.expectRevert("Already owner");
        forwarder.transferOwnership(owner);
    }

    function test_transferOwnership_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert("Not owner");
        forwarder.transferOwnership(makeAddr("nextOwner"));
    }

    function test_acceptOwnership_transfersAndOldOwnerLosesRights() public {
        address next = makeAddr("nextOwner");
        forwarder.transferOwnership(next);

        vm.expectEmit(true, true, false, true);
        emit IErc20Forwarder.OwnershipTransferred(owner, next);

        vm.prank(next);
        forwarder.acceptOwnership();

        assertEq(forwarder.owner(), next);
        assertEq(forwarder.pendingOwner(), address(0));

        // old owner can no longer configure
        vm.expectRevert("Not owner");
        forwarder.pause();
    }

    function test_acceptOwnership_revertsForNonPending() public {
        forwarder.transferOwnership(makeAddr("nextOwner"));
        vm.prank(stranger);
        vm.expectRevert("Not pending owner");
        forwarder.acceptOwnership();
    }
}
