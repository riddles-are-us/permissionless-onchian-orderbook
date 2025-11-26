# 测试 Matcher 事件监听

## 目标
验证 matcher 正确监听并处理 OrderBook 的 Trade、OrderFilled 等事件。

## 前置条件
1. Anvil 本地节点运行中
2. 合约已部署（运行 `make deploy`）
3. 配置已更新（运行 `make update-config`）

## 测试步骤

### 1. 终端 1: 启动 Anvil
```bash
cd /Users/xingao/orderbook
make anvil
```

### 2. 终端 2: 部署并下测试订单
```bash
cd /Users/xingao/orderbook
make full-setup
```

**预期输出：**
```
📦 部署合约...
✅ 合约部署完成
🔧 更新配置文件...
✅ 配置更新完成
📝 下测试订单...
✅ 已下 10 个订单（5 买 5 卖）
```

### 3. 终端 3: 启动 Matcher
```bash
cd /Users/xingao/orderbook/matcher
cargo run --release
```

**预期输出（关键日志）：**
```
🔄 Starting state synchronizer
📚 Syncing historical state from block XXX
  Loaded 10 requests from queue
✅ Historical state synced to block XXX
👀 Watching for OrderBook and Sequencer events
📡 Starting OrderBook event listener    ← ✅ 事件监听已启动
🔄 Starting Sequencer state poller

🎯 Starting matching engine
📋 Queue status: 10 pending requests
🔄 Processing batch: 1 orders
💰 Executing match batch with 1 orders
✅ Match batch executed successfully

🔄 Trade: pair=0x..., buy=1, sell=6, price=100000000, amount=10000000    ← ✅ 监听到 Trade 事件
✅ OrderFilled: order=1, filled=10000000, fully_filled=true                ← ✅ 监听到 OrderFilled 事件
  Removed fully filled order 1 from local state                            ← ✅ 更新本地状态
✅ OrderFilled: order=6, filled=10000000, fully_filled=true
  Removed fully filled order 6 from local state
```

### 4. 终端 4: 查看链上事件（验证）
```bash
cd /Users/xingao/orderbook
./monitor_events.sh
```

**预期输出：**
```
=== Trade 事件 ===
- address: 0xb9bEECD1A582768711dE1EE7B0A1d582D9d72a6C
  blockHash: 0x...
  blockNumber: 123
  data: 0x...
  topics: [
    0x... (Trade 事件签名)
    0x... (tradingPair)
    0x... (buyOrderId)
    0x... (sellOrderId)
  ]

=== OrderFilled 事件 ===
- address: 0xb9bEECD1A582768711dE1EE7B0A1d582D9d72a6C
  topics: [
    0x... (OrderFilled 事件签名)
    0x... (tradingPair)
    0x... (orderId)
  ]
  data: filledAmount=10000000, isFullyFilled=true
```

### 5. 手动触发更多匹配（可选）
```bash
cd /Users/xingao/orderbook
./test_manual_orders.sh
```

然后立即查看 Matcher 终端，应该看到新的事件日志。

## 验证清单

- [ ] Matcher 启动时看到 "📡 Starting OrderBook event listener"
- [ ] 匹配发生后看到 "🔄 Trade: ..." 日志
- [ ] 每次成交后看到 "✅ OrderFilled: ..." 日志
- [ ] 完全成交的订单看到 "Removed fully filled order X from local state"
- [ ] 使用 `monitor_events.sh` 能看到链上确实发出了事件
- [ ] Matcher 日志中的订单 ID 与链上事件中的订单 ID 一致

## 调试技巧

### 1. 查看 Matcher 详细日志
```bash
RUST_LOG=debug cargo run --release
```

### 2. 实时监控事件（持续监听）
```bash
# 在新终端运行
ORDERBOOK=$(cat deployments.json | jq -r '.orderbook')
cast logs --follow --address $ORDERBOOK 'Trade(bytes32,uint256,uint256,address,address,uint256,uint256)'
```

### 3. 检查特定订单状态
```bash
ORDERBOOK=$(cat deployments.json | jq -r '.orderbook')
ORDER_ID=1

# 查询订单信息
cast call $ORDERBOOK "orders(uint256)(uint256,address,uint256,uint256,bool,uint256,uint256,uint256)" $ORDER_ID
```

### 4. 查看订单簿快照
```bash
ORDERBOOK=$(cat deployments.json | jq -r '.orderbook')
PAIR_ID=$(cat deployments.json | jq -r '.pairId')

# 查询订单簿数据
cast call $ORDERBOOK "orderBooks(bytes32)(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)" $PAIR_ID
```

## 常见问题

### Q: Matcher 没有输出事件日志？
**A:** 检查：
1. WebSocket 连接是否正常（config.toml 中 rpc_url 应该是 `ws://127.0.0.1:8545`）
2. 是否有订单被匹配（运行 `monitor_events.sh` 验证链上事件）
3. Matcher 是否启动在事件发出之后（事件只会收到启动后的新事件）

### Q: 看到 "Error receiving trade event" 错误？
**A:** 可能是：
1. WebSocket 连接断开 - 重启 matcher
2. 事件流结束 - Matcher 会自动重启事件监听
3. 区块重组 - 属于正常情况，Matcher 会重新同步

### Q: 本地状态和链上状态不一致？
**A:**
1. 查看是否所有 OrderFilled 事件都被正确处理
2. 重启 matcher（会重新同步历史状态）
3. 检查 `state.orders` 中的订单与链上订单是否匹配

## 成功标准

✅ **测试通过条件：**
1. Matcher 成功启动事件监听器
2. 每次匹配后都能看到 Trade 和 OrderFilled 事件
3. 完全成交的订单被自动从本地状态移除
4. 部分成交的订单 filledAmount 被正确更新
5. Matcher 日志中的事件数据与链上事件一致
