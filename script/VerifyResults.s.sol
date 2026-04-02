// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {OrderBook} from "../OrderBook.sol";
import {Sequencer} from "../Sequencer.sol";
import {Account as AccountContract} from "../Account.sol";

/**
 * @title VerifyResultsScript
 * @notice 验证 Matcher 执行结果的脚本
 * @dev
 *   基础验证: forge script script/VerifyResults.s.sol --rpc-url http://127.0.0.1:8545
 *   详细验证: forge script script/VerifyResults.s.sol --sig "runDetailed()" --rpc-url ...
 *   Phase 1 验证: forge script script/VerifyResults.s.sol --sig "verifyPhase1()" --rpc-url ...
 *   Phase 2 验证: forge script script/VerifyResults.s.sol --sig "verifyPhase2()" --rpc-url ...
 *   Phase 3 验证: forge script script/VerifyResults.s.sol --sig "verifyPhase3()" --rpc-url ...
 */
contract VerifyResultsScript is Script {
    uint256 constant PRICE_DECIMALS = 1e8;

    function run() external view {
        string memory json = vm.readFile("deployments.json");
        address orderbookAddr = vm.parseJsonAddress(json, ".orderbook");
        address sequencerAddr = vm.parseJsonAddress(json, ".sequencer");
        bytes32 pairId = vm.parseJsonBytes32(json, ".pairId");

        OrderBook orderbook = OrderBook(orderbookAddr);
        Sequencer sequencer = Sequencer(sequencerAddr);

        console.log(unicode"🔍 验证 Matcher 执行结果");
        console.log("========================");
        console.log("");

        // 1. 检查队列状态
        console.log(unicode"📦 队列状态:");
        uint256 queueLen = sequencer.getQueueLength(100);
        console.log(unicode"  待处理订单:", queueLen);

        if (queueLen == 0) {
            console.log(unicode"  ✅ 队列已清空");
        } else {
            console.log(unicode"  ⚠️  还有订单待处理");
        }
        console.log("");

        // 2. 获取订单簿状态
        console.log(unicode"📊 订单簿状态:");
        (
            uint256 askHead,
            ,
            uint256 bidHead,
            ,
            uint256 marketAskHead,
            ,
            uint256 marketBidHead,
        ) = orderbook.orderBooks(pairId);

        console.log(unicode"  Bid 头部价格:", bidHead / PRICE_DECIMALS, "USDC");
        console.log(unicode"  Ask 头部价格:", askHead / PRICE_DECIMALS, "USDC");

        // 3. Bid 价格层级
        if (bidHead != 0) {
            console.log("");
            console.log(unicode"💰 Bid 价格层级 (买单):");
            _printPriceLevels(orderbook, pairId, bidHead, false, 5);
        } else {
            console.log("");
            console.log(unicode"💰 Bid 价格层级: (空)");
        }

        // 4. Ask 价格层级
        if (askHead != 0) {
            console.log("");
            console.log(unicode"💵 Ask 价格层级 (卖单):");
            _printPriceLevels(orderbook, pairId, askHead, true, 5);
        } else {
            console.log("");
            console.log(unicode"💵 Ask 价格层级: (空)");
        }

        // 5. 市价单队列
        console.log("");
        console.log(unicode"📋 市价单队列:");
        console.log(unicode"  市价买单队列:", marketBidHead == 0 ? unicode"空" : unicode"有订单");
        console.log(unicode"  市价卖单队列:", marketAskHead == 0 ? unicode"空" : unicode"有订单");

        // 6. 结论
        console.log("");
        if (queueLen == 0 && (bidHead != 0 || askHead != 0)) {
            console.log(unicode"✅ 测试成功! Matcher 已正确处理订单");
        } else if (queueLen == 0 && bidHead == 0 && askHead == 0) {
            console.log(unicode"ℹ️  队列已清空，订单簿为空");
        } else {
            console.log(unicode"⚠️  请检查 Matcher 日志");
        }
    }

    /**
     * @notice Phase 1 验证 - 限价单测试
     */
    function verifyPhase1() external view {
        string memory json = vm.readFile("deployments.json");
        address orderbookAddr = vm.parseJsonAddress(json, ".orderbook");
        address sequencerAddr = vm.parseJsonAddress(json, ".sequencer");
        bytes32 pairId = vm.parseJsonBytes32(json, ".pairId");

        OrderBook orderbook = OrderBook(orderbookAddr);
        Sequencer sequencer = Sequencer(sequencerAddr);

        console.log(unicode"");
        console.log(unicode"═══════════════════════════════════════════════════════");
        console.log(unicode"  Phase 1 验证: 限价单测试");
        console.log(unicode"═══════════════════════════════════════════════════════");

        uint256 queueLen = sequencer.getQueueLength(100);
        console.log(unicode"");
        console.log(unicode"📦 队列状态:");
        console.log("  Queue length:", queueLen);

        bool queueEmpty = (queueLen == 0);
        console.log("  Status:", queueEmpty ? unicode"✅ 已清空" : unicode"❌ 未清空");

        // 检查 Bid 价格层级
        console.log(unicode"");
        console.log(unicode"📊 Bid 订单簿:");
        (uint256[] memory bidPrices, uint256[] memory bidVolumes) = orderbook.getOrderBookSnapshot(pairId, false, 5);

        uint256 bidLevels = 0;
        for (uint256 i = 0; i < bidPrices.length; i++) {
            if (bidPrices[i] == 0) break;
            bidLevels++;
            console.log("    Price: %d USDC, Volume: %d (raw)", bidPrices[i] / PRICE_DECIMALS, bidVolumes[i]);
        }

        // 预期: 3 个 Bid 层级 (2000, 1950, 1900)
        bool bidCorrect = (bidLevels == 3);
        console.log("  Expected levels: 3, Actual:", bidLevels);
        console.log("  Status:", bidCorrect ? unicode"✅ 正确" : unicode"❌ 错误");

        // 检查 Ask 价格层级
        console.log(unicode"");
        console.log(unicode"📊 Ask 订单簿:");
        (uint256[] memory askPrices, uint256[] memory askVolumes) = orderbook.getOrderBookSnapshot(pairId, true, 5);

        uint256 askLevels = 0;
        for (uint256 i = 0; i < askPrices.length; i++) {
            if (askPrices[i] == 0) break;
            askLevels++;
            console.log("    Price: %d USDC, Volume: %d (raw)", askPrices[i] / PRICE_DECIMALS, askVolumes[i]);
        }

        // 预期: 2 个 Ask 层级 (2100, 2150)
        bool askCorrect = (askLevels == 2);
        console.log("  Expected levels: 2, Actual:", askLevels);
        console.log("  Status:", askCorrect ? unicode"✅ 正确" : unicode"❌ 错误");

        // 总结
        console.log(unicode"");
        console.log(unicode"═══════════════════════════════════════════════════════");
        if (queueEmpty && bidCorrect && askCorrect) {
            console.log(unicode"  ✅ Phase 1 验证通过!");
        } else {
            console.log(unicode"  ❌ Phase 1 验证失败");
            if (!queueEmpty) console.log(unicode"     - 队列未清空");
            if (!bidCorrect) console.log(unicode"     - Bid 层级数量不正确");
            if (!askCorrect) console.log(unicode"     - Ask 层级数量不正确");
        }
        console.log(unicode"═══════════════════════════════════════════════════════");
    }

    /**
     * @notice Phase 2 验证 - 市价单撮合测试
     */
    function verifyPhase2() external view {
        string memory json = vm.readFile("deployments.json");
        address orderbookAddr = vm.parseJsonAddress(json, ".orderbook");
        address sequencerAddr = vm.parseJsonAddress(json, ".sequencer");
        bytes32 pairId = vm.parseJsonBytes32(json, ".pairId");

        OrderBook orderbook = OrderBook(orderbookAddr);
        Sequencer sequencer = Sequencer(sequencerAddr);

        console.log(unicode"");
        console.log(unicode"═══════════════════════════════════════════════════════");
        console.log(unicode"  Phase 2 验证: 市价单撮合测试");
        console.log(unicode"═══════════════════════════════════════════════════════");

        uint256 queueLen = sequencer.getQueueLength(100);
        console.log(unicode"");
        console.log(unicode"📦 队列状态:");
        console.log("  Queue length:", queueLen);

        bool queueEmpty = (queueLen == 0);
        console.log("  Status:", queueEmpty ? unicode"✅ 已清空" : unicode"❌ 未清空");

        // 检查市价单队列
        console.log(unicode"");
        console.log(unicode"📋 市价单队列:");
        (
            ,,,,
            uint256 marketAskHead,
            ,
            uint256 marketBidHead,
        ) = orderbook.orderBooks(pairId);

        bool marketQueuesEmpty = (marketBidHead == 0 && marketAskHead == 0);
        console.log("  Market Bid Queue:", marketBidHead == 0 ? unicode"空" : unicode"有订单");
        console.log("  Market Ask Queue:", marketAskHead == 0 ? unicode"空" : unicode"有订单");
        console.log("  Status:", marketQueuesEmpty ? unicode"✅ 已处理完" : unicode"⚠️ 可能还有未撮合订单");

        // 检查订单簿变化
        console.log(unicode"");
        console.log(unicode"📊 订单簿状态 (市价单撮合后):");

        (uint256[] memory bidPrices, uint256[] memory bidVolumes) = orderbook.getOrderBookSnapshot(pairId, false, 5);
        console.log("  Bid:");
        for (uint256 i = 0; i < bidPrices.length; i++) {
            if (bidPrices[i] == 0) break;
            console.log("    Price: %d USDC, Volume: %d (raw)", bidPrices[i] / PRICE_DECIMALS, bidVolumes[i]);
        }

        (uint256[] memory askPrices, uint256[] memory askVolumes) = orderbook.getOrderBookSnapshot(pairId, true, 5);
        console.log("  Ask:");
        for (uint256 i = 0; i < askPrices.length; i++) {
            if (askPrices[i] == 0) break;
            console.log("    Price: %d USDC, Volume: %d (raw)", askPrices[i] / PRICE_DECIMALS, askVolumes[i]);
        }

        // Match ID
        uint256 matchId = orderbook.matchId();
        console.log(unicode"");
        console.log(unicode"🔢 Match ID:", matchId);
        console.log(unicode"  (应该 > 0 表示有撮合发生)");

        // 总结
        console.log(unicode"");
        console.log(unicode"═══════════════════════════════════════════════════════");
        if (queueEmpty && marketQueuesEmpty && matchId > 0) {
            console.log(unicode"  ✅ Phase 2 验证通过!");
        } else {
            console.log(unicode"  ⚠️ Phase 2 需要人工检查");
            console.log(unicode"     请查看 Trade 事件确认撮合是否正确");
        }
        console.log(unicode"═══════════════════════════════════════════════════════");
    }

    /**
     * @notice Phase 3 验证 - 撤单测试
     */
    function verifyPhase3() external view {
        string memory deployJson = vm.readFile("deployments.json");
        address orderbookAddr = vm.parseJsonAddress(deployJson, ".orderbook");
        address sequencerAddr = vm.parseJsonAddress(deployJson, ".sequencer");
        address accountAddr = vm.parseJsonAddress(deployJson, ".account");
        address usdc = vm.parseJsonAddress(deployJson, ".usdc");
        bytes32 pairId = vm.parseJsonBytes32(deployJson, ".pairId");

        OrderBook orderbook = OrderBook(orderbookAddr);
        Sequencer sequencer = Sequencer(sequencerAddr);
        AccountContract account = AccountContract(accountAddr);

        console.log(unicode"");
        console.log(unicode"═══════════════════════════════════════════════════════");
        console.log(unicode"  Phase 3 验证: 撤单测试");
        console.log(unicode"═══════════════════════════════════════════════════════");

        uint256 queueLen = sequencer.getQueueLength(100);
        console.log(unicode"");
        console.log(unicode"📦 队列状态:");
        console.log("  Queue length:", queueLen);
        console.log("  Status:", queueLen == 0 ? unicode"✅ 已清空" : unicode"❌ 未清空");

        // 使用固定的订单 ID (来自 Phase 3 测试脚本)
        uint256 orderIdToCancel = vm.envOr("ORDER_ID_TO_CANCEL", uint256(11));
        uint256 orderIdToKeep = vm.envOr("ORDER_ID_TO_KEEP", uint256(12));
        // anvil account #3
        address user3 = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;

        console.log(unicode"");
        console.log(unicode"📋 撤单信息:");
        console.log("  Order to cancel:", orderIdToCancel);
        console.log("  Order to keep:", orderIdToKeep);

        // 检查订单是否还在 OrderBook 中
        bool cancelledInBook = sequencer.ordersInBook(orderIdToCancel);
        bool keptInBook = sequencer.ordersInBook(orderIdToKeep);

        console.log(unicode"");
        console.log(unicode"📊 订单状态:");
        console.log("  Order", orderIdToCancel, "(to cancel) in book:", cancelledInBook);
        console.log("  Order", orderIdToKeep, "(to keep) in book:", keptInBook);

        // 检查用户余额
        (uint256 usdcAvail, uint256 usdcLocked,) = account.getBalance(user3, usdc);
        console.log(unicode"");
        console.log(unicode"💰 User3 USDC 余额:");
        console.log("  Available:", usdcAvail / 10**6);
        console.log("  Locked:", usdcLocked / 10**6);

        // 总结
        console.log(unicode"");
        console.log(unicode"═══════════════════════════════════════════════════════");
        if (!cancelledInBook && keptInBook && queueLen == 0) {
            console.log(unicode"  ✅ Phase 3 验证通过!");
            console.log(unicode"     - 订单已被撤销");
            console.log(unicode"     - 保留订单仍在簿中");
        } else if (cancelledInBook && keptInBook && queueLen == 0) {
            console.log(unicode"  ⚠️ 撤单请求可能尚未提交");
            console.log(unicode"     请运行 TestPhase3_RemoveOrders_Part2");
        } else {
            console.log(unicode"  ❌ Phase 3 验证失败");
        }
        console.log(unicode"═══════════════════════════════════════════════════════");
    }

    function runDetailed() external view {
        string memory json = vm.readFile("deployments.json");
        address orderbookAddr = vm.parseJsonAddress(json, ".orderbook");
        address sequencerAddr = vm.parseJsonAddress(json, ".sequencer");
        bytes32 pairId = vm.parseJsonBytes32(json, ".pairId");

        OrderBook orderbook = OrderBook(orderbookAddr);
        Sequencer sequencer = Sequencer(sequencerAddr);

        console.log(unicode"🔍 详细验证 Matcher 执行结果");
        console.log("================================");

        console.log("");
        console.log(unicode"📊 Bid 订单簿快照 (深度5):");
        (uint256[] memory bidPrices, uint256[] memory bidVolumes) = orderbook.getOrderBookSnapshot(pairId, false, 5);
        for (uint256 i = 0; i < bidPrices.length; i++) {
            if (bidPrices[i] == 0) break;
            console.log("  Price: %d USDC, Volume: %d (raw)", bidPrices[i] / PRICE_DECIMALS, bidVolumes[i]);
        }

        console.log("");
        console.log(unicode"📊 Ask 订单簿快照 (深度5):");
        (uint256[] memory askPrices, uint256[] memory askVolumes) = orderbook.getOrderBookSnapshot(pairId, true, 5);
        for (uint256 i = 0; i < askPrices.length; i++) {
            if (askPrices[i] == 0) break;
            console.log("  Price: %d USDC, Volume: %d (raw)", askPrices[i] / PRICE_DECIMALS, askVolumes[i]);
        }

        console.log("");
        console.log(unicode"💹 最优价格:");
        uint256 bestBid = orderbook.getBestPrice(pairId, false);
        uint256 bestAsk = orderbook.getBestPrice(pairId, true);
        console.log("  Best Bid: %d USDC", bestBid / PRICE_DECIMALS);
        console.log("  Best Ask: %d USDC", bestAsk / PRICE_DECIMALS);

        if (bestBid > 0 && bestAsk > 0) {
            uint256 spread = bestAsk - bestBid;
            console.log("  Spread: %d USDC", spread / PRICE_DECIMALS);
        }

        console.log("");
        console.log(unicode"📋 Sequencer 队列快照:");
        (uint256[] memory orderIds, address[] memory traders, uint256[] memory amounts) = sequencer.getQueueSnapshot(10);
        uint256 queueCount = 0;
        for (uint256 i = 0; i < orderIds.length; i++) {
            if (orderIds[i] == 0) break;
            console.log("  Order %d from %s amount: %d", orderIds[i], traders[i], amounts[i]);
            queueCount++;
        }
        if (queueCount == 0) {
            console.log(unicode"  队列为空");
        }

        console.log("");
        console.log(unicode"🔢 Match ID: %d", orderbook.matchId());
    }

    function _printPriceLevels(
        OrderBook orderbook,
        bytes32 pairId,
        uint256 startPrice,
        bool isAsk,
        uint256 maxLevels
    ) internal view {
        uint256 currentPrice = startPrice;

        for (uint256 i = 0; i < maxLevels && currentPrice != 0; i++) {
            OrderBook.PriceLevel memory level = orderbook.getPriceLevel(pairId, currentPrice, isAsk);

            uint256 priceWhole = level.price / PRICE_DECIMALS;

            console.log("  Level %d: %d USDC, Volume: %d (raw)", i + 1, priceWhole, level.totalVolume);

            currentPrice = level.nextPrice;
        }
    }
}
