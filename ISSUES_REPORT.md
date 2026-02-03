# OrderBook 系统问题报告

**生成日期**: 2026-02-03
**分析范围**: OrderBook.sol, Sequencer.sol, Matcher

---

## 问题总览

| 严重程度 | 问题数量 |
|---------|---------|
| 🔴 严重 | 2 |
| 🟠 中等 | 4 |
| 🟡 轻微 | 2 |

---

## 🔴 严重问题

### 问题 #1: 多 Trading Pair 共享 priceLevels

**状态**: ⏳ 已临时修复 (Matcher)，需要合约修复
**位置**: `OrderBook.sol` 第 51 行

**问题描述**:
```solidity
mapping(uint256 => PriceLevel) public priceLevels;  // (price | side_flag) => PriceLevel
```

`priceLevels` mapping 的 key 只包含价格和方向标志，不包含 trading pair ID。导致不同交易对在同一价格的订单会共享同一个 `PriceLevel` 结构。

**影响**:
- 不同交易对的订单混在一起
- 价格层级的 `totalVolume` 计算错误
- Matcher 计算 `insertAfterOrder` 时使用错误的 `tail_order_id`
- 可能导致系统崩溃

**复现场景**:
1. WBTC/USDC 在价格 200 USDC (bid) 有订单，`tailOrderId = 457`
2. WETH/USDC 想在同样的价格 200 USDC (bid) 放订单
3. 链上要求 `insertAfterOrder = 457`，但 Matcher 认为 WETH/USDC 的 orderbook 是空的，使用 `insertAfterOrder = 0`
4. 交易失败

**修复方案**:

**方案 A: 修改合约 (推荐)**
```solidity
// 修改前
mapping(uint256 => PriceLevel) public priceLevels;

// 修改后
mapping(bytes32 => PriceLevel) public priceLevels;
// key = keccak256(tradingPair, price, isAsk)
```

**方案 B: 修改 Matcher (已实施)**
- 添加全局 price level 缓存
- 在计算 `insertAfterOrder` 时使用全局的 `tail_order_id`
- 缺点：如果 Matcher 只处理部分 trading pair，可能仍有问题

---

### 问题 #2: 订单完全成交后未解锁剩余资金

**状态**: ❌ 未修复
**位置**: `OrderBook.sol` 第 1264-1288 行

**问题描述**:
```solidity
function _removeFilledOrder(bytes32 tradingPair, uint256 orderId, bool isAsk) internal {
    // ... 从价格层级移除订单
    delete orderTradingPairs[orderId];
    delete orders[orderId];  // ❌ 直接删除，没有解锁剩余资金！
}
```

当订单完全成交时，直接删除订单数据，但没有解锁剩余的锁定资金。

**影响**:
- 用户资金被**永久锁定**在合约中
- 无法取回

**复现场景**:
1. 用户下限价买单：价格 100 USDC，数量 10
2. 预锁定：100 × 10 × 1.001 = 1001 USDC
3. 实际成交价：90 USDC
4. 实际花费：90 × 10 × 1.001 = 900.9 USDC
5. **剩余 100.1 USDC 被永久锁定**

**修复方案**:
```solidity
function _removeFilledOrder(bytes32 tradingPair, uint256 orderId, bool isAsk) internal {
    Order storage order = orders[orderId];

    // 解锁剩余资金
    if (!isAsk) {  // 买单
        uint256 remainingLocked = order.amount - order.filledAmount;
        if (remainingLocked > 0) {
            // 计算剩余锁定的 quote tokens
            uint256 remainingQuote = remainingLocked * order.priceLevel / PRICE_DECIMALS;
            account.unlockFunds(order.trader, quoteToken, remainingQuote);
        }
    } else {  // 卖单
        uint256 remainingLocked = order.amount - order.filledAmount;
        if (remainingLocked > 0) {
            account.unlockFunds(order.trader, baseToken, remainingLocked);
        }
    }

    // 原有的删除逻辑
    delete orderTradingPairs[orderId];
    delete orders[orderId];
}
```

---

## 🟠 中等问题

### 问题 #3: 多次 Cancel 同一个订单

**状态**: ❌ 未修复
**位置**: `Sequencer.sol` 第 237-270 行

**问题描述**:
`requestRemoveOrder()` 函数只检查 `ordersInBook[orderIdToRemove]` 是否为 true，但当第一个撤单请求在队列中等待处理时，`ordersInBook` 状态还未更新。用户可以提交多个针对同一订单的撤单请求。

**影响**:
- 第一个撤单请求成功后，后续请求会失败（"Order does not exist"）
- 导致整个 batch 处理失败
- 浪费 gas

**修复方案**:

**方案 A: Sequencer 添加 pending 检查**
```solidity
mapping(uint256 => bool) public pendingRemoveRequests;

function requestRemoveOrder(uint256 orderIdToRemove) external returns (uint256 requestId) {
    require(!pendingRemoveRequests[orderIdToRemove], "Remove request already pending");
    pendingRemoveRequests[orderIdToRemove] = true;
    // ... 创建请求
}
```

**方案 B: OrderBook 优雅处理**
```solidity
function _batchProcessRemoveOrder(uint256 requestId) internal {
    // ...
    if (order.id == 0) {
        return; // 订单不存在，静默返回而不是 revert
    }
    // ... 正常移除逻辑
}
```

**方案 C: 前端防重复**
- 点击取消后禁用按钮
- 显示 loading 状态

---

