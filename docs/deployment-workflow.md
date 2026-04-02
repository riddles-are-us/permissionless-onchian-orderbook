# Permissionless OrderBook 部署工作流

本文档记录了 OrderBook 系统的完整部署和更新工作流程。

## 目录

1. [系统架构概述](#系统架构概述)
2. [Bug 分析与修复流程](#bug-分析与修复流程)
3. [代码合并流程](#代码合并流程)
4. [合约部署流程](#合约部署流程)
5. [前端配置更新](#前端配置更新)
6. [服务器 Matcher 配置更新](#服务器-matcher-配置更新)
7. [验证部署](#验证部署)

---

## 系统架构概述

### 组件

| 组件 | 描述 | 仓库/位置 |
|------|------|----------|
| **智能合约** | Sequencer, OrderBook, Account | `permissionless-onchian-orderbook/` |
| **Matcher** | Rust 后端服务，负责订单撮合 | `permissionless-onchian-orderbook/matcher/` |
| **前端** | React 交易界面 | `socrates-markets-72ff1b3c/` |

### 合约交互流程

```
用户 -> Sequencer (下单/撤单请求入队)
           |
           v
Matcher (监听事件，处理队列)
           |
           v
OrderBook (执行订单插入/撮合/删除)
           |
           v
Account (资金锁定/转移/解锁)
```

---

## Bug 分析与修复流程

### 问题描述

Matcher 报错 `Order does not exist`，无法处理 Sequencer 队列中的请求。

### 诊断步骤

1. **检查链上状态**

```bash
# 检查 Sequencer 队列头部
cast call <SEQUENCER_ADDRESS> "queueHead()(uint256)" --rpc-url <RPC_URL>

# 检查队列尾部
cast call <SEQUENCER_ADDRESS> "queueTail()(uint256)" --rpc-url <RPC_URL>

# 检查特定请求的数据
cast call <SEQUENCER_ADDRESS> "queuedRequests(uint256)(bytes32,address,uint8,uint8,bool,uint256,uint256,uint256,uint256,uint256)" <REQUEST_ID> --rpc-url <RPC_URL>
```

2. **分析请求类型**

返回数据结构：
- `tradingPair` (bytes32)
- `trader` (address)
- `requestType` (uint8): 0=PlaceOrder, 1=RemoveOrder
- `orderType` (uint8): 0=LimitOrder, 1=MarketOrder
- `isAsk` (bool)
- `price` (uint256): 对于 RemoveOrder，这里存储 `orderIdToRemove`
- `amount` (uint256)
- `uncancellableDuration` (uint256)
- `nextRequestId` (uint256)
- `prevRequestId` (uint256)

3. **检查 OrderBook 中的订单**

```bash
cast call <ORDERBOOK_ADDRESS> "orders(uint256)(uint256,address,uint256,uint256,bool,uint256,uint256,uint256,uint256,uint256)" <ORDER_ID> --rpc-url <RPC_URL>
```

4. **检查 ordersInBook 状态**

```bash
cast call <SEQUENCER_ADDRESS> "ordersInBook(uint256)(bool)" <ORDER_ID> --rpc-url <RPC_URL>
```

### 根本原因

`ordersInBook` 映射在订单被成交或撤销后没有被正确更新为 `false`，导致：
1. 用户可以对已成交的订单提交撤单请求
2. Sequencer 接受了撤单请求（因为 `ordersInBook[orderId] == true`）
3. OrderBook 处理撤单时失败（因为订单已被删除）

### 修复内容

1. **Sequencer.sol**: 在 `processRequest()` 中，处理 RemoveOrder 请求时将 `ordersInBook[orderIdToRemove]` 设为 `false`
2. **OrderBook.sol**: 添加 `isAsk` 字段到 Order 结构体，避免遍历链表判断
3. **OrderBook.sol**: 添加灰尘阈值处理，解决精度问题导致的订单无法完全成交

---

## 代码合并流程

### 1. 获取最新代码

```bash
cd /path/to/permissionless-onchian-orderbook
git fetch origin
```

### 2. 查看待合并的提交

```bash
git log --oneline jupiter..origin/main
```

### 3. 合并 main 到 jupiter

```bash
git checkout jupiter
git merge origin/main -m "Merge main branch bugfix into jupiter"
```

### 4. 解决冲突（如有）

常见冲突文件：`deployments.json`

```bash
# 编辑冲突文件，保留正确的部署信息
# 然后提交
git add deployments.json
git commit -m "Resolved conflict in deployments.json"
```

### 5. 推送更新

```bash
git push origin jupiter
```

---

## 合约部署流程

### 前置条件

- 安装 Foundry (`forge`, `cast`)
- 配置环境变量 `PRIVATE_KEY`（部署者私钥）
- 确保部署账户有足够的 ETH（Sepolia 测试网约需 0.02 ETH）

### 1. 编译合约

```bash
forge build --force
```

### 2. 部署到 Sepolia

**重要：Deploy.s.sol 现在会同时部署 ETH/USDC 和 BTC/USDC 两个交易对。**

```bash
forge script script/Deploy.s.sol:DeployScript \
  --rpc-url https://ethereum-sepolia-rpc.publicnode.com \
  --broadcast \
  --legacy \
  -vvv
```

部署脚本会自动：
1. 部署 WETH (18 位小数)
2. 部署 WBTC (8 位小数，与真实 Bitcoin 一致)
3. 部署 USDC (6 位小数)
4. 部署 Account、OrderBook、Sequencer 合约
5. 配置合约间的关联
6. 注册 WETH/USDC 交易对 (pairId: `keccak256("WETH/USDC")`)
7. 注册 WBTC/USDC 交易对 (wbtcPairId: `keccak256("WBTC/USDC")`)

**注意**：如果只需要单独部署 WBTC（例如在已有部署上添加），可以使用：

```bash
forge script script/DeployWBTC.s.sol:DeployWBTCScript \
  --rpc-url https://ethereum-sepolia-rpc.publicnode.com \
  --broadcast \
  --legacy \
  -vvv
```

部署前需要更新 `DeployWBTC.s.sol` 中的 `ACCOUNT` 和 `USDC` 地址。

### 3. 记录部署信息

部署脚本会自动生成 `deployments.json`：

```json
{
  "weth": "0x...",
  "wbtc": "0x...",
  "usdc": "0x...",
  "account": "0x...",
  "orderbook": "0x...",
  "sequencer": "0x...",
  "pairId": "0xe3fd74b5016b57bf4180a8d977a55d749f0f8f76be8d457de0768c85a6acc816",
  "wbtcPairId": "0xc4a4e865aa0aa1da3eb8811d14d304839f3002161a919075a08340898d445010",
  "deployer": "0x...",
  "deploymentBlock": 10105369
}
```

### 4. 提交部署记录

```bash
git add deployments.json broadcast/
git commit -m "Deploy new contracts with bugfix (YYYY-MM-DD)"
git push origin jupiter
```

---

## 前端配置更新

### 配置文件位置

`socrates-markets-72ff1b3c/src/config.ts`

### 更新内容

```typescript
export const CONFIG = {
  // 更新版本号
  APP_VERSION: '0.0.6',

  // 更新合约地址
  CONTRACTS: {
    ACCOUNT: '0x...' as `0x${string}`,
    ORDERBOOK: '0x...' as `0x${string}`,
    SEQUENCER: '0x...' as `0x${string}`,
    WETH: '0x...' as `0x${string}`,
    USDC: '0x...' as `0x${string}`,
  },

  // ... 其他配置保持不变
};
```

### 提交更新

```bash
cd /path/to/socrates-markets-72ff1b3c
git add src/config.ts
git commit -m "Update contract addresses for bugfix deployment (vX.X.X)"
git push origin main
```

---

## 服务器 Matcher 配置更新

### SSH 连接

```bash
ssh -i ~/.ssh/id_rsa_win jupitor@100.109.156.120
```

### 1. 更新代码

```bash
cd ~/permissionless-onchian-orderbook
git fetch origin
git checkout jupiter
git pull origin jupiter
```

### 2. 更新配置文件

编辑 `~/permissionless-onchian-orderbook/matcher/config.toml`：

```toml
# OrderBook Matcher 配置

[network]
rpc_url = "wss://sepolia.infura.io/ws/v3/<API_KEY>"
chain_id = 11155111

[contracts]
sequencer = "0x..."  # 新的 Sequencer 地址
orderbook = "0x..."  # 新的 OrderBook 地址
account = "0x..."    # 新的 Account 地址
trading_pair = "0xe3fd74b5016b57bf4180a8d977a55d749f0f8f76be8d457de0768c85a6acc816"

[sync]
start_block = 10105369  # 新的部署区块
sync_historical = true

[matching]
max_batch_size = 100
matching_interval_ms = 3000
max_iterations = 50

[executor]
private_key = "0x..."  # Matcher 执行者私钥
gas_price_gwei = 2
gas_limit = 5000000

[mongodb]
enabled = true
uri = "mongodb://localhost:27017"
database = "orderbook_0x..."  # 使用新的 OrderBook 地址

[api]
enabled = true
host = "0.0.0.0"
port = 8080
```

### 3. 重新编译 Matcher

```bash
source ~/.cargo/env
cd ~/permissionless-onchian-orderbook/matcher
cargo build --release
```

### 4. 重启 Matcher

```bash
# 停止当前运行的 matcher
tmux send-keys -t matcher C-c

# 等待停止
sleep 2

# 启动新的 matcher
tmux send-keys -t matcher 'cd ~/permissionless-onchian-orderbook/matcher && source ~/.cargo/env && RUST_LOG=info ./target/release/matcher' Enter
```

如果 tmux session 不存在：

```bash
tmux new-session -d -s matcher
tmux send-keys -t matcher 'cd ~/permissionless-onchian-orderbook/matcher && source ~/.cargo/env && RUST_LOG=info ./target/release/matcher' Enter
```

### 5. 查看日志

```bash
tmux capture-pane -t matcher -p | tail -30
```

---

## 验证部署

### 1. 验证合约部署

```bash
# 检查 OrderBook matchId
cast call <ORDERBOOK_ADDRESS> "matchId()(uint256)" --rpc-url <RPC_URL>

# 检查 Sequencer queueHead
cast call <SEQUENCER_ADDRESS> "queueHead()(uint256)" --rpc-url <RPC_URL>
```

### 2. 验证 Matcher API

```bash
# 健康检查
curl http://100.109.156.120:8080/health

# 预期响应
# {"success":true,"data":"OK","error":null}
```

### 3. 验证 Matcher 日志

检查是否有以下关键日志：

```
✅ Historical state synced at block XXXXX
🟢 Sync completed, MatchingEngine can start processing
📡 Unified WebSocket subscription created successfully
```

### 4. 验证前端

访问前端应用，检查：
- 版本号是否更新
- 能否正常连接钱包
- 能否查看订单簿

---

## 常见问题排查

### Matcher 无法连接 WebSocket

1. 检查 RPC URL 是否正确
2. 检查网络连接
3. 尝试更换 RPC 提供商

### "Order does not exist" 错误

1. 检查是否是 RemoveOrder 请求
2. 检查目标订单是否已被成交或撤销
3. 如果是新部署，确保使用了包含 bugfix 的合约

### MongoDB 连接失败

```bash
# 检查 MongoDB 状态
sudo systemctl status mongod

# 启动 MongoDB
sudo systemctl start mongod
```

### Gas 不足

1. 检查 Matcher 执行者账户余额
2. 调整 `gas_price_gwei` 配置

---

## 部署检查清单

- [ ] 合并最新 bugfix 代码
- [ ] 编译合约成功
- [ ] 部署合约到 Sepolia (Deploy.s.sol 会同时部署 ETH/USDC 和 BTC/USDC)
- [ ] 验证 deployments.json 包含 wbtc 和 wbtcPairId
- [ ] 更新前端 config.ts（包括 WBTC 地址和 BTC/USDC 交易对）
- [ ] 提交并推送前端更新
- [ ] 更新服务器 matcher config.toml（添加 BTC/USDC 交易对配置）
- [ ] 重新编译 matcher
- [ ] 重启 matcher
- [ ] 验证 matcher API 正常
- [ ] 验证前端功能正常（ETH/USDC 和 BTC/USDC 交易对）

---

## 版本历史

| 日期 | 版本 | 变更内容 |
|------|------|----------|
| 2026-01-29 | v0.0.7 | 添加 WBTC/USDC 交易对部署流程，更新部署检查清单 |
| 2026-01-23 | v0.0.6 | Bugfix: ordersInBook 状态追踪、isAsk 字段、灰尘阈值处理 |
| 2026-01-21 | v0.0.5 | 初始 Sepolia 部署 |
