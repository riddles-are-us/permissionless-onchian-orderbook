// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {Account as AccountContract} from "../Account.sol";
import {MockERC20} from "../MockERC20.sol";

/**
 * @title DeployYesNo
 * @notice Deploy YES and NO tokens and register YES/USDC and NO/USDC trading pairs
 * @dev Run with: forge script script/DeployYesNo.s.sol:DeployYesNoScript --rpc-url <RPC_URL> --broadcast --legacy -vvv
 */
contract DeployYesNoScript is Script {
    // Existing contract addresses from deployments.json
    address constant ACCOUNT = 0x9719651ca2B2c797F53E6d01304a0Bf0DDAc9165;
    address constant USDC = 0x0954F0aA437563F25a395963637077f724bC80d7;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying YES and NO tokens with address:", deployer);
        console.log("Deployer balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy YES token (18 decimals)
        console.log("\n=== Deploying YES Token ===");
        address yes = address(new MockERC20("Yes Token", "YES", 18));
        console.log("YES deployed at:", yes);

        // 2. Deploy NO token (18 decimals)
        console.log("\n=== Deploying NO Token ===");
        address no = address(new MockERC20("No Token", "NO", 18));
        console.log("NO deployed at:", no);

        // 3. Register YES/USDC trading pair
        console.log("\n=== Registering YES/USDC Trading Pair ===");
        bytes32 yesUsdcPairId = keccak256("YES/USDC");
        AccountContract(ACCOUNT).registerTradingPair(yesUsdcPairId, yes, USDC);
        console.log("Trading pair YES/USDC registered");
        console.log("Pair ID:", vm.toString(yesUsdcPairId));

        // 4. Register NO/USDC trading pair
        console.log("\n=== Registering NO/USDC Trading Pair ===");
        bytes32 noUsdcPairId = keccak256("NO/USDC");
        AccountContract(ACCOUNT).registerTradingPair(noUsdcPairId, no, USDC);
        console.log("Trading pair NO/USDC registered");
        console.log("Pair ID:", vm.toString(noUsdcPairId));

        vm.stopBroadcast();

        // 5. Summary
        console.log("\n=== Deployment Summary ===");
        console.log("YES:            ", yes);
        console.log("YES decimals:    18");
        console.log("NO:             ", no);
        console.log("NO decimals:     18");
        console.log("USDC:           ", USDC);
        console.log("Account:        ", ACCOUNT);
        console.log("YES/USDC Pair:  ", vm.toString(yesUsdcPairId));
        console.log("NO/USDC Pair:   ", vm.toString(noUsdcPairId));

        // 6. Update deployments.json hint
        console.log("\n=== Next Steps ===");
        console.log("Add to deployments.json:");
        console.log('  "yes": "', vm.toString(yes), '",');
        console.log('  "no": "', vm.toString(no), '",');
        console.log('  "yesUsdcPairId": "', vm.toString(yesUsdcPairId), '",');
        console.log('  "noUsdcPairId": "', vm.toString(noUsdcPairId), '"');
    }
}
