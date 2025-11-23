# 链上订单簿系统 (On-Chain Order Book System)

## 系统概述

这是一个完全去中心化的链上订单簿系统，通过 **Sequencer** 机制确保订单插入的公平性和顺序性。

## 核心特性

- ✅ **公平排序**: 通过链上Sequencer保证订单的先来先服务(FIFO)
- ✅ **Gas优化**: 链下计算插入位置，链上只做验证
- ✅ **双层链表**: 价格层级链表 + 订单链表的高效设计
- ✅ **市价单支持**: 同时支持限价单和市价单
- ✅ **严格验证**: 确保价格排序和插入位置的正确性

## 架构设计

### 1. Sequencer.sol - 订单排序器

**职责**: 管理订单提交顺序，确保公平性

**核心流程**:
```
用户提交订单 → Sequencer排队 → 验证头部订单 → 插入OrderBook → 从Sequencer弹出
```

**主要API**:

#### `placeLimitOrder()` - 提交限价单
```solidity
function placeLimitOrder(
    bytes32 tradingPair,  // 交易对，如 keccak256("ETH/USDC")
    bool isAsk,           // true=卖单, false=买单
    uint256 price,        // 价格
    uint256 amount        // 数量
) external returns (uint256 orderId)
```

#### `placeMarketOrder()` - 提交市价单
```solidity
function placeMarketOrder(
    bytes32 tradingPair,
    bool isAsk,
    uint256 amount
) external returns (uint256 orderId)
```

#### `requestRemoveOrder()` - 请求移除订单
```solidity
function requestRemoveOrder(
    uint256 orderIdToRemove  // 要移除的订单ID
) external returns (uint256 requestId)
```

**功能**:
- 提交撤单请求到队列
- 验证订单存在于 OrderBook 中
- 遵循 FIFO 原则，确保撤单的公平性
- 返回请求 ID 用于追踪处理状态

**流程**:
1. 用户调用 `requestRemoveOrder(orderId)`
2. Sequencer 验证订单存在
3. 创建 RemoveOrder 类型的请求
4. 请求进入队列等待处理
5. Matcher 处理时会调用 OrderBook.removeOrder()

#### `popOrder()` - 弹出订单（仅OrderBook可调用）
```solidity
function popOrder(uint256 orderId) external onlyOrderBook
```

#### `isHeadOrder()` - 验证是否为队列头部
```solidity
function isHeadOrder(uint256 orderId) external view returns (bool)
```

### 2. OrderBook.sol - 订单簿

**职责**: 管理订单簿的双向链表结构

**数据结构**:

```
OrderBookData {
    限价Ask列表 (头→尾: 价格递增)
    限价Bid列表 (头→尾: 价格递减)
    市价Ask列表 (FIFO)
    市价Bid列表 (FIFO)
}

每个价格层级包含:
- 价格
- 该价格下的订单链表
- 总挂单量
```

**主要API**:

#### `insertOrder()` - 插入限价单
```solidity
function insertOrder(
    uint256 sequencerOrderId,      // Sequencer中的订单ID
    uint256 insertAfterPriceLevel, // 在哪个价格层级之后插入 (0=头部)
    uint256 insertAfterOrder       // 在哪个订单之后插入 (0=该价格层级头部)
) external
```

**验证逻辑**:
1. 验证订单是Sequencer队列头部
2. 从Sequencer获取订单信息
3. 验证价格排序（Ask递增/Bid递减）
4. 插入订单
5. 从Sequencer弹出

#### `insertMarketOrder()` - 插入市价单
```solidity
function insertMarketOrder(
    uint256 sequencerOrderId,  // Sequencer中的订单ID
    uint256 insertAfterOrder   // 在哪个订单之后插入 (0=头部)
) external
```

#### `removeOrder()` - 删除限价单
```solidity
function removeOrder(
    bytes32 tradingPair,
    uint256 orderId,
    bool isAsk
) external
```

#### `removeMarketOrder()` - 删除市价单
```solidity
function removeMarketOrder(
    bytes32 tradingPair,
    uint256 orderId,
    bool isAsk
) external
```

## 使用流程示例

### 完整流程：提交并插入限价单

```solidity
// 1. 部署合约
Sequencer sequencer = new Sequencer();
OrderBook orderBook = new OrderBook();

// 2. 相互设置授权
sequencer.setOrderBook(address(orderBook));
orderBook.setSequencer(address(sequencer));

// 3. 用户提交限价卖单到Sequencer
bytes32 pair = keccak256("ETH/USDC");
uint256 orderId = sequencer.placeLimitOrder(
    pair,
    true,   // isAsk
    2000,   // price
    10      // amount
);

// 4. 链下计算插入位置（例如：应该插入到价格层级0之后）
// 链下程序监控Sequencer队列头部

// 5. 任何人都可以将头部订单插入OrderBook
orderBook.insertOrder(
    orderId,  // 必须是队列头部
    0,        // insertAfterPriceLevel (0表示插入到头部)
    0         // insertAfterOrder (0表示该价格层级头部)
);

// 订单现在已经在OrderBook中，并已从Sequencer中移除
```

