# 撮合引擎使用示例

## 完整的交易流程示例

### 场景1: 限价单撮合

```solidity
// 初始化
bytes32 pair = keccak256("ETH/USDC");

// === Alice提交卖单 ===
// 价格: 2000, 数量: 10
uint256 sellOrder1 = sequencer.placeLimitOrder(pair, true, 2000, 10);
orderBook.insertOrder(sellOrder1, 0, 0);

// === Bob提交卖单 ===
// 价格: 2010, 数量: 15
uint256 sellOrder2 = sequencer.placeLimitOrder(pair, true, 2010, 15);
orderBook.insertOrder(sellOrder2, sellOrder1PriceLevelId, 0);

// === Charlie提交买单 ===
// 价格: 2005, 数量: 12
uint256 buyOrder1 = sequencer.placeLimitOrder(pair, false, 2005, 12);
orderBook.insertOrder(buyOrder1, 0, 0);

// 此时订单簿状态:
// Ask: 2000 (10), 2010 (15)
// Bid: 2005 (12)

// === 执行撮合 ===
uint256 trades = orderBook.matchOrders(pair, 100);

// 撮合结果:
// trades = 1 (一笔交易)
//
// 交易详情:
// - 买单 2005 (12) 与 卖单 2000 (10) 成交
// - 成交价格: 2000 (使用卖单价格)
// - 成交数量: 10 (卖单完全成交)
// - 卖单 2000 完全成交，从订单簿移除
// - 买单 2005 部分成交，剩余 2 继续挂单
//
// 撮合后订单簿状态:
// Ask: 2010 (15)
// Bid: 2005 (2)
// 最高买价 2005 > 最低卖价 2010，还能继续撮合

// === 再次执行撮合 ===
trades = orderBook.matchOrders(pair, 100);

// 撮合结果:
// trades = 1
//
// 交易详情:
// - 买单 2005 (2) 与 卖单 2010 (15) 成交
// - 成交价格: 2010
// - 成交数量: 2
// - 买单 2005 完全成交，从订单簿移除
// - 卖单 2010 部分成交，剩余 13
//
// 最终订单簿状态:
// Ask: 2010 (13)
// Bid: (空)
// ✓ 撮合完成: 没有买单 < 最低卖价(2010)
```

### 场景2: 市价单撮合

```solidity
bytes32 pair = keccak256("ETH/USDC");

// === 初始订单簿 ===
// 限价卖单: 2000 (5), 2010 (10)
// 限价买单: 1980 (8)

// === David提交市价买单 ===
uint256 marketBuy = sequencer.placeMarketOrder(pair, false, 12);
orderBook.insertMarketOrder(marketBuy, 0);

// 市价单列表:
// MarketBid: 订单ID=marketBuy (12)

// === 执行市价单撮合 ===
uint256 trades = orderBook.matchMarketOrders(pair, 100);

// 撮合结果:
// trades = 2
//
// 第1笔交易:
// - 市价买单 (12) 与 限价卖单 2000 (5) 成交
// - 成交价格: 2000 (对手价)
// - 成交数量: 5
// - 卖单完全成交，移除
// - 市价买单剩余 7
//
// 第2笔交易:
// - 市价买单 (7) 与 限价卖单 2010 (10) 成交
// - 成交价格: 2010
// - 成交数量: 7
// - 市价买单完全成交，移除
// - 卖单剩余 3
//
// 最终订单簿状态:
// Ask: 2010 (3)
// Bid: 1980 (8)
// MarketBid: (空)
```

### 场景3: 完整撮合 (matchAll)

```solidity
bytes32 pair = keccak256("ETH/USDC");

// === 复杂的初始状态 ===
// 限价Ask: 1995 (5), 2000 (10), 2010 (8)
// 限价Bid: 2005 (12), 1990 (15), 1980 (20)
// 市价Ask: 订单A (3)
// 市价Bid: 订单B (7)

// === 执行完整撮合 ===
(uint256 limitTrades, uint256 marketTrades) = orderBook.matchAll(pair, 100);

// 撮合阶段1: 限价单撮合
// -----------------------
// 第1笔: Bid 2005 (12) × Ask 1995 (5) = 成交5@1995
//   结果: Bid 2005 剩余7, Ask 1995 移除
//
// 第2笔: Bid 2005 (7) × Ask 2000 (10) = 成交7@2000
//   结果: Bid 2005 移除, Ask 2000 剩余3
//
// 第3笔: Bid 1990 < Ask 2000, 停止限价单撮合
//   limitTrades = 2

// 撮合阶段2: 市价单撮合
// -----------------------
// 第1笔: 市价Bid订单B (7) × Ask 2000 (3) = 成交3@2000
//   结果: Ask 2000 移除, 市价Bid订单B 剩余4
//
// 第2笔: 市价Bid订单B (4) × Ask 2010 (8) = 成交4@2010
//   结果: 市价Bid订单B 移除, Ask 2010 剩余4
//
// 第3笔: Bid 1990 × 市价Ask订单A (3) = 成交3@1990
//   结果: 市价Ask订单A 移除, Bid 1990 剩余12
//
//   marketTrades = 3

// 最终订单簿状态:
// Ask: 2010 (4)
// Bid: 1990 (12), 1980 (20)
// MarketAsk: (空)
// MarketBid: (空)
//
// ✓ 最高买价(1990) < 最低卖价(2010)
```

## 撮合事件监听

```solidity
// 监听Trade事件
event Trade(
    bytes32 indexed tradingPair,
    uint256 indexed buyOrderId,
    uint256 indexed sellOrderId,
    address buyer,
    address seller,
    uint256 price,
    uint256 amount
);

// 示例: 监听ETH/USDC的所有成交
contract TradeListener {
    OrderBook public orderBook;

    function listenToTrades() external {
        // 订阅Trade事件
        // 每次撮合都会emit Trade事件
    }
}
```

