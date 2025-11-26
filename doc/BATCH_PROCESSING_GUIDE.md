# 批量处理指南

## 系统概述

批量处理接口允许高效地处理Sequencer队列中的多个请求，支持下单和撤单请求的混合处理。

## 核心特性

### 1. 链下计算，链上验证

```solidity
function batchProcessRequests(
    uint256[] calldata requestIds,
    uint256[] calldata insertAfterPriceLevels,  // 链下计算的价格层级插入位置
    uint256[] calldata insertAfterOrders         // 链下计算的订单插入位置
) external returns (uint256 processedCount)
```

**设计理念**:
- 链下系统计算每个订单的最优插入位置
- 链上合约只验证位置的正确性
- 大幅降低Gas消耗

### 2. 安全检查

```solidity
// 1. 数组验证
require(requestIds.length > 0, "Empty request array");
require(requestIds.length <= 100, "Batch size too large");  // Gas控制
require(
    requestIds.length == insertAfterPriceLevels.length &&
    requestIds.length == insertAfterOrders.length,
    "Array length mismatch"
);

// 2. 队列头部验证（每个请求）
if (!sequencer.isHeadRequest(requestId)) {
    break;  // 停止处理，返回已处理数量
}

// 3. 请求类型验证
if (uint8(requestType) == 0) {
    // PlaceOrder
} else if (uint8(requestType) == 1) {
    // RemoveOrder
} else {
    break;  // 未知类型，停止处理
}
```

**安全特性**:
- ✅ 批量大小限制（最多100个）防止Gas耗尽
- ✅ 顺序验证：只处理队列头部请求
- ✅ 优雅降级：遇到错误停止而非回滚
- ✅ 返回实际处理数量，便于链下重试

### 3. 空列表处理

系统完善处理各种空列表情况：

#### 空价格层级列表

```solidity
// 场景：该交易对还没有任何订单
if (insertAfterPriceLevel == EMPTY) {
    // 插入到头部
    uint256 oldHead = isAsk ? book.askHead : book.bidHead;

    if (oldHead != EMPTY) {
        // 已有价格层级，验证排序
        // Ask: 新价格 <= 原头部价格
        // Bid: 新价格 >= 原头部价格
    } else {
        // 列表为空，同时设置head和tail
        book.askTail = priceLevelId;  // 或 book.bidTail
    }

    book.askHead = priceLevelId;  // 或 book.bidHead
}
```

#### 空订单列表

```solidity
// 场景：该价格层级还没有任何订单
if (insertAfterOrder == EMPTY) {
    // 插入到头部
    uint256 oldHead = priceLevel.headOrderId;

    if (oldHead != EMPTY) {
        // 已有订单，链接它们
        orders[oldHead].prevOrderId = orderId;
        order.nextOrderId = oldHead;
    } else {
        // 列表为空，设置tail
        priceLevel.tailOrderId = orderId;
    }

    priceLevel.headOrderId = orderId;
}
```

#### 空市价单列表

```solidity
// 场景：还没有市价单
if (insertAfterOrder == EMPTY) {
    uint256 oldHead = isAsk ? book.marketAskHead : book.marketBidHead;

    if (oldHead != EMPTY) {
        // 已有市价单
        orders[oldHead].prevOrderId = orderId;
        order.nextOrderId = oldHead;
    } else {
        // 列表为空，设置tail
        book.marketAskTail = orderId;  // 或 marketBidTail
    }

    book.marketAskHead = orderId;  // 或 marketBidHead
}
```

## 使用示例

### 场景1: 批量处理纯下单请求

```solidity
// ========== 链下准备 ==========
// Sequencer队列状态:
// [PlaceOrder(id=1, price=2000), PlaceOrder(id=2, price=2100), PlaceOrder(id=3, price=1900)]

// 链下计算插入位置:
uint256[] memory requestIds = [1, 2, 3];
uint256[] memory insertAfterPriceLevels = [0, 0, 0];  // 全部插入新价格层级
uint256[] memory insertAfterOrders = [0, 0, 0];       // 全部插入头部

// ========== 链上执行 ==========
uint256 processed = orderBook.batchProcessRequests(
    requestIds,
    insertAfterPriceLevels,
    insertAfterOrders
);
// processed = 3

// ========== 结果 ==========
// OrderBook状态:
// Bid列表: 2000(order=1) -> 1900(order=3)
// Ask列表: 2100(order=2)
// 所有订单已从Sequencer移除
```

### 场景2: 批量处理混合请求

