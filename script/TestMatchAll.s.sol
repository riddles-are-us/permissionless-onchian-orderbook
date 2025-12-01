// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../Sequencer.sol";
import {Account as AccountContract} from "../Account.sol";
import "../MockERC20.sol";

/**
 * @title TestMatchAll Script
 * @notice 测试 matchAll() 功能
 *
 * 测试场景：
 * 1. 放置 5 个买单（bid）在相同价位
 * 2. matcher 处理这些买单插入 orderbook
 * 3. 放置一个大卖单在低价位，可以匹配所有买单
 * 4. 由于 OrderBook._tryMatchAfterInsertion 中 maxIterations=2，只会匹配 2 个
 * 5. Matcher 检测到还有可撮合订单（bidHead >= askHead），调用 matchAll()
 */
contract TestMatchAllScript is Script {
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
        MockERC20 usdc = MockERC20(usdcAddr);
        Sequencer sequencer = Sequencer(sequencerAddr);

        vm.startBroadcast(deployerPrivateKey);

        console.log("=== TestMatchAll Script ===");
        console.log("Deployer:", deployer);
        console.log("PairId:", vm.toString(pairId));

        // 铸造代币
        weth.mint(deployer, 1000 * 10**18);
        usdc.mint(deployer, 1000000 * 10**6);

        // 授权
        weth.approve(accountAddr, type(uint256).max);
        usdc.approve(accountAddr, type(uint256).max);

        // 充值
        console.log("\nDepositing tokens...");
        AccountContract(accountAddr).deposit(wethAddr, 100 * 10**18);
        AccountContract(accountAddr).deposit(usdcAddr, 100000 * 10**6);

        // 放置 5 个买单，都在价格 200（用 10^8 精度表示）
        // 这样当卖单以低于 200 的价格插入时，会触发撮合
        uint256 buyPrice = 200 * 10**8;  // 200 USDC (10^8 精度)
        uint256 buyAmount = 10 * 10**6;   // 0.1 WETH 每单 (10^6 精度)

        console.log("\n=== Phase 1: Place 5 buy orders at price 200 ===");
        console.log("Each order: price=200, amount=0.1 WETH");

        for (uint256 i = 0; i < 5; i++) {
            (uint256 requestId, ) = sequencer.placeLimitOrder(pairId, false, buyPrice, buyAmount);
            console.log("  Buy order #%s: requestId=%s", i+1, requestId);
        }

        console.log("\n=== Phase 1 Complete ===");
        console.log("Placed 5 buy orders at price 200");
        console.log("Wait for matcher to process these orders into orderbook...");
        console.log("Then run TestMatchAllPhase2.s.sol to place the sell order");

        vm.stopBroadcast();
    }
}
