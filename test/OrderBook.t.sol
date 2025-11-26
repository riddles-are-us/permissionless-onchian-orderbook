// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {Sequencer} from "../Sequencer.sol";
import {OrderBook} from "../OrderBook.sol";
import {MockERC20} from "../MockERC20.sol";
import {ISequencer} from "../ISequencer.sol";
import {Account as AccountContract} from "../Account.sol";

/**
 * @title OrderBookTest
 * @notice Foundry测试合约 - 使用Solidity编写测试
 */
contract OrderBookTest is Test {
    // 合约实例
    MockERC20 public weth;
    MockERC20 public usdc;
    AccountContract public accountContract;
    Sequencer public sequencer;
    OrderBook public orderBook;

    // 测试账户
    address public deployer;
    address public alice;
    address public bob;

    // 交易对ID
    bytes32 public pairId;

    // 订单ID追踪
    uint256[] public aliceOrderIds;
    uint256[] public bobOrderIds;

    function setUp() public {
        console.log("\n========================================");
        console.log("Deploying OrderBook System");
        console.log("========================================\n");

        // 设置测试账户
        deployer = address(this);
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        console.log("Test Accounts:");
        console.log("  Deployer:", deployer);
        console.log("  Alice:   ", alice);
        console.log("  Bob:     ", bob);

        // 部署代币
        console.log("\nDeploying Tokens...");
        weth = new MockERC20("Wrapped ETH", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        console.log("  WETH:", address(weth));
        console.log("  USDC:", address(usdc));

        // 部署核心合约
        console.log("\nDeploying Core Contracts...");
        accountContract = new AccountContract();
        sequencer = new Sequencer();
        orderBook = new OrderBook();
        console.log("  Account: ", address(accountContract));
        console.log("  Sequencer:", address(sequencer));
        console.log("  OrderBook:", address(orderBook));

        // 配置合约关系
        console.log("\nConfiguring Contract References...");
        sequencer.setAccount(address(accountContract));
        sequencer.setOrderBook(address(orderBook));
        orderBook.setSequencer(address(sequencer));
        orderBook.setAccount(address(accountContract));
        accountContract.setSequencer(address(sequencer));
        accountContract.setOrderBook(address(orderBook));
        console.log("  All references set");

        // 注册交易对
        console.log("\nRegistering Trading Pair...");
        pairId = keccak256("WETH/USDC");
        accountContract.registerTradingPair(pairId, address(weth), address(usdc));
        console.log("  WETH/USDC registered");

        // 准备测试资金
        console.log("\nPreparing Test Funds...");
        _setupFunds();

        console.log("\n========================================");
        console.log("Setup Complete - Starting Tests");
        console.log("========================================\n");
    }

    function _setupFunds() internal {
        // Alice: 10 WETH + 50000 USDC
        weth.mint(alice, 10 ether);
        usdc.mint(alice, 50000 * 10**6);

        vm.startPrank(alice);
        weth.approve(address(accountContract), 10 ether);
        usdc.approve(address(accountContract), 50000 * 10**6);
        accountContract.deposit(address(weth), 10 ether);
        accountContract.deposit(address(usdc), 50000 * 10**6);
        vm.stopPrank();

        console.log("  Alice: 10 WETH, 50000 USDC");

        // Bob: 5 WETH + 30000 USDC
        weth.mint(bob, 5 ether);
        usdc.mint(bob, 30000 * 10**6);

        vm.startPrank(bob);
        weth.approve(address(accountContract), 5 ether);
        usdc.approve(address(accountContract), 30000 * 10**6);
        accountContract.deposit(address(weth), 5 ether);
        accountContract.deposit(address(usdc), 30000 * 10**6);
        vm.stopPrank();

        console.log("  Bob: 5 WETH, 30000 USDC");
    }

    function testPlaceOrders() public {
        console.log("\n--- Test: Place Orders ---");

        // Alice 下买单
        console.log("\nAlice placing buy orders:");
        vm.startPrank(alice);

        (uint256 requestId1, uint256 orderId1) = sequencer.placeLimitOrder(
            pairId,
            false,  // 买单
            2000 * 10**8,  // 价格 (带精度)
            1 * 10**8  // 数量 (带精度，1个WETH)
        );
        aliceOrderIds.push(orderId1);
        console.log("  Order", orderId1, ": 2000 USDC buy 1 WETH");

        (uint256 requestId2, uint256 orderId2) = sequencer.placeLimitOrder(
            pairId,
            false,
            1950 * 10**8,  // 价格
            2 * 10**8      // 数量 (2个WETH)
        );
        aliceOrderIds.push(orderId2);
        console.log("  Order", orderId2, ": 1950 USDC buy 2 WETH");

        (uint256 requestId3, uint256 orderId3) = sequencer.placeLimitOrder(
            pairId,
            false,
            1900 * 10**8,  // 价格
            1 * 10**8      // 数量
        );
        aliceOrderIds.push(orderId3);
        console.log("  Order", orderId3, ": 1900 USDC buy 1 WETH");

        vm.stopPrank();

        // Bob 下卖单
        console.log("\nBob placing sell orders:");
        vm.startPrank(bob);

        (uint256 requestId4, uint256 orderId4) = sequencer.placeLimitOrder(
            pairId,
            true,  // 卖单
            2100 * 10**8,  // 价格
            1 * 10**8      // 数量
        );
        bobOrderIds.push(orderId4);
        console.log("  Order", orderId4, ": 2100 USDC sell 1 WETH");

        (uint256 requestId5, uint256 orderId5) = sequencer.placeLimitOrder(
            pairId,
            true,
            2150 * 10**8,     // 价格
            15 * 10**7        // 数量 (1.5个WETH = 1.5 * 10^8)
        );
        bobOrderIds.push(orderId5);
        console.log("  Order", orderId5, ": 2150 USDC sell 1.5 WETH");

        (uint256 requestId6, uint256 orderId6) = sequencer.placeLimitOrder(
            pairId,
            true,
            2200 * 10**8,     // 价格
            5 * 10**7         // 数量 (0.5个WETH = 0.5 * 10^8)
        );
        bobOrderIds.push(orderId6);
        console.log("  Order", orderId6, ": 2200 USDC sell 0.5 WETH");

        vm.stopPrank();

        // 验证订单已在Sequencer中
        assertEq(aliceOrderIds.length, 3);
        assertEq(bobOrderIds.length, 3);
    }

    function testBatchInsertOrders() public {
        // 先下单
        testPlaceOrders();

        console.log("\n--- Test: Batch Insert Orders ---");

        // 准备批量插入参数
        uint256[] memory allOrderIds = new uint256[](6);
        allOrderIds[0] = aliceOrderIds[0];  // 买单 2000
        allOrderIds[1] = aliceOrderIds[1];  // 买单 1950
        allOrderIds[2] = aliceOrderIds[2];  // 买单 1900
        allOrderIds[3] = bobOrderIds[0];    // 卖单 2100
        allOrderIds[4] = bobOrderIds[1];    // 卖单 2150
        allOrderIds[5] = bobOrderIds[2];    // 卖单 2200

        uint256[] memory insertAfterPriceLevels = new uint256[](6);
        uint256[] memory insertAfterOrders = new uint256[](6);

        // 设置插入位置：
        // 买单按价格从高到低：2000(头) -> 1950 -> 1900
        insertAfterPriceLevels[0] = 0;  // 2000插入到头部
        insertAfterPriceLevels[1] = 2000 * 10**8;  // 1950插入到价格2000之后
        insertAfterPriceLevels[2] = 1950 * 10**8;  // 1900插入到价格1950之后

        // 卖单按价格从低到高：2100(头) -> 2150 -> 2200
        insertAfterPriceLevels[3] = 0;  // 2100插入到头部
        insertAfterPriceLevels[4] = 2100 * 10**8;  // 2150插入到价格2100之后
        insertAfterPriceLevels[5] = 2150 * 10**8;  // 2200插入到价格2150之后

        console.log("\nBatch inserting 6 orders...");
        uint256 processedCount = orderBook.batchProcessRequests(
            allOrderIds,
            insertAfterPriceLevels,
            insertAfterOrders
        );

        console.log("  Processed count:", processedCount);
        assertEq(processedCount, 6);

        // 验证订单簿不为空
        (uint256 askHead, uint256 askTail, uint256 bidHead, uint256 bidTail, , , , ) = orderBook.orderBooks(pairId);
        console.log("  Bid Head:", bidHead);
        console.log("  Ask Head:", askHead);

        assertTrue(bidHead != 0);
        assertTrue(askHead != 0);
    }

    function testOrderBookStructure() public {
        // 先插入订单
        testBatchInsertOrders();

        console.log("\n--- Test: OrderBook Structure ---");

        (uint256 askHead, uint256 askTail, uint256 bidHead, uint256 bidTail, , , , ) = orderBook.orderBooks(pairId);

        // 遍历买单价格层级
        console.log("\nBid Price Levels:");
        uint256 currentPriceLevel = bidHead;
        uint256 bidLevels = 0;
        while (currentPriceLevel != 0) {
            OrderBook.PriceLevel memory level = orderBook.getPriceLevel(currentPriceLevel, false);
            console.log("  Price (USDC):", level.price / 10**6);
            console.log("  Volume (WETH):", level.totalVolume / 1 ether);
            currentPriceLevel = level.nextPrice;
            bidLevels++;
        }

        // 遍历卖单价格层级
        console.log("\nAsk Price Levels:");
        currentPriceLevel = askHead;
        uint256 askLevels = 0;
        while (currentPriceLevel != 0) {
            OrderBook.PriceLevel memory level = orderBook.getPriceLevel(currentPriceLevel, true);
            console.log("  Price (USDC):", level.price / 10**6);
            console.log("  Volume (WETH):", level.totalVolume / 1 ether);
            currentPriceLevel = level.nextPrice;
            askLevels++;
        }

        assertEq(bidLevels, 3);
        assertEq(askLevels, 3);
    }

    function testAccountBalances() public {
        // 先插入订单
        testBatchInsertOrders();

        console.log("\n--- Test: Account Balances ---");

        // Alice 余额
        (uint256 aliceWethAvail, uint256 aliceWethLocked, uint256 aliceWethTotal) = accountContract.getBalance(alice, address(weth));
        (uint256 aliceUsdcAvail, uint256 aliceUsdcLocked, uint256 aliceUsdcTotal) = accountContract.getBalance(alice, address(usdc));

        console.log("\nAlice:");
        console.log("  WETH: available =", aliceWethAvail / 1 ether, ", locked =", aliceWethLocked / 1 ether);
        console.log("  USDC: available =", aliceUsdcAvail / 10**6, ", locked =", aliceUsdcLocked / 10**6);

        // Bob 余额
        (uint256 bobWethAvail, uint256 bobWethLocked, uint256 bobWethTotal) = accountContract.getBalance(bob, address(weth));
        (uint256 bobUsdcAvail, uint256 bobUsdcLocked, uint256 bobUsdcTotal) = accountContract.getBalance(bob, address(usdc));

        console.log("\nBob:");
        console.log("  WETH: available =", bobWethAvail / 1 ether, ", locked =", bobWethLocked / 1 ether);
        console.log("  USDC: available =", bobUsdcAvail / 10**6, ", locked =", bobUsdcLocked / 10**6);

        // 验证锁定金额
        // Alice 应该锁定 2000*1 + 1950*2 + 1900*1 = 7800 USDC
        assertEq(aliceUsdcLocked, 7800 * 10**6);

        // Bob 应该锁定 1 + 1.5 + 0.5 = 3 WETH
        assertEq(bobWethLocked, 3 ether);
    }

    function testRemoveOrder() public {
        // 先插入订单
        testBatchInsertOrders();

        console.log("\n--- Test: Remove Order ---");

        // 获取Alice第一个订单
        uint256 orderToRemove = aliceOrderIds[0];
        console.log("\nRemoving order:", orderToRemove);

        // Alice 请求撤单
        vm.prank(alice);
        uint256 removeRequestId = sequencer.requestRemoveOrder(orderToRemove);
        console.log("  Remove request ID:", removeRequestId);

        // 处理撤单请求
        orderBook.processRemoveOrder(removeRequestId);
        console.log("  Order removed");

        // 验证资金已解锁
        (uint256 aliceUsdcAvail, uint256 aliceUsdcLocked, ) = accountContract.getBalance(alice, address(usdc));
        console.log("\nAlice USDC after removal:");
        console.log("  Available:", aliceUsdcAvail / 10**6);
        console.log("  Locked:", aliceUsdcLocked / 10**6);

        // 锁定应该减少 2000 USDC
        assertEq(aliceUsdcLocked, 5800 * 10**6);
    }

    function testMarketOrder() public {
        console.log("\n--- Test: Market Order ---");

        // Bob 下市价卖单
        console.log("\nBob placing market sell order:");
        vm.prank(bob);
        (uint256 requestId, uint256 orderId) = sequencer.placeMarketOrder(
            pairId,
            true,  // 市价卖单
            5 * 10**7  // 数量 (0.5个WETH)
        );
        console.log("  Market order", orderId, ": sell 0.5 WETH");

        // 插入市价单
        uint256[] memory orderIds = new uint256[](1);
        orderIds[0] = orderId;
        uint256[] memory insertAfterPriceLevels = new uint256[](1);
        uint256[] memory insertAfterOrders = new uint256[](1);

        uint256 processedCount = orderBook.batchProcessRequests(
            orderIds,
            insertAfterPriceLevels,
            insertAfterOrders
        );

        console.log("  Processed:", processedCount);
        assertEq(processedCount, 1);

        // 验证市价单在OrderBook中
        (, , , , uint256 marketAskHead, , , ) = orderBook.orderBooks(pairId);
        assertTrue(marketAskHead != 0);
        console.log("  Market ask head:", marketAskHead);
    }

    function testCompleteFlow() public {
        console.log("\n========================================");
        console.log("Complete Flow Test");
        console.log("========================================");

        // 下单
        testPlaceOrders();

        console.log("\n--- Test: Batch Insert Orders ---");
        // 准备批量插入参数
        uint256[] memory allOrderIds = new uint256[](6);
        allOrderIds[0] = aliceOrderIds[0];
        allOrderIds[1] = aliceOrderIds[1];
        allOrderIds[2] = aliceOrderIds[2];
        allOrderIds[3] = bobOrderIds[0];
        allOrderIds[4] = bobOrderIds[1];
        allOrderIds[5] = bobOrderIds[2];

        uint256[] memory insertAfterPriceLevels = new uint256[](6);
        uint256[] memory insertAfterOrders = new uint256[](6);
        insertAfterPriceLevels[0] = 0;                 // 2000插入到头部
        insertAfterPriceLevels[1] = 2000 * 10**8;     // 1950插入到价格2000之后
        insertAfterPriceLevels[2] = 1950 * 10**8;     // 1900插入到价格1950之后
        insertAfterPriceLevels[3] = 0;                 // 2100插入到头部
        insertAfterPriceLevels[4] = 2100 * 10**8;     // 2150插入到价格2100之后
        insertAfterPriceLevels[5] = 2150 * 10**8;     // 2200插入到价格2150之后

        console.log("\nBatch inserting 6 orders...");
        uint256 processedCount = orderBook.batchProcessRequests(
            allOrderIds,
            insertAfterPriceLevels,
            insertAfterOrders
        );
        console.log("  Processed count:", processedCount);
        assertEq(processedCount, 6);

        // 检查订单簿结构
        (uint256 askHead, , uint256 bidHead, , , , , ) = orderBook.orderBooks(pairId);
        console.log("  Bid Head:", bidHead);
        console.log("  Ask Head:", askHead);
        assertTrue(bidHead != 0);
        assertTrue(askHead != 0);

        // 检查账户余额
        console.log("\n--- Test: Account Balances ---");
        (,uint256 aliceUsdcLocked,) = accountContract.getBalance(alice, address(usdc));
        (,uint256 bobWethLocked,) = accountContract.getBalance(bob, address(weth));
        assertEq(aliceUsdcLocked, 7800 * 10**6);
        assertEq(bobWethLocked, 3 ether);

        // 撤单测试
        console.log("\n--- Test: Remove Order ---");
        uint256 orderToRemove = aliceOrderIds[0];
        console.log("\nRemoving order:", orderToRemove);

        vm.prank(alice);
        uint256 removeRequestId = sequencer.requestRemoveOrder(orderToRemove);
        console.log("  Remove request ID:", removeRequestId);

        orderBook.processRemoveOrder(removeRequestId);
        console.log("  Order removed");

        (,uint256 aliceUsdcLockedAfter,) = accountContract.getBalance(alice, address(usdc));
        console.log("  Alice USDC locked after removal:", aliceUsdcLockedAfter / 10**6);
        assertEq(aliceUsdcLockedAfter, 5800 * 10**6);

        console.log("\n========================================");
        console.log("All Tests Passed!");
        console.log("========================================\n");
    }
}
