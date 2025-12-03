// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {Account as AccountContract} from "../Account.sol";
import {Sequencer} from "../Sequencer.sol";
import {OrderBook} from "../OrderBook.sol";
import {MockERC20} from "../MockERC20.sol";

/**
 * @title TestAskOrderInsertion
 * @notice 测试 Ask 订单链表插入顺序
 * @dev 流程：
 *   1. 下价格 10 的卖单 (Ask)
 *   2. 下价格 9 的卖单 (Ask) - 应该插入到 10 前面
 *   3. 下价格 11 的卖单 (Ask) - 应该插入到 10 后面
 *   最终顺序应该是: 9 -> 10 -> 11 (Ask 从低到高排序)
 */
contract TestAskOrderInsertion is Script {
    function run() external {
        string memory json = vm.readFile("deployments.json");

        address weth = vm.parseJsonAddress(json, ".weth");
        address usdc = vm.parseJsonAddress(json, ".usdc");
        address account = vm.parseJsonAddress(json, ".account");
        address sequencer = vm.parseJsonAddress(json, ".sequencer");
        bytes32 pairId = vm.parseJsonBytes32(json, ".pairId");

        // 使用测试账户 #4
        uint256 userPrivateKey = 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a; // anvil account #4
        address user = vm.addr(userPrivateKey);

        console.log(unicode"");
        console.log(unicode"═══════════════════════════════════════════════════════");
        console.log(unicode"  Ask 订单链表插入测试");
        console.log(unicode"═══════════════════════════════════════════════════════");
        console.log(unicode"");
        console.log("Test user:", user);

        // Mint tokens to user (as deployer)
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        MockERC20(weth).mint(user, 100 ether);
        vm.stopBroadcast();

        // Setup user account
        vm.startBroadcast(userPrivateKey);

        MockERC20(weth).approve(account, type(uint256).max);
        AccountContract(account).deposit(weth, 50 ether);

        console.log(unicode"");
        console.log(unicode"📦 已存入 WETH: 50");

        // Step 1: 下价格 10 的卖单
        console.log(unicode"");
        console.log(unicode"📝 Step 1: 下价格 10 的卖单...");
        (uint256 reqId1, uint256 orderId1) = Sequencer(sequencer).placeLimitOrder(
            pairId,
            true,  // isAsk = true (卖单)
            10 * 10**8,  // price = 10
            1 * 10**8    // amount = 1 WETH
        );
        console.log("  Order #1: Sell 1 WETH @ 10");
        console.log("    RequestID:", reqId1);
        console.log("    OrderID:", orderId1);

        // Step 2: 下价格 9 的卖单
        console.log(unicode"");
        console.log(unicode"📝 Step 2: 下价格 9 的卖单...");
        (uint256 reqId2, uint256 orderId2) = Sequencer(sequencer).placeLimitOrder(
            pairId,
            true,  // isAsk
            9 * 10**8,   // price = 9
            1 * 10**8    // amount = 1 WETH
        );
        console.log("  Order #2: Sell 1 WETH @ 9");
        console.log("    RequestID:", reqId2);
        console.log("    OrderID:", orderId2);

        // Step 3: 下价格 11 的卖单
        console.log(unicode"");
        console.log(unicode"📝 Step 3: 下价格 11 的卖单...");
        (uint256 reqId3, uint256 orderId3) = Sequencer(sequencer).placeLimitOrder(
            pairId,
            true,  // isAsk
            11 * 10**8,  // price = 11
            1 * 10**8    // amount = 1 WETH
        );
        console.log("  Order #3: Sell 1 WETH @ 11");
        console.log("    RequestID:", reqId3);
        console.log("    OrderID:", orderId3);

        vm.stopBroadcast();

        // 显示队列状态
        uint256 queueLength = Sequencer(sequencer).getQueueLength(100);
        console.log(unicode"");
        console.log(unicode"📊 队列状态:");
        console.log("  Queue length:", queueLength);

        console.log(unicode"");
        console.log(unicode"═══════════════════════════════════════════════════════");
        console.log(unicode"  测试准备完成!");
        console.log(unicode"  ");
        console.log(unicode"  预期结果 (Matcher 处理后):");
        console.log(unicode"    Ask 链表顺序 (从低到高): 9 -> 10 -> 11");
        console.log(unicode"    askHead = 9");
        console.log(unicode"    askTail = 11");
        console.log(unicode"  ");
        console.log(unicode"  OrderID 映射:");
        console.log(unicode"    Order", orderId1, "@ price 10");
        console.log(unicode"    Order", orderId2, "@ price 9");
        console.log(unicode"    Order", orderId3, "@ price 11");
        console.log(unicode"═══════════════════════════════════════════════════════");
    }
}

