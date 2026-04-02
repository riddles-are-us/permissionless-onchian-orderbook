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

        // Deploy USDC
        address usdc = address(new MockERC20("USD Coin", "USDC", 6));
        console.log("USDC deployed at:", usdc);

        // Deploy 9 RWA assets
        address rRE = address(new MockERC20("Residential Real Estate Token", "rRE", 18));
        console.log("rRE deployed at:", rRE);

        address cRE = address(new MockERC20("Commercial Real Estate Token", "cRE", 18));
        console.log("cRE deployed at:", cRE);

        address tGOLD = address(new MockERC20("Tokenized Gold", "tGOLD", 8));
        console.log("tGOLD deployed at:", tGOLD);

        address tSILVER = address(new MockERC20("Tokenized Silver", "tSILVER", 8));
        console.log("tSILVER deployed at:", tSILVER);

        address tSOLAR = address(new MockERC20("Tokenized Solar Energy", "tSOLAR", 18));
        console.log("tSOLAR deployed at:", tSOLAR);

        address tWIND = address(new MockERC20("Tokenized Wind Energy", "tWIND", 18));
        console.log("tWIND deployed at:", tWIND);

        address tOIL = address(new MockERC20("Tokenized Oil", "tOIL", 8));
        console.log("tOIL deployed at:", tOIL);

        address tGAS = address(new MockERC20("Tokenized Natural Gas", "tGAS", 8));
        console.log("tGAS deployed at:", tGAS);

        address CARBON = address(new MockERC20("Carbon Credits Token", "CARBON", 18));
        console.log("CARBON deployed at:", CARBON);

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

        // 6. Register trading pairs (9 RWA assets with USDC)
        console.log("\n=== Registering Trading Pairs ===");

        bytes32 rREPairId = keccak256("rRE/USDC");
        AccountContract(account).registerTradingPair(rREPairId, rRE, usdc);
        console.log("Trading pair rRE/USDC registered");

        bytes32 cREPairId = keccak256("cRE/USDC");
        AccountContract(account).registerTradingPair(cREPairId, cRE, usdc);
        console.log("Trading pair cRE/USDC registered");

        bytes32 tGOLDPairId = keccak256("tGOLD/USDC");
        AccountContract(account).registerTradingPair(tGOLDPairId, tGOLD, usdc);
        console.log("Trading pair tGOLD/USDC registered");

        bytes32 tSILVERPairId = keccak256("tSILVER/USDC");
        AccountContract(account).registerTradingPair(tSILVERPairId, tSILVER, usdc);
        console.log("Trading pair tSILVER/USDC registered");

        bytes32 tSOLARPairId = keccak256("tSOLAR/USDC");
        AccountContract(account).registerTradingPair(tSOLARPairId, tSOLAR, usdc);
        console.log("Trading pair tSOLAR/USDC registered");

        bytes32 tWINDPairId = keccak256("tWIND/USDC");
        AccountContract(account).registerTradingPair(tWINDPairId, tWIND, usdc);
        console.log("Trading pair tWIND/USDC registered");

        bytes32 tOILPairId = keccak256("tOIL/USDC");
        AccountContract(account).registerTradingPair(tOILPairId, tOIL, usdc);
        console.log("Trading pair tOIL/USDC registered");

        bytes32 tGASPairId = keccak256("tGAS/USDC");
        AccountContract(account).registerTradingPair(tGASPairId, tGAS, usdc);
        console.log("Trading pair tGAS/USDC registered");

        bytes32 CARBONPairId = keccak256("CARBON/USDC");
        AccountContract(account).registerTradingPair(CARBONPairId, CARBON, usdc);
        console.log("Trading pair CARBON/USDC registered");

        vm.stopBroadcast();

        // 7. Save deployment info
        uint256 deploymentBlock = block.number;

        console.log("\n=== Deployment Summary ===");
        console.log("USDC:     ", usdc);
        console.log("rRE:      ", rRE);
        console.log("cRE:      ", cRE);
        console.log("tGOLD:    ", tGOLD);
        console.log("tSILVER:  ", tSILVER);
        console.log("tSOLAR:   ", tSOLAR);
        console.log("tWIND:    ", tWIND);
        console.log("tOIL:     ", tOIL);
        console.log("tGAS:     ", tGAS);
        console.log("CARBON:   ", CARBON);
        console.log("Account:  ", account);
        console.log("OrderBook:", orderbook);
        console.log("Sequencer:", sequencer);
        console.log("Block:    ", deploymentBlock);

        // Save to file for matcher to use
        string memory json = string.concat(
            '{\n',
            '  "usdc": "', vm.toString(usdc), '",\n',
            '  "tokens": {\n',
            '    "rRE": "', vm.toString(rRE), '",\n',
            '    "cRE": "', vm.toString(cRE), '",\n',
            '    "tGOLD": "', vm.toString(tGOLD), '",\n',
            '    "tSILVER": "', vm.toString(tSILVER), '",\n',
            '    "tSOLAR": "', vm.toString(tSOLAR), '",\n',
            '    "tWIND": "', vm.toString(tWIND), '",\n',
            '    "tOIL": "', vm.toString(tOIL), '",\n',
            '    "tGAS": "', vm.toString(tGAS), '",\n',
            '    "CARBON": "', vm.toString(CARBON), '"\n',
            '  },\n',
            '  "pairIds": {\n',
            '    "rRE/USDC": "', vm.toString(rREPairId), '",\n',
            '    "cRE/USDC": "', vm.toString(cREPairId), '",\n',
            '    "tGOLD/USDC": "', vm.toString(tGOLDPairId), '",\n',
            '    "tSILVER/USDC": "', vm.toString(tSILVERPairId), '",\n',
            '    "tSOLAR/USDC": "', vm.toString(tSOLARPairId), '",\n',
            '    "tWIND/USDC": "', vm.toString(tWINDPairId), '",\n',
            '    "tOIL/USDC": "', vm.toString(tOILPairId), '",\n',
            '    "tGAS/USDC": "', vm.toString(tGASPairId), '",\n',
            '    "CARBON/USDC": "', vm.toString(CARBONPairId), '"\n',
            '  },\n',
            '  "contracts": {\n',
            '    "account": "', vm.toString(account), '",\n',
            '    "orderbook": "', vm.toString(orderbook), '",\n',
            '    "sequencer": "', vm.toString(sequencer), '"\n',
            '  },\n',
            '  "deployer": "', vm.toString(deployer), '",\n',
            '  "deploymentBlock": ', vm.toString(deploymentBlock), '\n',
            '}'
        );

        vm.writeFile("deployments.json", json);
        console.log("\nDeployment addresses saved to deployments.json");
    }
}
