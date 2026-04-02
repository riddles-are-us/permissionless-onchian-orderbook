# OrderBook Matcher

基于 Rust 的链下撮合引擎，用于 OrderBook 去中心化交易所。

## 功能特性

- 🔄 **事件驱动同步**：通过链上事件实时更新本地订单簿状态
- 🎯 **精确模拟**：`OrderBookSimulator` 严格镜像链上订单簿结构
- 📦 **批量处理**：批量调用链上 `batchProcessRequests` API，节省 gas
- ⚡ **高性能**：使用深拷贝隔离模拟计算，保证状态一致性
- 🔁 **自动补撮合**：检测未完成撮合并自动调用 `matchAll()` 完成剩余匹配
- 📊 **实时监控**：完整的日志系统，监控匹配引擎运行状态
- 🌐 **REST API**：提供 HTTP API 查询订单和订单簿
- 💾 **MongoDB 存储**：持久化订单数据，支持历史查询
- ⏱️ **订单不可撤销期**：支持设置订单在指定时间内不可撤销

## 架构设计

### 核心组件

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
│  │  │                  │  │  • ask_head/tail           │  │ │
│  │  │                  │  │  • bid_head/tail           │  │ │
│  │  │                  │  │  • price_levels: HashMap   │  │ │
│  │  │                  │  │  • orders: HashMap         │  │ │
│  │  └──────────────────┘  └────────────────────────────┘  │ │
│  └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

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

### 关键设计

1. **事件驱动状态更新**
   - `GlobalState.orderbook` 只通过链上事件更新
   - 保证本地状态与链上严格一致

2. **深拷贝隔离模拟**
   - `clone_orderbook()` 创建完整深拷贝
   - 模拟计算不影响原始状态
   - 交易失败时状态自动保持正确

3. **请求队列管理**
   - 只有交易成功后才移除请求
   - 失败时请求保留，下轮重试

## 快速开始

### 本地测试

```bash
# 1. 启动 Anvil
anvil --block-time 1

# 2. 部署合约
forge script script/Deploy.s.sol --broadcast --rpc-url http://127.0.0.1:8545

# 3. 下测试订单
forge script script/PlaceTestOrders.s.sol --broadcast --rpc-url http://127.0.0.1:8545

# 4. 运行 Matcher
cd matcher
cargo run -- -l debug
```

### 配置文件

编辑 `config.toml`：

```toml
[network]
rpc_url = "ws://127.0.0.1:8545"
chain_id = 31337

[contracts]
sequencer = "0x..."
orderbook = "0x..."
account = "0x..."

[matching]
max_batch_size = 10
matching_interval_ms = 3000
max_iterations = 50  # matchAll 调用时的最大撮合次数

[executor]
private_key = "0x..."
gas_price_gwei = 1
gas_limit = 15000000

[mongodb]
enabled = true
uri = "mongodb://localhost:27017"
database = "orderbook_0x..."  # 建议使用合约地址作为数据库名

[api]
enabled = true
host = "127.0.0.1"
port = 8080
```

## REST API

启用 API 后，可通过 HTTP 接口查询订单数据。

### API 端点

| 方法 | 路径 | 描述 |
|------|------|------|
| GET | `/health` | 健康检查 |
| GET | `/api/v1/overview` | 获取系统概述 |
| GET | `/api/v1/users/{trader}/orders` | 获取用户所有订单 |
| GET | `/api/v1/users/{trader}/orders/active` | 获取用户活跃订单 |
| GET | `/api/v1/users/{trader}/trades` | 获取用户交易历史 |
| GET | `/api/v1/orders/{order_id}` | 获取单个订单详情 |
| GET | `/api/v1/orderbook/{trading_pair}` | 获取订单簿 |

### 请求示例

**获取系统概述**
```bash
curl -s "http://127.0.0.1:8080/api/v1/overview" | jq .
```

**响应示例**
```json
{
  "success": true,
  "data": {
    "current_block": 69,
    "match_id": "3",
    "pending_requests": [],
    "pending_request_count": 0,
    "asks": [
      {
        "price": "210000000000",
        "total_volume": "50000000",
        "order_count": 1
      }
    ],
    "bids": [
      {
        "price": "200000000000",
        "total_volume": "100000000",
        "order_count": 1
      },
      {
        "price": "195000000000",
        "total_volume": "100000000",
        "order_count": 1
      }
    ],
    "market_orders": {
      "total_buy_amount": "0",
      "total_sell_amount": "0",
      "buy_order_count": 0,
      "sell_order_count": 0
    }
  },
  "error": null
}
```

**系统概述字段说明**

| 字段 | 说明 |
|------|------|
| `current_block` | 当前同步到的区块高度 |
| `match_id` | 当前链上 matchId |
| `pending_requests` | 待处理的 Sequencer 请求列表 (最多 10 个) |
| `pending_request_count` | 待处理请求总数 |
| `asks` | 卖单价格层级 (最多 10 个，按价格从低到高) |
| `bids` | 买单价格层级 (最多 10 个，按价格从高到低) |
| `market_orders` | 市价单统计信息 |

**获取用户活跃订单**
```bash
curl -s "http://127.0.0.1:8080/api/v1/users/0x70997970c51812dc3a010c7d01b50e0d17dc79c8/orders/active" | jq .
```

