// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../Sequencer.sol";
import "../MockERC20.sol";

/**
 * @title PlaceMatchingOrders
 * @notice 下两个会自动匹配的订单，用于测试自动撮合功能
 */
contract PlaceMatchingOrders is Script {
    function run() external {
        // 从 deployments.json 读取配置
        string memory json = vm.readFile("deployments.json");

        address wethAddr = vm.parseJsonAddress(json, ".weth");
        address usdcAddr = vm.parseJsonAddress(json, ".usdc");
        address sequencerAddr = vm.parseJsonAddress(json, ".sequencer");
        bytes32 pairId = vm.parseJsonBytes32(json, ".pairId");

        MockERC20 weth = MockERC20(wethAddr);
        MockERC20 usdc = MockERC20(usdcAddr);
        Sequencer sequencer = Sequencer(sequencerAddr);

        vm.startBroadcast();

        console.log("\n=== Placing Matching Orders ===\n");

        // 1. 先下一个卖单：1 WETH @ 2000 USDC
        console.log("1. Placing SELL order: 1 WETH @ 2000 USDC");
        (uint256 sellOrderId, uint256 sellRequestId) = sequencer.placeLimitOrder(
            pairId,
            true,                    // is_ask = true (sell)
            2000 * 10**8,           // price = 2000 USDC
            1 * 10**8               // amount = 1 WETH
        );
        console.log("   Sell order placed:");
        console.log("     Order ID:", sellOrderId);
        console.log("     Request ID:", sellRequestId);

        // 2. 再下一个买单：1 WETH @ 2000 USDC（价格相同，会匹配）
        console.log("\n2. Placing BUY order: 1 WETH @ 2000 USDC");
        console.log("   This order should AUTO-MATCH with the sell order!\n");

        (uint256 buyOrderId, uint256 buyRequestId) = sequencer.placeLimitOrder(
            pairId,
            false,                   // is_ask = false (buy)
            2000 * 10**8,           // price = 2000 USDC
            1 * 10**8               // amount = 1 WETH
        );
        console.log("   Buy order placed:");
        console.log("     Order ID:", buyOrderId);
        console.log("     Request ID:", buyRequestId);

        console.log("\n=== Orders placed successfully! ===");
        console.log("Sell Request ID:", sellRequestId);
        console.log("Buy Request ID:", buyRequestId);
        console.log("\nExpected behavior:");
        console.log("  1. Matcher will process sellRequestId first");
        console.log("  2. Matcher will insert sell order into orderbook");
        console.log("  3. Matcher will process buyRequestId");
        console.log("  4. When buy order is inserted, AUTO-MATCH should trigger!");
        console.log("  5. Trade event should be emitted");
        console.log("  6. Both orders should be fully filled and removed");
        console.log("\nWatch the matcher logs for Trade events!\n");

        vm.stopBroadcast();
    }
}
