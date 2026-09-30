// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Erc20Forwarder} from "../contracts/Erc20Forwarder.sol";

contract DeployForwarder is Script {
    function run() external {
        uint256 chainId = vm.envUint("FORWARDER_CHAIN_ID");
        address forwardToken = vm.envAddress("FORWARDER_TOKEN");
        address recipient = vm.envAddress("FORWARDER_RECIPIENT");
        address owner = vm.envAddress("FORWARDER_OWNER");

        // The owner is a Safe and the recipient is the vault, both contracts. A
        // Safe that is not deployed on this chain would leave the forwarder with
        // no working owner forever, and the constructor cannot know that.
        require(block.chainid == chainId, "Wrong chain for FORWARDER_CHAIN_ID");
        require(owner.code.length > 0, "FORWARDER_OWNER has no code on this chain");
        require(recipient.code.length > 0, "FORWARDER_RECIPIENT has no code on this chain");

        vm.startBroadcast();

        Erc20Forwarder forwarder = new Erc20Forwarder(forwardToken, recipient, owner);

        vm.stopBroadcast();

        console2.log("Erc20Forwarder deployed at:", address(forwarder));
        console2.log("Chain ID:", block.chainid);
        console2.log("Token:", address(forwarder.token()));
        console2.log("Recipient:", forwarder.recipient());
        console2.log("Owner:", forwarder.owner());
        console2.log("Paused:", forwarder.paused());
    }
}
