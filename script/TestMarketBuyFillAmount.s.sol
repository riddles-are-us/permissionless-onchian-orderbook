// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../Sequencer.sol";
import {Account as AccountContract} from "../Account.sol";
import "../MockERC20.sol";

contract TestMarketBuyFillAmountScript is Script {
    function run() external {
        // 从 deployments.json 读取地址
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

        console.log("Deployer:", deployer);

        // 铸造代币
        weth.mint(deployer, 1000 * 10**18);
        usdc.mint(deployer, 1000000 * 10**6);

        // 授权
        weth.approve(accountAddr, type(uint256).max);
        usdc.approve(accountAddr, type(uint256).max);

        // 充值
        console.log("Depositing tokens...");
        AccountContract(accountAddr).deposit(wethAddr, 100 * 10**18);
        AccountContract(accountAddr).deposit(usdcAddr, 100000 * 10**6);

        // Step 1: 下一个价格2000，数量10的限价买单
        console.log("\n=== Step 1: Place limit buy order ===");
        uint256 buyPrice = 2000 * 10**8;  // 2000 USDC (8 decimals for price)
        uint256 buyAmount = 10 * 10**8;   // 10 base tokens (8 decimals)
        (uint256 reqId1, uint256 orderId1) = sequencer.placeLimitOrder(pairId, false, buyPrice, buyAmount, 0);
        console.log("  Limit Buy - RequestId:", reqId1, "OrderId:", orderId1);
        console.log("  Price: 2000, Amount: 10");

        // Step 2: 下一个价格2001，数量10的限价卖单
        console.log("\n=== Step 2: Place limit sell order ===");
        uint256 sellPrice = 2001 * 10**8;  // 2001 USDC (8 decimals for price)
        uint256 sellAmount = 10 * 10**8;   // 10 base tokens (8 decimals)
        (uint256 reqId2, uint256 orderId2) = sequencer.placeLimitOrder(pairId, true, sellPrice, sellAmount, 0);
        console.log("  Limit Sell - RequestId:", reqId2, "OrderId:", orderId2);
        console.log("  Price: 2001, Amount: 10");

        // Step 3: 下一个市价200u的买单
        console.log("\n=== Step 3: Place market buy order (200 USDC) ===");
        uint256 quoteToSpend = 200 * 10**8;  // 200 USDC worth (8 decimals for quote amount)
        (uint256 reqId3, uint256 orderId3) = sequencer.placeMarketOrder(pairId, false, quoteToSpend);
        console.log("  Market Buy - RequestId:", reqId3, "OrderId:", orderId3);
        console.log("  Quote to spend: 200 USDC");
        console.log("  Expected base tokens: ~0.0999 (200 / 2001)");

        vm.stopBroadcast();

        console.log("\n=== Orders placed successfully! ===");
        console.log("Market Buy Order ID:", orderId3);
        console.log("\nNow run the matcher to process these orders,");
        console.log("then query the market buy order via RPC to check filled_amount.");
    }
}
