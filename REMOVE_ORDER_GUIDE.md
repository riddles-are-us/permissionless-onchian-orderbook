# 撤单流程指南

## 系统概述

撤单请求现在也必须通过Sequencer排队，确保撤单的公平性和顺序性。只有队列头部的撤单请求才能被执行。

## 核心流程

```
用户请求撤单 → Sequencer排队 → 验证头部请求 → OrderBook执行撤单 → 解锁资金 → 从Sequencer弹出
```

## 详细步骤

### 1. 用户提交撤单请求

```solidity
// Alice想撤销她的订单（orderId = 100）
uint256 requestId = sequencer.requestRemoveOrder(100);

// 此时撤单请求进入Sequencer队列
// 资金仍然锁定，等待处理
```

**验证**:
- 订单必须已经在OrderBook中（`ordersInBook[orderId] == true`）
- 自动记录请求者地址

### 2. 等待请求排到队列头部

```solidity
// 检查请求是否在队列头部
bool isHead = sequencer.isHeadRequest(requestId);

if (isHead) {
    // 可以执行撤单
}
```

### 3. 执行撤单

```solidity
// 任何人都可以调用（通常是链下服务）
orderBook.processRemoveOrder(requestId);
```

**执行流程**:
1. ✅ 验证requestId是队列头部
2. ✅ 从Sequencer获取请求信息
3. ✅ 验证是撤单请求类型
4. ✅ 验证订单存在且属于请求者
5. ✅ 解锁未成交的资金
6. ✅ 从OrderBook移除订单
7. ✅ 从Sequencer移除请求
8. ✅ emit OrderRemoved事件

## 完整示例

### 场景1: 撤销限价单

```solidity
// ========== 初始状态 ==========
// Alice有一个限价买单：
// - orderId: 100
// - 价格: 2000 USDC
// - 数量: 1 ETH
// - 已成交: 0.3 ETH
// - 锁定资金: 1400 USDC (剩余0.7 ETH * 2000)

// ========== Step 1: 提交撤单请求 ==========
uint256 requestId = sequencer.requestRemoveOrder(100);
// requestId = 250

// Event: RemoveOrderRequested(250, 100, pair, alice, timestamp)

// ========== Step 2: 等待排队 ==========
// Sequencer队列状态:
// [... 其他请求 ..., requestId=250]

// 当requestId=250排到头部时...
bool isHead = sequencer.isHeadRequest(250);  // true

// ========== Step 3: 执行撤单 ==========
orderBook.processRemoveOrder(250);

// 内部执行:
// 1. 验证请求在队列头部 ✓
// 2. 获取请求信息: orderIdToRemove = 100
// 3. 验证订单100属于Alice ✓
// 4. 解锁资金: 1400 USDC
// 5. 从价格层级移除订单100
// 6. 删除订单数据
// 7. 处理Sequencer请求

// ========== 结果 ==========
// Alice账户:
//   - 可用余额: +1400 USDC
//   - 锁定余额: -1400 USDC
// 订单100已从OrderBook移除
// Event: OrderRemoved(pair, 100)
```

### 场景2: 撤销市价卖单

```solidity
// ========== 初始状态 ==========
// Bob有一个市价卖单：
// - orderId: 200
// - 数量: 5 ETH
// - 已成交: 2 ETH
// - 锁定资金: 3 ETH

// ========== Step 1: 提交撤单请求 ==========
uint256 requestId = sequencer.requestRemoveOrder(200);

// ========== Step 2: 执行撤单 ==========
// （等requestId排到头部后）
orderBook.processRemoveOrder(requestId);

// ========== 结果 ==========
// Bob账户:
//   - 可用余额: +3 ETH
//   - 锁定余额: -3 ETH
```

### 场景3: 部分成交后撤单

```solidity
// ========== 初始状态 ==========
// Charlie有一个限价卖单：
// - orderId: 300
// - 价格: 2100 USDC
// - 数量: 10 ETH
// - 已成交: 7 ETH
// - 锁定资金: 3 ETH (剩余)

// ========== 撤销剩余部分 ==========
uint256 requestId = sequencer.requestRemoveOrder(300);
orderBook.processRemoveOrder(requestId);

// ========== 结果 ==========
// 只解锁剩余的3 ETH
// 已成交的7 ETH不受影响（资金已转移给买方）
```

## 多请求排队示例

