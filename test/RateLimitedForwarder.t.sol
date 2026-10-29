// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {RateLimitedForwarder} from "../contracts/RateLimitedForwarder.sol";
import {IRateLimitedForwarder} from "../contracts/interfaces/IRateLimitedForwarder.sol";
import {IErc20Forwarder} from "../contracts/interfaces/IErc20Forwarder.sol";
import {FakeUSDC as MockUSDC} from "../contracts/FakeUSDC.sol";

/// @dev A deployed contract that is not an ERC20, so the constructor's balanceOf probe reverts.
contract NonTokenContract {}

contract RateLimitedForwarderTest is Test {
    RateLimitedForwarder public forwarder;
    MockUSDC public usdc;

    address public owner = address(this);
    address public recipient = makeAddr("recipient");
    address public stranger = makeAddr("stranger");

    function setUp() public {
        usdc = new MockUSDC();
        forwarder = new RateLimitedForwarder(address(usdc), recipient, owner, 0, 0, 0);
        forwarder.unpause();
    }

    function test_constructor_setsState() public {
        RateLimitedForwarder fresh = new RateLimitedForwarder(address(usdc), recipient, owner, 0, 0, 0);
        assertEq(address(fresh.token()), address(usdc));
        assertEq(fresh.recipient(), recipient);
        assertEq(fresh.owner(), owner);
        assertTrue(fresh.paused());
        assertEq(fresh.dripRate(), 0);
        assertEq(fresh.lastAccrual(), block.timestamp);
        assertEq(fresh.bucket(), 0);
    }

    function test_constructor_startsPausedUntilOwnerUnpauses() public {
        RateLimitedForwarder fresh = new RateLimitedForwarder(address(usdc), recipient, owner, 0, 0, 0);
        usdc.mint(address(fresh), 1000e6);
        vm.expectRevert("Paused");
        fresh.forward();
        fresh.unpause();
        fresh.forward();
        assertEq(usdc.balanceOf(recipient), 1000e6);
    }

    function test_constructor_revertsOnZeroPeriodWithRate() public {
        vm.expectRevert("Zero period");
        new RateLimitedForwarder(address(usdc), recipient, owner, 100e6, 0, 300e6);
    }

    function test_constructor_revertsOnZeroToken() public {
        vm.expectRevert("Zero token");
        new RateLimitedForwarder(address(0), recipient, owner, 0, 0, 0);
    }

    function test_constructor_revertsOnTokenWithoutCode() public {
        vm.expectRevert("Token has no code");
        new RateLimitedForwarder(makeAddr("eoa"), recipient, owner, 0, 0, 0);
    }

    function test_constructor_revertsOnPrecompile() public {
        vm.expectRevert("Token has no code");
        new RateLimitedForwarder(address(0x04), recipient, owner, 0, 0, 0);
    }

    function test_constructor_revertsOnNonTokenContract() public {
        address notAToken = address(new NonTokenContract());
        vm.expectRevert();
        new RateLimitedForwarder(notAToken, recipient, owner, 0, 0, 0);
    }

    function test_constructor_revertsOnZeroRecipient() public {
        vm.expectRevert("Zero recipient");
        new RateLimitedForwarder(address(usdc), address(0), owner, 0, 0, 0);
    }

    function test_constructor_revertsOnRecipientEqToken() public {
        vm.expectRevert("Recipient is token");
        new RateLimitedForwarder(address(usdc), address(usdc), owner, 0, 0, 0);
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert("Zero owner");
        new RateLimitedForwarder(address(usdc), recipient, address(0), 0, 0, 0);
    }

    function test_constructor_ownerIsNotTheDeployer() public {
        address safe = makeAddr("safe");
        vm.prank(stranger);
        RateLimitedForwarder deployed = new RateLimitedForwarder(address(usdc), recipient, safe, 0, 0, 0);
        assertEq(deployed.owner(), safe);
    }

    function test_constructor_emitsInitialState() public {
        vm.expectEmit(true, true, false, true);
        emit IErc20Forwarder.OwnershipTransferred(address(0), owner);
        vm.expectEmit(true, true, false, true);
        emit IErc20Forwarder.RecipientUpdated(address(0), recipient);
        vm.expectEmit(false, false, false, true);
        emit IRateLimitedForwarder.DripLimitUpdated(100e6, 3600, 300e6);
        vm.expectEmit(false, false, false, true);
        emit IErc20Forwarder.Paused(true);
        new RateLimitedForwarder(address(usdc), recipient, owner, 100e6, 3600, 300e6);
    }

    function test_forward_disabled_fullSweep() public {
        usdc.mint(address(forwarder), 1000e6);
        vm.expectEmit(true, true, false, true);
        emit IErc20Forwarder.Forwarded(address(usdc), recipient, 1000e6);
        forwarder.forward();
        assertEq(usdc.balanceOf(address(forwarder)), 0);
        assertEq(usdc.balanceOf(recipient), 1000e6);
    }

    function test_forward_isPermissionless() public {
        usdc.mint(address(forwarder), 1000e6);
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

    function test_tryForward_disabled_sweepsAndReturnsAmount() public {
        usdc.mint(address(forwarder), 1000e6);
        uint256 forwarded = forwarder.tryForward();
        assertEq(forwarded, 1000e6);
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
    }

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
        forwarder.setRecipient(makeAddr("x"));
    }

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

    function test_rescueToken_happyPath() public {
        usdc.mint(address(forwarder), 1000e6);
        vm.expectEmit(true, true, false, true);
        emit IErc20Forwarder.TokenRescued(address(usdc), owner, 400e6);
        forwarder.rescueToken(address(usdc), owner, 400e6);
        assertEq(usdc.balanceOf(owner), 400e6);
        assertEq(usdc.balanceOf(address(forwarder)), 600e6);
    }

    function test_rescueToken_recoversForeignToken() public {
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
        usdc.mint(address(forwarder), 1000e6);
        forwarder.pause();
        forwarder.rescueToken(address(usdc), owner, 1000e6);
        assertEq(usdc.balanceOf(owner), 1000e6);
    }

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
        vm.expectRevert("Not owner");
        forwarder.pause();
    }

    function test_acceptOwnership_revertsForNonPending() public {
        forwarder.transferOwnership(makeAddr("nextOwner"));
        vm.prank(stranger);
        vm.expectRevert("Not pending owner");
        forwarder.acceptOwnership();
    }

    function _limited() internal returns (RateLimitedForwarder f) {
        f = new RateLimitedForwarder(address(usdc), recipient, owner, 100e6, 3600, 300e6);
        f.unpause();
    }

    function test_accrual_halfPeriod() public {
        RateLimitedForwarder f = _limited();
        usdc.mint(address(f), 1000e6);
        skip(1800);
        assertEq(f.availableBalance(), 50e6);
    }

    function test_accrual_fullPeriod() public {
        RateLimitedForwarder f = _limited();
        usdc.mint(address(f), 1000e6);
        skip(3600);
        assertEq(f.availableBalance(), 100e6);
    }

    function test_cap_atMaxReserve() public {
        RateLimitedForwarder f = _limited();
        usdc.mint(address(f), 1000e6);
        skip(100 * 3600);
        assertEq(f.availableBalance(), 300e6);
    }

    function test_cap_limitedByBalance() public {
        RateLimitedForwarder f = _limited();
        usdc.mint(address(f), 40e6);
        skip(3600);
        assertEq(f.availableBalance(), 40e6);
    }

    function test_cap_maxReserveZero_releasesNothing() public {
        RateLimitedForwarder f = new RateLimitedForwarder(address(usdc), recipient, owner, 100e6, 3600, 0);
        f.unpause();
        usdc.mint(address(f), 1000e6);
        skip(100 * 3600);
        assertEq(f.availableBalance(), 0);
    }

    function test_cap_maxReserveBelowRate_clampsBelowOnePeriod() public {
        RateLimitedForwarder f = new RateLimitedForwarder(address(usdc), recipient, owner, 100e6, 3600, 40e6);
        f.unpause();
        usdc.mint(address(f), 1000e6);
        skip(3600);
        assertEq(f.availableBalance(), 40e6);
    }

    function test_forward_releasesOnlyAccruedSlice() public {
        RateLimitedForwarder f = _limited();
        usdc.mint(address(f), 1000e6);
        skip(3600);
        f.forward();
        assertEq(usdc.balanceOf(recipient), 100e6);
        assertEq(usdc.balanceOf(address(f)), 900e6);
    }

    function test_forward_secondCallSamePeriodReverts() public {
        RateLimitedForwarder f = _limited();
        usdc.mint(address(f), 1000e6);
        skip(3600);
        f.forward();
        vm.expectRevert("Nothing to forward");
        f.forward();
    }

    function test_partialRelease_keepsRemainder() public {
        RateLimitedForwarder f = _limited();
        usdc.mint(address(f), 40e6);
        skip(3600);
        f.forward();
        assertEq(usdc.balanceOf(recipient), 40e6);
        assertEq(f.bucket(), 60e6);
        usdc.mint(address(f), 1000e6);
        f.forward();
        assertEq(usdc.balanceOf(recipient), 100e6);
    }

    function test_reserve_disabledNeverTouchesBucket() public {
        usdc.mint(address(forwarder), 1000e6);
        forwarder.forward();
        assertEq(usdc.balanceOf(recipient), 1000e6);
        assertEq(forwarder.bucket(), 0);
    }

    function test_availableBalance_isPureView() public {
        RateLimitedForwarder f = _limited();
        usdc.mint(address(f), 1000e6);
        skip(3600);
        uint256 bucketBefore = f.bucket();
        uint256 accrualBefore = f.lastAccrual();
        uint256 preview = f.availableBalance();
        assertEq(f.bucket(), bucketBefore);
        assertEq(f.lastAccrual(), accrualBefore);
        f.forward();
        assertEq(usdc.balanceOf(recipient), preview);
    }

    function test_availableBalance_zeroWhenPaused() public {
        RateLimitedForwarder f = _limited();
        usdc.mint(address(f), 1000e6);
        skip(3600);
        vm.prank(owner);
        f.pause();
        assertEq(f.availableBalance(), 0);
    }

    function test_pause_freezesAccrualAndUnpauseResumes() public {
        RateLimitedForwarder f = _limited();
        usdc.mint(address(f), 1000e6);
        skip(3600);
        f.pause();
        assertEq(f.bucket(), 100e6);
        skip(100 * 3600);
        f.unpause();
        assertEq(f.availableBalance(), 100e6);
        skip(1800);
        assertEq(f.availableBalance(), 150e6);
    }

    function test_tryForward_returnsZeroWhenBucketEmpty() public {
        RateLimitedForwarder f = _limited();
        usdc.mint(address(f), 1000e6);
        vm.recordLogs();
        uint256 forwarded = f.tryForward();
        assertEq(forwarded, 0);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(usdc.balanceOf(address(f)), 1000e6);
    }

    function test_accrual_frequentCallsDoNotStarve() public {
        RateLimitedForwarder f = new RateLimitedForwarder(address(usdc), recipient, owner, 1, 3600, 3);
        f.unpause();
        usdc.mint(address(f), 1000e6);
        for (uint256 i = 0; i < 300; i++) {
            skip(12);
            f.tryForward();
        }
        assertEq(usdc.balanceOf(recipient), 1);
    }

    function test_accrual_largeRealisticRate_noOverflow() public {
        RateLimitedForwarder f =
            new RateLimitedForwarder(address(usdc), recipient, owner, 1_000_000e6, 3600, 3_000_000e6);
        f.unpause();
        usdc.mint(address(f), 10_000_000e6);
        skip(3600);
        assertEq(f.availableBalance(), 1_000_000e6);
    }

    function test_setDripLimit_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert("Not owner");
        forwarder.setDripLimit(100e6, 3600, 300e6);
    }

    function test_setDripLimit_revertsOnZeroPeriodWithRate() public {
        vm.expectRevert("Zero period");
        forwarder.setDripLimit(100e6, 0, 300e6);
    }

    function test_setDripLimit_emitsAndStores() public {
        vm.expectEmit(false, false, false, true);
        emit IRateLimitedForwarder.DripLimitUpdated(100e6, 3600, 300e6);
        forwarder.setDripLimit(100e6, 3600, 300e6);
        assertEq(forwarder.dripRate(), 100e6);
        assertEq(forwarder.dripPeriod(), 3600);
        assertEq(forwarder.maxReserve(), 300e6);
    }

    function test_setDripLimit_enablingFromDisabledStartsClockFresh() public {
        skip(10000);
        forwarder.setDripLimit(100e6, 3600, 300e6);
        assertEq(forwarder.lastAccrual(), block.timestamp);
        assertEq(forwarder.bucket(), 0);
    }

    function test_setDripLimit_settlesUnderOldRateNotNew() public {
        RateLimitedForwarder f = _limited();
        usdc.mint(address(f), 1000e6);
        skip(3600);
        f.setDripLimit(200e6, 3600, 300e6);
        assertEq(f.bucket(), 100e6);
        assertEq(f.lastAccrual(), block.timestamp);
        assertEq(f.dripRate(), 200e6);
    }

    function test_setDripLimit_refillsUnderOldRateThenClamps() public {
        RateLimitedForwarder f = _limited();
        usdc.mint(address(f), 1000e6);
        skip(3600);
        f.setDripLimit(200e6, 3600, 50e6);
        assertEq(f.bucket(), 50e6);
        assertEq(f.lastAccrual(), block.timestamp);
        assertEq(f.dripRate(), 200e6);
    }

    function test_setDripLimit_reEnableAfterDisableStartsFresh() public {
        RateLimitedForwarder f = _limited();
        usdc.mint(address(f), 1000e6);
        skip(3600);
        f.setDripLimit(0, 0, 300e6);
        assertEq(f.bucket(), 100e6);
        skip(5000);
        f.setDripLimit(100e6, 3600, 300e6);
        assertEq(f.bucket(), 0);
        assertEq(f.lastAccrual(), block.timestamp);
    }

    function test_setDripLimit_pausedDoesNotCreditAccruedInterval() public {
        RateLimitedForwarder f = _limited();
        usdc.mint(address(f), 1000e6);
        skip(3600);
        f.pause();
        assertEq(f.bucket(), 100e6);
        skip(100 * 3600);
        f.setDripLimit(100e6, 3600, 300e6);
        assertEq(f.bucket(), 100e6);
        assertEq(f.lastAccrual(), block.timestamp);
        assertEq(f.dripRate(), 100e6);
        f.setDripLimit(100e6, 3600, 50e6);
        assertEq(f.bucket(), 50e6);
    }

    function test_setDripLimit_pausedThenUnpauseCannotDrainReserve() public {
        RateLimitedForwarder f = new RateLimitedForwarder(address(usdc), recipient, owner, 100e6, 3600, 300e6);
        usdc.mint(address(f), 1000e6);
        skip(100 * 3600);
        f.setDripLimit(100e6, 3600, 300e6);
        assertEq(f.bucket(), 0);
        assertEq(f.lastAccrual(), block.timestamp);
        f.unpause();
        assertEq(f.availableBalance(), 0);
        skip(3600);
        assertEq(f.availableBalance(), 100e6);
        f.forward();
        assertEq(usdc.balanceOf(recipient), 100e6);
        assertEq(usdc.balanceOf(address(f)), 900e6);
    }

    function test_setDripLimit_pausedDisableThenReEnableClearsRetainedCredit() public {
        RateLimitedForwarder f = _limited();
        usdc.mint(address(f), 1000e6);
        skip(3600);
        f.pause();
        assertEq(f.bucket(), 100e6);
        f.setDripLimit(0, 0, 300e6);
        assertEq(f.bucket(), 100e6);
        skip(100 * 3600);
        f.setDripLimit(100e6, 3600, 300e6);
        assertEq(f.bucket(), 0);
        assertEq(f.lastAccrual(), block.timestamp);
        assertEq(f.dripRate(), 100e6);
    }

    function test_rescueToken_bypassesLimit() public {
        RateLimitedForwarder f = _limited();
        usdc.mint(address(f), 1000e6);
        f.rescueToken(address(usdc), owner, 1000e6);
        assertEq(usdc.balanceOf(owner), 1000e6);
        assertEq(usdc.balanceOf(address(f)), 0);
    }
}
