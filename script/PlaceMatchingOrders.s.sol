// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../Sequencer.sol";
import "../MockERC20.sol";

/**
 * @title PlaceMatchingOrders
 * @notice 下会触发撮合的订单，用于测试 matcher 对撮合情况的处理
 *
 * 当前订单簿状态（假设）:
 * - Bid (买单): 价格从高到低 2000, 1990, 1980, 1970, 1960
 * - Ask (卖单): 价格从低到高 2010, 2020, 2030, 2040, 2050
 *
 * 测试场景: 下一批价格会交叉的订单
 * - 卖单 at 1990, 2000 (会和现有买单撮合)
 * - 买单 at 2010, 2020 (会和现有卖单撮合)
 */
contract PlaceMatchingOrders is Script {
    function run() external {
        // 从 deployments.json 读取配置
        string memory json = vm.readFile("deployments.json");

        address sequencerAddr = vm.parseJsonAddress(json, ".sequencer");
        bytes32 pairId = vm.parseJsonBytes32(json, ".pairId");

        Sequencer sequencer = Sequencer(sequencerAddr);

        vm.startBroadcast();

        console.log("\n=== Placing Orders That Will Trigger Matching ===\n");
        console.log("Current orderbook (expected):");
        console.log("  Bid head: 2000 USDC");
        console.log("  Ask head: 2010 USDC");
        console.log("");

        // 下4个卖单，其中2个价格会和买单交叉
        console.log("Placing SELL orders:");

        // 卖单1: @ 1990 USDC (低于最高买价 2000，会被撮合)
        (uint256 reqId1,) = sequencer.placeLimitOrder(
            pairId, true, 1990 * 10**8, 5 * 10**6  // 0.05 WETH
        );
        console.log("  [1] Sell @ 1990 USDC, 0.05 WETH - WILL MATCH with bid", reqId1);

        // 卖单2: @ 2000 USDC (等于最高买价 2000，会被撮合)
        (uint256 reqId2,) = sequencer.placeLimitOrder(
            pairId, true, 2000 * 10**8, 5 * 10**6  // 0.05 WETH
        );
        console.log("  [2] Sell @ 2000 USDC, 0.05 WETH - WILL MATCH with bid", reqId2);

        // 卖单3: @ 2005 USDC (低于最低卖价 2010，会插入但不撮合)
        (uint256 reqId3,) = sequencer.placeLimitOrder(
            pairId, true, 2005 * 10**8, 5 * 10**6  // 0.05 WETH
        );
        console.log("  [3] Sell @ 2005 USDC, 0.05 WETH - insert only, no match", reqId3);

        // 卖单4: @ 2015 USDC (高于最低卖价 2010，会插入但不撮合)
        (uint256 reqId4,) = sequencer.placeLimitOrder(
            pairId, true, 2015 * 10**8, 5 * 10**6  // 0.05 WETH
        );
        console.log("  [4] Sell @ 2015 USDC, 0.05 WETH - insert only, no match", reqId4);

        console.log("\nPlacing BUY orders:");

        // 买单1: @ 2010 USDC (等于最低卖价 2010，会被撮合)
        (uint256 reqId5,) = sequencer.placeLimitOrder(
            pairId, false, 2010 * 10**8, 5 * 10**6  // 0.05 WETH
        );
        console.log("  [5] Buy @ 2010 USDC, 0.05 WETH - WILL MATCH with ask", reqId5);

        // 买单2: @ 2020 USDC (高于最低卖价 2010，会被撮合)
        (uint256 reqId6,) = sequencer.placeLimitOrder(
            pairId, false, 2020 * 10**8, 5 * 10**6  // 0.05 WETH
        );
        console.log("  [6] Buy @ 2020 USDC, 0.05 WETH - WILL MATCH with ask", reqId6);

        // 买单3: @ 1995 USDC (低于最高买价 2000，会插入但不撮合)
        (uint256 reqId7,) = sequencer.placeLimitOrder(
            pairId, false, 1995 * 10**8, 5 * 10**6  // 0.05 WETH
        );
        console.log("  [7] Buy @ 1995 USDC, 0.05 WETH - insert only, no match", reqId7);

        // 买单4: @ 1985 USDC (低于最高买价 2000，会插入但不撮合)
        (uint256 reqId8,) = sequencer.placeLimitOrder(
            pairId, false, 1985 * 10**8, 5 * 10**6  // 0.05 WETH
        );
        console.log("  [8] Buy @ 1985 USDC, 0.05 WETH - insert only, no match", reqId8);

        console.log("\n=== Summary ===");
        console.log("Total: 8 orders placed");
        console.log("Expected matches: 4 orders (reqId1, reqId2, reqId5, reqId6)");
        console.log("Expected inserts: 4 orders (reqId3, reqId4, reqId7, reqId8)");
        console.log("\nMatcher should:");
        console.log("  1. Calculate insertAfterPrice for each order");
        console.log("  2. Consider that matched orders will be REMOVED from orderbook");
        console.log("  3. Not use removed orders' price as insertAfterPrice for subsequent orders");
        console.log("\nWatch the matcher logs!\n");

        vm.stopBroadcast();
    }
}