/**
 * @title VerifyAskOrderInsertion
 * @notice 验证 Ask 订单链表插入结果
 */
contract VerifyAskOrderInsertion is Script {
    function run() external view {
        string memory json = vm.readFile("deployments.json");
        address orderbook = vm.parseJsonAddress(json, ".orderbook");
        address sequencer = vm.parseJsonAddress(json, ".sequencer");
        bytes32 pairId = vm.parseJsonBytes32(json, ".pairId");

        console.log(unicode"");
        console.log(unicode"═══════════════════════════════════════════════════════");
        console.log(unicode"  验证 Ask 订单链表插入结果");
        console.log(unicode"═══════════════════════════════════════════════════════");

        // 检查队列状态
        uint256 queueLen = Sequencer(sequencer).getQueueLength(100);
        console.log(unicode"");
        console.log(unicode"📦 队列状态:");
        console.log("  Queue length:", queueLen);
        if (queueLen == 0) {
            console.log(unicode"  Status: ✅ 已清空");
        } else {
            console.log(unicode"  Status: ⚠️  还有订单待处理");
        }

        // 获取订单簿状态
        (
            uint256 askHead,
            uint256 askTail,
            uint256 bidHead,
            uint256 bidTail,
            ,,,
        ) = OrderBook(orderbook).orderBooks(pairId);

        console.log(unicode"");
        console.log(unicode"📊 订单簿头尾:");
        console.log("  askHead:", askHead / 10**8);
        console.log("  askTail:", askTail / 10**8);
        console.log("  bidHead:", bidHead / 10**8);
        console.log("  bidTail:", bidTail / 10**8);

        // 遍历 Ask 链表
        console.log(unicode"");
        console.log(unicode"📋 Ask 链表遍历 (从低到高):");

        uint256 currentPrice = askHead;
        uint256 levelCount = 0;
        uint256 maxLevels = 10;

        while (currentPrice > 0 && levelCount < maxLevels) {
            OrderBook.PriceLevel memory level = OrderBook(orderbook).getPriceLevel(currentPrice, true);

            console.log(unicode"  Level", levelCount + 1, ":");
            console.log("    Price:", currentPrice / 10**8);
            console.log("    TotalVolume:", level.totalVolume / 10**8, "WETH");
            console.log("    Next:", level.nextPrice / 10**8);

            currentPrice = level.nextPrice;
            levelCount++;
        }

        // 验证结果
        console.log(unicode"");
        console.log(unicode"═══════════════════════════════════════════════════════");

        bool askHeadCorrect = (askHead == 9 * 10**8);
        bool askTailCorrect = (askTail == 11 * 10**8);

        if (askHeadCorrect && askTailCorrect && levelCount == 3) {
            console.log(unicode"  ✅ 测试通过!");
            console.log(unicode"     Ask 链表顺序正确: 9 -> 10 -> 11");
        } else {
            console.log(unicode"  ❌ 测试失败!");
            if (!askHeadCorrect) {
                console.log(unicode"     askHead 应该是 9, 实际是", askHead / 10**8);
            }
            if (!askTailCorrect) {
                console.log(unicode"     askTail 应该是 11, 实际是", askTail / 10**8);
            }
            if (levelCount != 3) {
                console.log(unicode"     价格层级数量应该是 3, 实际是", levelCount);
            }
        }
        console.log(unicode"═══════════════════════════════════════════════════════");
    }
}
