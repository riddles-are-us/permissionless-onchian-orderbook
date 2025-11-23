# Matcher 测试指南

完整的端到端测试流程，使用 Foundry 部署合约，然后用 Rust Matcher 进行匹配。

## 快速开始（3 步）

### 步骤 1: 启动本地节点

在终端 1 中运行：

```bash
anvil
```

保持此终端运行，你会看到 10 个测试账户和它们的私钥。

### 步骤 2: 部署合约并准备测试数据

在终端 2 中运行：

```bash
./test_matcher.sh
```

这个脚本会自动：
- ✅ 部署所有合约（WETH, USDC, Account, OrderBook, Sequencer）
- ✅ 配置合约之间的关系
- ✅ 注册 WETH/USDC 交易对
- ✅ 给测试用户铸造代币
- ✅ 充值到 Account 合约
- ✅ 下 3 个测试订单到 Sequencer 队列
- ✅ 生成 matcher/config.toml 配置文件

执行完成后，你会看到部署的合约地址和待处理订单数量。

### 步骤 3: 运行 Matcher

在终端 3 中运行：

```bash
cd matcher
cargo run -- --log-level debug
```

或使用已编译的二进制：

```bash
cd matcher
./target/debug/matcher --log-level debug
```

### 步骤 4: 验证结果

Matcher 运行后，在终端 4 中运行：

```bash
./verify_results.sh
```

你应该看到：
- ✅ 队列已清空（待处理订单 = 0）
- ✅ 订单簿有数据（Bid 头部层级 ID ≠ 0）
- ✅ 3 个价格层级（2000, 1950, 1900 USDC）

## 详细说明

### 部署脚本做了什么

`./test_matcher.sh` 执行以下操作：

#### 1. 部署合约
使用 `script/Deploy.s.sol` Foundry 脚本：
```bash
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

部署顺序：
1. MockERC20 (WETH, 18 decimals)
2. MockERC20 (USDC, 6 decimals)
3. Account 合约
4. OrderBook 合约
5. Sequencer 合约

#### 2. 配置合约
- `Account.setOrderBook(orderbook)`
- `Account.setSequencer(sequencer)`
- `OrderBook.setSequencer(sequencer)`
- `Account.registerTradingPair("WETH/USDC", weth, usdc)`

#### 3. 准备测试数据
使用 `script/PrepareTest.s.sol`：
```bash
forge script script/PrepareTest.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

测试用户操作：
- 铸造 100 WETH
- 铸造 100,000 USDC
- 授权 Account 合约
- 充值 10 WETH 到 Account
- 充值 10,000 USDC 到 Account
- 下 3 个买单（价格递减：2000, 1950, 1900）

#### 4. 生成配置文件
自动创建 `matcher/config.toml`：
```toml
[network]
rpc_url = "ws://127.0.0.1:8545"
chain_id = 31337

[contracts]
account = "0x..."
orderbook = "0x..."
sequencer = "0x..."

[executor]
private_key = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
gas_price_gwei = 1
gas_limit = 5000000

[matching]
max_batch_size = 10
matching_interval_ms = 3000

[sync]
start_block = 0
sync_historical = true
```

### Matcher 工作流程

启动后，Matcher 执行以下步骤：

