# Matcher 快速开始 ⚡

3 分钟完成端到端测试。

## 前置要求

- ✅ Foundry (forge, anvil, cast)
- ✅ Rust 和 Cargo
- ✅ jq

## 一键测试

### 终端 1: 启动 Anvil
```bash
anvil
```

### 终端 2: 部署和准备
```bash
./test_matcher.sh
```

### 终端 3: 运行 Matcher
```bash
cd matcher
cargo run -- --log-level debug
```

### 终端 4: 验证结果
```bash
./verify_results.sh
```

## 期望输出

### Matcher 日志
```
[INFO] 🔄 Starting state synchronizer
[INFO] 📚 Syncing historical state from block 0
[DEBUG]   Queue head: 1
[DEBUG]   Loaded 3 requests from queue
[INFO] ✅ Historical state synced to block 0
[INFO] 🎯 Starting matching engine
[INFO]   Batch size: 10
[INFO]   Interval: 3000ms
[INFO] 📤 Executing batch with 3 orders
[INFO] 📝 Transaction sent: 0x...
[INFO] ✅ Transaction confirmed in block: Some(5)
[INFO]   3 events emitted
[INFO] ✨ Processed 3 requests
```

### 验证结果
```
🔍 验证 Matcher 执行结果
========================

📦 队列状态:
  待处理订单: 0
  ✅ 队列已清空

📊 订单簿状态:
  Bid 头部层级 ID: 1

💰 Bid 价格层级:
  Level 1: 2000.00 USDC x 1.0000 WETH
  Level 2: 1950.00 USDC x 1.0000 WETH
  Level 3: 1900.00 USDC x 1.0000 WETH

✅ 测试成功! Matcher 已正确处理订单
```

## 工作原理

1. **Anvil**: 本地以太坊测试网络
2. **Deploy.s.sol**: 部署所有合约（WETH, USDC, Account, OrderBook, Sequencer）
3. **PrepareTest.s.sol**: 铸造代币、充值、下 3 个测试订单
4. **Matcher**: 读取队列、计算插入位置、批量提交交易
5. **verify_results.sh**: 检查队列和订单簿状态

## 故障排查

### 问题: WebSocket 连接失败
**解决**: 确保 Anvil 正在运行

### 问题: 合约部署失败
**解决**:
```bash
# 重新编译
forge build

# 重新运行
./test_matcher.sh
```

### 问题: Matcher 不处理订单
**解决**: 检查日志级别是否为 debug
```bash
cd matcher
cargo run -- --log-level debug
```

## 详细文档

- 📖 完整测试指南: [TESTING_GUIDE.md](TESTING_GUIDE.md)
- 📖 Matcher 使用说明: [matcher/USAGE.md](matcher/USAGE.md)
- 📖 部署指南: [matcher/DEPLOYMENT_GUIDE.md](matcher/DEPLOYMENT_GUIDE.md)

## 下一步

测试成功后，可以：
- 修改 `PrepareTest.s.sol` 下更多订单
- 测试卖单场景
- **测试订单取消** - 使用 `Sequencer.requestRemoveOrder(orderId)`
- 测试订单撮合
- 调整 Matcher 配置（batch size, interval）
- 测试多交易对

## 清理

停止所有进程 (Ctrl+C)，重新开始：
```bash
# 重启 Anvil（会创建新链）
anvil

# 重新部署
./test_matcher.sh

# 重新运行 Matcher
cd matcher && cargo run
```
