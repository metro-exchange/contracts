// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ICommissionVault} from "./interfaces/ICommissionVault.sol";

contract CommissionVault is ICommissionVault, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint256 public immutable settlementTimelock;
    // Independent clock for owner payout changes —
    // deliberately NOT the settlement slot's timelock.
    uint256 public immutable payoutTimelock;
    uint256 public constant MAX_MIN_CLAIM_AMOUNT = 100e6;
    uint256 public constant MAX_BATCH_SIZE = 200;

    IERC20 public immutable usdc;

    address public owner;
    address public operator;
    address public guardian;
    address public pendingOwner;
    address public distributor;
    bool public paused;

    // Split entitlement storage (HARD requirement: settlement writes ONLY the
    // amount, payout changes write ONLY the address — they must never clobber).
    mapping(bytes32 => address) public payoutAddress;
    mapping(bytes32 => uint256) public cumulativeAmount;
    // Cumulative claimed per code
    mapping(bytes32 => uint256) public claimed;

    // Pending settlement state: proposed cumulative amount per code, plus a
    // per-code in-batch dedup marker.
    mapping(bytes32 => uint256) internal _pendingAmount;
    mapping(bytes32 => bool) internal _pendingInBatch;
    bytes32[] internal _pendingCodeHashes;
    uint256 public pendingActivationTime;

    // Single pending payout change per code, on its own independent clock.
    mapping(bytes32 => PendingPayoutChange) public pendingPayoutChange;

    // Aggregate counters
    uint256 public totalOwed;
    uint256 public totalClaimed;

    // Configuration
    uint256 public maxCodeDelta;
    uint256 public maxBatchDelta;
    uint256 public minClaimAmount;

    // Migration
    bool public migrationFinalized;

    // ── Modifiers ─────────────────────────────────────────────

    modifier onlyOwner() {
        if (!(msg.sender == owner)) revert NotOwner();
        _;
    }

    modifier onlyOperator() {
        if (!(msg.sender == operator)) revert NotOperator();
        _;
    }

    modifier onlyGuardian() {
        if (!(msg.sender == guardian)) revert NotGuardian();
        _;
    }

    modifier whenNotPaused() {
        if (!(!paused)) revert Paused();
        _;
    }

    // ── Constructor ───────────────────────────────────────────

    constructor(
        address _usdc,
        address _distributor,
        address _operator,
        address _guardian,
        uint256 _maxCodeDelta,
        uint256 _maxBatchDelta,
        bool _isMigrationTarget,
        uint256 _settlementTimelock,
        uint256 _payoutTimelock
    ) {
        if (!(_usdc != address(0))) revert ZeroUSDC();
        if (!(_distributor != address(0))) revert ZeroDistributor();
        if (!(_operator != address(0))) revert ZeroOperator();
        if (!(_guardian != address(0))) revert ZeroGuardian();
        if (!(_maxCodeDelta > 0)) revert ZeroMaxCodeDelta();
        if (!(_maxBatchDelta > 0)) revert ZeroMaxBatchDelta();
        if (!(_settlementTimelock >= 1 minutes)) revert TimelockTooShort();
        if (!(_payoutTimelock >= 1 minutes)) revert PayoutTimelockTooShort();

        usdc = IERC20(_usdc);
        distributor = _distributor;
        owner = msg.sender;
        operator = _operator;
        guardian = _guardian;
        maxCodeDelta = _maxCodeDelta;
        maxBatchDelta = _maxBatchDelta;
        migrationFinalized = !_isMigrationTarget;
        settlementTimelock = _settlementTimelock;
        payoutTimelock = _payoutTimelock;
    }

    // ── Operator functions ────────────────────────────────────

    /// @inheritdoc ICommissionVault
    function proposeSettlement(
        string[] calldata codes,
        uint256[] calldata cumulativeAmounts
    ) external onlyOperator whenNotPaused {
        uint256 len = codes.length;
        if (!(len > 0)) revert EmptyBatch();
        if (!(len == cumulativeAmounts.length)) revert LengthMismatch();
        if (!(len <= MAX_BATCH_SIZE)) revert BatchTooLarge();
        if (!(_pendingCodeHashes.length == 0)) revert PendingSettlementExists();

        uint256 batchIncrease = 0;

        for (uint256 i = 0; i < len; i++) {
            bytes32 codeHash = keccak256(bytes(codes[i]));
            if (!(!_pendingInBatch[codeHash])) revert DuplicateCodeInBatch();

            uint256 currentAmount = cumulativeAmount[codeHash];
            if (!(cumulativeAmounts[i] >= currentAmount)) revert CannotDecreaseAmount();

            uint256 increase = cumulativeAmounts[i] - currentAmount;
            if (!(increase <= maxCodeDelta)) revert ExceedsMaxCodeDelta();
            batchIncrease += increase;

            _pendingAmount[codeHash] = cumulativeAmounts[i];
            _pendingInBatch[codeHash] = true;
            _pendingCodeHashes.push(codeHash);
        }

        if (!(batchIncrease <= maxBatchDelta)) revert ExceedsMaxBatchDelta();

        pendingActivationTime = block.timestamp + settlementTimelock;

        emit SettlementProposed(pendingActivationTime, len, batchIncrease);
    }

    /// @inheritdoc ICommissionVault
    function processIncoming() external onlyOperator whenNotPaused nonReentrant {
        if (!(migrationFinalized)) revert MigrationNotFinalized();

        uint256 balance = usdc.balanceOf(address(this));
        uint256 mustRetain = requiredReserve();

        if (balance <= mustRetain) {
            return;
        }

        uint256 surplus = balance - mustRetain;
        usdc.safeTransfer(distributor, surplus);

        emit IncomingProcessed(mustRetain, surplus);
    }

    // ── Public functions ──────────────────────────────────────

    /// @inheritdoc ICommissionVault
    function activateSettlement() external whenNotPaused {
        uint256 len = _pendingCodeHashes.length;
        if (!(len > 0)) revert NoPendingSettlement();
        if (!(block.timestamp >= pendingActivationTime)) revert TimelockNotExpired();

        uint256 totalIncrease = 0;

        for (uint256 i = 0; i < len; i++) {
            bytes32 codeHash = _pendingCodeHashes[i];
            uint256 newAmount = _pendingAmount[codeHash];
            uint256 priorAmount = cumulativeAmount[codeHash];

            totalIncrease += newAmount - priorAmount;
            cumulativeAmount[codeHash] = newAmount;

            delete _pendingAmount[codeHash];
            delete _pendingInBatch[codeHash];

            emit EntitlementUpdated(codeHash, payoutAddress[codeHash], newAmount);
        }

        totalOwed += totalIncrease;

        delete _pendingCodeHashes;
        pendingActivationTime = 0;

        emit SettlementActivated(len, totalIncrease);
    }

    /// @inheritdoc ICommissionVault
    function claim(string calldata code) external whenNotPaused nonReentrant {
        bytes32 codeHash = keccak256(bytes(code));

        if (!(msg.sender == payoutAddress[codeHash])) revert WrongSender();

        uint256 cumulative = cumulativeAmount[codeHash];
        uint256 alreadyClaimed = claimed[codeHash];
        if (!(cumulative > alreadyClaimed)) revert NothingToClaim();

        uint256 claimable = cumulative - alreadyClaimed;
        if (!(claimable >= minClaimAmount)) revert BelowMinimumClaim();

        uint256 balance = usdc.balanceOf(address(this));
        if (!(claimable <= balance)) revert VaultUnderfunded();

        claimed[codeHash] = cumulative;
        totalClaimed += claimable;

        usdc.safeTransfer(msg.sender, claimable);

        emit CommissionClaimed(codeHash, msg.sender, claimable, claimed[codeHash]);
    }

    // ── Payout address changes ──

    /// @inheritdoc ICommissionVault
    function registerCode(string calldata code) external whenNotPaused {
        _registerCode(code, msg.sender);
    }

    /// @inheritdoc ICommissionVault
    function registerCode(string calldata code, address payout) external whenNotPaused {
        // Same self-service registration, but the affiliate can direct payouts to a
        // different wallet (e.g. a treasury or cold wallet) instead of the tx sender.
        // A zero payout means "no custom address given" and binds to the sender, so
        // the option stays optional however the caller encodes it.
        _registerCode(code, payout == address(0) ? msg.sender : payout);
    }

    function _registerCode(string calldata code, address payout) private {
        bytes32 codeHash = keccak256(bytes(code));
        if (!(payoutAddress[codeHash] == address(0))) revert AlreadyRegistered();
        // Two guards, two windows: _pendingInBatch covers a proposed-but-not-yet-
        // activated batch (cumulativeAmount is still 0 then), cumulativeAmount the
        // activated one. Self-service stays blocked for either; owner binds via
        // ownerRegisterCode.
        if (!(!_pendingInBatch[codeHash])) revert SettlementPending();
        if (!(cumulativeAmount[codeHash] == 0)) revert CodeHasValue();
        payoutAddress[codeHash] = payout;
        emit CodeRegistered(codeHash, code, payout);
    }

    /// @inheritdoc ICommissionVault
    function changePayoutAddress(string calldata code, address newPayout) external whenNotPaused {
        // Self-service, instant: the affiliate moves their own code's payout to a
        // new wallet in one tx, sent from the CURRENT payout address. No timelock — a
        // compromised key can already drain via claim(), so a delay here buys
        // nothing; the affiliate owns their wallet security. Owner-recovery
        // (ownerSetPayoutAddress, timelocked) remains for the lost-key case, so a
        // change is blocked while a recovery is pending on the shared slot.
        bytes32 codeHash = keccak256(bytes(code));
        address current = payoutAddress[codeHash];
        if (!(current != address(0))) revert CodeNotOnChain();
        if (!(msg.sender == current)) revert WrongSender();
        if (!(newPayout != address(0))) revert ZeroAddress();
        if (!(newPayout != current)) revert SameAddress();
        if (!(pendingPayoutChange[codeHash].effectiveAt == 0)) revert ChangePending();

        payoutAddress[codeHash] = newPayout;

        emit PayoutAddressChanged(codeHash, current, newPayout);
    }

    /// @inheritdoc ICommissionVault
    function activatePayoutChange(string calldata code) external whenNotPaused {
        bytes32 codeHash = keccak256(bytes(code));
        PendingPayoutChange memory change = pendingPayoutChange[codeHash];
        if (!(change.effectiveAt != 0)) revert NoPendingChange();
        if (!(block.timestamp >= change.effectiveAt)) revert TimelockNotExpired();

        address old = payoutAddress[codeHash];
        payoutAddress[codeHash] = change.newPayout;
        delete pendingPayoutChange[codeHash];

        emit PayoutChangeActivated(codeHash, old, change.newPayout);
    }

    /// @inheritdoc ICommissionVault
    function cancelPayoutChange(string calldata code) external onlyGuardian {
        bytes32 codeHash = keccak256(bytes(code));
        PendingPayoutChange memory change = pendingPayoutChange[codeHash];
        if (!(change.effectiveAt != 0)) revert NoPendingChange();
        delete pendingPayoutChange[codeHash];

        emit PayoutChangeCancelled(codeHash, change.newPayout);
    }

    // ── View functions ────────────────────────────────────────

    /// @inheritdoc ICommissionVault
    function entitlements(bytes32 codeHash) external view returns (address, uint256) {
        return (payoutAddress[codeHash], cumulativeAmount[codeHash]);
    }

    /// @inheritdoc ICommissionVault
    function getClaimable(string calldata code) external view returns (uint256) {
        bytes32 codeHash = keccak256(bytes(code));
        uint256 cumulative = cumulativeAmount[codeHash];
        uint256 alreadyClaimed = claimed[codeHash];
        if (cumulative <= alreadyClaimed) {
            return 0;
        }
        return cumulative - alreadyClaimed;
    }

    /// @inheritdoc ICommissionVault
    function getEntitlement(string calldata code)
        external
        view
        returns (address, uint256, uint256)
    {
        bytes32 codeHash = keccak256(bytes(code));
        return (payoutAddress[codeHash], cumulativeAmount[codeHash], claimed[codeHash]);
    }

    /// @inheritdoc ICommissionVault
    function requiredReserve() public view returns (uint256) {
        // USDC the vault must retain to cover every outstanding earned-but-unclaimed
        // commission. The >= guard matters post-migration, where seedClaimed can leave
        // totalClaimed above totalOwed — an unguarded subtraction would underflow-revert.
        return totalOwed >= totalClaimed ? totalOwed - totalClaimed : 0;
    }

    /// @inheritdoc ICommissionVault
    function requiredTopUp() external view returns (uint256) {
        // The exact USDC the vault is short of its required reserve — what an external
        // distributor must push in so the vault can cover all outstanding commissions.
        uint256 reserve = requiredReserve();
        uint256 balance = usdc.balanceOf(address(this));
        return balance >= reserve ? 0 : reserve - balance;
    }

    // ── Guardian functions ────────────────────────────────────

    /// @inheritdoc ICommissionVault
    function cancelSettlement() external onlyGuardian {
        uint256 len = _pendingCodeHashes.length;
        if (!(len > 0)) revert NoPendingSettlement();

        for (uint256 i = 0; i < len; i++) {
            bytes32 codeHash = _pendingCodeHashes[i];
            delete _pendingAmount[codeHash];
            delete _pendingInBatch[codeHash];
        }

        delete _pendingCodeHashes;
        pendingActivationTime = 0;

        emit SettlementCancelled();
    }

    /// @inheritdoc ICommissionVault
    function pause() external onlyGuardian {
        paused = true;
    }

    // ── Owner functions ───────────────────────────────────────

    /// @inheritdoc ICommissionVault
    function unpause() external onlyOwner {
        paused = false;
    }

    /// @inheritdoc ICommissionVault
    function ownerSetPayoutAddress(string calldata code, address newPayout) external onlyOwner {
        bytes32 codeHash = keccak256(bytes(code));
        if (!(payoutAddress[codeHash] != address(0))) revert CodeNotOnChain();
        if (!(newPayout != address(0))) revert ZeroAddress();
        if (!(pendingPayoutChange[codeHash].effectiveAt == 0)) revert ChangeAlreadyPending();

        // Owner recovery reuses the shared pending slot (guardian veto + public
        // activation for free).
        uint40 effectiveAt = uint40(block.timestamp + payoutTimelock);
        pendingPayoutChange[codeHash] = PendingPayoutChange({newPayout: newPayout, effectiveAt: effectiveAt});

        emit OwnerPayoutChangeProposed(codeHash, newPayout, effectiveAt);
    }

    function ownerRegisterCode(string calldata code, address payout) external onlyOwner {
        // Break-glass: no pending-settlement guard, unlike _registerCode — a
        // settlement never touches the payout, so there is nothing to race.
        bytes32 codeHash = keccak256(bytes(code));
        if (!(payoutAddress[codeHash] == address(0))) revert AlreadyRegistered();
        if (!(payout != address(0))) revert ZeroPayout();
        payoutAddress[codeHash] = payout;
        emit CodeRegistered(codeHash, code, payout);
    }

    /// @inheritdoc ICommissionVault
    function ownerDistribute(string[] calldata codes) external onlyOwner nonReentrant whenNotPaused {
        // Push each code's owed balance to its ACTIVE payout address — the same
        // amount an affiliate would `claim`, paid to the same address. Reuses the
        // CommissionClaimed event so the vault-events indexer records each as a claim.
        // The contract cannot enumerate codes (mappings aren't iterable), so the owner
        // supplies the list in batches; for a migration, page over all codes until
        // totalClaimed == totalOwed, then rescueToken the dust.
        // Gated by whenNotPaused (a migration is a deliberate, unpaused op — the
        // guardian's pause must still freeze all outbound USDC). Codes with a pending
        // payout change are SKIPPED: that address is mid-recovery (likely a
        // key-compromise), and force-pushing to the old address would override the
        // timelock's whole purpose. Resolve pending changes, then re-run the sweep.
        uint256 len = codes.length;
        if (!(len > 0)) revert EmptyBatch();
        if (!(len <= MAX_BATCH_SIZE)) revert BatchTooLarge();

        uint256 totalPaid = 0;
        uint256 paidCount = 0;

        for (uint256 i = 0; i < len; i++) {
            bytes32 codeHash = keccak256(bytes(codes[i]));
            address payout = payoutAddress[codeHash];
            if (payout == address(0)) {
                continue; // never bound on-chain
            }
            if (pendingPayoutChange[codeHash].effectiveAt != 0) {
                continue; // a payout change is in flight — never override its timelock
            }

            uint256 owed = cumulativeAmount[codeHash] - claimed[codeHash];
            if (owed == 0) {
                continue; // already fully paid
            }

            claimed[codeHash] = cumulativeAmount[codeHash];
            totalPaid += owed;
            paidCount++;

            usdc.safeTransfer(payout, owed);

            emit CommissionClaimed(codeHash, payout, owed, claimed[codeHash]);
        }

        totalClaimed += totalPaid;

        emit CommissionsDistributed(paidCount, totalPaid);
    }

    /// @inheritdoc ICommissionVault
    function distributeEligible(string[] calldata codes) external nonReentrant whenNotPaused {
        // Backend-triggered threshold payout (ENG-2384): forces an EARLY payout of
        // exactly what each affiliate could already claim, to the code's own
        // registered payout address — never a redirection. Auth is deliberately
        // wider than ownerDistribute (routine op, not a one-shot migration): the
        // operator runs it, guardian/owner are fallbacks. The extra power this
        // hands the operator/guardian is bounded to accelerating a payout the
        // affiliate could take themselves. Unlike ownerDistribute it respects
        // minClaimAmount, so dust keeps accruing instead of burning gas.
        if (!(msg.sender == operator || msg.sender == guardian || msg.sender == owner)) revert NotAuthorized();

        uint256 len = codes.length;
        if (!(len > 0)) revert EmptyBatch();
        if (!(len <= MAX_BATCH_SIZE)) revert BatchTooLarge();

        uint256 totalPaid = 0;
        uint256 paidCount = 0;

        for (uint256 i = 0; i < len; i++) {
            bytes32 codeHash = keccak256(bytes(codes[i]));
            address payout = payoutAddress[codeHash];
            if (payout == address(0)) {
                continue; // never bound on-chain
            }
            if (pendingPayoutChange[codeHash].effectiveAt != 0) {
                continue; // a payout change is in flight — never override its timelock
            }

            uint256 owed = cumulativeAmount[codeHash] - claimed[codeHash];
            // Explicit owed == 0 keeps the skip correct when minClaimAmount is 0.
            if (owed == 0 || owed < minClaimAmount) {
                continue; // nothing owed, or below the payout threshold
            }

            claimed[codeHash] = cumulativeAmount[codeHash];
            totalPaid += owed;
            paidCount++;

            usdc.safeTransfer(payout, owed);

            emit CommissionClaimed(codeHash, payout, owed, claimed[codeHash]);
        }

        totalClaimed += totalPaid;

        emit EligibleDistribution(msg.sender, paidCount, totalPaid, len - paidCount);
    }

    /// @inheritdoc ICommissionVault
    function setOperator(address newOperator) external onlyOwner {
        if (!(newOperator != address(0))) revert ZeroOperator();
        emit OperatorUpdated(operator, newOperator);
        operator = newOperator;
    }

    /// @inheritdoc ICommissionVault
    function setGuardian(address newGuardian) external onlyOwner {
        if (!(newGuardian != address(0))) revert ZeroGuardian();
        emit GuardianUpdated(guardian, newGuardian);
        guardian = newGuardian;
    }

    /// @inheritdoc ICommissionVault
    function setDistributor(address newDistributor) external onlyOwner {
        if (!(newDistributor != address(0))) revert ZeroDistributor();
        emit DistributorUpdated(distributor, newDistributor);
        distributor = newDistributor;
    }

    /// @inheritdoc ICommissionVault
    function setMinClaimAmount(uint256 newMinClaimAmount) external onlyOwner {
        if (!(newMinClaimAmount <= MAX_MIN_CLAIM_AMOUNT)) revert ExceedsMaxMinClaim();
        emit MinClaimAmountUpdated(minClaimAmount, newMinClaimAmount);
        minClaimAmount = newMinClaimAmount;
    }

    /// @inheritdoc ICommissionVault
    function setMaxCodeDelta(uint256 newMaxCodeDelta) external onlyOwner {
        if (!(newMaxCodeDelta > 0)) revert ZeroMaxCodeDelta();
        emit MaxCodeDeltaUpdated(maxCodeDelta, newMaxCodeDelta);
        maxCodeDelta = newMaxCodeDelta;
    }

    /// @inheritdoc ICommissionVault
    function setMaxBatchDelta(uint256 newMaxBatchDelta) external onlyOwner {
        if (!(newMaxBatchDelta > 0)) revert ZeroMaxBatchDelta();
        emit MaxBatchDeltaUpdated(maxBatchDelta, newMaxBatchDelta);
        maxBatchDelta = newMaxBatchDelta;
    }

    /// @inheritdoc ICommissionVault
    function seedClaimed(bytes32[] calldata codeHashes, uint256[] calldata amounts, address[] calldata payouts)
        external
        onlyOwner
    {
        if (!(!migrationFinalized)) revert MigrationAlreadyFinalized();
        if (!(codeHashes.length == amounts.length && codeHashes.length == payouts.length)) revert LengthMismatch();
        if (!(codeHashes.length <= MAX_BATCH_SIZE)) revert BatchTooLarge();

        for (uint256 i = 0; i < codeHashes.length; i++) {
            if (!(codeHashes[i] != bytes32(0))) revert ZeroCodeHash();
            if (!(amounts[i] > 0)) revert ZeroAmount();
            if (!(payouts[i] != address(0))) revert ZeroPayout();
            // Key on cumulativeAmount, not claimed: a code that was already settled
            // has claimed == 0 but cumulativeAmount != 0 — seeding it would overwrite
            // its real entitlement and double-count totalOwed.
            if (!(cumulativeAmount[codeHashes[i]] == 0 && claimed[codeHashes[i]] == 0)) revert AlreadyKnown();

            // Seed net-zero (cumulative == claimed) and bump both aggregates
            // together, so mustRetain stays correct and later settlements compute
            // their delta from the seeded baseline rather than from zero.
            payoutAddress[codeHashes[i]] = payouts[i];
            claimed[codeHashes[i]] = amounts[i];
            cumulativeAmount[codeHashes[i]] = amounts[i];
            totalClaimed += amounts[i];
            totalOwed += amounts[i];
            emit ClaimedSeeded(codeHashes[i], payouts[i], amounts[i]);
        }
    }

    /// @inheritdoc ICommissionVault
    function migrateBalance(address oldVault, uint256 amount) external onlyOwner nonReentrant {
        if (!(!migrationFinalized)) revert MigrationAlreadyFinalized();
        usdc.safeTransferFrom(oldVault, address(this), amount);
        emit BalanceMigrated(oldVault, amount);
    }

    /// @inheritdoc ICommissionVault
    function finalizeMigration() external onlyOwner {
        migrationFinalized = true;
        emit MigrationFinalized();
    }

    /// @inheritdoc ICommissionVault
    function rescueToken(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }

    /// @inheritdoc ICommissionVault
    function transferOwnership(address newOwner) external onlyOwner {
        if (!(newOwner != address(0))) revert ZeroAddress();
        if (!(newOwner != owner)) revert AlreadyOwner();
        pendingOwner = newOwner;
        emit OwnershipTransferProposed(owner, newOwner);
    }

    /// @inheritdoc ICommissionVault
    function acceptOwnership() external {
        if (!(msg.sender == pendingOwner)) revert NotPendingOwner();
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

}
