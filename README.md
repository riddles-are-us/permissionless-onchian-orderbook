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
    uint256 sequencerOrderId  // Sequencer中的订单ID
) external
```

**说明**：
- 市价单总是插入到队尾，保证 FIFO（先进先出）
- 不需要提供插入位置，简化 API 并节省 gas

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

#### `batchProcessRequests()` - 批量处理请求
```solidity
function batchProcessRequests(
    uint256[] calldata requestIds,           // 请求ID数组（必须按Sequencer队列顺序）
    uint256[] calldata insertAfterPriceLevels, // 每个订单的插入位置（价格层级）
    uint256[] calldata insertAfterOrders       // 每个订单的插入位置（订单ID）
) external
```

**说明**：
- 批量处理多个 Sequencer 请求，支持 PlaceOrder 和 RemoveOrder
- `requestIds` 必须从队列头部开始，按顺序排列
- 链下 Matcher 计算 `insertAfterPriceLevels`，链上只验证位置正确性
- 大幅节省 gas（避免多次交易的基础 gas 开销）
- 自动触发撮合：插入订单后会尝试与对手方撮合

**处理流程**：
1. 验证 `requestIds[0]` 是队列头部
2. 依次处理每个请求（PlaceOrder 或 RemoveOrder）
3. PlaceOrder: 验证插入位置，插入订单，尝试撮合
4. RemoveOrder: 从订单簿移除订单，解锁资金
5. 从 Sequencer 队列弹出已处理的请求

## 使用流程示例

### 完整流程：提交并插入限价单

```solidity
// 1. 部署合约
Sequencer sequencer = new Sequencer();
OrderBook orderBook = new OrderBook();
Account account = new Account();

// 2. 配置合约关系
sequencer.setOrderBook(address(orderBook));
sequencer.setAccount(address(account));
orderBook.setSequencer(address(sequencer));
orderBook.setAccount(address(account));
account.setSequencer(address(sequencer));
account.setOrderBook(address(orderBook));

// 3. 注册交易对
bytes32 pair = keccak256("WETH/USDC");
account.registerTradingPair(pair, wethAddress, usdcAddress);

// 4. 用户充值
account.deposit(wethAddress, 10 ether);
account.deposit(usdcAddress, 10000 * 10**6);

// 5. 用户提交限价单到 Sequencer（带精度）
(uint256 requestId1, uint256 orderId1) = sequencer.placeLimitOrder(
    pair,
    false,              // bid (买单)
    2000 * 10**8,      // price with PRICE_DECIMALS
    1 * 10**8          // amount with AMOUNT_DECIMALS
);

(uint256 requestId2, uint256 orderId2) = sequencer.placeLimitOrder(
    pair,
    false,
    1950 * 10**8,
    1 * 10**8
);

(uint256 requestId3, uint256 orderId3) = sequencer.placeLimitOrder(
    pair,
    false,
    1900 * 10**8,
    1 * 10**8
);

// 6. 链下 Matcher 计算插入位置
// Matcher 监控 Sequencer 队列，计算每个订单的正确插入位置
// 对于 bid（买单），价格从高到低排序：2000 > 1950 > 1900

// 7. Matcher 批量处理请求
uint256[] memory orderIds = new uint256[](3);
orderIds[0] = orderId1;
orderIds[1] = orderId2;
orderIds[2] = orderId3;

uint256[] memory insertAfterPriceLevels = new uint256[](3);
insertAfterPriceLevels[0] = 0;  // 2000 插入到 bid 头部（创建新价格层级）
insertAfterPriceLevels[1] = 1;  // 1950 插入到价格层级 1 之后
insertAfterPriceLevels[2] = 2;  // 1900 插入到价格层级 2 之后

uint256[] memory insertAfterOrders = new uint256[](3);
insertAfterOrders[0] = 0;  // 在新价格层级的头部
insertAfterOrders[1] = 0;  // 在新价格层级的头部
insertAfterOrders[2] = 0;  // 在新价格层级的头部

orderBook.batchProcessRequests(
    orderIds,
    insertAfterPriceLevels,
    insertAfterOrders
);