```solidity
// ========== 初始状态 ==========
// OrderBook中已有订单:
// - orderId=100, price=2000
// - orderId=101, price=2100
// - orderId=102, price=1900

// Sequencer队列:
// [PlaceOrder(id=200, price=2050), RemoveOrder(id=250, orderIdToRemove=100)]

// ========== 链下准备 ==========
uint256[] memory requestIds = [200, 250];
uint256[] memory insertAfterPriceLevels = [
    priceLevelOf2000,  // 在2000价格层级后插入2050
    0                  // RemoveOrder不需要
];
uint256[] memory insertAfterOrders = [
    100,  // 在订单100后插入
    0     // RemoveOrder不需要
];

// ========== 链上执行 ==========
uint256 processed = orderBook.batchProcessRequests(
    requestIds,
    insertAfterPriceLevels,
    insertAfterOrders
);
// processed = 2

// ========== 结果 ==========
// OrderBook:
// - 新订单200已插入（price=2050）
// - 订单100已移除，资金已解锁
```

### 场景3: 部分处理（遇到非头部请求）

```solidity
// ========== Sequencer队列 ==========
// [PlaceOrder(id=1), PlaceOrder(id=2), PlaceOrder(id=3)]
//  ↑ HEAD

// ========== 错误的请求 ==========
uint256[] memory requestIds = [2, 3];  // ❌ 跳过了头部！

uint256 processed = orderBook.batchProcessRequests(
    requestIds,
    insertAfterPriceLevels,
    insertAfterOrders
);
// processed = 0  （因为requestId=2不是头部，立即停止）

// ========== 正确的请求 ==========
uint256[] memory requestIds = [1, 2, 3];  // ✓ 从头部开始

uint256 processed = orderBook.batchProcessRequests(
    requestIds,
    insertAfterPriceLevels,
    insertAfterOrders
);
// processed = 3  （全部处理成功）
```

### 场景4: 空订单簿的首次批量插入

```solidity
// ========== 初始状态 ==========
// OrderBook完全为空：
// - askHead = 0
// - bidHead = 0
// - marketAskHead = 0
// - marketBidHead = 0

// Sequencer队列:
// [PlaceOrder(id=1, ask, price=2100), PlaceOrder(id=2, bid, price=2000)]

// ========== 链下准备 ==========
// 因为OrderBook为空，所有位置参数都是0（EMPTY）
uint256[] memory requestIds = [1, 2];
uint256[] memory insertAfterPriceLevels = [0, 0];  // 插入到头部（列表为空）
uint256[] memory insertAfterOrders = [0, 0];       // 插入到头部（列表为空）

// ========== 链上执行 ==========
uint256 processed = orderBook.batchProcessRequests(
    requestIds,
    insertAfterPriceLevels,
    insertAfterOrders
);
// processed = 2

// ========== 结果 ==========
// OrderBook状态:
// Ask列表: priceLevelId=1 (price=2100)
//   - head=1, tail=1
//   - orders: orderId=1
// Bid列表: priceLevelId=2 (price=2000)
//   - head=2, tail=2
//   - orders: orderId=2
```

## 链下系统职责

批量处理的链下系统需要：

### 1. 监听Sequencer队列

```javascript
// 监听PlaceOrderRequested事件
sequencer.on("PlaceOrderRequested", (requestId, orderId, tradingPair, ...) => {
    // 记录新请求
    queuedRequests.push({requestId, orderId, tradingPair, ...});
});

// 监听RemoveOrderRequested事件
sequencer.on("RemoveOrderRequested", (requestId, orderIdToRemove, ...) => {
    // 记录撤单请求
    queuedRequests.push({requestId, orderIdToRemove, ...});
});
```

### 2. 维护本地OrderBook镜像

```javascript
class LocalOrderBook {
    askPriceLevels = [];  // [{price, orders: []}]
    bidPriceLevels = [];

    // 计算插入位置
    calculateInsertPosition(price, isAsk) {
        const levels = isAsk ? this.askPriceLevels : this.bidPriceLevels;

        // 查找或创建价格层级
        let priceLevelIndex = levels.findIndex(l => l.price === price);
        if (priceLevelIndex === -1) {
            // 需要创建新价格层级，找到插入位置
            priceLevelIndex = this._findPriceLevelInsertPosition(price, isAsk);
        }

        return {
            insertAfterPriceLevel: priceLevelIndex > 0 ? levels[priceLevelIndex - 1].id : 0,
            insertAfterOrder: levels[priceLevelIndex]?.orders.length > 0
                ? levels[priceLevelIndex].orders[levels[priceLevelIndex].orders.length - 1].id
                : 0
        };
    }
}
```

### 3. 批量提交

