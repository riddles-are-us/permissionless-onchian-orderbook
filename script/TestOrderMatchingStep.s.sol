// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../OrderBook.sol";
import "../Sequencer.sol";
import {Account as AccountContract} from "../Account.sol";
import "../MockERC20.sol";

/**
 * @title TestOrderMatchingStep
 * @notice 分步订单撮合测试，每一步需要手动触发并验证
 *
 * 使用方法：
 * 1. 部署合约并启动 Matcher
 * 2. 准备资金: forge script script/TestOrderMatchingStep.s.sol --sig "prepare()" --rpc-url http://127.0.0.1:8545 --broadcast
 * 3. 逐步测试:
 *    - Test 1-1: forge script script/TestOrderMatchingStep.s.sol --sig "test1_1()" --rpc-url http://127.0.0.1:8545 --broadcast
 *    - 等待 Matcher 处理，然后验证
 *    - Test 1-2: forge script script/TestOrderMatchingStep.s.sol --sig "test1_2()" ...
 *    - 以此类推
 * 4. 验证: forge script script/TestOrderMatchingStep.s.sol --sig "verify()" --rpc-url http://127.0.0.1:8545
 */
contract TestOrderMatchingStep is Script {
    // 从 deployments.json 读取的合约地址
    address wethAddress;
    address usdcAddress;
    address accountAddress;
    address orderbookAddress;
    address sequencerAddress;
    bytes32 pairId;

    MockERC20 weth;
    MockERC20 usdc;
    AccountContract accountContract;
    OrderBook orderbook;
    Sequencer sequencer;

    // 测试用户
    address user1;
    uint256 user1Key;
    address user2;
    uint256 user2Key;

    // 价格精度 (8位小数)
    uint256 constant PRICE_DECIMALS = 1e8;

    // 测试价格
    uint256 constant PRICE_10 = 10 * PRICE_DECIMALS;  // 价格 10
    uint256 constant PRICE_11 = 11 * PRICE_DECIMALS;  // 价格 11
    uint256 constant PRICE_9 = 9 * PRICE_DECIMALS;    // 价格 9

    // 测试数量 (系统使用8位小数)
    uint256 constant AMOUNT_10_WETH = 10 * 1e8;  // 10 WETH

    function loadConfig() internal {
        // 读取部署信息
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/deployments.json");
        string memory json = vm.readFile(path);

        wethAddress = vm.parseJsonAddress(json, ".weth");
        usdcAddress = vm.parseJsonAddress(json, ".usdc");
        accountAddress = vm.parseJsonAddress(json, ".account");
        orderbookAddress = vm.parseJsonAddress(json, ".orderbook");
        sequencerAddress = vm.parseJsonAddress(json, ".sequencer");
        pairId = vm.parseJsonBytes32(json, ".pairId");

        weth = MockERC20(wethAddress);
        usdc = MockERC20(usdcAddress);
        accountContract = AccountContract(accountAddress);
        orderbook = OrderBook(orderbookAddress);
        sequencer = Sequencer(sequencerAddress);

        // 使用 Anvil 的测试账户
        user1Key = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        user1 = vm.addr(user1Key);
        user2Key = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
        user2 = vm.addr(user2Key);
    }

    /// @notice 准备测试资金
    function prepare() external {
        loadConfig();

        console.log("=== Preparing Test Funds ===");
        console.log("User1 (buyer):", user1);
        console.log("User2 (seller):", user2);

        // User1 存入 USDC (买方)
        vm.startBroadcast(user1Key);
        uint256 usdcNeeded = 10000 * 1e6; // 10000 USDC
        usdc.mint(user1, usdcNeeded);
        usdc.approve(accountAddress, type(uint256).max);
        accountContract.deposit(usdcAddress, usdcNeeded);
        vm.stopBroadcast();

        // User2 存入 WETH (卖方)
        vm.startBroadcast(user2Key);
        uint256 wethNeeded = 1000 * 1e18; // 1000 WETH
        weth.mint(user2, wethNeeded);
        weth.approve(accountAddress, type(uint256).max);
        accountContract.deposit(wethAddress, wethNeeded);
        vm.stopBroadcast();

        console.log("User1 USDC deposited:", usdcNeeded / 1e6);
        console.log("User2 WETH deposited:", wethNeeded / 1e18);
        console.log("Preparation complete!");
    }

    /// @notice 重置测试环境 - 需要重新部署合约
    function reset() external view {
        console.log("To reset, run:");
        console.log("1. Restart Anvil");
        console.log("2. Re-deploy contracts");
        console.log("3. Run prepare()");
    }

    /// @notice 验证当前订单簿状态
    function verify() external {
        loadConfig();

        console.log("\n=== Current OrderBook State ===");
        console.log("matchId:", orderbook.matchId());

        // 获取订单簿快照
        (uint256[] memory bidPrices, uint256[] memory bidVolumes) = orderbook.getOrderBookSnapshot(pairId, false, 10);
        (uint256[] memory askPrices, uint256[] memory askVolumes) = orderbook.getOrderBookSnapshot(pairId, true, 10);

        console.log("\n--- Bids (Buy Orders) ---");
        for (uint256 i = 0; i < bidPrices.length && bidPrices[i] > 0; i++) {
            console.log("  Price:", bidPrices[i] / PRICE_DECIMALS);
            console.log("  Volume (raw):", bidVolumes[i]);
            console.log("  Volume:", bidVolumes[i] / PRICE_DECIMALS, "WETH");
        }
        if (bidPrices[0] == 0) {
            console.log("  (empty)");
        }

        console.log("\n--- Asks (Sell Orders) ---");
        for (uint256 i = 0; i < askPrices.length && askPrices[i] > 0; i++) {
            console.log("  Price:", askPrices[i] / PRICE_DECIMALS);
            console.log("  Volume (raw):", askVolumes[i]);
            console.log("  Volume:", askVolumes[i] / PRICE_DECIMALS, "WETH");
        }
        if (askPrices[0] == 0) {
            console.log("  (empty)");
        }

        // 获取 Sequencer 队列状态
        console.log("\n--- Sequencer Queue ---");
        console.log("  Next request ID:", sequencer.nextRequestId());
    }

    // ============ Test 1-1 ============
    /// @notice 买单和卖单价格相同，完全成交
    function test1_1() external {
        loadConfig();

        console.log("\n=== Test 1-1: Same price, full match ===");
        console.log("Buy 10 WETH @ 10, Sell 10 WETH @ 10");
        console.log("Expected: Full match, orderbook empty");

        // User1 买单
        vm.startBroadcast(user1Key);
        sequencer.placeLimitOrder(pairId, false, PRICE_10, AMOUNT_10_WETH, 0);
        vm.stopBroadcast();
        console.log("Buy order submitted");

        // User2 卖单
        vm.startBroadcast(user2Key);
        sequencer.placeLimitOrder(pairId, true, PRICE_10, AMOUNT_10_WETH, 0);
        vm.stopBroadcast();
        console.log("Sell order submitted");

        console.log("\nWait for Matcher to process, then run verify()");
    }

    // ============ Test 1-2 ============
    /// @notice 买单价格高于卖单，完全成交
    function test1_2() external {
        loadConfig();

        console.log("\n=== Test 1-2: Buy price > Sell price, full match ===");
        console.log("Buy 10 WETH @ 10, Sell 10 WETH @ 9");
        console.log("Expected: Full match at maker price (10), orderbook empty");

        vm.startBroadcast(user1Key);
        sequencer.placeLimitOrder(pairId, false, PRICE_10, AMOUNT_10_WETH, 0);
        vm.stopBroadcast();
        console.log("Buy order @ 10 submitted");

        vm.startBroadcast(user2Key);
        sequencer.placeLimitOrder(pairId, true, PRICE_9, AMOUNT_10_WETH, 0);
        vm.stopBroadcast();
        console.log("Sell order @ 9 submitted");

        console.log("\nWait for Matcher to process, then run verify()");
    }

    // ============ Test 1-3 ============
    /// @notice 买单价格低于卖单，不成交
    function test1_3() external {
        loadConfig();

        console.log("\n=== Test 1-3: Buy price < Sell price, no match ===");
        console.log("Buy 10 WETH @ 10, Sell 10 WETH @ 11");
        console.log("Expected: No match, 1 bid @ 10, 1 ask @ 11");

        vm.startBroadcast(user1Key);
        sequencer.placeLimitOrder(pairId, false, PRICE_10, AMOUNT_10_WETH, 0);
        vm.stopBroadcast();
        console.log("Buy order @ 10 submitted");

        vm.startBroadcast(user2Key);
        sequencer.placeLimitOrder(pairId, true, PRICE_11, AMOUNT_10_WETH, 0);
        vm.stopBroadcast();
        console.log("Sell order @ 11 submitted");

        console.log("\nWait for Matcher to process, then run verify()");
    }

    // ============ Test 2-1 ============
    /// @notice 在现有基础上再加一个买单
    function test2_1() external {
        loadConfig();

        console.log("\n=== Test 2-1: Add another buy order ===");
        console.log("Buy 10 WETH @ 10");
        console.log("Expected: No match, 2 bids @ 10, 1 ask @ 11");

        vm.startBroadcast(user1Key);
        sequencer.placeLimitOrder(pairId, false, PRICE_10, AMOUNT_10_WETH, 0);
        vm.stopBroadcast();
        console.log("Buy order @ 10 submitted");

        console.log("\nWait for Matcher to process, then run verify()");
    }

    // ============ Test 2-2 ============
    /// @notice 在现有基础上再加一个卖单
    function test2_2() external {
        loadConfig();

        console.log("\n=== Test 2-2: Add another sell order ===");
        console.log("Sell 10 WETH @ 11");
        console.log("Expected: No match, 2 bids @ 10, 2 asks @ 11");

        vm.startBroadcast(user2Key);
        sequencer.placeLimitOrder(pairId, true, PRICE_11, AMOUNT_10_WETH, 0);
        vm.stopBroadcast();
        console.log("Sell order @ 11 submitted");

        console.log("\nWait for Matcher to process, then run verify()");
    }

    // ============ Test 2-3 ============
    /// @notice 用卖单撮合第一个买单
    function test2_3() external {
        loadConfig();

        console.log("\n=== Test 2-3: Sell matches first bid (FIFO) ===");
        console.log("Sell 10 WETH @ 10");
        console.log("Expected: Match first bid @ 10, remaining: 1 bid @ 10, 2 asks @ 11");

        vm.startBroadcast(user2Key);
        sequencer.placeLimitOrder(pairId, true, PRICE_10, AMOUNT_10_WETH, 0);
        vm.stopBroadcast();
        console.log("Sell order @ 10 submitted");

        console.log("\nWait for Matcher to process, then run verify()");
    }

    // ============ Test 2-4 ============
    /// @notice 用买单撮合第一个卖单
    function test2_4() external {
        loadConfig();

        console.log("\n=== Test 2-4: Buy matches first ask (FIFO) ===");
        console.log("Buy 10 WETH @ 11");
        console.log("Expected: Match first ask @ 11, remaining: 1 bid @ 10, 1 ask @ 11");

        vm.startBroadcast(user1Key);
        sequencer.placeLimitOrder(pairId, false, PRICE_11, AMOUNT_10_WETH, 0);
        vm.stopBroadcast();
        console.log("Buy order @ 11 submitted");

        console.log("\nWait for Matcher to process, then run verify()");
    }

    // ============ 辅助函数 ============

    /// @notice 仅下买单
    function placeBuy(uint256 price, uint256 amount) external {
        loadConfig();
        vm.startBroadcast(user1Key);
        sequencer.placeLimitOrder(pairId, false, price * PRICE_DECIMALS, amount * PRICE_DECIMALS, 0);
        vm.stopBroadcast();
        console.log("Buy order submitted: price =", price);
        console.log("  amount =", amount, "WETH");
    }

    /// @notice 仅下卖单
    function placeSell(uint256 price, uint256 amount) external {
        loadConfig();
        vm.startBroadcast(user2Key);
        sequencer.placeLimitOrder(pairId, true, price * PRICE_DECIMALS, amount * PRICE_DECIMALS, 0);
        vm.stopBroadcast();
        console.log("Sell order submitted: price =", price);
        console.log("  amount =", amount, "WETH");
    }
}
