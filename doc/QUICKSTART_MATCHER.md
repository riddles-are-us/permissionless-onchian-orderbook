# Matcher 快速开始

3 分钟完成端到端测试。

## 前置要求

- Foundry (forge, anvil, cast)
- Rust 和 Cargo
- jq

## 一键测试

### 终端 1: 启动 Anvil
```bash
anvil --block-time 1
```

### 终端 2: 部署和准备
```bash
# 部署合约
forge script script/Deploy.s.sol --broadcast --rpc-url http://127.0.0.1:8545

# 下测试订单
forge script script/PlaceTestOrders.s.sol --broadcast --rpc-url http://127.0.0.1:8545
```

### 终端 3: 运行 Matcher
```bash
cd matcher
cargo run -- --log-level debug
```

## 期望输出

### Matcher 日志
```
🚀 Starting OrderBook Matcher
📋 Configuration loaded
🔄 Starting state synchronizer
📚 Syncing historical state at block 100
📊 Trading pair: askHead=201000000000, bidHead=200000000000
✅ Historical state synced at block 100
👀 Watching for OrderBook and Sequencer events from block 100
📡 Starting OrderBook event listener from block 100
📡 Starting Sequencer event listener from block 100
🎯 Starting matching engine
📊 Simulator state: ask_head=201000000000, bid_head=200000000000, 10 price_levels, 10 orders
📤 Executing batch with 10 orders
📝 Transaction sent: 0x...
📦 OrderInserted: orderId=1, price=200000000000, amount=10000000, isAsk=false
📊 PriceLevelCreated: price=200000000000, isAsk=false
...
✅ Transaction confirmed, 40 events emitted
✨ Processed 10 requests
```

## 核心架构

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

## 关键设计

### 1. 事件驱动状态更新
- `GlobalState.orderbook` 只通过链上事件更新
- 保证本地状态与链上严格一致

### 2. 深拷贝隔离模拟
- `clone_orderbook()` 创建完整深拷贝
- 模拟计算不影响原始状态
- 交易失败时状态自动保持正确

### 3. 请求队列管理
- 只有交易成功后才移除请求
- 失败时请求保留，下轮重试

## 测试场景

### 测试新订单插入
```bash
# 在已有订单的情况下，插入新订单到正确位置
cast send $SEQUENCER "requestPlaceOrder(bytes32,uint256,uint256,bool,uint8)" \
  $PAIR_ID \
  199500000000 \
  20000000 \
  false \
  1 \
  --private-key $PRIVATE_KEY \
  --rpc-url http://127.0.0.1:8545
```

观察 Matcher 日志：
```
📥 PlaceOrderRequested: requestId=11, price=199500000000, isAsk=false
PlaceOrder 11 (price=199500000000, is_ask=false): insertAfterPrice=200000000000
```

### 测试订单取消
```bash
# 取消订单 ID 为 1 的订单
cast send $SEQUENCER "requestRemoveOrder(uint256)" 1 \
  --private-key $PRIVATE_KEY \
  --rpc-url http://127.0.0.1:8545
```

观察 Matcher 日志：
```
📥 RemoveOrderRequested: requestId=12, orderIdToRemove=1
🗑️ OrderRemoved: order=1
```

### 测试订单撮合
```bash
# 下买单价格高于最佳卖价，触发撮合
cast send $SEQUENCER "requestPlaceOrder(bytes32,uint256,uint256,bool,uint8)" \
  $PAIR_ID \
  201000000000 \
  10000000 \
  false \
  1 \
  --private-key $PRIVATE_KEY \
  --rpc-url http://127.0.0.1:8545
```

观察 Matcher 日志：
```
📥 PlaceOrderRequested: requestId=13, price=201000000000, isAsk=false
💰 Trade: buy=13, sell=6, price=201000000000, amount=10000000
📦 OrderFilled: orderId=6, filledAmount=10000000
📦 OrderFilled: orderId=13, filledAmount=10000000
```

## 故障排查

### 问题: WebSocket 连接失败
**解决**: 确保 Anvil 正在运行
```bash
anvil --block-time 1
```

### 问题: 合约部署失败
**解决**:
```bash
# 重新编译
forge build

# 重新部署
forge script script/Deploy.s.sol --broadcast --rpc-url http://127.0.0.1:8545
```

### 问题: Matcher 不处理订单
**解决**: 检查日志级别是否为 debug
```bash
cd matcher
cargo run -- --log-level debug
```

### 问题: insertAfterPrice 计算错误
**解决**: 确保监听了所有 OrderBook 事件
- OrderInserted
- PriceLevelCreated
- PriceLevelRemoved
- OrderFilled
- OrderRemoved

## 详细文档

- 完整使用说明: [../matcher/USAGE.md](../matcher/USAGE.md)
- 架构设计文档: [../matcher/ARCHITECTURE.md](../matcher/ARCHITECTURE.md)
- 主 README: [../matcher/README.md](../matcher/README.md)

## 下一步

测试成功后，可以：
- 修改 `PlaceTestOrders.s.sol` 下更多订单
- 测试卖单场景
- **测试订单取消** - 使用 `Sequencer.requestRemoveOrder(orderId)`
- **测试订单撮合** - 下穿越价差的订单
- 调整 Matcher 配置（batch size, interval）
- 运行单元测试: `cd matcher && cargo test`

## 清理

停止所有进程 (Ctrl+C)，重新开始：
```bash
# 重启 Anvil（会创建新链）
anvil --block-time 1

# 重新部署
forge script script/Deploy.s.sol --broadcast --rpc-url http://127.0.0.1:8545

# 重新下测试订单
forge script script/PlaceTestOrders.s.sol --broadcast --rpc-url http://127.0.0.1:8545

# 重新运行 Matcher
cd matcher && cargo run -- -l debug
```
