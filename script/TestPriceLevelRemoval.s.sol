// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {Sequencer} from "../Sequencer.sol";
import {OrderBook} from "../OrderBook.sol";
import {Account as AccountContract} from "../Account.sol";
import {MockERC20} from "../MockERC20.sol";

/**
 * @title TestPriceLevelRemoval
 * @notice 测试 PriceLevel 正确删除的场景
 * @dev 测试流程:
 *   1. 下一个限价卖单 (Ask): 价格 2100, 数量 1 WETH
 *   2. 下一个市价买单 (Market Buy): 数量 1 WETH (完全吃掉卖单)
 *   3. 验证 Ask 2100 的 PriceLevel 被删除
 */
contract TestPriceLevelRemoval is Script {
    uint256 constant PRICE_DECIMALS = 1e8;
    uint256 constant AMOUNT_DECIMALS = 1e8;

    function run() external {
        string memory json = vm.readFile("deployments.json");
        address sequencerAddr = vm.parseJsonAddress(json, ".sequencer");
        address accountAddr = vm.parseJsonAddress(json, ".account");
        address weth = vm.parseJsonAddress(json, ".weth");
        address usdc = vm.parseJsonAddress(json, ".usdc");
        bytes32 pairId = vm.parseJsonBytes32(json, ".pairId");

        Sequencer sequencer = Sequencer(sequencerAddr);
        AccountContract account = AccountContract(accountAddr);

        // 使用 anvil 测试账户
        // Account #1: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 (seller)
        // Account #2: 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC (buyer)
        uint256 sellerPk = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
        uint256 buyerPk = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;

        address seller = vm.addr(sellerPk);
        address buyer = vm.addr(buyerPk);

        console.log(unicode"");
        console.log(unicode"═══════════════════════════════════════════════════════");
        console.log(unicode"  测试 PriceLevel 删除");
        console.log(unicode"═══════════════════════════════════════════════════════");
        console.log(unicode"");

        // Step 0: Mint tokens for seller and buyer (using deployer)
        uint256 deployerPk = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        console.log(unicode"📥 Step 0: Mint tokens for seller and buyer");
        vm.startBroadcast(deployerPk);
        MockERC20(weth).mint(seller, 10 ether);
        MockERC20(usdc).mint(buyer, 10000 * 10**6);
        vm.stopBroadcast();
        console.log("  Minted 10 WETH to seller");
        console.log("  Minted 10000 USDC to buyer");

        // Step 1: Seller 存入 WETH
        console.log(unicode"");
        console.log(unicode"📥 Step 1: Seller 存入 1 WETH");
        vm.startBroadcast(sellerPk);
        uint256 depositAmount = 1 * 10**18; // 1 WETH (18 decimals)
        MockERC20(weth).approve(accountAddr, depositAmount);
        account.deposit(weth, depositAmount);
        vm.stopBroadcast();
        console.log("  Seller:", seller);
        console.log("  Deposited: 1 WETH");

        // Step 2: Buyer 存入 USDC
        console.log(unicode"");
        console.log(unicode"📥 Step 2: Buyer 存入 2500 USDC");
        vm.startBroadcast(buyerPk);
        uint256 usdcAmount = 2500 * 10**6; // 2500 USDC (6 decimals)
        MockERC20(usdc).approve(accountAddr, usdcAmount);
        account.deposit(usdc, usdcAmount);
        vm.stopBroadcast();
        console.log("  Buyer:", buyer);
        console.log("  Deposited: 2500 USDC");

        // Step 3: Seller 下限价卖单
        console.log(unicode"");
        console.log(unicode"📝 Step 3: Seller 下限价卖单 - 价格 2100 USDC, 数量 1 WETH");
        vm.startBroadcast(sellerPk);
        uint256 sellPrice = 2100 * PRICE_DECIMALS;  // 2100 USDC
        uint256 sellAmount = 1 * AMOUNT_DECIMALS;   // 1 WETH
        (, uint256 sellOrderId) = sequencer.placeLimitOrder(
            pairId,
            true,   // isAsk = true (卖单)
            sellPrice,
            sellAmount,
            0  // uncancellableDuration
        );
        vm.stopBroadcast();
        console.log("  Sell Order ID:", sellOrderId);
        console.log("  Price: 2100 USDC");
        console.log("  Amount: 1 WETH");

        // Step 4: Buyer 下市价买单 (完全吃掉卖单)
        // 注意: 市价买单的 amount 是 quote 金额 (USDC), 不是 base 金额 (WETH)
        // 要买 1 WETH @ 2100 USDC, 需要 2100 * PRICE_DECIMALS USDC
        console.log(unicode"");
        console.log(unicode"📝 Step 4: Buyer 下市价买单 - 2100 USDC (买 1 WETH)");
        vm.startBroadcast(buyerPk);
        uint256 buyQuoteAmount = 2100 * PRICE_DECIMALS;    // 2100 USDC (足够买 1 WETH)
        (, uint256 buyOrderId) = sequencer.placeMarketOrder(
            pairId,
            false,  // isAsk = false (买单)
            buyQuoteAmount
        );
        vm.stopBroadcast();
        console.log("  Buy Order ID:", buyOrderId);
        console.log("  Quote Amount: 2100 USDC");

        console.log(unicode"");
        console.log(unicode"✅ 订单已提交，等待 Matcher 处理...");
        console.log(unicode"");
        console.log(unicode"═══════════════════════════════════════════════════════");
        console.log(unicode"  预期结果:");
        console.log(unicode"  - 卖单完全成交");
        console.log(unicode"  - Ask 2100 的 PriceLevel 被删除");
        console.log(unicode"  - 订单簿中不存在 amount=0 的 PriceLevel");
        console.log(unicode"═══════════════════════════════════════════════════════");
    }
}

