// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {Account as AccountContract} from "../Account.sol";
import {OrderBook} from "../OrderBook.sol";
import {Sequencer} from "../Sequencer.sol";
import {MockERC20} from "../MockERC20.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying contracts with address:", deployer);
        console.log("Deployer balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy MockERC20 tokens
        console.log("\n=== Deploying Tokens ===");
        address weth = address(new MockERC20("Wrapped Ether", "WETH", 18));
        console.log("WETH deployed at:", weth);

        address usdc = address(new MockERC20("USD Coin", "USDC", 6));
        console.log("USDC deployed at:", usdc);

        // 2. Deploy Account
        console.log("\n=== Deploying Account ===");
        address account = address(new AccountContract());
        console.log("Account deployed at:", account);

        // 3. Deploy OrderBook
        console.log("\n=== Deploying OrderBook ===");
        address orderbook = address(new OrderBook());
        console.log("OrderBook deployed at:", orderbook);

        // 4. Deploy Sequencer
        console.log("\n=== Deploying Sequencer ===");
        address sequencer = address(new Sequencer());
        console.log("Sequencer deployed at:", sequencer);

        // 5. Configure contracts
        console.log("\n=== Configuring Contracts ===");
        AccountContract(account).setOrderBook(orderbook);
        console.log("Account.setOrderBook() called");

        AccountContract(account).setSequencer(sequencer);
        console.log("Account.setSequencer() called");

        OrderBook(orderbook).setSequencer(sequencer);
        console.log("OrderBook.setSequencer() called");

        OrderBook(orderbook).setAccount(account);
        console.log("OrderBook.setAccount() called");

        Sequencer(sequencer).setAccount(account);
        console.log("Sequencer.setAccount() called");

        Sequencer(sequencer).setOrderBook(orderbook);
        console.log("Sequencer.setOrderBook() called");

        // 6. Register trading pair
        console.log("\n=== Registering Trading Pair ===");
        bytes32 pairId = keccak256("WETH/USDC");
        AccountContract(account).registerTradingPair(pairId, weth, usdc);
        console.log("Trading pair WETH/USDC registered");

        vm.stopBroadcast();

        // 7. Save deployment info
        console.log("\n=== Deployment Summary ===");
        console.log("WETH:     ", weth);
        console.log("USDC:     ", usdc);
        console.log("Account:  ", account);
        console.log("OrderBook:", orderbook);
        console.log("Sequencer:", sequencer);
        console.log("Pair ID:  ", vm.toString(pairId));

        // Save to file for matcher to use
        string memory json = string.concat(
            '{\n',
            '  "weth": "', vm.toString(weth), '",\n',
            '  "usdc": "', vm.toString(usdc), '",\n',
            '  "account": "', vm.toString(account), '",\n',
            '  "orderbook": "', vm.toString(orderbook), '",\n',
            '  "sequencer": "', vm.toString(sequencer), '",\n',
            '  "pairId": "', vm.toString(pairId), '",\n',
            '  "deployer": "', vm.toString(deployer), '"\n',
            '}'
        );

        vm.writeFile("deployments.json", json);
        console.log("\nDeployment addresses saved to deployments.json");
    }
}
