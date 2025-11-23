// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {OrderBook} from "../OrderBook.sol";
import {Sequencer} from "../Sequencer.sol";
import {Account as AccountContract} from "../Account.sol";
import {MockERC20} from "../MockERC20.sol";

contract GasTest is Test {
    OrderBook public orderbook;
    Sequencer public sequencer;
    AccountContract public account;
    MockERC20 public weth;
    MockERC20 public usdc;

    address public trader1 = address(0x1);
    address public trader2 = address(0x2);
    address public matcher = address(0x999);

    bytes32 public pairId;

    function setUp() public {
        // 部署代币
        weth = new MockERC20("WETH", "WETH", 18);
        usdc = new MockERC20("USDC", "USDC", 6);

        // 部署核心合约
        account = new AccountContract();
        orderbook = new OrderBook();
        sequencer = new Sequencer();

        // 配置合约关系
        account.setOrderBook(address(orderbook));
        account.setSequencer(address(sequencer));
        orderbook.setSequencer(address(sequencer));
        sequencer.setAccount(address(account));
        sequencer.setOrderBook(address(orderbook));

        // 计算并注册交易对
        pairId = keccak256("WETH/USDC");
        account.registerTradingPair(pairId, address(weth), address(usdc));

        // 为测试账户铸造代币
        weth.mint(trader1, 1000 * 10**18);
        usdc.mint(trader1, 1000000 * 10**6);
        weth.mint(trader2, 1000 * 10**18);
        usdc.mint(trader2, 1000000 * 10**6);

        // 授权和充值
        vm.startPrank(trader1);
        weth.approve(address(account), type(uint256).max);
        usdc.approve(address(account), type(uint256).max);
        account.deposit(address(weth), 100 * 10**18);
        account.deposit(address(usdc), 100000 * 10**6);
        vm.stopPrank();

        vm.startPrank(trader2);
        weth.approve(address(account), type(uint256).max);
        usdc.approve(address(account), type(uint256).max);
        account.deposit(address(weth), 100 * 10**18);
        account.deposit(address(usdc), 100000 * 10**6);
        vm.stopPrank();
    }

    /// @notice 测试单个订单下单的 gas 消耗
    function test_Gas_SingleOrder() public {
        vm.startPrank(trader1);

        uint256 gasBefore = gasleft();
        sequencer.placeLimitOrder(
            pairId,
            false, // buy
            2000 * 10**8, // price
            1 * 10**8 // amount
        );
        uint256 gasUsed = gasBefore - gasleft();

        vm.stopPrank();

        console.log("=== Single Order Gas ===");
        console.log("placeLimitOrder gas:", gasUsed);
    }

    /// @notice 测试批量处理 10 个订单的 gas 消耗
    function test_Gas_BatchProcess() public {
        console.log("\n=== Batch Process 10 Orders (Same Price) ===");

        uint256 batchSize = 10;
        uint256 basePrice = 3000 * 10**8; // 使用不同的价格避免与其他测试冲突

        // 准备订单
        uint256[] memory requestIds = new uint256[](batchSize);
        uint256[] memory insertAfterPriceLevels = new uint256[](batchSize);
        uint256[] memory insertAfterOrders = new uint256[](batchSize);

        // 下订单到 Sequencer
        vm.startPrank(trader1);
        uint256 firstRequestId = 2; // 第一个测试已经用了 requestId=1
        for (uint256 j = 0; j < batchSize; j++) {
            sequencer.placeLimitOrder(pairId, false, basePrice, 1 * 10**8);
            requestIds[j] = firstRequestId + j;
            insertAfterPriceLevels[j] = j == 0 ? 0 : 2; // 第一个插入新层级ID=2
            insertAfterOrders[j] = j == 0 ? 0 : (firstRequestId + j - 1); // 插入到前一个订单后
        }
        vm.stopPrank();

        // 批量处理
        vm.prank(matcher);
        uint256 gasBefore = gasleft();
        orderbook.batchProcessRequests(requestIds, insertAfterPriceLevels, insertAfterOrders);
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Total gas:", gasUsed);
        console.log("Gas per order:", gasUsed / batchSize);
    }

    /// @notice 测试订单撮合的 gas 消耗
    function test_Gas_Matching() public {
        console.log("\n=== Order Matching Gas ===");

        // 准备买单
        vm.startPrank(trader1);
        for (uint256 i = 0; i < 5; i++) {
            uint256 price = (2000 - i * 10) * 10**8;
            sequencer.placeLimitOrder(pairId, false, price, 1 * 10**8);
        }
        vm.stopPrank();

        // 批量处理买单
        uint256[] memory buyRequestIds = new uint256[](5);
        uint256[] memory insertAfterPriceLevels = new uint256[](5);
        uint256[] memory insertAfterOrders = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            buyRequestIds[i] = i + 1;
            insertAfterPriceLevels[i] = 0;
            insertAfterOrders[i] = 0;
        }
        vm.prank(matcher);
        orderbook.batchProcessRequests(buyRequestIds, insertAfterPriceLevels, insertAfterOrders);

        // 准备卖单（会触发撮合）
        vm.startPrank(trader2);
        for (uint256 i = 0; i < 5; i++) {
            uint256 price = (1990 + i * 10) * 10**8;
            sequencer.placeLimitOrder(pairId, true, price, 1 * 10**8);
        }
        vm.stopPrank();

        // 批量处理卖单
        uint256[] memory sellRequestIds = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            sellRequestIds[i] = 6 + i;
            insertAfterPriceLevels[i] = 0;
            insertAfterOrders[i] = 0;
        }

        // 测试撮合
        vm.prank(matcher);
        uint256 gasBefore = gasleft();
        orderbook.batchProcessRequests(sellRequestIds, insertAfterPriceLevels, insertAfterOrders);
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Matching 5 orders:");
        console.log("  Total gas:", gasUsed);
        console.log("  Gas per order:", gasUsed / 5);
    }

    /// @notice 测试不同撮合深度的 gas 消耗
    function test_Gas_MatchingDepth() public {
        console.log("\n=== Matching Depth Gas ===");

        uint256[] memory depths = new uint256[](3);
        depths[0] = 5;
        depths[1] = 10;
        depths[2] = 20;

        for (uint256 d = 0; d < depths.length; d++) {
            uint256 depth = depths[d];

            // 准备买单
            vm.startPrank(trader1);
            for (uint256 i = 0; i < depth; i++) {
                uint256 price = (2000 - i * 5) * 10**8;
                sequencer.placeLimitOrder(pairId, false, price, 1 * 10**8);
            }
            vm.stopPrank();

            // 批量处理买单
            uint256[] memory buyRequestIds = new uint256[](depth);
            uint256[] memory insertAfterPriceLevels = new uint256[](depth);
            uint256[] memory insertAfterOrders = new uint256[](depth);
            for (uint256 i = 0; i < depth; i++) {
                buyRequestIds[i] = i + 1;
                insertAfterPriceLevels[i] = 0;
                insertAfterOrders[i] = 0;
            }
            vm.prank(matcher);
            orderbook.batchProcessRequests(buyRequestIds, insertAfterPriceLevels, insertAfterOrders);

            // 下一个卖单触发撮合
            vm.prank(trader2);
            sequencer.placeLimitOrder(pairId, true, 1950 * 10**8, depth * 10**8);

            // 处理卖单并撮合
            uint256[] memory sellRequestIds = new uint256[](1);
            uint256[] memory sellInsertAfter = new uint256[](1);
            uint256[] memory sellInsertAfterOrders = new uint256[](1);
            sellRequestIds[0] = depth + 1;
            sellInsertAfter[0] = 0;
            sellInsertAfterOrders[0] = 0;

            vm.prank(matcher);
            uint256 gasBefore = gasleft();
            orderbook.batchProcessRequests(sellRequestIds, sellInsertAfter, sellInsertAfterOrders);
            uint256 gasUsed = gasBefore - gasleft();

            console.log("Matching depth:", depth);
            console.log("  Total gas:", gasUsed);
            console.log("  Gas per matched order:", gasUsed / depth);

            // 清理
            _clearOrderBook();
        }
    }

    /// @notice 比较批量处理 vs 单个处理的 gas 节省
    function test_Gas_BatchVsSingle() public {
        console.log("\n=== Batch vs Single Comparison ===");

        uint256 orderCount = 10;

        // 测试 1: 单个处理 (模拟)
        uint256 totalSingleGas = 0;
        for (uint256 i = 0; i < orderCount; i++) {
            vm.prank(trader1);
            sequencer.placeLimitOrder(
                pairId,
                false,
                (2000 - i * 10) * 10**8,
                1 * 10**8
            );

            uint256[] memory requestIds = new uint256[](1);
            uint256[] memory insertAfter = new uint256[](1);
            uint256[] memory insertAfterOrders = new uint256[](1);
            requestIds[0] = i + 1;
            insertAfter[0] = 0;
            insertAfterOrders[0] = 0;

            vm.prank(matcher);
            uint256 gasBefore = gasleft();
            orderbook.batchProcessRequests(requestIds, insertAfter, insertAfterOrders);
            uint256 gasUsed = gasBefore - gasleft();
            totalSingleGas += gasUsed;
        }

        console.log("Single processing (10 orders):");
        console.log("  Total gas:", totalSingleGas);
        console.log("  Gas per order:", totalSingleGas / orderCount);

        // 清理
        _clearOrderBook();

        // 测试 2: 批量处理
        vm.startPrank(trader1);
        for (uint256 i = 0; i < orderCount; i++) {
            sequencer.placeLimitOrder(
                pairId,
                false,
                (2000 - i * 10) * 10**8,
                1 * 10**8
            );
        }
        vm.stopPrank();

        uint256[] memory requestIds = new uint256[](orderCount);
        uint256[] memory insertAfter = new uint256[](orderCount);
        uint256[] memory insertAfterOrders = new uint256[](orderCount);
        for (uint256 i = 0; i < orderCount; i++) {
            requestIds[i] = i + 1;
            insertAfter[i] = 0;
            insertAfterOrders[i] = 0;
        }

        vm.prank(matcher);
        uint256 gasBefore = gasleft();
        orderbook.batchProcessRequests(requestIds, insertAfter, insertAfterOrders);
        uint256 batchGas = gasBefore - gasleft();

        console.log("\nBatch processing (10 orders):");
        console.log("  Total gas:", batchGas);
        console.log("  Gas per order:", batchGas / orderCount);

        console.log("\nComparison:");
        console.log("  Gas saved:", totalSingleGas - batchGas);
        console.log("  Savings percentage:",
            ((totalSingleGas - batchGas) * 100) / totalSingleGas, "%");
    }

    /// @notice 测试订单取消的 gas 消耗
    function test_Gas_RemoveOrder() public {
        console.log("\n=== Remove Order Gas ===");

        // 下一个订单
        vm.prank(trader1);
        sequencer.placeLimitOrder(pairId, false, 2000 * 10**8, 1 * 10**8);

        // 处理订单
        uint256[] memory requestIds = new uint256[](1);
        uint256[] memory insertAfter = new uint256[](1);
        uint256[] memory insertAfterOrders = new uint256[](1);
        requestIds[0] = 1;
        insertAfter[0] = 0;
        insertAfterOrders[0] = 0;

        vm.prank(matcher);
        orderbook.batchProcessRequests(requestIds, insertAfter, insertAfterOrders);

        // 请求取消订单
        vm.prank(trader1);
        uint256 gasBefore = gasleft();
        sequencer.requestRemoveOrder(1);
        uint256 requestGas = gasBefore - gasleft();

        console.log("Request remove order gas:", requestGas);

        // 处理取消请求
        requestIds[0] = 2;
        vm.prank(matcher);
        gasBefore = gasleft();
        orderbook.batchProcessRequests(requestIds, insertAfter, insertAfterOrders);
        uint256 processGas = gasBefore - gasleft();

        console.log("Process remove order gas:", processGas);
        console.log("Total remove order gas:", requestGas + processGas);
    }

    /// @notice 辅助函数：清空订单簿
    function _clearOrderBook() internal {
        // 简单的清理方式：重新部署合约
        orderbook = new OrderBook();
        orderbook.setSequencer(address(sequencer));
        account.setOrderBook(address(orderbook));

        // 重新设置 Sequencer 队列头
        sequencer = new Sequencer();
        sequencer.setAccount(address(account));
        sequencer.setOrderBook(address(orderbook));
        account.setSequencer(address(sequencer));
    }
}
