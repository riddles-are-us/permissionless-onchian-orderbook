// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../Sequencer.sol";
import "../Account.sol";
import "../MockERC20.sol";

contract PlaceTestOrdersScript is Script {
    function run() external {
        // 使用 deployments.json 中的地址
        address wethAddr = 0x5FbDB2315678afecb367f032d93F642f64180aa3;
        address usdcAddr = 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512;
        address accountAddr = 0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0;
        address sequencerAddr = 0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9;
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        MockERC20 weth = MockERC20(wethAddr);
        MockERC20 usdc = MockERC20(usdcAddr);
        Account account = Account(accountAddr);
        Sequencer sequencer = Sequencer(sequencerAddr);
        
        bytes32 pairId = keccak256("WETH/USDC");
        
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
        account.deposit(wethAddr, 100 * 10**18);
        account.deposit(usdcAddr, 100000 * 10**6);
        
        // 下买单 (bid orders)
        console.log("\nPlacing buy orders:");
        for (uint256 i = 0; i < 5; i++) {
            uint256 price = (2000 - i * 10) * 10**8;  // 2000, 1990, 1980, 1970, 1960
            uint256 amount = (1 + i * 2) * 10**7;      // 0.1, 0.3, 0.5, 0.7, 0.9 WETH
            (uint256 requestId, uint256 orderId) = sequencer.placeLimitOrder(pairId, false, price, amount);
            console.log("  Buy order #%s: price=%s USDC, amount=%s WETH", orderId, price / 10**8, amount / 10**8);
        }
        
        // 下卖单 (ask orders)
        console.log("\nPlacing sell orders:");
        for (uint256 i = 0; i < 5; i++) {
            uint256 price = (2010 + i * 10) * 10**8;  // 2010, 2020, 2030, 2040, 2050
            uint256 amount = (1 + i * 2) * 10**7;      // 0.1, 0.3, 0.5, 0.7, 0.9 WETH
            (uint256 requestId, uint256 orderId) = sequencer.placeLimitOrder(pairId, true, price, amount);
            console.log("  Sell order #%s: price=%s USDC, amount=%s WETH", orderId, price / 10**8, amount / 10**8);
        }
        
        vm.stopBroadcast();
        
        console.log("\n=== Test orders placed successfully! ===");
        console.log("Total: 5 buy orders + 5 sell orders = 10 orders");
        console.log("\nNote: Orders are now in Sequencer queue.");
        console.log("The matcher will process them and insert into OrderBook.");
    }
}
