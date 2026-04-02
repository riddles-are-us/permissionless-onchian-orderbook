// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {Account as AccountContract} from "../Account.sol";
import {MockERC20} from "../MockERC20.sol";

/**
 * @title DeployWBTC
 * @notice Deploy WBTC token and register WBTC/USDC trading pair
 * @dev Run with: forge script script/DeployWBTC.s.sol:DeployWBTCScript --rpc-url <RPC_URL> --broadcast --legacy -vvv
 */
contract DeployWBTCScript is Script {
    // Existing contract addresses from deployments.json
    address constant ACCOUNT = 0x8EE3a2f7Ba1D0071cD53F06f04E22Ecc35B521dd;
    address constant USDC = 0x092C283EDeF672cC791A5DbfB6BAdc4406A75C48;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying WBTC with address:", deployer);
        console.log("Deployer balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy WBTC (8 decimals, same as real BTC)
        console.log("\n=== Deploying WBTC ===");
        address wbtc = address(new MockERC20("Wrapped Bitcoin", "WBTC", 8));
        console.log("WBTC deployed at:", wbtc);

        // 2. Register WBTC/USDC trading pair
        console.log("\n=== Registering Trading Pair ===");
        bytes32 wbtcUsdcPairId = keccak256("WBTC/USDC");
        AccountContract(ACCOUNT).registerTradingPair(wbtcUsdcPairId, wbtc, USDC);
        console.log("Trading pair WBTC/USDC registered");
        console.log("Pair ID:", vm.toString(wbtcUsdcPairId));

        vm.stopBroadcast();

        // 3. Summary
        console.log("\n=== Deployment Summary ===");
        console.log("WBTC:           ", wbtc);
        console.log("WBTC decimals:   8");
        console.log("USDC:           ", USDC);
        console.log("Account:        ", ACCOUNT);
        console.log("WBTC/USDC Pair: ", vm.toString(wbtcUsdcPairId));

        // 4. Update deployments.json hint
        console.log("\n=== Next Steps ===");
        console.log("Add to deployments.json:");
        console.log('  "wbtc": "', vm.toString(wbtc), '",');
        console.log('  "wbtcUsdcPairId": "', vm.toString(wbtcUsdcPairId), '"');
    }
}
