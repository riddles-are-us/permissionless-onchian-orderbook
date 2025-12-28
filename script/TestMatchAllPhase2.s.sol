// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../Sequencer.sol";
import {Account as AccountContract} from "../Account.sol";
import "../MockERC20.sol";

/**
 * @title TestMatchAllPhase2 Script
 * @notice 测试 matchAll() 功能 - Phase 2
 *
 * 前置条件：
 * - 已运行 TestMatchAll.s.sol 放置了 5 个买单
 * - Matcher 已将这些买单处理到 orderbook
 *
 * Phase 2 操作：
 * 1. 放置一个大卖单在低价位（如 190），可以匹配所有 5 个买单（价格 200）
 * 2. 由于 maxIterations=2，自动撮合只会匹配 2 个
 * 3. Matcher 检测到还有可撮合订单，调用 matchAll() 完成剩余撮合
 */
contract TestMatchAllPhase2Script is Script {
    function run() external {
        string memory json = vm.readFile("deployments.json");
        address wethAddr = vm.parseJsonAddress(json, ".weth");
        address usdcAddr = vm.parseJsonAddress(json, ".usdc");
        address accountAddr = vm.parseJsonAddress(json, ".account");
        address sequencerAddr = vm.parseJsonAddress(json, ".sequencer");
        bytes32 pairId = vm.parseJsonBytes32(json, ".pairId");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        MockERC20 weth = MockERC20(wethAddr);
        Sequencer sequencer = Sequencer(sequencerAddr);

        vm.startBroadcast(deployerPrivateKey);

        console.log("=== Phase 2: Place sell order to trigger matching ===");

        // 确保有足够的 WETH 余额
        weth.mint(deployer, 100 * 10**18);
        weth.approve(accountAddr, type(uint256).max);
        AccountContract(accountAddr).deposit(wethAddr, 10 * 10**18);

        // 放置一个大卖单，价格 190，数量 0.5 WETH（足以匹配所有 5 个买单）
        // 买单价格 200 > 卖单价格 190，所以会触发撮合
        uint256 sellPrice = 190 * 10**8;  // 190 USDC
        uint256 sellAmount = 50 * 10**6;   // 0.5 WETH (enough to match all 5 buy orders of 0.1 each)

        console.log("Placing sell order:");
        console.log("  price: 190 (lower than buy orders at 200)");
        console.log("  amount: 0.5 WETH (matches all 5 buy orders of 0.1 each)");

        (uint256 requestId, ) = sequencer.placeLimitOrder(pairId, true, sellPrice, sellAmount, 0);
        console.log("  Sell order requestId:", requestId);

        console.log("\n=== Phase 2 Complete ===");
        console.log("The matcher will:");
        console.log("1. Process the sell order");
        console.log("2. Auto-match will only complete 2 iterations (maxIterations=2)");
        console.log("3. Detect remaining matchable orders (bidHead >= askHead)");
        console.log("4. Call matchAll() to complete remaining matches");
        console.log("\nWatch matcher logs for:");
        console.log("  'Found matchable orders (limit=true...), calling matchAll...'");
        console.log("  'matchAll transaction sent: ...'");

        vm.stopBroadcast();
    }
}
