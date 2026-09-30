// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {CommissionVault} from "../contracts/CommissionVault.sol";

contract Deploy is Script {
    function run() external {
        address usdc = vm.envAddress("USDC_ADDRESS");
        address distributor = vm.envAddress("DISTRIBUTOR_ADDRESS");
        address operatorAddr = vm.envAddress("OPERATOR_ADDRESS");
        address guardianAddr = vm.envAddress("GUARDIAN_ADDRESS");
        uint256 maxCodeDelta = vm.envUint("MAX_CODE_DELTA");
        uint256 maxBatchDelta = vm.envUint("MAX_BATCH_DELTA");
        bool isMigrationTarget = vm.envOr("IS_MIGRATION_TARGET", false);
        uint256 settlementTimelock = vm.envOr("SETTLEMENT_TIMELOCK", uint256(86400));
        uint256 payoutTimelock = vm.envOr("PAYOUT_TIMELOCK", uint256(86400));

        vm.startBroadcast();

        CommissionVault vault = new CommissionVault(
            usdc,
            distributor,
            operatorAddr,
            guardianAddr,
            maxCodeDelta,
            maxBatchDelta,
            isMigrationTarget,
            settlementTimelock,
            payoutTimelock
        );

        console2.log("CommissionVault deployed at:", address(vault));
        console2.log("Chain ID:", block.chainid);
        console2.log("USDC:", usdc);
        console2.log("Distributor:", distributor);
        console2.log("Operator:", operatorAddr);
        console2.log("Guardian:", guardianAddr);
        console2.log("Owner:", msg.sender);
        console2.log("maxCodeDelta:", maxCodeDelta);
        console2.log("maxBatchDelta:", maxBatchDelta);
        console2.log("settlementTimelock:", settlementTimelock);
        console2.log("payoutTimelock:", payoutTimelock);

        vm.stopBroadcast();
    }
}
