// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IErc20Forwarder {
    // ── Events ─────────────────────────────────────────────────
    event Forwarded(address indexed token, address indexed recipient, uint256 amount);
    event RecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event Paused(bool paused);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event OwnershipTransferProposed(address indexed currentOwner, address indexed proposedOwner);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    // ── Views ──────────────────────────────────────────────────
    function token() external view returns (IERC20);
    function recipient() external view returns (address);
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function paused() external view returns (bool);

    // ── Sweep ──────────────────────────────────────────────────
    /// @notice Sweeps the full balance to the recipient. Reverts when paused or
    /// when the balance is zero, so a standalone caller fails loud.
    function forward() external;

    /// @notice Sweep variant for composing contracts: returns 0 instead of
    /// reverting when paused or when the balance is zero, so a workflow that
    /// forwards as one of several steps is not reverted by an empty or held
    /// forwarder. Still reverts if the token transfer itself reverts (e.g. a
    /// blacklisted or globally paused USDC) — that is a real failure, not a skip.
    /// @return forwarded The amount swept, 0 when nothing was.
    function tryForward() external returns (uint256 forwarded);

    // ── Owner: configuration ───────────────────────────────────
    function setRecipient(address newRecipient) external;
    function pause() external;
    function unpause() external;

    // ── Owner: rescue ──────────────────────────────────────────
    function rescueToken(address asset, address to, uint256 amount) external;

    // ── Ownership (2-step) ─────────────────────────────────────
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}
