// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {Account as AccountContract} from "../Account.sol";
import {Sequencer} from "../Sequencer.sol";
import {MockERC20} from "../MockERC20.sol";

/**
 * @title TestPhase1_LimitOrders
 * @notice Phase 1: 测试限价单下单和处理
 * @dev 下 3 个买单和 2 个卖单，等待 Matcher 处理后验证订单簿状态
 */
contract TestPhase1_LimitOrders is Script {
    function run() external {
        string memory json = vm.readFile("deployments.json");

        address weth = vm.parseJsonAddress(json, ".weth");
        address usdc = vm.parseJsonAddress(json, ".usdc");
        address account = vm.parseJsonAddress(json, ".account");
        address sequencer = vm.parseJsonAddress(json, ".sequencer");
        bytes32 pairId = vm.parseJsonBytes32(json, ".pairId");

        uint256 userPrivateKey = vm.envUint("USER_PRIVATE_KEY");
        address user = vm.addr(userPrivateKey);

        console.log(unicode"");
        console.log(unicode"═══════════════════════════════════════════════════════");
        console.log(unicode"  Phase 1: 限价单测试");
        console.log(unicode"═══════════════════════════════════════════════════════");
        console.log(unicode"");
        console.log("Test user:", user);

        // Mint tokens (as deployer)
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        MockERC20(weth).mint(user, 100 ether);
        MockERC20(usdc).mint(user, 100_000 * 10**6);
        vm.stopBroadcast();

        // Setup user account
        vm.startBroadcast(userPrivateKey);

        MockERC20(weth).approve(account, type(uint256).max);
        MockERC20(usdc).approve(account, type(uint256).max);

        AccountContract(account).deposit(weth, 10 ether);
        AccountContract(account).deposit(usdc, 20_000 * 10**6);

        console.log(unicode"");
        console.log(unicode"📦 已存入资金:");
        console.log("  WETH: 10");
        console.log("  USDC: 20,000");

        // Place limit orders
        console.log(unicode"");
        console.log(unicode"📝 下单中...");
        console.log(unicode"");

        // Bid orders (买单)
        console.log(unicode"  买单 (Bid):");
        (uint256 reqId1,) = Sequencer(sequencer).placeLimitOrder(pairId, false, 2000 * 10**8, 1 * 10**8, 0);
        console.log("    #1: Buy 1 WETH @ 2000 USDC (reqId:", reqId1, ")");

        (uint256 reqId2,) = Sequencer(sequencer).placeLimitOrder(pairId, false, 1950 * 10**8, 1 * 10**8, 0);
        console.log("    #2: Buy 1 WETH @ 1950 USDC (reqId:", reqId2, ")");

        (uint256 reqId3,) = Sequencer(sequencer).placeLimitOrder(pairId, false, 1900 * 10**8, 2 * 10**8, 0);
        console.log("    #3: Buy 2 WETH @ 1900 USDC (reqId:", reqId3, ")");

        // Ask orders (卖单)
        console.log(unicode"");
        console.log(unicode"  卖单 (Ask):");
        (uint256 reqId4,) = Sequencer(sequencer).placeLimitOrder(pairId, true, 2100 * 10**8, 1 * 10**8, 0);
        console.log("    #4: Sell 1 WETH @ 2100 USDC (reqId:", reqId4, ")");

        (uint256 reqId5,) = Sequencer(sequencer).placeLimitOrder(pairId, true, 2150 * 10**8, 1 * 10**8, 0);
        console.log("    #5: Sell 1 WETH @ 2150 USDC (reqId:", reqId5, ")");

        vm.stopBroadcast();

        // Show queue status
        uint256 queueLength = Sequencer(sequencer).getQueueLength(100);

        console.log(unicode"");
        console.log(unicode"📊 队列状态:");
        console.log("  Queue length:", queueLength);

        console.log(unicode"");
        console.log(unicode"═══════════════════════════════════════════════════════");
        console.log(unicode"  Phase 1 准备完成!");
        console.log(unicode"  ");
        console.log(unicode"  预期结果 (Matcher 处理后):");
        console.log(unicode"    - 3 个 Bid 价格层级: 2000, 1950, 1900");
        console.log(unicode"    - 2 个 Ask 价格层级: 2100, 2150");
        console.log(unicode"    - 队列清空");
        console.log(unicode"═══════════════════════════════════════════════════════");
    }
}