// 订单现在已经在 OrderBook 中，资金已锁定，并已从 Sequencer 队列中移除
```

**关键点**:
- `insertAfterPriceLevel = 0` 表示在该价格的订单之前插入（如果是第一个订单，则创建新的价格层级在头部）
- `insertAfterPriceLevel = N` 表示在价格层级 N 之后插入（如果价格相同则插入到同一层级，否则创建新层级）
- `insertAfterOrder = 0` 表示插入到该价格层级的头部
- `insertAfterOrder = M` 表示在订单 M 之后插入（同一价格层级内按时间排序）

### 删除订单

```solidity
// 用户请求删除订单（通过 Sequencer 确保 FIFO）
uint256 removeRequestId = sequencer.requestRemoveOrder(orderId);

// Matcher 会自动处理这个移除请求
// 当 removeRequestId 成为队列头部时，Matcher 调用：
// orderBook.removeOrder(orderId)
// 订单被移除，锁定资金解锁返还给用户
```

**注意**:
- 订单移除也必须通过 Sequencer 队列，遵循 FIFO 原则
- 不能直接调用 `orderBook.removeOrder()`，该函数只能由 OrderBook 自己调用
- 这样设计防止了移除请求的抢跑（front-running）

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

### 自动撮合机制

**撮合在订单插入时自动触发**，无需单独调用撮合函数：

```
batchProcessRequests()
  → 插入订单
  → _tryMatchAfterInsertion()  // 自动触发
      → 限价单撮合
      → 市价单撮合
```

**撮合逻辑**:
1. 获取最优买价（bidHead）和最优卖价（askHead）
2. 检查是否可以成交：`买价 >= 卖价`
3. 如果可以成交，执行交易
4. 重复直到 `买价 < 卖价` 或达到最大次数（默认10次）

**成交价格**: 使用卖单价格（价格优先原则）

**部分成交**:
- 支持订单部分成交
- 未完全成交的订单保留在订单簿中
- 完全成交的订单自动从订单簿移除

### 手动撮合函数（可选）

以下函数可用于手动触发撮合，通常不需要调用：

```solidity
// 综合撮合（先限价单后市价单）- 推荐使用
function matchAll(bytes32 tradingPair, uint256 maxIterations)
    external returns (uint256 limitTrades, uint256 marketTrades)

// 手动撮合限价单
function matchOrders(bytes32 tradingPair, uint256 maxIterations) external returns (uint256)

// 手动撮合市价单
function matchMarketOrders(bytes32 tradingPair, uint256 maxIterations) external returns (uint256)
```

**使用场景**：当自动撮合因 `maxIteration` 限制未完全执行时，Matcher 会自动调用 `matchAll()` 继续撮合剩余的可匹配订单。

**`matchAll()` 函数说明**：
- 先调用 `_matchOrdersInternal()` 撮合限价单
- 再调用 `_matchMarketOrdersInternal()` 撮合市价单
- 只有在有成交时才更新 `matchId`
- 返回限价单和市价单的成交数量

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
2. **价格-时间优先**: 价格优先，同价格按 FIFO 顺序
3. **部分成交**: 支持订单部分成交，未成交部分保留
4. **自动清理**: 完全成交的订单自动移除
5. **Gas控制**: 每次插入后最多撮合10次，防止 gas 耗尽

## Rust Matcher 引擎

### 概述

基于 Rust 的链下撮合引擎，通过**事件驱动**方式实时同步链上订单簿状态，使用本地模拟器计算正确的插入位置，并批量提交到 OrderBook。

### 核心功能

- 🔄 **事件驱动同步**: 通过链上事件实时更新本地订单簿状态
- 🎯 **精确模拟**: `OrderBookSimulator` 严格镜像链上订单簿结构
- 📦 **批量处理**: 批量调用 `batchProcessRequests` 节省 gas 成本
- ⚡ **深拷贝隔离**: 使用深拷贝隔离模拟计算，保证状态一致性
- 📊 **实时监控**: 完整的日志系统，监控匹配引擎运行状态

### 架构设计

```
┌─────────────────────────────────────────────────────────────┐
│                        Matcher                               │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────────┐    ┌─────────────────────────────────┐ │
│  │ StateSynchronizer│    │      MatchingEngine             │ │
│  │                 │    │                                 │ │
│  │ • 启动时同步状态  │    │ • 定期处理请求队列               │ │
│  │ • 监听链上事件   │    │ • 计算 insertAfterPrice         │ │
│  │ • 更新 GlobalState│   │ • 执行批量交易                  │ │
│  └────────┬────────┘    └────────────┬────────────────────┘ │
│           │                          │                       │
│           ▼                          ▼                       │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │                    GlobalState                          │ │
│  │  ┌──────────────────┐  ┌────────────────────────────┐  │ │
│  │  │ queued_requests  │  │      orderbook             │  │ │
│  │  │ (Sequencer队列)   │  │   (OrderBookSimulator)     │  │ │
│  │  └──────────────────┘  └────────────────────────────┘  │ │
│  └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### 关键设计