#### 1. 初始化
- 连接到 WebSocket RPC (ws://127.0.0.1:8545)
- 加载合约 ABI
- 创建合约实例

#### 2. 状态同步
```
[INFO] 🔄 Starting state synchronizer
[INFO] 📚 Syncing historical state from block 0
```

- 读取 `Sequencer.queueHead()`
- 遍历队列加载所有请求
- 构建本地请求缓存

```
[DEBUG]   Queue head: 1
[DEBUG]   Loaded 3 requests from queue
[INFO] ✅ Historical state synced to block 0
```

#### 3. 匹配引擎启动
```
[INFO] 🎯 Starting matching engine
[INFO]   Batch size: 10
[INFO]   Interval: 3000ms
```

每 3 秒执行一次批处理周期。

#### 4. 批处理循环
每个周期：

a. **获取请求**
```rust
let requests = self.state.get_head_requests(max_batch_size);
```

b. **计算插入位置**
对每个订单：
- 检查本地价格层级缓存
- 如果缓存未命中，从链上读取
- 根据价格排序找到正确位置
  - Bid: 从高到低 (2000 → 1950 → 1900)
  - Ask: 从低到高 (2100 → 2150 → 2200)

c. **构建批处理交易**
```solidity
orderbook.batchProcessRequests(
    [orderId1, orderId2, orderId3],
    [insertAfterPriceLevel1, insertAfterPriceLevel2, insertAfterPriceLevel3],
    [insertAfterOrder1, insertAfterOrder2, insertAfterOrder3]
)
```

d. **提交并等待确认**
```
[INFO] 📤 Executing batch with 3 orders
[INFO] 📝 Transaction sent: 0x1234...
[INFO] ✅ Transaction confirmed in block: Some(5)
[INFO]   3 events emitted
[INFO] ✨ Processed 3 requests
```

### 验证脚本

`verify_results.sh` 检查：

#### 1. 队列状态
```bash
cast call $SEQUENCER "getQueueLength(uint256)" 100
```
期望：`0` (队列已清空)

#### 2. 订单簿状态
```bash
cast call $ORDERBOOK "getTradingPairData(bytes32)" $PAIR_ID
```
期望：`bid_head != 0` (有买单)

#### 3. 价格层级详情
对每个价格层级：
```bash
cast call $ORDERBOOK "priceLevels(uint256)" $LEVEL_ID
```
显示：价格和数量

期望输出示例：
```
📦 队列状态:
  待处理订单: 0
  ✅ 队列已清空

📊 订单簿状态:
  Bid 头部层级 ID: 1
  Ask 头部层级 ID: 0

💰 Bid 价格层级:
  Level 1: 2000.00 USDC x 1.0000 WETH
  Level 2: 1950.00 USDC x 1.0000 WETH
  Level 3: 1900.00 USDC x 1.0000 WETH

✅ 测试成功! Matcher 已正确处理订单
```

## 故障排查

### Anvil 连接失败

**症状**: `Failed to connect to WebSocket`

**解决方案**:
1. 确保 Anvil 正在运行
2. 检查端口 8545 未被占用
3. 尝试重启 Anvil

### 部署失败

**症状**: `forge script` 报错

**可能原因**:
- Anvil 未运行
- 合约编译错误
- 私钥错误

**解决方案**:
```bash
# 重新编译
forge build

# 检查 Anvil 连接
cast chain-id --rpc-url http://127.0.0.1:8545

# 重新运行部署脚本
./test_matcher.sh
```

### Matcher 不处理订单

**症状**: Matcher 运行但队列未清空

**检查清单**:
1. ✅ 配置文件正确
2. ✅ WebSocket 连接正常
3. ✅ Executor 账户有 ETH (Anvil 默认账户有足够余额)
4. ✅ 日志级别设为 debug 查看详细信息

**调试**:
```bash
# 查看详细日志
cd matcher
RUST_LOG=debug ./target/debug/matcher

# 手动检查队列
cast call $SEQUENCER "queueHead()" --rpc-url http://127.0.0.1:8545
cast call $SEQUENCER "getQueueLength(uint256)" 100 --rpc-url http://127.0.0.1:8545
```

### 交易 Revert

**症状**: Transaction failed

**可能原因**:
- 插入位置错误
- Gas 不足
- 权限问题

**查看错误**:
Anvil 终端会显示 revert 原因。

**常见错误**:
- "Only sequencer": Executor 未被授权
- "Invalid price level": 插入位置计算错误
- "Insufficient balance": 用户余额不足

## 手动测试步骤

如果自动脚本有问题，可以手动执行：

### 1. 启动 Anvil
```bash
anvil
```

### 2. 部署合约
```bash
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --legacy
```

### 3. 准备测试数据
```bash
export USER_PRIVATE_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
forge script script/PrepareTest.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --legacy
```

### 4. 手动生成配置
```bash
cat > matcher/config.toml <<EOF
[network]
rpc_url = "ws://127.0.0.1:8545"
chain_id = 31337

[contracts]
account = "$(jq -r '.account' deployments.json)"
orderbook = "$(jq -r '.orderbook' deployments.json)"
sequencer = "$(jq -r '.sequencer' deployments.json)"

[executor]
private_key = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
gas_price_gwei = 1
gas_limit = 5000000

[matching]
max_batch_size = 10
matching_interval_ms = 3000

[sync]
start_block = 0
sync_historical = true
EOF
```

### 5. 运行 Matcher
```bash
cd matcher
cargo run -- --log-level debug
```

## 性能测试

### 批量下单测试

修改 `PrepareTest.s.sol`，增加订单数量：

```solidity
// 下 20 个订单
for (uint256 i = 0; i < 20; i++) {
    uint256 price = (2000 - i * 10) * 10**8;
    sequencer.placeLimitOrder(pairId, false, price, 1 * 10**8);
}
```

观察 Matcher 批处理性能。

### Gas 消耗分析

查看交易 receipt：
```bash
cast tx <TX_HASH> --rpc-url http://127.0.0.1:8545
```

对比：
- 单个订单 gas 消耗
- 批量处理 gas 消耗
- Gas 节省百分比

## 下一步

- [ ] 添加卖单测试
- [ ] 测试撮合场景（买卖单匹配）
- [ ] 压力测试（大量订单）
- [ ] 测试订单取消
- [ ] 多交易对测试
- [ ] 实时事件监听测试
