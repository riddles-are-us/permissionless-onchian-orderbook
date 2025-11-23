// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {Account as AccountContract} from "../Account.sol";
import {Sequencer} from "../Sequencer.sol";
import {MockERC20} from "../MockERC20.sol";

contract PrepareTestScript is Script {
    function run() external {
        // Read deployment addresses
        string memory json = vm.readFile("deployments.json");

        address weth = vm.parseJsonAddress(json, ".weth");
        address usdc = vm.parseJsonAddress(json, ".usdc");
        address account = vm.parseJsonAddress(json, ".account");
        address sequencer = vm.parseJsonAddress(json, ".sequencer");
        bytes32 pairId = vm.parseJsonBytes32(json, ".pairId");

        // Get test user private key
        uint256 userPrivateKey = vm.envUint("USER_PRIVATE_KEY");
        address user = vm.addr(userPrivateKey);

        console.log("\n=== Preparing Test Data ===");
        console.log("Test user:", user);
        console.log("User balance:", user.balance);

        vm.startBroadcast(userPrivateKey);

        // 1. Mint tokens to user
        console.log("\n--- Minting Tokens ---");

        // Switch to deployer to mint
        vm.stopBroadcast();
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        MockERC20(weth).mint(user, 100 ether);
        console.log("Minted 100 WETH to user");

        MockERC20(usdc).mint(user, 100_000 * 10**6);
        console.log("Minted 100,000 USDC to user");

        vm.stopBroadcast();

        // Switch back to user
        vm.startBroadcast(userPrivateKey);

        // 2. Approve Account contract
        console.log("\n--- Approving Tokens ---");
        MockERC20(weth).approve(account, type(uint256).max);
        console.log("Approved WETH");

        MockERC20(usdc).approve(account, type(uint256).max);
        console.log("Approved USDC");

        // 3. Deposit to Account
        console.log("\n--- Depositing to Account ---");
        AccountContract(account).deposit(weth, 10 ether);
        console.log("Deposited 10 WETH");

        AccountContract(account).deposit(usdc, 10_000 * 10**6);
        console.log("Deposited 10,000 USDC");

        // Check balances
        (uint256 wethAvail, uint256 wethLocked, uint256 wethTotal) = AccountContract(account).getBalance(user, weth);
        (uint256 usdcAvail, uint256 usdcLocked, uint256 usdcTotal) = AccountContract(account).getBalance(user, usdc);

        console.log("\nUser balances in Account:");
        console.log("  WETH - Available:", wethAvail / 1e18);
        console.log("  WETH - Locked:", wethLocked / 1e18);
        console.log("  WETH - Total:", wethTotal / 1e18);
        console.log("  USDC - Available:", usdcAvail / 1e6);
        console.log("  USDC - Locked:", usdcLocked / 1e6);
        console.log("  USDC - Total:", usdcTotal / 1e6);

        // 4. Place test orders
        console.log("\n--- Placing Test Orders ---");

        // Order 1: Buy @ 2000 USDC
        (uint256 reqId1, uint256 orderId1) = Sequencer(sequencer).placeLimitOrder(
            pairId,
            false, // bid
            2000 * 10**8, // price with PRICE_DECIMALS
            1 * 10**8 // amount with AMOUNT_DECIMALS
        );
        console.log("Order 1: Buy 1 WETH @ 2000 USDC - RequestID:", reqId1, "OrderID:", orderId1);

        // Order 2: Buy @ 1950 USDC
        (uint256 reqId2, uint256 orderId2) = Sequencer(sequencer).placeLimitOrder(
            pairId,
            false,
            1950 * 10**8,
            1 * 10**8
        );
        console.log("Order 2: Buy 1 WETH @ 1950 USDC - RequestID:", reqId2, "OrderID:", orderId2);

        // Order 3: Buy @ 1900 USDC
        (uint256 reqId3, uint256 orderId3) = Sequencer(sequencer).placeLimitOrder(
            pairId,
            false,
            1900 * 10**8,
            1 * 10**8
        );
        console.log("Order 3: Buy 1 WETH @ 1900 USDC - RequestID:", reqId3, "OrderID:", orderId3);

        vm.stopBroadcast();

        // 5. Check queue status
        console.log("\n--- Queue Status ---");
        uint256 queueHead = Sequencer(sequencer).queueHead();
        uint256 queueLength = Sequencer(sequencer).getQueueLength(100);

        console.log("Queue head:", queueHead);
        console.log("Queue length:", queueLength);

        if (queueLength > 0) {
            console.log("\nQueued orders ready for matcher to process!");
        }

        console.log("\n=== Test Data Prepared ===");
    }
}
