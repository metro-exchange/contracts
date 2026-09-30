// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {CommissionVault} from "../contracts/CommissionVault.sol";
import {FakeDistributor} from "../contracts/FakeDistributor.sol";
import {FakeUSDC} from "../contracts/FakeUSDC.sol";

contract DeployTestbed is Script {
    function run() external {
        address operatorAddr = vm.envAddress("OPERATOR_ADDRESS");
        address guardianAddr = vm.envAddress("GUARDIAN_ADDRESS");
        uint256 maxCodeDelta = vm.envOr("MAX_CODE_DELTA", uint256(10_000e6));
        uint256 maxBatchDelta = vm.envOr("MAX_BATCH_DELTA", uint256(100_000e6));
        uint256 settlementTimelock = vm.envOr("SETTLEMENT_TIMELOCK", uint256(300));
        uint256 payoutTimelock = vm.envOr("PAYOUT_TIMELOCK", uint256(300));

        vm.startBroadcast();

        // 1. Deploy FakeUSDC
        FakeUSDC fakeUsdc = new FakeUSDC();
        console2.log("FakeUSDC deployed at:", address(fakeUsdc));

        // 2. Deploy FakeDistributor (placeholder for production revenue-distribution contract)
        FakeDistributor fakeDistributor = new FakeDistributor();
        console2.log("FakeDistributor deployed at:", address(fakeDistributor));

        // 3. Deploy CommissionVault
        CommissionVault vault = new CommissionVault(
            address(fakeUsdc),
            address(fakeDistributor),
            operatorAddr,
            guardianAddr,
            maxCodeDelta,
            maxBatchDelta,
            false, // not a migration target
            settlementTimelock,
            payoutTimelock
        );
        console2.log("CommissionVault deployed at:", address(vault));

        console2.log("--- Testbed Configuration ---");
        console2.log("Chain ID:", block.chainid);
        console2.log("FakeUSDC:", address(fakeUsdc));
        console2.log("FakeDistributor:", address(fakeDistributor));
        console2.log("CommissionVault:", address(vault));
        console2.log("Operator:", operatorAddr);
        console2.log("Guardian:", guardianAddr);
        console2.log("Owner:", msg.sender);
        console2.log("settlementTimelock:", settlementTimelock);
        console2.log("payoutTimelock:", payoutTimelock);
        console2.log("maxCodeDelta:", maxCodeDelta);
        console2.log("maxBatchDelta:", maxBatchDelta);

        vm.stopBroadcast();
    }
}