1. **事件驱动状态更新**: `GlobalState.orderbook` 只通过链上事件更新，保证本地与链上严格一致
2. **深拷贝隔离模拟**: `clone_orderbook()` 创建完整深拷贝，模拟计算不影响原始状态
3. **请求队列管理**: 只有交易成功后才移除请求，失败时自动重试

### 快速测试

```bash
# 1. 启动 Anvil
anvil --block-time 1

# 2. 部署合约
forge script script/Deploy.s.sol --broadcast --rpc-url http://127.0.0.1:8545

# 3. 下测试订单
forge script script/PlaceTestOrders.s.sol --broadcast --rpc-url http://127.0.0.1:8545

# 4. 运行 Matcher
cd matcher && cargo run -- --log-level debug
```

详细文档：
- 📖 [Matcher 快速开始](doc/QUICKSTART_MATCHER.md)
- 📖 [Matcher 使用指南](matcher/USAGE.md)
- 📖 [Matcher 架构说明](matcher/ARCHITECTURE.md)

### 数据流

```
链上事件                    本地状态                    交易执行
─────────────────────────────────────────────────────────────────
PlaceOrderRequested ──────► queued_requests.add()
                                   │
                                   ▼
                          MatchingEngine.process_batch()
                                   │
                          clone_orderbook() ──► 深拷贝
                                   │
                          simulate_insert() ──► 计算 insertAfterPrice
                                   │
                          execute_batch() ───► batchProcessRequests tx
                                   │
                                   ▼
OrderInserted ────────────► orderbook.orders.insert()
PriceLevelCreated ────────► orderbook.price_levels.insert()
OrderFilled ──────────────► orderbook.orders.update()
OrderRemoved ─────────────► orderbook.orders.remove()
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
├── src/
│   ├── Sequencer.sol          # 订单排序器
│   ├── OrderBook.sol          # 订单簿核心
│   └── Account.sol            # 账户和资金管理
├── script/                    # Foundry 部署脚本
│   ├── Deploy.s.sol          # 合约部署
│   └── PlaceTestOrders.s.sol # 测试订单脚本
├── test/                      # Foundry 测试
│   └── OrderBook.t.sol       # 单元测试
├── matcher/                   # Rust Matcher 引擎
│   ├── src/
│   │   ├── main.rs               # 主入口
│   │   ├── config.rs             # 配置管理
│   │   ├── contracts.rs          # 合约绑定
│   │   ├── types.rs              # 类型定义
│   │   ├── state.rs              # GlobalState 状态管理
│   │   ├── sync.rs               # 状态同步 + 事件监听
│   │   ├── matcher.rs            # 匹配引擎
│   │   └── orderbook_simulator.rs # 订单簿模拟器
│   ├── abi/                  # 合约 ABI
│   └── config.toml           # 配置文件
├── doc/                       # 文档目录
│   ├── QUICKSTART_MATCHER.md # Matcher 快速开始
│   ├── TESTING_GUIDE.md      # 测试指南
│   ├── DEPLOYMENT.md         # 部署指南
│   └── ...                   # 其他文档
└── deployments.json          # 部署地址
```

## 许可证

MIT License
