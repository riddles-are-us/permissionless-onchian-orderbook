# 部署和配置指南

## 自动化配置系统

现在所有配置都会自动从 `deployments.json` 更新，**不再需要手动修改地址**！

## 快速开始

### 1. 启动本地节点（新终端）

```bash
make anvil
```

### 2. 完整部署流程（一条命令搞定）

```bash
make full-setup
```

这个命令会自动：
1. 部署所有合约
2. 更新 `matcher/config.toml`
3. 更新 `orderbook-app/src/config.js`
4. 下 10 个测试订单

### 3. 启动 Matcher（新终端）

```bash
cd matcher
cargo run --release
```

### 4. 启动前端（新终端）

```bash
cd orderbook-app
npm run dev
```

## 分步操作

如果你想分步执行：

### 部署合约

```bash
make deploy
```

### 更新配置文件

```bash
make update-config
# 或
npm run update-config
# 或
node update_config.js
```

### 下测试订单

```bash
make place-orders
```

### 查看当前部署信息

```bash
make show-config
# 或
cat deployments.json
```

## 配置文件说明

### deployments.json

部署脚本自动生成，包含所有合约地址：

```json
{
  "weth": "0x...",
  "usdc": "0x...",
  "account": "0x...",
  "orderbook": "0x...",
  "sequencer": "0x...",
  "pairId": "0x...",
  "deployer": "0x..."
}
```

### 自动更新的配置文件

1. **matcher/config.toml** - Matcher 配置（通过 `build.rs` 在编译时自动更新）
2. **orderbook-app/src/config.js** - 前端配置（通过 `update_config.js` 更新）
3. **script/PlaceTestOrders.s.sol** - 测试脚本（运行时自动读取）

## 工作流程

```
部署合约 → 生成 deployments.json → 自动更新所有配置 → 开始测试
   ↓
deploy.s.sol
   ↓
deployments.json
   ↓
   ├─→ matcher/build.rs (编译时自动更新 config.toml)
   └─→ update_config.js (更新 orderbook-app/src/config.js)
   ↓
PlaceTestOrders.s.sol（运行时自动读取 deployments.json）
```

### Matcher 配置自动更新机制

Matcher 使用 Rust 的 `build.rs` 在**编译时**自动更新配置：

1. 每次运行 `cargo build` 或 `cargo run` 时
2. `build.rs` 自动读取 `../deployments.json`
3. 自动更新 `config.toml` 中的合约地址
4. 无需手动运行任何脚本！

```bash
cd matcher
cargo build  # config.toml 自动更新！
```

## 注意事项

1. **每次部署后自动更新**：使用 `make full-setup` 或 `make deploy && make update-config`
2. **测试脚本自动读取**：`script/PlaceTestOrders.s.sol` 运行时自动从 `deployments.json` 读取地址
3. **无需手动修改**：所有地址配置都自动管理

## Makefile 命令一览

```bash
# 部署和配置
make deploy          # 部署合约
make update-config   # 更新配置文件
make full-setup      # 完整流程（推荐）
make place-orders    # 下测试订单
make show-config     # 显示部署信息

# 开发测试
make build          # 编译合约
make test           # 运行测试
make test-v         # 详细测试输出
make clean          # 清理编译产物

# 节点
make anvil          # 启动本地节点
```

## 常见问题

### Q: 重新部署后需要做什么？

**A:** 只需运行：
```bash
make deploy
make update-config
```

或者直接：
```bash
make full-setup
```

### Q: 如何验证配置是否正确？

**A:** 运行：
```bash
make show-config
```

### Q: 配置更新失败怎么办？

**A:** 确保：
1. `deployments.json` 存在
2. Node.js 已安装
3. 文件权限正确

手动运行：
```bash
node update_config.js
```
