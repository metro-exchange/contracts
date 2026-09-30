// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Placeholder distributor for testbed. In production this would be
///         the THORSwap revenue-distribution contract. Receives surplus USDC
///         from the CommissionVault and allows the owner to withdraw.
contract FakeDistributor {
    using SafeERC20 for IERC20;

    address public immutable owner;

    constructor() {
        owner = msg.sender;
    }

    /// @notice Withdraw any ERC20 sent to this contract.
    function withdraw(IERC20 token, address to, uint256 amount) external {
        require(msg.sender == owner, "Not owner");
        token.safeTransfer(to, amount);
    }

    /// @notice Accept native ETH (in case someone sends gas).
    receive() external payable {}
}
