// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ICommissionVault} from "./interfaces/ICommissionVault.sol";

contract CommissionVault is ICommissionVault, ReentrancyGuard {
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

    // Pending settlement (amount + first-bind address, applied on activate)
    mapping(bytes32 => uint256) internal _pendingAmount;
    mapping(bytes32 => address) internal _pendingBindAddress;
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
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyOperator() {
        require(msg.sender == operator, "Not operator");
        _;
    }

    modifier onlyGuardian() {
        require(msg.sender == guardian, "Not guardian");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Paused");
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
        require(_usdc != address(0), "Zero USDC");
        require(_distributor != address(0), "Zero distributor");
        require(_operator != address(0), "Zero operator");
        require(_guardian != address(0), "Zero guardian");
        require(_maxCodeDelta > 0, "Zero maxCodeDelta");
        require(_maxBatchDelta > 0, "Zero maxBatchDelta");
        require(_settlementTimelock >= 1 minutes, "Timelock too short");
        require(_payoutTimelock >= 1 minutes, "Payout timelock too short");

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
        address[] calldata addresses,
        uint256[] calldata cumulativeAmounts
    ) external onlyOperator whenNotPaused {
        uint256 len = codes.length;
        require(len > 0, "Empty batch");
        require(len == addresses.length && len == cumulativeAmounts.length, "Length mismatch");
        require(len <= MAX_BATCH_SIZE, "Batch too large");
        require(_pendingCodeHashes.length == 0, "Pending settlement exists");

        uint256 batchIncrease = 0;

        for (uint256 i = 0; i < len; i++) {
            require(addresses[i] != address(0), "Zero address");
            bytes32 codeHash = keccak256(bytes(codes[i]));
            require(_pendingBindAddress[codeHash] == address(0), "Duplicate code in batch");

            uint256 currentAmount = cumulativeAmount[codeHash];
            require(cumulativeAmounts[i] >= currentAmount, "Cannot decrease amount");

            uint256 increase = cumulativeAmounts[i] - currentAmount;
            require(increase <= maxCodeDelta, "Exceeds max code delta");
            batchIncrease += increase;

            _pendingAmount[codeHash] = cumulativeAmounts[i];
            _pendingBindAddress[codeHash] = addresses[i];
            _pendingCodeHashes.push(codeHash);
        }

        require(batchIncrease <= maxBatchDelta, "Exceeds max batch delta");

        pendingActivationTime = block.timestamp + settlementTimelock;

        emit SettlementProposed(pendingActivationTime, len, batchIncrease);
    }

    /// @inheritdoc ICommissionVault
    function processIncoming() external onlyOperator whenNotPaused nonReentrant {
        require(migrationFinalized, "Migration not finalized");

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
        require(len > 0, "No pending settlement");
        require(block.timestamp >= pendingActivationTime, "Timelock not expired");

        uint256 totalIncrease = 0;

        for (uint256 i = 0; i < len; i++) {
            bytes32 codeHash = _pendingCodeHashes[i];
            uint256 newAmount = _pendingAmount[codeHash];

            totalIncrease += newAmount - cumulativeAmount[codeHash];
            cumulativeAmount[codeHash] = newAmount;

            // First bind only: never overwrite an existing (possibly just-changed)
            // payout address. This is what decouples address from earnings.
            if (payoutAddress[codeHash] == address(0)) {
                payoutAddress[codeHash] = _pendingBindAddress[codeHash];
            }

            delete _pendingAmount[codeHash];
            delete _pendingBindAddress[codeHash];

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

        require(msg.sender == payoutAddress[codeHash], "Wrong sender");

        uint256 cumulative = cumulativeAmount[codeHash];
        uint256 alreadyClaimed = claimed[codeHash];
        require(cumulative > alreadyClaimed, "Nothing to claim");

        uint256 claimable = cumulative - alreadyClaimed;
        require(claimable >= minClaimAmount, "Below minimum claim");

        uint256 balance = usdc.balanceOf(address(this));
        require(claimable <= balance, "Vault underfunded");

        claimed[codeHash] = cumulative;
        totalClaimed += claimable;

        usdc.safeTransfer(msg.sender, claimable);

        emit CommissionClaimed(codeHash, msg.sender, claimable, claimed[codeHash]);
    }

    // ── Payout address changes ──

    /// @inheritdoc ICommissionVault
    function registerCode(string calldata code) external whenNotPaused {
        // Self-service on-chain registration: the affiliate binds their code's payout
        // to their own wallet in one tx. The tx sender IS the payout, so no signature
        // is needed. First-come-first-served on the codeHash; settlement's first-bind
        // then skips this code, leaving the self-registered address intact.
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
        require(payoutAddress[codeHash] == address(0), "Already registered");
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
        require(current != address(0), "Code not on-chain yet");
        require(msg.sender == current, "Wrong sender");
        require(newPayout != address(0), "Zero address");
        require(newPayout != current, "Same address");
        require(pendingPayoutChange[codeHash].effectiveAt == 0, "Change pending");

        payoutAddress[codeHash] = newPayout;

        emit PayoutAddressChanged(codeHash, current, newPayout);
    }

    /// @inheritdoc ICommissionVault
    function activatePayoutChange(string calldata code) external whenNotPaused {
        bytes32 codeHash = keccak256(bytes(code));
        PendingPayoutChange memory change = pendingPayoutChange[codeHash];
        require(change.effectiveAt != 0, "No pending change");
        require(block.timestamp >= change.effectiveAt, "Timelock not expired");

        address old = payoutAddress[codeHash];
        payoutAddress[codeHash] = change.newPayout;
        delete pendingPayoutChange[codeHash];

        emit PayoutChangeActivated(codeHash, old, change.newPayout);
    }

    /// @inheritdoc ICommissionVault
    function cancelPayoutChange(string calldata code) external onlyGuardian {
        bytes32 codeHash = keccak256(bytes(code));
        PendingPayoutChange memory change = pendingPayoutChange[codeHash];
        require(change.effectiveAt != 0, "No pending change");
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
        require(len > 0, "No pending settlement");

        for (uint256 i = 0; i < len; i++) {
            bytes32 codeHash = _pendingCodeHashes[i];
            delete _pendingAmount[codeHash];
            delete _pendingBindAddress[codeHash];
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
        require(payoutAddress[codeHash] != address(0), "Code not on-chain yet");
        require(newPayout != address(0), "Zero address");
        require(pendingPayoutChange[codeHash].effectiveAt == 0, "Change already pending");

        // Owner recovery reuses the shared pending slot (guardian veto + public
        // activation for free).
        uint40 effectiveAt = uint40(block.timestamp + payoutTimelock);
        pendingPayoutChange[codeHash] = PendingPayoutChange({newPayout: newPayout, effectiveAt: effectiveAt});

        emit OwnerPayoutChangeProposed(codeHash, newPayout, effectiveAt);
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
        require(len > 0, "Empty batch");
        require(len <= MAX_BATCH_SIZE, "Batch too large");

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
        require(msg.sender == operator || msg.sender == guardian || msg.sender == owner, "Not authorized");

        uint256 len = codes.length;
        require(len > 0, "Empty batch");
        require(len <= MAX_BATCH_SIZE, "Batch too large");

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
        require(newOperator != address(0), "Zero operator");
        emit OperatorUpdated(operator, newOperator);
        operator = newOperator;
    }

    /// @inheritdoc ICommissionVault
    function setGuardian(address newGuardian) external onlyOwner {
        require(newGuardian != address(0), "Zero guardian");
        emit GuardianUpdated(guardian, newGuardian);
        guardian = newGuardian;
    }

    /// @inheritdoc ICommissionVault
    function setDistributor(address newDistributor) external onlyOwner {
        require(newDistributor != address(0), "Zero distributor");
        emit DistributorUpdated(distributor, newDistributor);
        distributor = newDistributor;
    }

    /// @inheritdoc ICommissionVault
    function setMinClaimAmount(uint256 newMinClaimAmount) external onlyOwner {
        require(newMinClaimAmount <= MAX_MIN_CLAIM_AMOUNT, "Exceeds max min claim");
        emit MinClaimAmountUpdated(minClaimAmount, newMinClaimAmount);
        minClaimAmount = newMinClaimAmount;
    }

    /// @inheritdoc ICommissionVault
    function setMaxCodeDelta(uint256 newMaxCodeDelta) external onlyOwner {
        require(newMaxCodeDelta > 0, "Zero maxCodeDelta");
        emit MaxCodeDeltaUpdated(maxCodeDelta, newMaxCodeDelta);
        maxCodeDelta = newMaxCodeDelta;
    }

    /// @inheritdoc ICommissionVault
    function setMaxBatchDelta(uint256 newMaxBatchDelta) external onlyOwner {
        require(newMaxBatchDelta > 0, "Zero maxBatchDelta");
        emit MaxBatchDeltaUpdated(maxBatchDelta, newMaxBatchDelta);
        maxBatchDelta = newMaxBatchDelta;
    }

    /// @inheritdoc ICommissionVault
    function seedClaimed(bytes32[] calldata codeHashes, uint256[] calldata amounts) external onlyOwner {
        require(!migrationFinalized, "Migration finalized");
        require(codeHashes.length == amounts.length, "Length mismatch");
        require(codeHashes.length <= MAX_BATCH_SIZE, "Batch too large");

        for (uint256 i = 0; i < codeHashes.length; i++) {
            require(codeHashes[i] != bytes32(0), "Zero code hash");
            require(amounts[i] > 0, "Zero amount");
            // Key on cumulativeAmount, not claimed: a code that was already settled
            // has claimed == 0 but cumulativeAmount != 0 — seeding it would overwrite
            // its real entitlement and double-count totalOwed.
            require(cumulativeAmount[codeHashes[i]] == 0 && claimed[codeHashes[i]] == 0, "Already known");

            // Seed net-zero (cumulative == claimed) and bump both aggregates
            // together, so mustRetain stays correct and later settlements compute
            // their delta from the seeded baseline rather than from zero.
            claimed[codeHashes[i]] = amounts[i];
            cumulativeAmount[codeHashes[i]] = amounts[i];
            totalClaimed += amounts[i];
            totalOwed += amounts[i];
            emit ClaimedSeeded(codeHashes[i], amounts[i]);
        }
    }

    /// @inheritdoc ICommissionVault
    function migrateBalance(address oldVault, uint256 amount) external onlyOwner nonReentrant {
        require(!migrationFinalized, "Migration finalized");
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
        if (token == address(usdc)) {
            uint256 balance = usdc.balanceOf(address(this));
            uint256 mustRetain = requiredReserve();
            uint256 rescuable = balance > mustRetain ? balance - mustRetain : 0;
            require(amount <= rescuable, "Cannot rescue commission USDC");
        }
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }

    /// @inheritdoc ICommissionVault
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        require(newOwner != owner, "Already owner");
        pendingOwner = newOwner;
        emit OwnershipTransferProposed(owner, newOwner);
    }

    /// @inheritdoc ICommissionVault
    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "Not pending owner");
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

}