```solidity
// ========== Sequencer队列状态 ==========
// 假设当前队列:
// [PlaceOrder(id=1), RemoveOrder(id=2), PlaceOrder(id=3), RemoveOrder(id=4)]
//  ↑ HEAD

// ========== 处理顺序 ==========

// 1. 处理第一个请求（下单）
orderBook.insertOrder(1, ...);
// 队列: [RemoveOrder(id=2), PlaceOrder(id=3), RemoveOrder(id=4)]

// 2. 处理第二个请求（撤单）
orderBook.processRemoveOrder(2);
// 队列: [PlaceOrder(id=3), RemoveOrder(id=4)]

// 3. 处理第三个请求（下单）
orderBook.insertOrder(3, ...);
// 队列: [RemoveOrder(id=4)]

// 4. 处理第四个请求（撤单）
orderBook.processRemoveOrder(4);
// 队列: []
```

## 关键验证点

### 1. 队列头部验证

```solidity
// processRemoveOrder会验证
require(sequencer.isHeadRequest(requestId), "Request is not at head of sequencer queue");
```

**不能跳过队列**:
```solidity
// ❌ 错误：尝试处理非头部请求
orderBook.processRemoveOrder(250);  // requestId=250不在头部
// Error: "Request is not at head of sequencer queue"
```

### 2. 请求类型验证

```solidity
// processRemoveOrder会验证
require(uint8(requestType) == 1, "Not a remove order request");
```

### 3. 订单所有权验证

```solidity
// processRemoveOrder会验证
require(order.trader == trader, "Not order owner");
```

**不能撤销别人的订单**:
```solidity
// Alice提交请求撤销Bob的订单
sequencer.requestRemoveOrder(bobOrderId);
// ✓ 请求会被接受并排队

// 但执行时会失败
orderBook.processRemoveOrder(requestId);
// ✗ Error: "Not order owner"
```

## 对比：下单 vs 撤单

| 操作 | Sequencer请求 | 锁定资金 | OrderBook处理 | 解锁资金 |
|------|--------------|---------|--------------|----------|
| **下单** | placeLimitOrder() | ✓ 立即锁定 | insertOrder() | ✗ 不解锁 |
| **撤单** | requestRemoveOrder() | ✗ 保持锁定 | processRemoveOrder() | ✓ 执行时解锁 |

## 事件监听

### RemoveOrderRequested事件
```solidity
event RemoveOrderRequested(
    uint256 indexed requestId,
    uint256 indexed orderIdToRemove,
    bytes32 indexed tradingPair,
    address trader,
    uint256 timestamp
);
```

监听用户何时提交撤单请求。

### OrderRemoved事件
```solidity
event OrderRemoved(
    bytes32 indexed tradingPair,
    uint256 indexed orderId
);
```

监听订单何时真正被移除（资金已解锁）。

### RequestProcessed事件
```solidity
event RequestProcessed(
    uint256 indexed requestId,
    RequestType requestType  // RemoveOrder
);
```

监听请求何时从Sequencer队列移除。

## 查询函数

### 检查请求是否在队列头部
```solidity
bool isHead = sequencer.isHeadRequest(requestId);
```

### 获取请求详情
```solidity
(
    ISequencer.RequestType requestType,
    bytes32 tradingPair,
    address trader,
    ,  // orderType
    ,  // isAsk
    ,  // price
    ,  // amount
    uint256 orderIdToRemove,
    uint256 timestamp
) = sequencer.getQueuedRequest(requestId);
```

### 检查订单是否在OrderBook中
```solidity
bool inBook = sequencer.ordersInBook(orderId);
```

## 错误处理

### 常见错误

1. **订单不在OrderBook中**
```solidity
sequencer.requestRemoveOrder(999);
// Error: "Order not in book"
```

2. **请求不在队列头部**
```solidity
orderBook.processRemoveOrder(nonHeadRequestId);
// Error: "Request is not at head of sequencer queue"
```

3. **订单不存在**
```solidity
// OrderBook中没有该订单
orderBook.processRemoveOrder(requestId);
// Error: "Order does not exist"
```

4. **不是订单所有者**
```solidity
// Alice尝试撤销Bob的订单
// 请求能提交，但执行时失败
orderBook.processRemoveOrder(requestId);
// Error: "Not order owner"
```

## 安全保证

1. **公平排队**: 所有撤单请求按时间顺序处理
2. **原子解锁**: 撤单和解锁资金在同一交易中完成
3. **所有权验证**: 只能撤销自己的订单
4. **头部验证**: 只能处理队列头部的请求
5. **资金安全**: 解锁资金回到可用余额，可以立即提取

## 总结

新的撤单流程确保：
- ✅ 所有撤单请求公平排队
- ✅ 按提交顺序执行（FIFO）
- ✅ 只有队列头部请求可以执行
- ✅ 解锁资金在OrderBook执行时完成
- ✅ Sequencer不处理资金，只管理队列
- ✅ 完整的事件追踪

这样设计保证了撤单的公平性，防止抢先交易（front-running）！
