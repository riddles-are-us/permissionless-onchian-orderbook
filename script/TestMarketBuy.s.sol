// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "../Sequencer.sol";

contract TestMarketBuyScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        // 读取部署地址
        string memory json = vm.readFile("deployments.json");
        address sequencer = vm.parseJsonAddress(json, ".sequencer");
        bytes32 pairId = vm.parseJsonBytes32(json, ".pairId");
        
        vm.startBroadcast(deployerPrivateKey);
        
        Sequencer seq = Sequencer(sequencer);
        
        // 下市价买单：花费 5000 * 10^8 quote tokens
        // 这应该能买到约 2.48 ETH (at price 2010 * 10^8)
        uint256 quoteToSpend = 5000 * 10**8;  // 5000 USDC worth
        
        console.log("Placing market buy order:");
        console.log("  Quote to spend:", quoteToSpend);
        console.log("  Expected: Buy ~2.48 ETH at price 2010");
        
        (uint256 requestId, uint256 orderId) = seq.placeMarketOrder(
            pairId,
            false,  // isAsk = false means buy
            quoteToSpend
        );
        
        console.log("  Request ID:", requestId);
        console.log("  Order ID:", orderId);
        
        vm.stopBroadcast();
        
        console.log("Market buy order placed! Waiting for matcher to process...");
    }
}