### 提交并插入市价单

```solidity
// 1. 提交市价买单到Sequencer
uint256 marketOrderId = sequencer.placeMarketOrder(
    pair,
    false,  // isBid
    5       // amount
);

// 2. 插入到OrderBook
orderBook.insertMarketOrder(
    marketOrderId,  // 必须是队列头部
    0               // insertAfterOrder (0表示插入到头部)
);
```

### 删除订单

```solidity
// 删除限价单
orderBook.removeOrder(pair, orderId, true);

// 删除市价单
orderBook.removeMarketOrder(pair, marketOrderId, false);
```

## 关键设计要点

### 1. 公平性保证

**问题**: 如何防止抢先交易(Front-running)？

**解决方案**:
- 所有订单必须先在Sequencer中排队
- OrderBook只接受队列头部的订单
- 按照区块时间戳的严格顺序处理

### 2. Gas优化

**问题**: 链上排序Gas成本高

**解决方案**:
- 链下计算最优插入位置
- 链上只验证位置是否正确
- 避免链上遍历查找

### 3. 插入位置验证

**Ask列表（卖单）** - 价格递增:
```
验证: 前一个价格 <= 新价格 <= 后一个价格
```

**Bid列表（买单）** - 价格递减:
```
验证: 前一个价格 >= 新价格 >= 后一个价格
```

### 4. 订单ID管理

- Sequencer生成全局唯一的订单ID
- OrderBook使用相同的订单ID
- 确保订单在两个合约间的一致性

## 查询功能

### 获取订单簿深度
```solidity
(uint256[] memory prices, uint256[] memory volumes) =
    orderBook.getOrderBookSnapshot(pair, true, 10);  // 获取10档卖单
```

### 获取最优价格
```solidity
uint256 bestAsk = orderBook.getBestPrice(pair, true);
uint256 bestBid = orderBook.getBestPrice(pair, false);
```

### 获取市价单列表
```solidity
(uint256[] memory orderIds, uint256[] memory amounts) =
    orderBook.getMarketOrderSnapshot(pair, true, 10);
```

### 查看Sequencer队列
```solidity
(uint256[] memory orderIds, address[] memory traders, uint256[] memory amounts) =
    sequencer.getQueueSnapshot(20);
```

### 获取队列头部
```solidity
uint256 headOrderId = sequencer.getHeadOrderId();
```

## 安全考虑

1. **权限控制**:
   - `popOrder()` 只能由OrderBook调用
   - `setOrderBook()` 和 `setSequencer()` 只能设置一次

2. **订单验证**:
   - 验证订单必须是队列头部
   - 验证订单类型（限价/市价）
   - 验证价格排序规则

3. **所有权验证**:
   - 删除订单时验证 `msg.sender` 是订单所有者

## 撮合引擎

### 核心撮合函数

#### `matchOrders()` - 撮合限价单
```solidity
function matchOrders(
    bytes32 tradingPair,
    uint256 maxIterations  // 最大撮合次数（防止gas耗尽）
) external returns (uint256 totalTrades)
```

**撮合逻辑**:
1. 获取最优买价（bidHead）和最优卖价（askHead）
2. 检查是否可以成交：`买价 >= 卖价`
3. 如果可以成交，执行交易
4. 重复直到 `买价 < 卖价` 或达到最大次数

**成交价格**: 使用卖单价格（价格优先原则）

**部分成交**:
- 支持订单部分成交
- 未完全成交的订单保留在订单簿中
- 完全成交的订单自动从订单簿移除

#### `matchMarketOrders()` - 撮合市价单
```solidity
function matchMarketOrders(
    bytes32 tradingPair,
    uint256 maxIterations
) external returns (uint256 totalTrades)
```

**撮合逻辑**:
- 市价买单：与最优卖价（askHead）撮合
- 市价卖单：与最优买价（bidHead）撮合

#### `matchAll()` - 完整撮合
```solidity
function matchAll(
    bytes32 tradingPair,
    uint256 maxIterations
) external returns (uint256 limitTrades, uint256 marketTrades)
```

先撮合限价单，再撮合市价单。

### 撮合示例

```solidity
bytes32 pair = keccak256("ETH/USDC");

// 假设订单簿状态:
// Bid: 2000 (10), 1990 (5)
// Ask: 1995 (8), 2005 (12)

// 执行撮合
uint256 trades = orderBook.matchOrders(pair, 100);

// 撮合结果:
// - 买单 2000 与 卖单 1995 成交 8个，成交价 1995
// - 买单 2000 剩余 2个，继续与 卖单 2005 成交 2个，成交价 2005
// - 买单 1990 < 卖单 2005，停止撮合
//
// 最终状态:
// Bid: 1990 (5)
// Ask: 2005 (10)
// 确保了: 最高买价(1990) < 最低卖价(2005) ✓
```

### 撮合事件

