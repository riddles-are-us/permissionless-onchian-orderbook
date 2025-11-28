// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {OrderBook} from "../OrderBook.sol";
import {Sequencer} from "../Sequencer.sol";
import {Account as AccountContract} from "../Account.sol";
import {MockERC20} from "../MockERC20.sol";

/**
 * @title AutoMatchingTest
 * @notice 测试自动匹配功能 - 验证 batchProcessRequests 是否能准确撮合
 */
contract AutoMatchingTest is Test {
    MockERC20 weth;
    MockERC20 usdc;
    AccountContract account;
    Sequencer sequencer;
    OrderBook orderbook;

    bytes32 pairId;

    address alice = address(0x1);
    address bob = address(0x2);
    address deployer = address(this);

    function setUp() public {
        // 部署代币
        weth = new MockERC20("Wrapped Ether", "WETH", 8);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // 部署核心合约
        account = new AccountContract();
        sequencer = new Sequencer();
        orderbook = new OrderBook();

        // 配置引用
        account.setSequencer(address(sequencer));
        account.setOrderBook(address(orderbook));
        sequencer.setAccount(address(account));
        sequencer.setOrderBook(address(orderbook));
        orderbook.setSequencer(address(sequencer));
        orderbook.setAccount(address(account));

        // 注册交易对
        pairId = keccak256("WETH/USDC");
        account.registerTradingPair(pairId, address(weth), address(usdc));

        // 准备测试资金
        weth.mint(alice, 100 * 10**8);  // 100 WETH
        usdc.mint(alice, 500000 * 10**6);  // 500,000 USDC
        weth.mint(bob, 100 * 10**8);
        usdc.mint(bob, 500000 * 10**6);

        // Approve
        vm.prank(alice);
        weth.approve(address(account), type(uint256).max);
        vm.prank(alice);
        usdc.approve(address(account), type(uint256).max);

        vm.prank(bob);
        weth.approve(address(account), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(account), type(uint256).max);

        // 存入资金到 Account
        vm.prank(alice);
        account.deposit(address(weth), 50 * 10**8);
        vm.prank(alice);
        account.deposit(address(usdc), 200000 * 10**6);

        vm.prank(bob);
        account.deposit(address(weth), 50 * 10**8);
        vm.prank(bob);
        account.deposit(address(usdc), 200000 * 10**6);
    }

    /**
     * @notice 测试1: 单个订单插入后自动匹配
     */
    function test_AutoMatch_SingleOrder() public {
        console.log("\n=== Test 1: Single Order Auto-Matching ===\n");

        // Alice 下卖单: 2000 USDC 卖 1 WETH
        vm.prank(alice);
        (uint256 sellRequestId, uint256 sellOrderId) = sequencer.placeLimitOrder(
            pairId,
            true,  // Ask
            2000 * 10**8,  // 2000 USDC (price with decimals)
            1 * 10**8  // 1 WETH
        );

        console.log("Alice placed sell order:", sellOrderId, "Request:", sellRequestId);
        console.log("  Price: 2000 USDC, Amount: 1 WETH");

        // 插入卖单（不会匹配，因为没有买单）
        uint256[] memory requestIds1 = new uint256[](1);
        uint256[] memory priceLevels1 = new uint256[](1);
        uint256[] memory afterOrders1 = new uint256[](1);
        requestIds1[0] = sellRequestId;
        priceLevels1[0] = 0;
        afterOrders1[0] = 0;

        orderbook.batchProcessRequests(requestIds1, priceLevels1, afterOrders1);
        console.log("  Inserted into orderbook");

        // 验证订单存在
        (uint256 orderId, , uint256 amount, uint256 filledAmount, , , , ) = orderbook.orders(sellOrderId);
        assertEq(orderId, sellOrderId, "Sell order should exist");
        assertEq(filledAmount, 0, "Sell order should not be filled yet");
        console.log("  Verified: Order exists, not filled");

        // Bob 下买单: 2000 USDC 买 1 WETH（价格匹配，应该自动成交）
        vm.prank(bob);
        (uint256 buyRequestId, uint256 buyOrderId) = sequencer.placeLimitOrder(
            pairId,
            false,  // Bid
            2000 * 10**8,  // 2000 USDC (price with decimals)
            1 * 10**8  // 1 WETH
        );

        console.log("\nBob placed buy order:", buyOrderId, "Request:", buyRequestId);
        console.log("  Price: 2000 USDC, Amount: 1 WETH");
        console.log("  Expected: Should AUTO-MATCH with Alice's sell order");

        // 插入买单 - 应该自动触发匹配
        uint256[] memory requestIds2 = new uint256[](1);
        uint256[] memory priceLevels2 = new uint256[](1);
        uint256[] memory afterOrders2 = new uint256[](1);
        requestIds2[0] = buyRequestId;
        priceLevels2[0] = 0;
        afterOrders2[0] = 0;

        vm.recordLogs();
        orderbook.batchProcessRequests(requestIds2, priceLevels2, afterOrders2);

        // 检查事件
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool tradeEventFound = false;
        bool buyOrderFilledFound = false;
        bool sellOrderFilledFound = false;

        for (uint i = 0; i < entries.length; i++) {
            bytes32 eventSig = entries[i].topics[0];

            // Trade event signature
            if (eventSig == keccak256("Trade(bytes32,uint256,uint256,address,address,uint256,uint256)")) {
                tradeEventFound = true;
                console.log("\n  [OK] Trade event emitted");
            }

            // OrderFilled event signature
            if (eventSig == keccak256("OrderFilled(bytes32,uint256,uint256,bool)")) {
                uint256 filledOrderId = uint256(entries[i].topics[2]);
                if (filledOrderId == buyOrderId) {
                    buyOrderFilledFound = true;
                    console.log("  [OK] Buy order filled event emitted");
                } else if (filledOrderId == sellOrderId) {
                    sellOrderFilledFound = true;
                    console.log("  [OK] Sell order filled event emitted");
                }
            }
        }

        assertTrue(tradeEventFound, "Trade event should be emitted");
        assertTrue(buyOrderFilledFound, "Buy order filled event should be emitted");
        assertTrue(sellOrderFilledFound, "Sell order filled event should be emitted");

        // 验证订单已完全成交并被移除
        (uint256 buyId, , , uint256 buyFilled, , , , ) = orderbook.orders(buyOrderId);
        (uint256 sellId, , , uint256 sellFilled, , , , ) = orderbook.orders(sellOrderId);

        assertEq(buyId, 0, "Buy order should be removed (fully filled)");
        assertEq(sellId, 0, "Sell order should be removed (fully filled)");

        console.log("\n  [OK] Both orders removed (fully filled)");
        console.log("\n=== Test 1 PASSED: Auto-matching works! ===\n");
    }

    /**
     * @notice 测试2: 批量插入多个订单，验证自动匹配
     */
    function test_AutoMatch_BatchOrders() public {
        console.log("\n=== Test 2: Batch Orders Auto-Matching ===\n");

        // 准备订单
        // Alice: 3个卖单
        vm.startPrank(alice);
        (, uint256 sell1) = sequencer.placeLimitOrder(pairId, true, 2000 * 10**8, 1 * 10**8);  // 2000 * 1
        (, uint256 sell2) = sequencer.placeLimitOrder(pairId, true, 2100 * 10**8, 2 * 10**8);  // 2100 * 2
        (, uint256 sell3) = sequencer.placeLimitOrder(pairId, true, 2200 * 10**8, 1 * 10**8);  // 2200 * 1
        vm.stopPrank();

        // Bob: 3个买单（可以匹配前2个卖单）
        vm.startPrank(bob);
        (, uint256 buy1) = sequencer.placeLimitOrder(pairId, false, 2000 * 10**8, 1 * 10**8);  // 2000 * 1 (匹配 sell1)
        (, uint256 buy2) = sequencer.placeLimitOrder(pairId, false, 2100 * 10**8, 1 * 10**8);  // 2100 * 1 (部分匹配 sell2)
        (, uint256 buy3) = sequencer.placeLimitOrder(pairId, false, 1900 * 10**8, 1 * 10**8);  // 1900 * 1 (不匹配)
        vm.stopPrank();

        console.log("Orders placed:");
        console.log("  Alice sell orders: 3 (2000, 2100, 2200)");
        console.log("  Bob buy orders: 3 (2000, 2100, 1900)");
        console.log("  Expected matches:");
        console.log("    - Buy1 (2000) matches Sell1 (2000) fully");
        console.log("    - Buy2 (2100) matches Sell2 (2100) partially");
        console.log("    - Sell3 (2200) remains (price too high)");
        console.log("    - Buy3 (1900) remains (price too low)");

        // 批量插入所有订单
        uint256[] memory requestIds = new uint256[](6);
        uint256[] memory priceLevels = new uint256[](6);
        uint256[] memory afterOrders = new uint256[](6);

        requestIds[0] = sell1;
        requestIds[1] = sell2;
        requestIds[2] = sell3;
        requestIds[3] = buy1;
        requestIds[4] = buy2;
        requestIds[5] = buy3;

        // 设置正确的插入位置
        // Ask订单(价格从低到高): 2000 -> 2100 -> 2200
        priceLevels[0] = 0;                  // sell1 (2000): 插入头部
        priceLevels[1] = 2000 * 10**8;       // sell2 (2100): 插入到2000之后
        priceLevels[2] = 2100 * 10**8;       // sell3 (2200): 插入到2100之后

        // Buy订单会触发自动撮合，全部插入头部
        priceLevels[3] = 0;                  // buy1 (2000): 会与sell1匹配
        priceLevels[4] = 0;                  // buy2 (2100): 会与sell2匹配
        priceLevels[5] = 0;                  // buy3 (1900): 不会匹配，保留

        for (uint i = 0; i < 6; i++) {
            afterOrders[i] = 0;
        }

        console.log("\nBatch processing 6 orders...");
        vm.recordLogs();
        uint256 processed = orderbook.batchProcessRequests(requestIds, priceLevels, afterOrders);

        assertEq(processed, 6, "Should process all 6 orders");
        console.log("  Processed:", processed, "orders");

        // 检查匹配事件
        Vm.Log[] memory entries = vm.getRecordedLogs();
        uint256 tradeCount = 0;

        for (uint i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == keccak256("Trade(bytes32,uint256,uint256,address,address,uint256,uint256)")) {
                tradeCount++;
            }
        }

        console.log("  Trade events:", tradeCount);
        assertGt(tradeCount, 0, "Should have trade events");

        // 验证订单状态
        (uint256 sell1Id, , , , , , , ) = orderbook.orders(sell1);
        (uint256 sell2Id, , uint256 sell2Amount, uint256 sell2Filled, , , , ) = orderbook.orders(sell2);
        (uint256 sell3Id, , , , , , , ) = orderbook.orders(sell3);
        (uint256 buy1Id, , , , , , , ) = orderbook.orders(buy1);
        (uint256 buy2Id, , , , , , , ) = orderbook.orders(buy2);
        (uint256 buy3Id, , , , , , , ) = orderbook.orders(buy3);

        console.log("\nOrder states:");
        console.log("  Sell1:", sell1Id == 0 ? "REMOVED" : "EXISTS", "(expected: REMOVED)");
        console.log("  Sell2:", sell2Id == 0 ? "REMOVED" : "EXISTS", "(expected: EXISTS, partially filled)");
        if (sell2Id != 0) {
            console.log("    Amount:", sell2Amount / 10**8, "WETH");
            console.log("    Filled:", sell2Filled / 10**8, "WETH");
        }
        console.log("  Sell3:", sell3Id == 0 ? "REMOVED" : "EXISTS", "(expected: EXISTS)");
        console.log("  Buy1:", buy1Id == 0 ? "REMOVED" : "EXISTS", "(expected: REMOVED)");
        console.log("  Buy2:", buy2Id == 0 ? "REMOVED" : "EXISTS", "(expected: REMOVED)");
        console.log("  Buy3:", buy3Id == 0 ? "REMOVED" : "EXISTS", "(expected: EXISTS)");

        // 验证预期状态
        assertEq(sell1Id, 0, "Sell1 should be fully filled and removed");
        assertNotEq(sell2Id, 0, "Sell2 should still exist (partially filled)");
        assertNotEq(sell3Id, 0, "Sell3 should still exist (no match)");
        assertEq(buy1Id, 0, "Buy1 should be fully filled and removed");
        assertEq(buy2Id, 0, "Buy2 should be fully filled and removed");
        assertNotEq(buy3Id, 0, "Buy3 should still exist (no match)");

        if (sell2Id != 0) {
            assertGt(sell2Filled, 0, "Sell2 should be partially filled");
            assertLt(sell2Filled, sell2Amount, "Sell2 should not be fully filled");
        }

        console.log("\n=== Test 2 PASSED: Batch auto-matching works correctly! ===\n");
    }

    /**
     * @notice 测试3: 市价单自动匹配
     */
    function test_AutoMatch_MarketOrder() public {
        console.log("\n=== Test 3: Market Order Auto-Matching ===\n");

        // Alice 先下限价卖单
        vm.prank(alice);
        (, uint256 limitSell) = sequencer.placeLimitOrder(pairId, true, 2000 * 10**8, 5 * 10**8);  // 2000 * 5 WETH

        uint256[] memory requestIds1 = new uint256[](1);
        uint256[] memory priceLevels1 = new uint256[](1);
        uint256[] memory afterOrders1 = new uint256[](1);
        requestIds1[0] = limitSell;

        orderbook.batchProcessRequests(requestIds1, priceLevels1, afterOrders1);
        console.log("Alice placed limit sell: 5 WETH @ 2000 USDC");

        // Bob 下市价买单（应该立即与 Alice 的限价单匹配）
        // 新语义：市价买单的 amount 是要花费的 quote tokens (USDC)
        // 要买 3 WETH @ 2000 USDC/WETH = 6000 USDC
        vm.prank(bob);
        (, uint256 marketBuy) = sequencer.placeMarketOrder(pairId, false, 6000 * 10**8);  // Spend 6000 USDC

        console.log("Bob placed market buy: spend 6000 USDC (to buy ~3 WETH @ 2000)");
        console.log("  Expected: Should immediately match 3 WETH from Alice's sell order");

        vm.recordLogs();
        orderbook.insertMarketOrder(marketBuy);

        // 检查事件
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool tradeFound = false;
        for (uint i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == keccak256("Trade(bytes32,uint256,uint256,address,address,uint256,uint256)")) {
                tradeFound = true;
                console.log("  [OK] Trade event found");
                break;
            }
        }

        assertTrue(tradeFound, "Market order should trigger trade");

        // 验证订单状态
        (uint256 marketId, , , , , , , ) = orderbook.orders(marketBuy);
        (uint256 limitId, , uint256 limitAmount, uint256 limitFilled, , , , ) = orderbook.orders(limitSell);

        assertEq(marketId, 0, "Market order should be fully filled and removed");
        assertNotEq(limitId, 0, "Limit order should still exist");
        assertEq(limitFilled, 3 * 10**8, "Limit order should be partially filled (3 WETH)");
        assertEq(limitAmount - limitFilled, 2 * 10**8, "Limit order should have 2 WETH remaining");

        console.log("\nResults:");
        console.log("  Market buy order: REMOVED (fully filled)");
        console.log("  Limit sell order: PARTIALLY FILLED");
        console.log("    Filled: 3 WETH, Remaining: 2 WETH");

        console.log("\n=== Test 3 PASSED: Market order auto-matching works! ===\n");
    }

    /**
     * @notice 测试4: 连续多次匹配（测试 maxIterations）
     */
    function test_AutoMatch_MultipleMatches() public {
        console.log("\n=== Test 4: Multiple Sequential Matches ===\n");

        // Alice 下多个小额卖单
        vm.startPrank(alice);
        uint256[] memory sells = new uint256[](5);
        for (uint i = 0; i < 5; i++) {
            (, sells[i]) = sequencer.placeLimitOrder(pairId, true, 2000 * 10**8, 5 * 10**7);  // 2000 * 0.5 WETH each
        }
        vm.stopPrank();

        // 批量插入卖单
        uint256[] memory sellIds = new uint256[](5);
        uint256[] memory sellPriceLevels = new uint256[](5);
        uint256[] memory sellAfterOrders = new uint256[](5);
        for (uint i = 0; i < 5; i++) {
            sellIds[i] = sells[i];
        }
        orderbook.batchProcessRequests(sellIds, sellPriceLevels, sellAfterOrders);

        console.log("Alice placed 5 sell orders: 0.5 WETH each @ 2000 USDC");
        console.log("  Total: 2.5 WETH available");

        // Bob 下一个大额买单（应该匹配多个卖单）
        vm.prank(bob);
        (, uint256 bigBuy) = sequencer.placeLimitOrder(pairId, false, 2000 * 10**8, 25 * 10**7);  // Buy 2.5 WETH

        console.log("\nBob placed buy order: 2.5 WETH @ 2000 USDC");
        console.log("  Expected: Should match all 5 sell orders (0.5 * 5 = 2.5)");

        uint256[] memory buyIds = new uint256[](1);
        uint256[] memory buyPriceLevels = new uint256[](1);
        uint256[] memory buyAfterOrders = new uint256[](1);
        buyIds[0] = bigBuy;

        vm.recordLogs();
        orderbook.batchProcessRequests(buyIds, buyPriceLevels, buyAfterOrders);

        // 统计 Trade 事件
        Vm.Log[] memory entries = vm.getRecordedLogs();
        uint256 tradeCount = 0;
        for (uint i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == keccak256("Trade(bytes32,uint256,uint256,address,address,uint256,uint256)")) {
                tradeCount++;
            }
        }

        console.log("\n  Trade events:", tradeCount);
        assertEq(tradeCount, 5, "Should have 5 trade events (one for each sell order)");

        // 验证所有订单都被移除
        for (uint i = 0; i < 5; i++) {
            (uint256 orderId, , , , , , , ) = orderbook.orders(sells[i]);
            assertEq(orderId, 0, "All sell orders should be removed");
        }

        (uint256 buyId, , , , , , , ) = orderbook.orders(bigBuy);
        assertEq(buyId, 0, "Buy order should be removed");

        console.log("  [OK] All 6 orders removed (fully matched)");
        console.log("\n=== Test 4 PASSED: Multiple sequential matches work! ===\n");
    }
}
