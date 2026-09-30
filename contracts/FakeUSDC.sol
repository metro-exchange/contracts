// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Mintable ERC20 for testbed use. Only the deployer (owner) can mint.
contract FakeUSDC is ERC20 {
    address public immutable owner;

    constructor() ERC20("Fake USDC", "fUSDC") {
        owner = msg.sender;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == owner, "Not owner");
        _mint(to, amount);
    }
}