## 部分成交示例

```solidity
// === 初始状态 ===
// Ask: 2000 (10)
// Bid: 2005 (3)

// === 执行撮合 ===
orderBook.matchOrders(pair, 100);

// 成交: 3 @ 2000
// 事件:
// - Trade(pair, bidOrderId, askOrderId, buyer, seller, 2000, 3)
// - OrderFilled(pair, bidOrderId, 3, true)   // 买单完全成交
// - OrderFilled(pair, askOrderId, 3, false)  // 卖单部分成交

// 撮合后:
// Ask: 2000 (7)  ← 部分成交，剩余7
// Bid: (空)

// 订单信息:
// orders[askOrderId].amount = 10
// orders[askOrderId].filledAmount = 3
// orders[askOrderId] 仍在订单簿中
```

## Gas优化建议

```solidity
// 方法1: 小批量撮合（推荐用于高频场景）
// 每次撮合少量订单，降低单笔交易gas消耗
orderBook.matchOrders(pair, 10);  // 最多撮合10笔

// 方法2: 大批量撮合（推荐用于低频场景）
// 一次性撮合大量订单，减少交易次数
orderBook.matchOrders(pair, 1000);

// 方法3: 分离撮合
// 先撮合限价单，再单独撮合市价单
orderBook.matchOrders(pair, 50);
orderBook.matchMarketOrders(pair, 50);

// 方法4: 一次性完整撮合
orderBook.matchAll(pair, 100);
```

## 撮合时机

### 方案A: 插入时自动撮合
```solidity
function insertOrderAndMatch(
    uint256 sequencerOrderId,
    uint256 insertAfterPriceLevel,
    uint256 insertAfterOrder
) external {
    // 插入订单
    orderBook.insertOrder(sequencerOrderId, insertAfterPriceLevel, insertAfterOrder);

    // 立即撮合
    orderBook.matchOrders(pair, 10);
}
```

### 方案B: 定期批量撮合
```solidity
// 每N个区块执行一次撮合
uint256 constant MATCH_INTERVAL = 5;

function periodicMatch() external {
    require(block.number % MATCH_INTERVAL == 0, "Not match time");
    orderBook.matchAll(pair, 100);
}
```

### 方案C: 手动触发撮合
```solidity
// 任何人都可以调用撮合函数
// 可以设置激励机制鼓励用户调用
function manualMatch() external {
    uint256 trades = orderBook.matchOrders(pair, 100);

    // 给调用者奖励
    if (trades > 0) {
        // 发放撮合奖励
    }
}
```

## 撮合不变量验证

```solidity
// 撮合前后应该满足的不变量

function verifyMatchingInvariants(bytes32 pair) public view {
    OrderBookData memory book = orderBook.orderBooks(pair);

    // 不变量1: 如果bid和ask都存在，则 最高买价 < 最低卖价
    if (book.bidHead != 0 && book.askHead != 0) {
        uint256 bestBid = orderBook.getBestPrice(pair, false);
        uint256 bestAsk = orderBook.getBestPrice(pair, true);
        assert(bestBid < bestAsk);
    }

    // 不变量2: Bid列表价格递减
    // 不变量3: Ask列表价格递增
    // 不变量4: 所有订单的 filledAmount <= amount
    // 不变量5: 价格层级的totalVolume = 该层级所有订单的剩余数量之和
}
```

## 错误处理

```solidity
// 错误场景1: 订单簿为空
orderBook.matchOrders(emptyPair, 100);
// 返回: totalTrades = 0 (正常，不会revert)

// 错误场景2: 无法成交（买价 < 卖价）
// Bid: 1990
// Ask: 2000
orderBook.matchOrders(pair, 100);
// 返回: totalTrades = 0 (正常，价差太大)

// 错误场景3: Gas不足
orderBook.matchOrders(pair, 10000);  // 太多次迭代
// 可能: Out of gas (减少maxIterations)
```

## 高级用例

### 用例1: 价格发现
```solidity
// 通过撮合找到市场清算价格
function findClearingPrice(bytes32 pair) external returns (uint256) {
    orderBook.matchAll(pair, 1000);

    // 撮合后的最优买价和卖价之间就是当前的价格发现区间
    uint256 bestBid = orderBook.getBestPrice(pair, false);
    uint256 bestAsk = orderBook.getBestPrice(pair, true);

    // 中间价
    return (bestBid + bestAsk) / 2;
}
```

### 用例2: 流动性检查
```solidity
// 检查某个数量能否被完全撮合
function canFillAmount(bytes32 pair, bool isBuy, uint256 amount)
    external
    view
    returns (bool, uint256 avgPrice)
{
    // 模拟撮合，计算需要的深度
    // (需要实现view版本的撮合模拟)
}
```

### 用例3: 撮合奖励系统
```solidity
// 激励用户调用撮合函数
function matchWithReward(bytes32 pair) external {
    uint256 trades = orderBook.matchOrders(pair, 100);

    if (trades > 0) {
        // 每成交一笔，给调用者0.01%的奖励
        uint256 reward = calculateReward(trades);
        rewardToken.transfer(msg.sender, reward);
    }
}
```

## 总结

撮合引擎的核心保证:
1. ✅ **价格单调性**: 撮合后 `最高买价 < 最低卖价`
2. ✅ **公平性**: 价格-时间优先原则
3. ✅ **部分成交**: 支持订单部分执行
4. ✅ **自动清理**: 完全成交的订单自动移除
5. ✅ **Gas可控**: 通过maxIterations控制执行成本