#### Trade事件
```solidity
event Trade(
    bytes32 indexed tradingPair,
    uint256 indexed buyOrderId,
    uint256 indexed sellOrderId,
    address buyer,
    address seller,
    uint256 price,      // 成交价格
    uint256 amount      // 成交数量
);
```

#### OrderFilled事件
```solidity
event OrderFilled(
    bytes32 indexed tradingPair,
    uint256 indexed orderId,
    uint256 filledAmount,    // 本次成交数量
    bool isFullyFilled       // 是否完全成交
);
```

### 撮合保证

1. **价格单调性**: 撮合后确保 `最高买价 < 最低卖价`
2. **价格-时间优先**:
   - 价格优先：最优价格优先撮合
   - 时间优先：同价格层级内按FIFO顺序
3. **部分成交**: 支持订单部分成交，未成交部分保留
4. **自动清理**: 完全成交的订单自动移除
5. **Gas控制**: 通过maxIterations参数控制单次执行的撮合次数

### 撮合流程图

```
┌─────────────────┐
│  matchOrders()  │
└────────┬────────┘
         │
         ▼
   ┌─────────────┐
   │ bidHead价格 │ >= ┌─────────────┐
   │   >= ?      │    │ askHead价格 │
   └─────┬───────┘    └─────────────┘
         │ Yes
         ▼
   ┌──────────────────┐
   │  执行交易         │
   │  - 计算成交量     │
   │  - 更新filledAmount│
   │  - 更新totalVolume│
   │  - emit Trade事件 │
   └─────┬────────────┘
         │
         ▼
   ┌──────────────────┐
   │  检查订单状态     │
   │  完全成交?       │
   └─────┬────────────┘
         │ Yes
         ▼
   ┌──────────────────┐
   │  移除订单         │
   │  - 从链表移除     │
   │  - 删除订单数据   │
   │  - 清理空价格层级 │
   └─────┬────────────┘
         │
         ▼
   继续下一轮撮合...
```

## Rust Matcher 引擎

### 概述

基于 Rust 的链下撮合引擎，自动从 Sequencer 队列读取订单，计算正确的插入位置，并批量提交到 OrderBook。

### 核心功能

- 🔄 **状态同步**: 从指定区块高度读取合约状态，通过 WebSocket 监听事件
- 🎯 **智能匹配**: 自动计算每个订单在订单簿中的正确插入位置
- 📦 **批量处理**: 批量调用 `batchProcessRequests` 节省 gas 成本
- ⚡ **高性能**: 使用 DashMap 实现线程安全的状态管理
- 📊 **实时监控**: 完整的日志系统，追踪匹配过程

### 快速测试

```bash
# 1. 启动 Anvil
anvil

# 2. 部署合约并准备测试数据
./test_matcher.sh

# 3. 运行 Matcher
cd matcher && cargo run -- --log-level debug

# 4. 验证结果
./verify_results.sh
```

详细文档：
- 📖 [Matcher 快速开始](QUICKSTART_MATCHER.md)
- 📖 [完整测试指南](TESTING_GUIDE.md)
- 📖 [Matcher 架构说明](matcher/ARCHITECTURE.md)

### 工作流程

```
1. 启动 → 读取配置 → 连接到区块链 (WebSocket)
           ↓
2. 状态同步 → 从指定区块读取历史状态
           ├─ 加载 Sequencer 队列
           ├─ 加载订单簿价格层级
           └─ 构建本地缓存
           ↓
3. 匹配循环 (每 3 秒)
           ├─ 获取队列头部的 N 个请求
           ├─ 计算每个订单的插入位置
           │   ├─ 查找价格层级缓存
           │   ├─ 如未命中，从链上读取
           │   └─ 根据 Bid/Ask 确定正确位置
           ├─ 构建批处理交易
           └─ 提交并等待确认
           ↓
4. 事件监听 → 实时更新本地状态
```

## 未来扩展

- [x] 订单撮合引擎
- [x] 部分成交支持
- [x] Rust Matcher 引擎
- [x] 批量订单处理
- [ ] 订单过期时间
- [ ] 手续费机制
- [ ] MEV保护机制
- [ ] 价格预言机集成

## 项目结构

```
orderbook/
├── Sequencer.sol              # 订单排序器
├── OrderBook.sol              # 订单簿核心
├── Account.sol                # 账户和资金管理
├── script/                    # Foundry 部署脚本
│   ├── Deploy.s.sol          # 合约部署
│   └── PrepareTest.s.sol     # 测试数据准备
├── test/                      # Foundry 测试
│   └── OrderBook.t.sol       # 单元测试
├── matcher/                   # Rust Matcher 引擎
│   ├── src/
│   │   ├── main.rs           # 主入口
│   │   ├── sync.rs           # 状态同步
│   │   ├── matcher.rs        # 匹配引擎
│   │   └── ...
│   └── abi/                  # 合约 ABI
├── test_matcher.sh           # 一键测试脚本
└── *.md                      # 文档
```

## 许可证

MIT License
