// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IErc20Forwarder} from "./IErc20Forwarder.sol";

/// @dev Unlike the base IErc20Forwarder, `forward()`/`tryForward()` release only
/// the accrued token-bucket slice (`min(bucket, balance)`) while `dripRate != 0`,
/// not the full balance. Setting `dripRate == 0` restores the base full-sweep.
/// Accrual pauses while the forwarder is paused and resumes on unpause.
interface IRateLimitedForwarder is IErc20Forwarder {
    event DripLimitUpdated(uint256 dripRate, uint256 dripPeriod, uint256 maxReserve);

    function availableBalance() external view returns (uint256);
    function dripRate() external view returns (uint256);
    function dripPeriod() external view returns (uint256);
    function maxReserve() external view returns (uint256);
    function bucket() external view returns (uint256);

    function setDripLimit(uint256 rate, uint256 period, uint256 maxReserve) external;
}
