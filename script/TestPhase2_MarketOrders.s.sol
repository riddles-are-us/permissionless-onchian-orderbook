// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {Account as AccountContract} from "../Account.sol";
import {Sequencer} from "../Sequencer.sol";
import {OrderBook} from "../OrderBook.sol";
import {MockERC20} from "../MockERC20.sol";

/**
 * @title TestPhase2_MarketOrders
 * @notice Phase 2: 测试市价单撮合
 * @dev 需要在 Phase 1 完成后运行，市价单会与现有限价单撮合
 */
contract TestPhase2_MarketOrders is Script {
    function run() external {
        string memory json = vm.readFile("deployments.json");

        address weth = vm.parseJsonAddress(json, ".weth");
        address usdc = vm.parseJsonAddress(json, ".usdc");
        address account = vm.parseJsonAddress(json, ".account");
        address sequencer = vm.parseJsonAddress(json, ".sequencer");
        address orderbook = vm.parseJsonAddress(json, ".orderbook");
        bytes32 pairId = vm.parseJsonBytes32(json, ".pairId");

        // 使用第二个测试用户
        uint256 user2PrivateKey = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a; // anvil account #2
        address user2 = vm.addr(user2PrivateKey);

        console.log(unicode"");
        console.log(unicode"═══════════════════════════════════════════════════════");
        console.log(unicode"  Phase 2: 市价单测试");
        console.log(unicode"═══════════════════════════════════════════════════════");
        console.log(unicode"");
        console.log("Test user 2:", user2);

        // 检查当前订单簿状态
        console.log(unicode"");
        console.log(unicode"📊 当前订单簿状态:");
        uint256 bestBid = OrderBook(orderbook).getBestPrice(pairId, false);
        uint256 bestAsk = OrderBook(orderbook).getBestPrice(pairId, true);
        console.log("  Best Bid:", bestBid / 10**8, "USDC");
        console.log("  Best Ask:", bestAsk / 10**8, "USDC");

        if (bestBid == 0 && bestAsk == 0) {
            console.log(unicode"");
            console.log(unicode"⚠️  订单簿为空! 请先运行 Phase 1 并等待 Matcher 处理");
            return;
        }

        // Mint tokens to user2 (as deployer)
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        MockERC20(weth).mint(user2, 50 ether);
        MockERC20(usdc).mint(user2, 50_000 * 10**6);
        vm.stopBroadcast();

        // Setup user2 account
        vm.startBroadcast(user2PrivateKey);

        MockERC20(weth).approve(account, type(uint256).max);
        MockERC20(usdc).approve(account, type(uint256).max);

        AccountContract(account).deposit(weth, 5 ether);
        AccountContract(account).deposit(usdc, 10_000 * 10**6);

        console.log(unicode"");
        console.log(unicode"📦 User2 已存入资金:");
        console.log("  WETH: 5");
        console.log("  USDC: 10,000");

        // Place market orders
        console.log(unicode"");
        console.log(unicode"📝 下市价单...");
        console.log(unicode"");

        // Market buy: 花费 3000 USDC 买入 WETH
        // 应该以 2100 USDC 的价格买入约 1.43 WETH
        console.log(unicode"  市价买单:");
        (uint256 reqId1,) = Sequencer(sequencer).placeMarketOrder(
            pairId,
            false,  // isAsk = false, 买单
            3000 * 10**8  // 花费 3000 USDC
        );
        console.log("    #1: Market Buy with 3000 USDC (reqId:", reqId1, ")");

        // Market sell: 卖出 0.5 WETH
        // 应该以 2000 USDC 的价格卖出
        console.log(unicode"");
        console.log(unicode"  市价卖单:");
        (uint256 reqId2,) = Sequencer(sequencer).placeMarketOrder(
            pairId,
            true,  // isAsk = true, 卖单
            5 * 10**7  // 卖出 0.5 WETH
        );
        console.log("    #2: Market Sell 0.5 WETH (reqId:", reqId2, ")");

        vm.stopBroadcast();

        // Show queue status
        uint256 queueLength = Sequencer(sequencer).getQueueLength(100);

        console.log(unicode"");
        console.log(unicode"📊 队列状态:");
        console.log("  Queue length:", queueLength);

        console.log(unicode"");
        console.log(unicode"═══════════════════════════════════════════════════════");
        console.log(unicode"  Phase 2 准备完成!");
        console.log(unicode"  ");
        console.log(unicode"  预期结果 (Matcher 处理后):");
        console.log(unicode"    - 市价买单消耗部分 Ask 订单");
        console.log(unicode"    - 市价卖单消耗部分 Bid 订单");
        console.log(unicode"    - 触发 Trade 事件");
        console.log(unicode"═══════════════════════════════════════════════════════");
    }
}