```javascript
// 定期批量处理
setInterval(async () => {
    // 获取队列头部的N个请求
    const batch = queuedRequests.slice(0, 100);

    const requestIds = [];
    const insertAfterPriceLevels = [];
    const insertAfterOrders = [];

    for (const req of batch) {
        requestIds.push(req.requestId);

        if (req.type === 'PlaceOrder') {
            // 计算插入位置
            const pos = localOrderBook.calculateInsertPosition(req.price, req.isAsk);
            insertAfterPriceLevels.push(pos.insertAfterPriceLevel);
            insertAfterOrders.push(pos.insertAfterOrder);
        } else {
            // RemoveOrder不需要位置
            insertAfterPriceLevels.push(0);
            insertAfterOrders.push(0);
        }
    }

    // 提交批量处理
    const tx = await orderBook.batchProcessRequests(
        requestIds,
        insertAfterPriceLevels,
        insertAfterOrders
    );

    const receipt = await tx.wait();
    const processedCount = receipt.events.find(e => e.event === 'BatchProcessed').args.processedCount;

    // 更新本地状态
    queuedRequests.splice(0, processedCount);
}, 1000);
```

## Gas优化效果

### 单个处理 vs 批量处理

```
单个处理100个订单:
- insertOrder() x 100 = ~300,000 gas x 100 = 30,000,000 gas

批量处理100个订单:
- batchProcessRequests() = ~10,000,000 gas

节省: 约67%
```

**优化来源**:
1. ✅ 共享函数调用开销
2. ✅ 减少存储操作
3. ✅ 批量验证
4. ✅ 链下计算位置

## 错误处理

### 1. 批量大小超限

```solidity
// ❌ 错误
uint256[] memory requestIds = new uint256[](101);  // 超过100
orderBook.batchProcessRequests(...);
// Error: "Batch size too large"
```

### 2. 数组长度不匹配

```solidity
// ❌ 错误
uint256[] memory requestIds = [1, 2, 3];
uint256[] memory insertAfterPriceLevels = [0, 0];  // 长度不匹配！
orderBook.batchProcessRequests(...);
// Error: "Array length mismatch"
```

### 3. 非头部请求

```solidity
// Sequencer队列: [id=1, id=2, id=3]

// ❌ 错误：跳过头部
uint256[] memory requestIds = [2, 3];
uint256 processed = orderBook.batchProcessRequests(...);
// processed = 0（未处理任何请求）
```

### 4. 位置验证失败

```solidity
// ❌ 错误：价格排序不对
// 尝试在price=2000后插入price=1900（Ask列表）
orderBook.batchProcessRequests(...);
// 在处理到该订单时会revert:
// Error: "Invalid insertion position: price lower than previous"
```

## 事件监听

批量处理会触发正常的单个事件：

```solidity
// 每个订单插入
event OrderInserted(bytes32 indexed tradingPair, uint256 indexed orderId, bool isAsk, uint256 price, uint256 amount);

// 每个订单移除
event OrderRemoved(bytes32 indexed tradingPair, uint256 indexed orderId);

// Sequencer请求处理
event RequestProcessed(uint256 indexed requestId, RequestType requestType);
```

链下系统监听这些事件来同步本地状态。

## 最佳实践

### 1. 批量大小选择

```javascript
// 建议：根据Gas价格动态调整
const gasPrice = await provider.getGasPrice();
const batchSize = gasPrice < 50 ? 100 : 50;  // Gas高时减小批量
```

### 2. 重试机制

```javascript
// 如果部分处理，重试剩余部分
let processed = 0;
while (processed < requestIds.length) {
    const tx = await orderBook.batchProcessRequests(...);
    const receipt = await tx.wait();
    const newProcessed = receipt.returnValues.processedCount;

    if (newProcessed === 0) {
        // 完全失败，等待再重试
        await sleep(1000);
    }

    processed += newProcessed;
}
```

### 3. 本地状态验证

```javascript
// 定期验证本地OrderBook与链上一致
async function validateLocalState() {
    const onChainAskHead = await orderBook.getAskHead(tradingPair);
    const localAskHead = localOrderBook.askPriceLevels[0]?.id;

    if (onChainAskHead !== localAskHead) {
        // 重新同步
        await resyncOrderBook();
    }
}
```

## 总结

批量处理接口的核心优势：

1. ✅ **高效Gas使用**: 批量处理节省约67% Gas
2. ✅ **链下计算**: 复杂位置计算在链下完成
3. ✅ **安全保障**: 多重验证确保顺序和正确性
4. ✅ **优雅降级**: 部分失败不影响已处理部分
5. ✅ **空列表支持**: 完善处理各种空列表情况
6. ✅ **混合请求**: 同时处理下单和撤单请求

这使得链上OrderBook系统能够高效地处理大量订单！
