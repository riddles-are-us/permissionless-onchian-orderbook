// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {Account as AccountContract} from "../Account.sol";
import {Sequencer} from "../Sequencer.sol";
import {OrderBook} from "../OrderBook.sol";
import {MockERC20} from "../MockERC20.sol";

/**
 * @title TestPhase3_RemoveOrders
 * @notice Phase 3: 测试撤单功能
 * @dev 先下新订单，然后请求撤销其中一个
 */
contract TestPhase3_RemoveOrders is Script {
    function run() external {
        string memory json = vm.readFile("deployments.json");

        address weth = vm.parseJsonAddress(json, ".weth");
        address usdc = vm.parseJsonAddress(json, ".usdc");
        address account = vm.parseJsonAddress(json, ".account");
        address sequencer = vm.parseJsonAddress(json, ".sequencer");
        address orderbook = vm.parseJsonAddress(json, ".orderbook");
        bytes32 pairId = vm.parseJsonBytes32(json, ".pairId");

        // 使用第三个测试用户
        uint256 user3PrivateKey = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6; // anvil account #3
        address user3 = vm.addr(user3PrivateKey);

        console.log(unicode"");
        console.log(unicode"═══════════════════════════════════════════════════════");
        console.log(unicode"  Phase 3: 撤单测试");
        console.log(unicode"═══════════════════════════════════════════════════════");
        console.log(unicode"");
        console.log("Test user 3:", user3);

        // Mint tokens to user3 (as deployer)
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        MockERC20(weth).mint(user3, 50 ether);
        MockERC20(usdc).mint(user3, 50_000 * 10**6);
        vm.stopBroadcast();

        // Setup user3 account
        vm.startBroadcast(user3PrivateKey);

        MockERC20(weth).approve(account, type(uint256).max);
        MockERC20(usdc).approve(account, type(uint256).max);

        AccountContract(account).deposit(weth, 5 ether);
        AccountContract(account).deposit(usdc, 10_000 * 10**6);

        console.log(unicode"");
        console.log(unicode"📦 User3 已存入资金:");
        console.log("  WETH: 5");
        console.log("  USDC: 10,000");

        // 查看当前余额
        (uint256 usdcAvailBefore,,) = AccountContract(account).getBalance(user3, usdc);
        console.log(unicode"");
        console.log(unicode"📊 下单前 USDC 可用余额:", usdcAvailBefore / 10**6);

        // Place orders to be cancelled
        console.log(unicode"");
        console.log(unicode"📝 下单中 (准备撤销)...");
        console.log(unicode"");

        // 下一个买单，稍后撤销
        (uint256 reqId1, uint256 orderId1) = Sequencer(sequencer).placeLimitOrder(
            pairId,
            false,  // bid
            1800 * 10**8,  // price
            1 * 10**8,  // amount
            0  // uncancellableDuration
        );
        console.log("  Order #1: Buy 1 WETH @ 1800 USDC");
        console.log("    RequestID:", reqId1);
        console.log("    OrderID:", orderId1);

        // 再下一个买单，保留
        (uint256 reqId2, uint256 orderId2) = Sequencer(sequencer).placeLimitOrder(
            pairId,
            false,
            1750 * 10**8,
            1 * 10**8,
            0  // uncancellableDuration
        );
        console.log(unicode"");
        console.log("  Order #2: Buy 1 WETH @ 1750 USDC");
        console.log("    RequestID:", reqId2);
        console.log("    OrderID:", orderId2);

        vm.stopBroadcast();

        // 等待 Matcher 处理下单请求
        console.log(unicode"");
        console.log(unicode"⏳ 需要等待 Matcher 处理这两个下单请求后，才能提交撤单请求");
        console.log(unicode"   (订单必须先在 OrderBook 中才能被撤销)");

        // 显示队列状态
        uint256 queueLength = Sequencer(sequencer).getQueueLength(100);
        console.log(unicode"");
        console.log(unicode"📊 队列状态:");
        console.log("  Queue length:", queueLength);

        console.log(unicode"");
        console.log(unicode"═══════════════════════════════════════════════════════");
        console.log(unicode"  Phase 3 第一步完成!");
        console.log(unicode"  ");
        console.log(unicode"  下一步:");
        console.log(unicode"    1. 等待 Matcher 处理上述订单");
        console.log(unicode"    2. 运行 TestPhase3_RemoveOrders_Part2 提交撤单请求");
        console.log(unicode"  ");
        console.log(unicode"  要撤销的订单 ID:", orderId1);
        console.log(unicode"═══════════════════════════════════════════════════════");
    }
}

/**
 * @title TestPhase3_RemoveOrders_Part2
 * @notice Phase 3 Part 2: 提交撤单请求
 * @dev 在 Matcher 处理完下单请求后运行
 * @dev 使用环境变量 ORDER_ID_TO_CANCEL 指定要撤销的订单 ID
 */
contract TestPhase3_RemoveOrders_Part2 is Script {
    function run() external {
        string memory deployJson = vm.readFile("deployments.json");
        address sequencer = vm.parseJsonAddress(deployJson, ".sequencer");

        // 从环境变量获取要撤销的订单 ID，默认为 11
        uint256 orderIdToCancel = vm.envOr("ORDER_ID_TO_CANCEL", uint256(11));
        uint256 user3PrivateKey = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;

        console.log(unicode"");
        console.log(unicode"═══════════════════════════════════════════════════════");
        console.log(unicode"  Phase 3 Part 2: 提交撤单请求");
        console.log(unicode"═══════════════════════════════════════════════════════");
        console.log(unicode"");

        // 检查订单是否已在 OrderBook 中
        bool isInBook = Sequencer(sequencer).ordersInBook(orderIdToCancel);
        console.log("Order", orderIdToCancel, "in OrderBook:", isInBook);

        if (!isInBook) {
            console.log(unicode"");
            console.log(unicode"⚠️  订单尚未在 OrderBook 中!");
            console.log(unicode"   请等待 Matcher 处理下单请求后再运行此脚本");
            return;
        }

        // 提交撤单请求
        vm.startBroadcast(user3PrivateKey);

        console.log(unicode"");
        console.log(unicode"📝 提交撤单请求...");
        uint256 cancelReqId = Sequencer(sequencer).requestRemoveOrder(orderIdToCancel);
        console.log("  Cancel request submitted!");
        console.log("  RequestID:", cancelReqId);
        console.log("  OrderID to cancel:", orderIdToCancel);

        vm.stopBroadcast();

        // 显示队列状态
        uint256 queueLength = Sequencer(sequencer).getQueueLength(100);
        console.log(unicode"");
        console.log(unicode"📊 队列状态:");
        console.log("  Queue length:", queueLength);

        console.log(unicode"");
        console.log(unicode"═══════════════════════════════════════════════════════");
        console.log(unicode"  Phase 3 Part 2 完成!");
        console.log(unicode"  ");
        console.log(unicode"  预期结果 (Matcher 处理后):");
        console.log(unicode"    - Order", orderIdToCancel, unicode"被撤销");
        console.log(unicode"    - 用户锁定资金被释放");
        console.log(unicode"    - OrderRemoved 事件被触发");
        console.log(unicode"═══════════════════════════════════════════════════════");
    }
}
