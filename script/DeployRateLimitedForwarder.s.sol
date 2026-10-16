// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {RateLimitedForwarder} from "../contracts/RateLimitedForwarder.sol";

contract DeployRateLimitedForwarder is Script {
    function run() external {
        uint256 chainId = vm.envUint("FORWARDER_CHAIN_ID");
        address forwardToken = vm.envAddress("FORWARDER_TOKEN");
        address recipient = vm.envAddress("FORWARDER_RECIPIENT");
        address owner = vm.envAddress("FORWARDER_OWNER");
        uint256 dripRate = vm.envUint("FORWARDER_DRIP_RATE");
        uint256 dripPeriod = vm.envUint("FORWARDER_DRIP_PERIOD");
        uint256 maxReserve = vm.envUint("FORWARDER_MAX_RESERVE");

        require(block.chainid == chainId, "Wrong chain for FORWARDER_CHAIN_ID");
        require(owner.code.length > 0, "FORWARDER_OWNER has no code on this chain");
        require(recipient.code.length > 0, "FORWARDER_RECIPIENT has no code on this chain");

        vm.startBroadcast();

        RateLimitedForwarder forwarder =
            new RateLimitedForwarder(forwardToken, recipient, owner, dripRate, dripPeriod, maxReserve);

        vm.stopBroadcast();

        console2.log("RateLimitedForwarder deployed at:", address(forwarder));
        console2.log("Chain ID:", block.chainid);
        console2.log("Token:", address(forwarder.token()));
        console2.log("Recipient:", forwarder.recipient());
        console2.log("Owner:", forwarder.owner());
        console2.log("Drip rate:", forwarder.dripRate());
        console2.log("Drip period:", forwarder.dripPeriod());
        console2.log("Max reserve:", forwarder.maxReserve());
        console2.log("Paused:", forwarder.paused());
    }
}