### 问题 #4: 对已成交订单发送 Cancel 请求

**状态**: ❌ 未修复
**位置**: `Sequencer.sol` 第 237-270 行

**问题描述**:
用户可能在订单成交前提交撤单请求到队列，当撤单请求被处理时，订单已经不存在。

**影响**:
- 导致 batch 处理中断
- 浪费 gas

**修复方案**:
与问题 #3 的方案 B 相同，在 OrderBook 中优雅处理订单不存在的情况。

---

### 问题 #5: Batch 处理部分失败导致全部回滚

**状态**: ❌ 未修复
**位置**: `OrderBook.sol` 第 299-376 行

**问题描述**:
```solidity
for (uint256 i = 0; i < requestIds.length; i++) {
    if (uint8(requestType) == 0) {
        _batchProcessPlaceOrder(requestId, insertAfterPrices[i], insertAfterOrders[i]);
    } else if (uint8(requestType) == 1) {
        _batchProcessRemoveOrder(requestId);  // 如果失败，整个 batch revert
    }
}
```

如果某个请求处理失败，整个 batch 会 revert，前面已处理的请求也会回滚。

**影响**:
- 一个失败的请求导致整个 batch 失败
- 浪费 gas 和时间

**修复方案**:
```solidity
for (uint256 i = 0; i < requestIds.length; i++) {
    try this._processRequest(requestId, ...) {
        processedCount++;
    } catch {
        // 记录失败，继续处理下一个
        emit RequestFailed(requestId);
    }
}
```

---

### 问题 #6: 撤单时 Sequencer 未检查订单所有权

**状态**: ❌ 未修复
**位置**: `Sequencer.sol` 第 237-270 行

**问题描述**:
Sequencer 没有验证 `msg.sender` 是否是订单的所有者，只在 OrderBook 处理时验证。

**影响**:
- 任何人都可以提交撤单请求到队列
- 恶意用户可以提交大量无效的撤单请求，堵塞队列

**修复方案**:
```solidity
function requestRemoveOrder(uint256 orderIdToRemove) external returns (uint256 requestId) {
    // 验证订单所有权
    require(
        IOrderBook(orderBook).getOrderTrader(orderIdToRemove) == msg.sender,
        "Not order owner"
    );
    // ...
}
```

---

## 🟡 轻微问题

### 问题 #7: 灰尘阈值导致少量资金损失

**状态**: ❌ 未修复
**位置**: `OrderBook.sol` 第 1237-1256 行

**问题描述**:
```solidity
uint256 public constant DUST_THRESHOLD = 1000000;  // 0.01 USDC

// 当剩余价值 <= 0.01 USDC 时，订单被删除
if (remainingValue <= DUST_THRESHOLD) {
    _removeFilledOrder(tradingPair, orderId, isAsk);
    // ❌ 没有退还剩余资金！
}
```

**影响**:
- 每笔交易可能损失最多 0.01 USDC
- 累积损失可能很大

**修复方案**:
在删除订单前，先退还剩余资金（与问题 #2 的修复方案合并）。

---

### 问题 #8: FIFO 强制可能导致插入失败

**状态**: ❌ 未修复
**位置**: `OrderBook.sol` 第 688-717 行

**问题描述**:
```solidity
require(insertAfterOrder == oldTail, "FIFO: insertAfterOrder must equal tailOrderId");
```

如果在 Matcher 计算插入位置和实际插入之间，有新订单插入，`tailOrderId` 会改变，导致插入失败。

**影响**:
- 在高并发场景下，插入可能频繁失败
- 影响用户体验

**修复方案**:
允许 Matcher 在失败后重新计算插入位置并重试。

---

## 修复优先级建议

### 第一优先级（必须修复）
1. **问题 #2**: 订单完全成交后未解锁剩余资金 - 资金安全问题
2. **问题 #1**: 多 Trading Pair 共享 priceLevels - 系统稳定性问题

### 第二优先级（建议修复）
3. **问题 #3**: 多次 Cancel 同一个订单
4. **问题 #5**: Batch 处理部分失败导致全部回滚
5. **问题 #6**: 撤单时 Sequencer 未检查订单所有权

### 第三优先级（可选修复）
6. **问题 #4**: 对已成交订单发送 Cancel 请求（与 #3 一起修复）
7. **问题 #7**: 灰尘阈值导致少量资金损失（与 #2 一起修复）
8. **问题 #8**: FIFO 强制可能导致插入失败

---

## 修复影响分析

### 如果修复问题 #1（合约方案）
- 需要修改 `OrderBook.sol` 中所有访问 `priceLevels` 的函数
- 需要更新 Matcher 的 ABI 和 key 计算逻辑
- **需要回退之前对 Matcher 的全局缓存修改**
- 需要重新部署合约

### 如果修复问题 #2
- 只需要修改 `OrderBook.sol` 中的 `_removeFilledOrder` 函数
- 可以同时修复问题 #7
- 需要重新部署合约

### 如果修复问题 #3-6
- 需要修改 `Sequencer.sol` 和/或 `OrderBook.sol`
- 需要重新部署合约

---

## 附录：当前临时修复状态

### Matcher 全局 Price Level 缓存
- **状态**: 已部署
- **修改文件**:
  - `matcher/src/state.rs`
  - `matcher/src/sync.rs`
  - `matcher/src/orderbook_simulator.rs`
  - `matcher/src/matcher.rs`
- **注意**: 如果修复合约问题 #1，需要回退这些修改
