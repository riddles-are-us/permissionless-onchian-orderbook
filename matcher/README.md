# OrderBook Matcher

基于 Rust 的链下撮合引擎，用于 OrderBook 去中心化交易所。

## 功能特性

- 🔄 **状态同步**：从指定区块高度读取合约状态，通过事件监听维护增量状态
- 🎯 **智能匹配**：自动计算订单的正确插入位置
- 📦 **批量处理**：批量调用链上 `batchProcessRequests` API，节省 gas
- ⚡ **高性能**：使用 DashMap 实现线程安全的状态管理
- 📊 **实时监控**：完整的日志系统，监控匹配引擎运行状态

## 架构设计

### 组件说明

1. **StateSynchronizer（状态同步器）**
   - 从指定区块高度读取初始状态
   - 监听 Sequencer 和 OrderBook 合约事件
   - 维护本地状态缓存

2. **MatchingEngine（匹配引擎）**
   - 定期从 Sequencer 队列获取待处理请求
   - 计算每个订单的正确插入位置
   - 批量调用链上 API 执行插入

3. **GlobalState（全局状态）**
   - 使用 DashMap 实现线程安全的状态存储
   - 缓存价格层级、订单、请求队列等数据

### 工作流程

```
1. 启动时从指定区块同步历史状态
   ├─ 读取 Sequencer 请求队列
   ├─ 读取 OrderBook 价格层级
   └─ 读取订单数据

2. 启动事件监听器
   ├─ 监听 RequestAdded 事件
   ├─ 监听 RequestProcessed 事件
   ├─ 监听 PriceLevelCreated 事件
   └─ 监听 OrderInserted 事件

3. 定期执行匹配
   ├─ 从队列获取前 N 个请求
   ├─ 计算每个订单的插入位置
   │   ├─ 查找现有价格层级
   │   ├─ 确定正确的排序位置
   │   └─ 处理 Bid/Ask 排序差异
   └─ 批量调用 batchProcessRequests
```

## 快速开始

### 本地测试（推荐）

使用 Foundry 脚本快速测试完整流程：

```bash
# 1. 启动 Anvil（在终端 1）
cd /Users/xingao/orderbook
anvil

# 2. 部署合约并准备测试数据（在终端 2）
./test_matcher.sh

# 3. 运行 Matcher（在终端 3）
cd matcher
cargo run -- --log-level debug

# 4. 验证结果（在终端 4）
./verify_results.sh
```

详细测试指南请查看：[../TESTING_GUIDE.md](../TESTING_GUIDE.md)

### 生产环境部署

### 1. 配置

编辑 `config.toml`：

```toml
[network]
rpc_url = "ws://localhost:8545"
chain_id = 31337

[contracts]
sequencer = "0x..."
orderbook = "0x..."
account = "0x..."

[sync]
start_block = 0  # 0 表示从最新区块开始
sync_historical = true

[matching]
max_batch_size = 100
matching_interval_ms = 1000

[executor]
private_key = "0x..."
gas_price_gwei = 1
gas_limit = 5000000
```

### 2. 编译

```bash
cd matcher
cargo build --release
```

### 3. 运行

```bash
# 使用默认配置
./target/release/matcher

# 指定配置文件
./target/release/matcher -c custom_config.toml

# 指定起始区块和日志级别
./target/release/matcher -s 1000 -l debug
```

### 4. 命令行参数

```
Options:
  -c, --config <CONFIG>        配置文件路径 [default: config.toml]
  -l, --log-level <LOG_LEVEL>  日志级别 [default: info]
  -s, --start-block <START_BLOCK>  起始区块号（覆盖配置文件）
  -h, --help                   显示帮助信息
  -V, --version                显示版本信息
```

## 开发

### 项目结构

```
matcher/
├── src/
│   ├── main.rs           # 主入口
│   ├── config.rs         # 配置管理
│   ├── contracts.rs      # 合约绑定
│   ├── types.rs          # 类型定义
│   ├── state.rs          # 状态管理
│   ├── sync.rs           # 状态同步器
│   └── matcher.rs        # 匹配引擎
├── abi/                  # 合约 ABI 文件
│   ├── Sequencer.json
│   ├── OrderBook.json
│   └── Account.json
├── Cargo.toml            # 依赖配置
└── config.toml           # 运行配置
```

### 关键依赖

- `ethers`: Ethereum 交互库
- `tokio`: 异步运行时
- `dashmap`: 线程安全的 HashMap
- `tracing`: 日志框架

## 日志说明

引擎会输出以下日志：

```
🚀 Starting OrderBook Matcher
📋 Configuration loaded
🔄 Starting state synchronizer
📚 Syncing historical state from block 1000
✅ Historical state synced to block 1000
👀 Watching for contract events
🎯 Starting matching engine
📥 Request added: 123
🎯 Processing 5 requests
📤 Executing batch with 5 orders
📝 Transaction sent: 0xabc...
✅ Transaction confirmed in block: 1001
```

## 优化建议

1. **Gas 优化**
   - 调整 `max_batch_size` 以优化 gas 使用
   - 根据网络拥堵情况动态调整 `gas_price`

2. **性能优化**
   - 调整 `matching_interval_ms` 平衡延迟和吞吐量
   - 使用更快的 RPC 节点

3. **可靠性优化**
   - 添加交易重试机制
   - 实现状态检查点，支持断点续传

## 注意事项

⚠️ **安全**
- 私钥应使用环境变量或密钥管理系统
- 生产环境不应将私钥写入配置文件

⚠️ **Gas**
- 批量处理会消耗较多 gas
- 建议先在测试网测试 gas 消耗

⚠️ **网络**
- WebSocket 连接可能中断，需要实现重连机制
- 建议使用稳定的 RPC 服务商

## License

MIT
