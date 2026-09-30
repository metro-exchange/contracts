// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IErc20Forwarder} from "./interfaces/IErc20Forwarder.sol";

/// @notice Holds a fixed ERC20 and lets anyone sweep the full balance to a
/// configured recipient. Affiliate configs point permanently at this address;
/// swapping the downstream distributor is a single setRecipient call. Owner
/// configures the recipient, can pause, and can rescue stuck funds. The owner is
/// set explicitly at deploy so the broadcasting key never holds custody. Deploys
/// paused: the owner's first unpause() is the go-live switch.
contract Erc20Forwarder is IErc20Forwarder, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    address public recipient;
    // Shares a slot with recipient so forward() reads both with one cold SLOAD.
    bool public paused;
    address public owner;
    address public pendingOwner;

    // ── Modifiers ─────────────────────────────────────────────

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Paused");
        _;
    }

    // ── Constructor ───────────────────────────────────────────

    constructor(address _token, address _recipient, address _owner) {
        require(_owner != address(0), "Zero owner");
        require(_token != address(0), "Zero token");
        // A bad FORWARDER_TOKEN must fail the deploy instead of bricking an immutable
        // field. The code check rejects EOAs, wrong-chain addresses and precompiles;
        // the probe rejects contracts that do not answer balanceOf with a word. A
        // contract with a catch-all fallback still passes, so this is a liveness
        // check, not proof of ERC20 behaviour.
        require(_token.code.length > 0, "Token has no code");
        IERC20(_token).balanceOf(address(this));
        token = IERC20(_token);
        _checkRecipient(_recipient);
        owner = _owner;
        recipient = _recipient;
        // Deploys paused: go-live is an explicit unpause() by the owner, which also
        // proves the owner account can execute against this contract before any
        // affiliate config points funds at it.
        paused = true;
        emit OwnershipTransferred(address(0), _owner);
        emit RecipientUpdated(address(0), _recipient);
        emit Paused(true);
    }

    // Pointing at self makes forward() a silent no-op that still emits Forwarded;
    // pointing at the token contract strands the balance inside it.
    function _checkRecipient(address candidate) internal view {
        require(candidate != address(0), "Zero recipient");
        require(candidate != address(this), "Recipient is self");
        require(candidate != address(token), "Recipient is token");
    }

    // ── Sweep ──────────────────────────────────────────────────

    /// @inheritdoc IErc20Forwarder
    function forward() external whenNotPaused {
        uint256 bal = token.balanceOf(address(this));
        require(bal > 0, "Nothing to forward");
        _sweep(bal);
    }

    /// @inheritdoc IErc20Forwarder
    function tryForward() external returns (uint256 forwarded) {
        if (paused) return 0;
        forwarded = token.balanceOf(address(this));
        if (forwarded > 0) _sweep(forwarded);
    }

    function _sweep(uint256 amount) internal {
        token.safeTransfer(recipient, amount);
        emit Forwarded(address(token), recipient, amount);
    }

    // ── Owner: configuration ───────────────────────────────────

    /// @inheritdoc IErc20Forwarder
    function setRecipient(address newRecipient) external onlyOwner {
        _checkRecipient(newRecipient);
        emit RecipientUpdated(recipient, newRecipient);
        recipient = newRecipient;
    }

    /// @inheritdoc IErc20Forwarder
    function pause() external onlyOwner {
        paused = true;
        emit Paused(true);
    }

    /// @inheritdoc IErc20Forwarder
    function unpause() external onlyOwner {
        paused = false;
        emit Paused(false);
    }

    // ── Owner: rescue ──────────────────────────────────────────

    /// @inheritdoc IErc20Forwarder
    function rescueToken(address asset, address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "Zero address");
        IERC20(asset).safeTransfer(to, amount);
        emit TokenRescued(asset, to, amount);
    }

    /// @inheritdoc IErc20Forwarder
    function rescueETH(address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "Zero address");
        (bool ok,) = to.call{value: amount}("");
        require(ok, "ETH transfer failed");
        emit EthRescued(to, amount);
    }

    // ── Ownership (2-step) ─────────────────────────────────────

    /// @inheritdoc IErc20Forwarder
    /// @dev Proposing address(0) cancels a pending proposal, as OpenZeppelin Ownable2Step does.
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != owner, "Already owner");
        pendingOwner = newOwner;
        emit OwnershipTransferProposed(owner, newOwner);
    }

    /// @inheritdoc IErc20Forwarder
    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "Not pending owner");
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }
}
