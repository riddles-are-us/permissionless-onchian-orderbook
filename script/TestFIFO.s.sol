// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../OrderBook.sol";
import "../Sequencer.sol";
import {Account as AccountContract} from "../Account.sol";
import "../MockERC20.sol";

/**
 * TestFIFO - 测试 FIFO 订单撮合
 * 
 * 场景: A 下买单 10, B 下买单 10, C 下卖单 10
 * 预期: C 应该和 A 成交(先到先得)
 */
contract TestFIFO is Script {
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

    // 三个用户
    uint256 userAKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;  // Account 0
    uint256 userBKey = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;  // Account 1
    uint256 userCKey = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;  // Account 2
    
    address userA;
    address userB;
    address userC;

    uint256 constant PRICE_DECIMALS = 1e8;
    uint256 constant PRICE_10 = 10 * PRICE_DECIMALS;
    uint256 constant AMOUNT_10_WETH = 10 * 1e8;

    function loadConfig() internal {
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

        userA = vm.addr(userAKey);
        userB = vm.addr(userBKey);
        userC = vm.addr(userCKey);
    }

    /// @notice 准备三个用户的资金
    function prepare() external {
        loadConfig();

        console.log("=== Preparing Funds for FIFO Test ===");
        console.log("User A (buyer 1):", userA);
        console.log("User B (buyer 2):", userB);
        console.log("User C (seller):", userC);

        // User A 存入 USDC (买方1)
        vm.startBroadcast(userAKey);
        uint256 usdcNeeded = 10000 * 1e6;
        usdc.mint(userA, usdcNeeded);
        usdc.approve(accountAddress, type(uint256).max);
        accountContract.deposit(usdcAddress, usdcNeeded);
        vm.stopBroadcast();
        console.log("User A deposited", usdcNeeded / 1e6, "USDC");

        // User B 存入 USDC (买方2)
        vm.startBroadcast(userBKey);
        usdc.mint(userB, usdcNeeded);
        usdc.approve(accountAddress, type(uint256).max);
        accountContract.deposit(usdcAddress, usdcNeeded);
        vm.stopBroadcast();
        console.log("User B deposited", usdcNeeded / 1e6, "USDC");

        // User C 存入 WETH (卖方)
        vm.startBroadcast(userCKey);
        uint256 wethNeeded = 100 * 1e18;
        weth.mint(userC, wethNeeded);
        weth.approve(accountAddress, type(uint256).max);
        accountContract.deposit(wethAddress, wethNeeded);
        vm.stopBroadcast();
        console.log("User C deposited", wethNeeded / 1e18, "WETH");

        console.log("=== Funds Prepared ===");
    }

    /// @notice Step 1: A 下买单 @10
    function step1_A_buy() external {
        loadConfig();
        console.log("=== Step 1: User A places BUY order @10 ===");

        vm.startBroadcast(userAKey);
        sequencer.placeLimitOrder(pairId, false, PRICE_10, AMOUNT_10_WETH, 0);  // isAsk=false (buy)
        vm.stopBroadcast();
        
        console.log("User A placed BUY 10 WETH @ price 10");
        console.log("Wait for matcher to process, then run step2_B_buy()");
    }

    /// @notice Step 2: B 下买单 @10
    function step2_B_buy() external {
        loadConfig();
        console.log("=== Step 2: User B places BUY order @10 ===");

        vm.startBroadcast(userBKey);
        sequencer.placeLimitOrder(pairId, false, PRICE_10, AMOUNT_10_WETH, 0);  // isAsk=false (buy)
        vm.stopBroadcast();
        
        console.log("User B placed BUY 10 WETH @ price 10");
        console.log("Wait for matcher to process, then run step3_C_sell()");
    }

    /// @notice Step 3: C 下卖单 @10
    function step3_C_sell() external {
        loadConfig();
        console.log("=== Step 3: User C places SELL order @10 ===");

        vm.startBroadcast(userCKey);
        sequencer.placeLimitOrder(pairId, true, PRICE_10, AMOUNT_10_WETH, 0);   // isAsk=true (sell)
        vm.stopBroadcast();
        
        console.log("User C placed SELL 10 WETH @ price 10");
        console.log("Wait for matcher to process, then check results");
        console.log("Expected: Trade between A and C (FIFO - A was first)");
    }

    /// @notice 验证结果
    function verify() external {
        loadConfig();
        console.log("=== Verifying FIFO Results ===");
        
        // 检查 A 的余额
        (uint256 aUsdc,) = accountContract.balances(userA, usdcAddress);
        (uint256 aWeth,) = accountContract.balances(userA, wethAddress);
        console.log("User A - USDC:", aUsdc / 1e6, "WETH:", aWeth / 1e8);
        
        // 检查 B 的余额
        (uint256 bUsdc,) = accountContract.balances(userB, usdcAddress);
        (uint256 bWeth,) = accountContract.balances(userB, wethAddress);
        console.log("User B - USDC:", bUsdc / 1e6, "WETH:", bWeth / 1e8);
        
        // 检查 C 的余额
        (uint256 cUsdc,) = accountContract.balances(userC, usdcAddress);
        (uint256 cWeth,) = accountContract.balances(userC, wethAddress);
        console.log("User C - USDC:", cUsdc / 1e6, "WETH:", cWeth / 1e8);
        
        // 判断成交情况
        // 如果 A 获得了 WETH，说明 A 和 C 成交了 (正确的 FIFO)
        // 如果 B 获得了 WETH，说明 B 和 C 成交了 (错误)
        
        if (aWeth > 0) {
            console.log("CORRECT: User A matched with C (FIFO working)");
        } else if (bWeth > 0) {
            console.log("ERROR: User B matched with C (FIFO broken!)");
        } else {
            console.log("No match yet - wait for processing");
        }
    }
}
