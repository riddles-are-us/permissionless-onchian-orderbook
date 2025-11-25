// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../Sequencer.sol";
import {Account as AccountContract} from "../Account.sol";
import "../MockERC20.sol";

contract PlaceTestOrdersScript is Script {
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

        console.log("Minting tokens for deployer:", deployer);

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
        
        // 下买单 (bid orders)
        console.log("\nPlacing buy orders:");
        for (uint256 i = 0; i < 5; i++) {
            uint256 price = (2000 - i * 10) * 10**8;  // 2000, 1990, 1980, 1970, 1960 USDC
            uint256 amount = (10 + i * 20) * 10**6;    // 0.1, 0.3, 0.5, 0.7, 0.9 WETH (8 decimals)
            (uint256 requestId, uint256 orderId) = sequencer.placeLimitOrder(pairId, false, price, amount);
            console.log("  Buy order requestId=%s, price=%s USDC, amount=%s", requestId, price / 10**8, amount);
        }

        // 下卖单 (ask orders)
        console.log("\nPlacing sell orders:");
        for (uint256 i = 0; i < 5; i++) {
            uint256 price = (2010 + i * 10) * 10**8;  // 2010, 2020, 2030, 2040, 2050 USDC
            uint256 amount = (10 + i * 20) * 10**6;    // 0.1, 0.3, 0.5, 0.7, 0.9 WETH (8 decimals)
            (uint256 requestId, uint256 orderId) = sequencer.placeLimitOrder(pairId, true, price, amount);
            console.log("  Sell order requestId=%s, price=%s USDC, amount=%s", requestId, price / 10**8, amount);
        }
        
        vm.stopBroadcast();
        
        console.log("\n=== Test orders placed successfully! ===");
        console.log("Total: 5 buy orders + 5 sell orders = 10 orders");
        console.log("\nNote: Orders are now in Sequencer queue.");
        console.log("The matcher will process them and insert into OrderBook.");
    }
}