/**
 * @title VerifyPriceLevelRemoval
 * @notice 验证 PriceLevel 是否被正确删除
 */
contract VerifyPriceLevelRemoval is Script {
    uint256 constant PRICE_DECIMALS = 1e8;

    function run() external view {
        string memory json = vm.readFile("deployments.json");
        address orderbookAddr = vm.parseJsonAddress(json, ".orderbook");
        address sequencerAddr = vm.parseJsonAddress(json, ".sequencer");
        bytes32 pairId = vm.parseJsonBytes32(json, ".pairId");

        OrderBook orderbook = OrderBook(orderbookAddr);
        Sequencer sequencer = Sequencer(sequencerAddr);

        console.log(unicode"");
        console.log(unicode"═══════════════════════════════════════════════════════");
        console.log(unicode"  验证 PriceLevel 删除");
        console.log(unicode"═══════════════════════════════════════════════════════");

        // 检查队列
        uint256 queueLen = sequencer.getQueueLength(100);
        console.log(unicode"");
        console.log(unicode"📦 队列状态:");
        console.log("  Queue length:", queueLen);
        console.log("  Status:", queueLen == 0 ? unicode"✅ 已清空" : unicode"❌ 未清空");

        // 检查订单簿
        console.log(unicode"");
        console.log(unicode"📊 订单簿状态:");

        (
            uint256 askHead,
            uint256 askTail,
            uint256 bidHead,
            uint256 bidTail,
            ,,,
        ) = orderbook.orderBooks(pairId);

        console.log("  Ask Head:", askHead / PRICE_DECIMALS, "USDC");
        console.log("  Ask Tail:", askTail / PRICE_DECIMALS, "USDC");
        console.log("  Bid Head:", bidHead / PRICE_DECIMALS, "USDC");
        console.log("  Bid Tail:", bidTail / PRICE_DECIMALS, "USDC");

        // 检查 Ask 2100 是否还存在
        uint256 testPrice = 2100 * PRICE_DECIMALS;
        OrderBook.PriceLevel memory level = orderbook.getPriceLevel(testPrice, true);

        console.log(unicode"");
        console.log(unicode"🔍 检查 Ask 2100 PriceLevel:");
        console.log("  Price:", level.price / PRICE_DECIMALS);
        console.log("  TotalVolume:", level.totalVolume);
        console.log("  HeadOrderId:", level.headOrderId);
        console.log("  TailOrderId:", level.tailOrderId);

        bool priceLevelRemoved = (level.totalVolume == 0 && level.headOrderId == 0);

        // 遍历所有 Ask 价格层级，检查是否有 totalVolume = 0 的
        console.log(unicode"");
        console.log(unicode"📋 遍历 Ask 价格层级:");
        uint256 currentPrice = askHead;
        uint256 count = 0;
        bool hasZeroVolume = false;

        while (currentPrice != 0 && count < 10) {
            OrderBook.PriceLevel memory pl = orderbook.getPriceLevel(currentPrice, true);
            console.log("  Price: %d USDC, Volume: %d, HeadOrderId: %d",
                currentPrice / PRICE_DECIMALS, pl.totalVolume, pl.headOrderId);

            if (pl.totalVolume == 0) {
                hasZeroVolume = true;
            }

            currentPrice = pl.nextPrice;
            count++;
        }

        if (count == 0) {
            console.log("  (empty)");
        }

        // 遍历所有 Bid 价格层级
        console.log(unicode"");
        console.log(unicode"📋 遍历 Bid 价格层级:");
        currentPrice = bidHead;
        count = 0;

        while (currentPrice != 0 && count < 10) {
            OrderBook.PriceLevel memory pl = orderbook.getPriceLevel(currentPrice, false);
            console.log("  Price: %d USDC, Volume: %d, HeadOrderId: %d",
                currentPrice / PRICE_DECIMALS, pl.totalVolume, pl.headOrderId);

            if (pl.totalVolume == 0) {
                hasZeroVolume = true;
            }

            currentPrice = pl.nextPrice;
            count++;
        }

        if (count == 0) {
            console.log("  (empty)");
        }

        // 检查 Match ID
        uint256 matchId = orderbook.matchId();
        console.log(unicode"");
        console.log(unicode"🔢 Match ID:", matchId);

        // 总结
        console.log(unicode"");
        console.log(unicode"═══════════════════════════════════════════════════════");
        if (queueLen == 0 && priceLevelRemoved && !hasZeroVolume) {
            console.log(unicode"  ✅ 验证通过!");
            console.log(unicode"     - 队列已清空");
            console.log(unicode"     - Ask 2100 PriceLevel 已删除");
            console.log(unicode"     - 无 totalVolume=0 的 PriceLevel");
        } else {
            console.log(unicode"  ❌ 验证失败");
            if (queueLen != 0) console.log(unicode"     - 队列未清空");
            if (!priceLevelRemoved) console.log(unicode"     - Ask 2100 PriceLevel 未删除");
            if (hasZeroVolume) console.log(unicode"     - 存在 totalVolume=0 的 PriceLevel");
        }
        console.log(unicode"═══════════════════════════════════════════════════════");
    }
}
