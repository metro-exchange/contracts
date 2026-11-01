// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ICommissionVault {
    struct PendingPayoutChange {
        address newPayout;
        uint40 effectiveAt;
    }

    // ── Views ──────────────────────────────────────────────────
    function entitlements(bytes32 codeHash) external view returns (address payoutAddress, uint256 cumulativeAmount);
    function payoutAddress(bytes32 codeHash) external view returns (address);
    function cumulativeAmount(bytes32 codeHash) external view returns (uint256);
    function claimed(bytes32 codeHash) external view returns (uint256);
    function pendingPayoutChange(bytes32 codeHash) external view returns (address newPayout, uint40 effectiveAt);
    function totalOwed() external view returns (uint256);
    function totalClaimed() external view returns (uint256);
    function pendingActivationTime() external view returns (uint256);
    function minClaimAmount() external view returns (uint256);
    function maxCodeDelta() external view returns (uint256);
    function maxBatchDelta() external view returns (uint256);
    function migrationFinalized() external view returns (bool);
    function settlementTimelock() external view returns (uint256);
    function payoutTimelock() external view returns (uint256);
    function requiredReserve() external view returns (uint256);
    function requiredTopUp() external view returns (uint256);
    function usdc() external view returns (IERC20);

    function getClaimable(string calldata code) external view returns (uint256);
    function getEntitlement(string calldata code)
        external
        view
        returns (address payoutAddress, uint256 cumulativeAmount, uint256 claimedAmount);

    // ── Operator ───────────────────────────────────────────────
    function proposeSettlement(string[] calldata codes, uint256[] calldata cumulativeAmounts) external;
    function processIncoming() external;

    // ── Anyone (after timelock) ────────────────────────────────
    function activateSettlement() external;
    function activatePayoutChange(string calldata code) external;

    // ── Affiliate ──────────────────────────────────────────────
    function claim(string calldata code) external;
    function registerCode(string calldata code) external;
    function registerCode(string calldata code, address payout) external;

    // ── Affiliate: self-service payout change ──────────────────
    function changePayoutAddress(string calldata code, address newPayout) external;

    // ── Operator / Guardian / Owner ────────────────────────────
    function distributeEligible(string[] calldata codes) external;

    // ── Guardian ───────────────────────────────────────────────
    function cancelSettlement() external;
    function cancelPayoutChange(string calldata code) external;
    function pause() external;

    // ── Owner ──────────────────────────────────────────────────
    function unpause() external;
    function ownerSetPayoutAddress(string calldata code, address newPayout) external;
    function ownerRegisterCode(string calldata code, address payout) external;
    function ownerDistribute(string[] calldata codes) external;
    function setOperator(address newOperator) external;
    function setGuardian(address newGuardian) external;
    function setDistributor(address newDistributor) external;
    function setMinClaimAmount(uint256 newMinClaimAmount) external;
    function setMaxCodeDelta(uint256 newMaxCodeDelta) external;
    function setMaxBatchDelta(uint256 newMaxBatchDelta) external;
    function seedClaimed(bytes32[] calldata codeHashes, uint256[] calldata amounts, address[] calldata payouts) external;
    function migrateBalance(address oldVault, uint256 amount) external;
    function finalizeMigration() external;
    function rescueToken(address token, address to, uint256 amount) external;
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
    function pendingOwner() external view returns (address);

    // ── Errors ─────────────────────────────────────────────────
    error BatchTooLarge();
    error ZeroAddress();
    error EmptyBatch();
    error ZeroPayout();
    error ZeroOperator();
    error ZeroMaxCodeDelta();
    error ZeroMaxBatchDelta();
    error ZeroGuardian();
    error ZeroDistributor();
    error WrongSender();
    error TimelockNotExpired();
    error NoPendingSettlement();
    error NoPendingChange();
    error MigrationAlreadyFinalized();
    error LengthMismatch();
    error CodeNotOnChain();
    error AlreadyRegistered();
    error ZeroCodeHash();
    error ZeroAmount();
    error ZeroUSDC();
    error VaultUnderfunded();
    error TimelockTooShort();
    error SettlementPending();
    error SameAddress();
    error PendingSettlementExists();
    error PayoutTimelockTooShort();
    error Paused();
    error NothingToClaim();
    error NotPendingOwner();
    error NotOwner();
    error NotOperator();
    error NotGuardian();
    error NotAuthorized();
    error MigrationNotFinalized();
    error ExceedsMaxMinClaim();
    error ExceedsMaxCodeDelta();
    error ExceedsMaxBatchDelta();
    error DuplicateCodeInBatch();
    error CodeHasValue();
    error ChangePending();
    error ChangeAlreadyPending();
    error CannotDecreaseAmount();
    error BelowMinimumClaim();
    error AlreadyOwner();
    error AlreadyKnown();

    // ── Events ─────────────────────────────────────────────────
    event SettlementProposed(uint256 activationTime, uint256 codeCount, uint256 totalIncrease);
    event SettlementActivated(uint256 codeCount, uint256 totalIncrease);
    event SettlementCancelled();
    event EntitlementUpdated(bytes32 indexed codeHash, address payoutAddress, uint256 cumulativeAmount);
    event CommissionClaimed(bytes32 indexed codeHash, address indexed affiliate, uint256 amount, uint256 totalClaimed);
    event IncomingProcessed(uint256 retained, uint256 forwarded);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    event DistributorUpdated(address indexed oldDistributor, address indexed newDistributor);
    event MinClaimAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event MaxCodeDeltaUpdated(uint256 oldValue, uint256 newValue);
    event MaxBatchDeltaUpdated(uint256 oldValue, uint256 newValue);
    event MigrationFinalized();
    event ClaimedSeeded(bytes32 indexed codeHash, address indexed payout, uint256 amount);
    event BalanceMigrated(address indexed oldVault, uint256 amount);
    event OwnershipTransferProposed(address indexed currentOwner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // Self-service on-chain code registration (ENG-2402)
    // `payout` is the address the code is bound to — the custom payout when one is
    // supplied to registerCode, otherwise the registering wallet. Not necessarily the sender.
    event CodeRegistered(bytes32 indexed codeHash, string code, address indexed payout);

    // Payout address changes
    event PayoutAddressChanged(bytes32 indexed codeHash, address oldPayout, address newPayout);
    event PayoutChangeActivated(bytes32 indexed codeHash, address oldPayout, address newPayout);
    event PayoutChangeCancelled(bytes32 indexed codeHash, address cancelledPayout);
    event OwnerPayoutChangeProposed(bytes32 indexed codeHash, address newPayout, uint256 effectiveAt);

    // Owner mass distribution (migration): per-code payouts emit CommissionClaimed;
    // this is the batch summary.
    event CommissionsDistributed(uint256 codeCount, uint256 totalPaid);

    // Backend-triggered threshold payout (ENG-2384): per-code payouts emit
    // CommissionClaimed; this is the batch summary. skippedCount counts input
    // codes not paid (unbound, pending payout change, zero owed, or below
    // minClaimAmount).
    event EligibleDistribution(address indexed caller, uint256 paidCount, uint256 totalPaid, uint256 skippedCount);
}
