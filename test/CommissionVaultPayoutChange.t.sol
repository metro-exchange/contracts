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

/// Tests for the payout-address-change machinery: self-service instant change
/// (changePayoutAddress), owner recovery path (ownerSetPayoutAddress, timelocked),
/// no-clobber split storage, and lifecycle (activate/cancel).
contract CommissionVaultPayoutChangeTest is Test {
    CommissionVault public vault;
    MockUSDC public usdc;

    address public owner = address(this);
    address public operator = makeAddr("operator");
    address public guardian = makeAddr("guardian");
    address public distributor = makeAddr("distributor");

    address public affiliate = makeAddr("affiliate");
    address public newPayout = makeAddr("newPayout");
    address public otherAffiliate = makeAddr("otherAffiliate");

    uint256 constant MAX_CODE_DELTA = 1000e6;
    uint256 constant MAX_BATCH_DELTA = 10000e6;
    uint256 constant SETTLEMENT_TIMELOCK = 24 hours;
    uint256 constant PAYOUT_TIMELOCK = 24 hours;

    string constant CODE_A = "CODE_A";
    bytes32 CODE_A_HASH = keccak256(bytes(CODE_A));

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
        // Bind CODE_A on-chain to `affiliate` with 100 USDC and fund the vault.
        _settle(CODE_A, affiliate, 100e6);
        usdc.mint(address(vault), 100e6);
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

    // ── Self-service payout change (instant) ─────────────────

    function test_changePayoutAddress_currentWalletFlipsInstantly() public {
        vm.prank(affiliate);
        vault.changePayoutAddress(CODE_A, newPayout);
        assertEq(vault.payoutAddress(CODE_A_HASH), newPayout);
    }

    function test_changePayoutAddress_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit ICommissionVault.PayoutAddressChanged(CODE_A_HASH, affiliate, newPayout);
        vm.prank(affiliate);
        vault.changePayoutAddress(CODE_A, newPayout);
    }

    function test_changePayoutAddress_newAddressClaimsOldReverts() public {
        vm.prank(affiliate);
        vault.changePayoutAddress(CODE_A, newPayout);
        // Old address can no longer claim.
        vm.prank(affiliate);
        vm.expectRevert("Wrong sender");
        vault.claim(CODE_A);
        // New address claims the full accrued balance.
        vm.prank(newPayout);
        vault.claim(CODE_A);
        assertEq(usdc.balanceOf(newPayout), 100e6);
    }

    function test_changePayoutAddress_onlyCurrentSender() public {
        vm.prank(otherAffiliate);
        vm.expectRevert("Wrong sender");
        vault.changePayoutAddress(CODE_A, newPayout);
    }

    function test_changePayoutAddress_revertsZeroAddress() public {
        vm.prank(affiliate);
        vm.expectRevert("Zero address");
        vault.changePayoutAddress(CODE_A, address(0));
    }

    function test_changePayoutAddress_revertsSameAddress() public {
        vm.prank(affiliate);
        vm.expectRevert("Same address");
        vault.changePayoutAddress(CODE_A, affiliate);
    }

    function test_changePayoutAddress_revertsCodeNotOnChain() public {
        vm.prank(affiliate);
        vm.expectRevert("Code not on-chain yet");
        vault.changePayoutAddress("NEVER_BOUND", newPayout);
    }

    function test_changePayoutAddress_revertsWhileOwnerRecoveryPending() public {
        vault.ownerSetPayoutAddress(CODE_A, otherAffiliate); // owner queues recovery
        vm.prank(affiliate);
        vm.expectRevert("Change pending");
        vault.changePayoutAddress(CODE_A, newPayout);
    }

    function test_changePayoutAddress_revertsWhenPaused() public {
        vm.prank(guardian);
        vault.pause();
        vm.prank(affiliate);
        vm.expectRevert("Paused");
        vault.changePayoutAddress(CODE_A, newPayout);
    }

    function test_changePayoutAddress_settlementAfterChangeKeepsNewAddress() public {
        vm.prank(affiliate);
        vault.changePayoutAddress(CODE_A, newPayout);
        // A later settlement for the same code must NOT clobber the new address
        // (first-bind only), only bump the amount.
        _settle(CODE_A, otherAffiliate, 150e6); // stale bind addr ignored
        assertEq(vault.payoutAddress(CODE_A_HASH), newPayout);
        (, uint256 cumulative,) = vault.getEntitlement(CODE_A);
        assertEq(cumulative, 150e6);
    }

    function test_changePayoutAddress_distributeEligiblePaysNewAddress() public {
        vault.setMinClaimAmount(1);
        vm.prank(affiliate);
        vault.changePayoutAddress(CODE_A, newPayout);
        string[] memory codes = new string[](1);
        codes[0] = CODE_A;
        vm.prank(operator);
        vault.distributeEligible(codes);
        assertEq(usdc.balanceOf(newPayout), 100e6);
        assertEq(usdc.balanceOf(affiliate), 0);
    }

    // ── Lifecycle — activate / cancel / timelock ─────────────

    function test_activatePayoutChange_afterTimelockFlipsAddress() public {
        vault.ownerSetPayoutAddress(CODE_A, newPayout);
        vm.warp(block.timestamp + PAYOUT_TIMELOCK);
        vault.activatePayoutChange(CODE_A); // public
        assertEq(vault.payoutAddress(CODE_A_HASH), newPayout);
        (address queued, uint40 eff) = vault.pendingPayoutChange(CODE_A_HASH);
        assertEq(queued, address(0));
        assertEq(uint256(eff), 0);
    }

    function test_activatePayoutChange_revertsBeforeTimelock() public {
        vault.ownerSetPayoutAddress(CODE_A, newPayout);
        vm.warp(block.timestamp + PAYOUT_TIMELOCK - 1);
        vm.expectRevert("Timelock not expired");
        vault.activatePayoutChange(CODE_A);
    }

    function test_activatePayoutChange_revertsNoPending() public {
        vm.expectRevert("No pending change");
        vault.activatePayoutChange(CODE_A);
    }

    function test_cancelPayoutChange_clearsAndOldStaysActive() public {
        vault.ownerSetPayoutAddress(CODE_A, newPayout);
        vm.prank(guardian);
        vault.cancelPayoutChange(CODE_A);
        (address queued,) = vault.pendingPayoutChange(CODE_A_HASH);
        assertEq(queued, address(0));
        assertEq(vault.payoutAddress(CODE_A_HASH), affiliate, "OLD stays active after cancel");
        // A fresh owner recovery works after cancel.
        vault.ownerSetPayoutAddress(CODE_A, newPayout);
        (address requeued,) = vault.pendingPayoutChange(CODE_A_HASH);
        assertEq(requeued, newPayout);
    }

    function test_cancelPayoutChange_onlyGuardian() public {
        vault.ownerSetPayoutAddress(CODE_A, newPayout);
        vm.expectRevert("Not guardian");
        vault.cancelPayoutChange(CODE_A);
    }

    function test_cancelPayoutChange_worksWhilePaused() public {
        vault.ownerSetPayoutAddress(CODE_A, newPayout);
        vm.prank(guardian);
        vault.pause();
        vm.prank(guardian);
        vault.cancelPayoutChange(CODE_A); // must not revert while paused
        (address queued,) = vault.pendingPayoutChange(CODE_A_HASH);
        assertEq(queued, address(0));
    }

    // ── Independent clocks + no-clobber ─────────────────────

    function test_independentClocks_settlementAndChangeCoexist() public {
        // Queue a payout change on its own clock.
        vault.ownerSetPayoutAddress(CODE_A, newPayout);
        (, uint40 changeEff) = vault.pendingPayoutChange(CODE_A_HASH);

        // Simultaneously queue a settlement (its own clock, own slot).
        string[] memory codes = new string[](1);
        codes[0] = "CODE_B";
        address[] memory addrs = new address[](1);
        addrs[0] = otherAffiliate;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 50e6;
        vm.prank(operator);
        vault.proposeSettlement(codes, addrs, amounts);

        // Both pending, independent effective times.
        assertGt(uint256(changeEff), 0);
        assertGt(vault.pendingActivationTime(), 0);

        // Warp past both timelocks; each activates on its own path.
        vm.warp(block.timestamp + PAYOUT_TIMELOCK + 1);
        vault.activatePayoutChange(CODE_A);
        vault.activateSettlement();
        assertEq(vault.payoutAddress(CODE_A_HASH), newPayout);
        assertEq(vault.payoutAddress(keccak256(bytes("CODE_B"))), otherAffiliate);
    }

    /// A settlement carrying the OLD address must NOT overwrite a just-applied change.
    function test_noClobber_settlementAfterChangeKeepsNewAddress() public {
        vault.ownerSetPayoutAddress(CODE_A, newPayout);
        vm.warp(block.timestamp + PAYOUT_TIMELOCK);
        vault.activatePayoutChange(CODE_A); // address now newPayout

        // Operator proposes a settlement still carrying the OLD address (affiliate).
        string[] memory codes = new string[](1);
        codes[0] = CODE_A;
        address[] memory addrs = new address[](1);
        addrs[0] = affiliate; // stale address
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 200e6;
        vm.prank(operator);
        vault.proposeSettlement(codes, addrs, amounts);
        vm.warp(block.timestamp + SETTLEMENT_TIMELOCK);
        vault.activateSettlement();

        assertEq(vault.payoutAddress(CODE_A_HASH), newPayout, "settlement must not clobber address");
        assertEq(vault.cumulativeAmount(CODE_A_HASH), 200e6, "settlement updates amount only");
    }

    /// A settlement then a change: settlement sets amount, change sets address, no interference.
    function test_noClobber_changeAfterSettlement() public {
        // New settlement bumps amount (address stays affiliate).
        string[] memory codes = new string[](1);
        codes[0] = CODE_A;
        address[] memory addrs = new address[](1);
        addrs[0] = affiliate;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 150e6;
        vm.prank(operator);
        vault.proposeSettlement(codes, addrs, amounts);
        vm.warp(block.timestamp + SETTLEMENT_TIMELOCK);
        vault.activateSettlement();
        assertEq(vault.cumulativeAmount(CODE_A_HASH), 150e6);

        vault.ownerSetPayoutAddress(CODE_A, newPayout);
        vm.warp(block.timestamp + PAYOUT_TIMELOCK);
        vault.activatePayoutChange(CODE_A);
        assertEq(vault.payoutAddress(CODE_A_HASH), newPayout);
        assertEq(vault.cumulativeAmount(CODE_A_HASH), 150e6, "amount untouched by change");
    }

    /// After an owner-recovery change, the NEW address can claim the full pre+post-change
    /// balance; the OLD address can no longer claim.
    function test_retroactiveFlip_newClaimsFullBalanceOldCannot() public {
        vault.ownerSetPayoutAddress(CODE_A, newPayout);
        vm.warp(block.timestamp + PAYOUT_TIMELOCK);
        vault.activatePayoutChange(CODE_A);

        // OLD can't claim.
        vm.prank(affiliate);
        vm.expectRevert("Wrong sender");
        vault.claim(CODE_A);

        // NEW claims the whole 100e6 (all pre-change earnings).
        vm.prank(newPayout);
        vault.claim(CODE_A);
        assertEq(usdc.balanceOf(newPayout), 100e6);
    }

    /// During the pending owner-recovery window, OLD stays claimable and NEW cannot claim yet.
    function test_claimTargeting_duringPendingOldClaimsNewCannot() public {
        vault.ownerSetPayoutAddress(CODE_A, newPayout);
        // NEW cannot claim yet.
        vm.prank(newPayout);
        vm.expectRevert("Wrong sender");
        vault.claim(CODE_A);
        // OLD still can.
        vm.prank(affiliate);
        vault.claim(CODE_A);
        assertEq(usdc.balanceOf(affiliate), 100e6);
    }

    // ── A3: owner recovery ──────────────────────────────────

    function test_ownerSetPayoutAddress_timelockedRepoints() public {
        vault.ownerSetPayoutAddress(CODE_A, newPayout);
        (address queued, uint40 eff) = vault.pendingPayoutChange(CODE_A_HASH);
        assertEq(queued, newPayout);
        assertEq(uint256(eff), block.timestamp + PAYOUT_TIMELOCK);

        vm.warp(block.timestamp + PAYOUT_TIMELOCK);
        vault.activatePayoutChange(CODE_A);
        assertEq(vault.payoutAddress(CODE_A_HASH), newPayout);
    }

    function test_ownerSetPayoutAddress_onlyOwner() public {
        vm.prank(operator);
        vm.expectRevert("Not owner");
        vault.ownerSetPayoutAddress(CODE_A, newPayout);
    }

    function test_ownerSetPayoutAddress_revertsChangeAlreadyPending() public {
        vault.ownerSetPayoutAddress(CODE_A, newPayout);
        vm.expectRevert("Change already pending");
        vault.ownerSetPayoutAddress(CODE_A, otherAffiliate);
    }

    function test_ownerSetPayoutAddress_guardianCanCancel() public {
        vault.ownerSetPayoutAddress(CODE_A, newPayout);
        vm.prank(guardian);
        vault.cancelPayoutChange(CODE_A);
        (address queued,) = vault.pendingPayoutChange(CODE_A_HASH);
        assertEq(queued, address(0));
        assertEq(vault.payoutAddress(CODE_A_HASH), affiliate);
    }

    // ── Owner mass distribution (migration) ─────────────────

    function test_ownerDistribute_paysOwedToActivePayoutAndBumpsClaimed() public {
        _settle("CODE_B", otherAffiliate, 60e6);
        usdc.mint(address(vault), 60e6);
        uint256 totalClaimedBefore = vault.totalClaimed();

        string[] memory codes = new string[](2);
        codes[0] = CODE_A;
        codes[1] = "CODE_B";
        vault.ownerDistribute(codes);

        // Each affiliate paid their full owed balance to their active payout address.
        assertEq(usdc.balanceOf(affiliate), 100e6);
        assertEq(usdc.balanceOf(otherAffiliate), 60e6);
        assertEq(vault.claimed(CODE_A_HASH), 100e6);
        assertEq(vault.claimed(keccak256(bytes("CODE_B"))), 60e6);
        assertEq(vault.totalClaimed(), totalClaimedBefore + 160e6);
        // Reserve fully paid down → nothing left owed.
        assertEq(vault.totalOwed(), vault.totalClaimed());
    }

    function test_ownerDistribute_emitsCommissionClaimedPerCode() public {
        string[] memory codes = new string[](1);
        codes[0] = CODE_A;
        vm.expectEmit(true, true, false, true);
        emit ICommissionVault.CommissionClaimed(CODE_A_HASH, affiliate, 100e6, 100e6);
        vault.ownerDistribute(codes);
    }

    function test_ownerDistribute_skipsZeroOwedAndUnboundCodes() public {
        // CODE_A already fully claimed by the affiliate.
        vm.prank(affiliate);
        vault.claim(CODE_A);

        string[] memory codes = new string[](2);
        codes[0] = CODE_A; // owed == 0
        codes[1] = "NEVER_BOUND"; // payoutAddress == 0
        // No revert, no double-pay.
        vault.ownerDistribute(codes);
        assertEq(usdc.balanceOf(affiliate), 100e6);
        assertEq(vault.claimed(CODE_A_HASH), 100e6);
    }

    function test_ownerDistribute_skipsCodeWithPendingChange() public {
        // A payout change is in flight (owner recovery) → distribute
        // must NOT force-push to the old address, overriding the timelock.
        vault.ownerSetPayoutAddress(CODE_A, newPayout);

        string[] memory codes = new string[](1);
        codes[0] = CODE_A;
        vault.ownerDistribute(codes);

        // Nobody paid — the code is skipped while the change is pending.
        assertEq(usdc.balanceOf(affiliate), 0);
        assertEq(usdc.balanceOf(newPayout), 0);
        assertEq(vault.claimed(CODE_A_HASH), 0);

        // Once the change activates, a fresh sweep pays the NEW (safe) address.
        vm.warp(block.timestamp + PAYOUT_TIMELOCK);
        vault.activatePayoutChange(CODE_A);
        vault.ownerDistribute(codes);
        assertEq(usdc.balanceOf(newPayout), 100e6);
        assertEq(usdc.balanceOf(affiliate), 0);
    }

    function test_ownerDistribute_revertsWhenPaused() public {
        vm.prank(guardian);
        vault.pause();
        string[] memory codes = new string[](1);
        codes[0] = CODE_A;
        vm.expectRevert("Paused");
        vault.ownerDistribute(codes);
    }

    function test_ownerDistribute_emitsPaidCountNotInputLen() public {
        // Batch of 2 but only CODE_A is payable (the second is unbound) → count == 1.
        string[] memory codes = new string[](2);
        codes[0] = CODE_A;
        codes[1] = "NEVER_BOUND";
        vm.expectEmit(false, false, false, true);
        emit ICommissionVault.CommissionsDistributed(1, 100e6);
        vault.ownerDistribute(codes);
    }

    function test_ownerDistribute_onlyOwner() public {
        string[] memory codes = new string[](1);
        codes[0] = CODE_A;
        vm.prank(operator);
        vm.expectRevert("Not owner");
        vault.ownerDistribute(codes);
    }

    function test_entitlements_viewMatchesSplitMaps() public view {
        // Backward-compat view consumed by the settlement-service multicall.
        (address addr, uint256 amount) = vault.entitlements(CODE_A_HASH);
        assertEq(addr, affiliate);
        assertEq(amount, 100e6);
    }

    function test_ownerDistribute_revertsEmptyBatch() public {
        string[] memory codes = new string[](0);
        vm.expectRevert("Empty batch");
        vault.ownerDistribute(codes);
    }

    function test_ownerDistribute_reservePreservedForUnlistedCodes() public {
        // CODE_B funded + owed but NOT in the distribute batch — must stay claimable.
        _settle("CODE_B", otherAffiliate, 100e6);
        usdc.mint(address(vault), 100e6);

        string[] memory codes = new string[](1);
        codes[0] = CODE_A;
        vault.ownerDistribute(codes);

        // CODE_B untouched, still fully claimable from the retained reserve.
        assertEq(vault.claimed(keccak256(bytes("CODE_B"))), 0);
        vm.prank(otherAffiliate);
        vault.claim("CODE_B");
        assertEq(usdc.balanceOf(otherAffiliate), 100e6);
    }

    // ── A4: constructor + first-bind + reserve invariant fuzz ─

    function test_constructor_revertsShortPayoutTimelock() public {
        vm.expectRevert("Payout timelock too short");
        new CommissionVault(
            address(usdc), distributor, operator, guardian, MAX_CODE_DELTA, MAX_BATCH_DELTA, false, SETTLEMENT_TIMELOCK, 59
        );
    }

    function test_firstBind_setsAddressThenSecondSettlementDoesNotTouchIt() public {
        // CODE_A already first-bound to `affiliate` in setUp.
        assertEq(vault.payoutAddress(CODE_A_HASH), affiliate);
        // A second settlement passing a different address must NOT rebind.
        string[] memory codes = new string[](1);
        codes[0] = CODE_A;
        address[] memory addrs = new address[](1);
        addrs[0] = otherAffiliate;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 300e6;
        vm.prank(operator);
        vault.proposeSettlement(codes, addrs, amounts);
        vm.warp(block.timestamp + SETTLEMENT_TIMELOCK);
        vault.activateSettlement();
        assertEq(vault.payoutAddress(CODE_A_HASH), affiliate, "already-bound address is immutable via settlement");
    }

    /// Reserve invariant: across arbitrary interleavings of change / claim / distribute,
    /// balance >= totalOwed - totalClaimed always holds and other codes stay whole.
    function testFuzz_reserveInvariant(bool doChange, bool doDistribute, bool doClaim) public {
        // A second funded code that is never distributed/claimed here — its reserve
        // must survive whatever happens to CODE_A.
        _settle("CODE_B", otherAffiliate, 70e6);
        usdc.mint(address(vault), 70e6);

        if (doChange) {
            vault.ownerSetPayoutAddress(CODE_A, newPayout);
            vm.warp(block.timestamp + PAYOUT_TIMELOCK);
            vault.activatePayoutChange(CODE_A);
        }
        if (doDistribute) {
            string[] memory codes = new string[](1);
            codes[0] = CODE_A;
            vault.ownerDistribute(codes);
        }
        if (doClaim) {
            address active = vault.payoutAddress(CODE_A_HASH);
            if (vault.cumulativeAmount(CODE_A_HASH) > vault.claimed(CODE_A_HASH)) {
                vm.prank(active);
                vault.claim(CODE_A);
            }
        }

        uint256 balance = usdc.balanceOf(address(vault));
        uint256 mustRetain = vault.totalOwed() >= vault.totalClaimed() ? vault.totalOwed() - vault.totalClaimed() : 0;
        assertGe(balance, mustRetain, "reserve invariant violated");
        // CODE_B always remains fully payable regardless of CODE_A activity.
        assertGe(balance, 70e6, "unlisted code reserve consumed");
    }
}