**响应示例**
```json
{
  "success": true,
  "data": [
    {
      "_id": "1",
      "trading_pair": "0xe3fd74b5016b57bf4180a8d977a55d749f0f8f76be8d457de0768c85a6acc816",
      "trader": "0x70997970c51812dc3a010c7d01b50e0d17dc79c8",
      "order_type": "limit",
      "is_ask": false,
      "price": "200000000000",
      "amount": "100000000",
      "filled_amount": "0",
      "status": "active",
      "created_at": "2025-11-30T06:14:43.736925606Z",
      "updated_at": "2025-11-30T06:14:43.736925995Z",
      "block_number": 59,
      "tx_hash": null
    }
  ],
  "error": null
}
```

**获取订单簿**
```bash
curl -s "http://127.0.0.1:8080/api/v1/orderbook/0xe3fd74b5016b57bf4180a8d977a55d749f0f8f76be8d457de0768c85a6acc816?depth=10" | jq .
```

**响应示例**
```json
{
  "success": true,
  "data": {
    "bids": [
      {
        "_id": "1",
        "price": "200000000000",
        "amount": "100000000",
        "status": "active"
      }
    ],
    "asks": []
  },
  "error": null
}
```

### 查询参数

| 端点 | 参数 | 说明 |
|------|------|------|
| `/users/{trader}/orders` | `status` | 过滤状态: pending, active, partiallyfilled, filled, cancelled |
| `/users/{trader}/orders` | `limit` | 返回数量限制 (默认 50, 最大 100) |
| `/users/{trader}/orders` | `offset` | 分页偏移 |
| `/orderbook/{trading_pair}` | `depth` | 订单簿深度 (默认 20, 最大 100) |

### 订单状态说明

| 状态 | 说明 |
|------|------|
| `pending` | 在 Sequencer 队列中等待处理 |
| `active` | 已插入 OrderBook，等待成交 |
| `partiallyfilled` | 部分成交 |
| `filled` | 完全成交 |
| `cancelled` | 已取消 |

### 命令行参数

```
Options:
  -c, --config <CONFIG>        配置文件路径 [default: config.toml]
  -l, --log-level <LOG_LEVEL>  日志级别 [default: info]
  -s, --start-block <BLOCK>    起始区块号（覆盖配置文件）
      --disable-rpc            禁用 RPC/API 服务器（用于纯撮合节点）
  -h, --help                   显示帮助信息
```

**运行多个 Matcher 节点**

可以运行多个 Matcher 实例，主节点提供 API 服务，其他节点仅做撮合：

```bash
# 主节点（带 API）
./matcher -c config.toml

# 撮合节点（无 API，config2.toml 无需 mongodb/api 配置）
./matcher -c config2.toml --disable-rpc
```

## 项目结构

```
matcher/
├── src/
│   ├── main.rs               # 主入口
│   ├── config.rs             # 配置管理
│   ├── contracts.rs          # 合约绑定
│   ├── types.rs              # 类型定义
│   ├── state.rs              # GlobalState 状态管理
│   ├── sync.rs               # 状态同步器 + 事件监听
│   ├── matcher.rs            # 匹配引擎
│   ├── orderbook_simulator.rs # 订单簿模拟器
│   ├── api.rs                # REST API 服务
│   └── storage.rs            # MongoDB 存储层
├── abi/                      # 合约 ABI 文件
├── Cargo.toml
└── config.toml
```

## 监听的事件

| 事件 | 来源 | 处理 |
|------|------|------|
| `PlaceOrderRequested` | Sequencer | 添加到请求队列（包含 uncancellableDuration） |
| `RemoveOrderRequested` | Sequencer | 添加到请求队列 |
| `OrderInserted` | OrderBook | 更新 simulator.orders（包含 createdAt, uncancellableDuration） |
| `PriceLevelCreated` | OrderBook | 更新 simulator.price_levels |
| `PriceLevelRemoved` | OrderBook | 从 simulator 移除 |
| `OrderFilled` | OrderBook | 更新订单 filled_amount |
| `OrderRemoved` | OrderBook | 从 simulator 移除 |
| `Trade` | OrderBook | 记录交易日志 |

## 订单不可撤销期

限价订单可以设置 `uncancellableDuration` 参数（秒），在此期间订单无法被撤销：

- `uncancellableDuration = 0`：订单可立即撤销
- `uncancellableDuration > 0`：订单在 `createdAt + uncancellableDuration` 之后才能撤销

撤销请求在进入 Sequencer 队列之前会进行时间检查，若订单仍在不可撤销期内，请求会被拒绝。

## 日志示例

```
🚀 Starting OrderBook Matcher
📋 Configuration loaded
🔄 Starting state synchronizer
📚 Syncing historical state at block 100
📊 Trading pair: askHead=201, bidHead=200
✅ Historical state synced at block 100
👀 Watching for OrderBook and Sequencer events from block 100
📡 Starting OrderBook event listener from block 100
📡 Starting Sequencer event listener from block 100
🎯 Starting matching engine
📥 PlaceOrderRequested: requestId=11, price=199500000000, isAsk=false
📊 Simulator state: ask_head=201, bid_head=200, 10 price_levels, 10 orders
PlaceOrder 11 (price=199500000000, is_ask=false): insertAfterPrice=200000000000
📤 Executing batch with 1 orders
📝 Transaction sent: 0xabc...
📦 OrderInserted: orderId=11, price=199500000000, amount=20000000, isAsk=false
📊 PriceLevelCreated: price=199500000000, isAsk=false
✅ Transaction confirmed, 4 events emitted
✨ Processed 1 requests
```

## 安全注意事项

⚠️ **私钥**：生产环境应使用环境变量或密钥管理系统

⚠️ **Gas**：批量处理会消耗较多 gas，建议先测试

⚠️ **网络**：WebSocket 连接可能中断，内置重连机制

## License

MIT
