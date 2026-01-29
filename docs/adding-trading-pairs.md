# 添加新交易对指南

本文档说明如何在 OrderBook 系统中添加新的代币交易对。

## 目录

1. [架构概述](#架构概述)
2. [添加新交易对步骤](#添加新交易对步骤)
3. [Matcher 配置](#matcher-配置)
4. [前端配置](#前端配置)
5. [验证部署](#验证部署)

---

## 架构概述

### 当前支持的交易对

| 交易对 | Pair ID | Base Token | Quote Token |
|--------|---------|------------|-------------|
| ETH/USDC | `keccak256("WETH/USDC")` | WETH (18 decimals) | USDC (6 decimals) |
| BTC/USDC | `keccak256("WBTC/USDC")` | WBTC (8 decimals) | USDC (6 decimals) |

### Matcher 架构说明

**Matcher 现已支持多交易对模式**，单个 Matcher 实例可以同时处理多个交易对。

特性：
- 每个交易对维护独立的 OrderBook Simulator
- 事件处理自动根据 `trading_pair` 字段路由到正确的 orderbook
- 配置文件支持 `trading_pairs` 数组
- 向后兼容单个 `trading_pair` 配置
- **自动读取代币 symbol 和 decimals**（从 ERC20 合约）

---

## 添加新交易对步骤

### 1. 部署代币合约（如果是新代币）

如果需要部署新的测试代币，创建部署脚本：

```solidity
// script/DeployNewToken.s.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {Account as AccountContract} from "../Account.sol";
import {MockERC20} from "../MockERC20.sol";

contract DeployNewTokenScript is Script {
    // 更新为当前部署的合约地址
    address constant ACCOUNT = 0x8EE3a2f7Ba1D0071cD53F06f04E22Ecc35B521dd;
    address constant USDC = 0x092C283EDeF672cC791A5DbfB6BAdc4406A75C48;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        // 1. 部署新代币（根据需要调整名称和小数位）
        // 示例：部署 SOL 代币（9 位小数）
        address newToken = address(new MockERC20("Wrapped SOL", "SOL", 9));
        console.log("New token deployed at:", newToken);

        // 2. 计算交易对 ID
        bytes32 pairId = keccak256("SOL/USDC");
        console.log("Pair ID:", vm.toString(pairId));

        // 3. 注册交易对
        AccountContract(ACCOUNT).registerTradingPair(pairId, newToken, USDC);
        console.log("Trading pair registered");

        vm.stopBroadcast();
    }
}
```

运行部署：

```bash
forge script script/DeployNewToken.s.sol:DeployNewTokenScript \
  --rpc-url https://ethereum-sepolia-rpc.publicnode.com \
  --broadcast \
  --legacy \
  -vvv
```

### 2. 更新 deployments.json

部署完成后，更新 `deployments.json` 添加新代币和交易对信息：

```json
{
  "weth": "0x51F42ee29aa544CfD34Fc8077536701Fcb1cf2Ba",
  "wbtc": "0xdA41B4D98cBDCA4ca36B91309CDF2d2ecdD35d15",
  "sol": "0x...",  // 新代币地址
  "usdc": "0x092C283EDeF672cC791A5DbfB6BAdc4406A75C48",
  "account": "0x8EE3a2f7Ba1D0071cD53F06f04E22Ecc35B521dd",
  "orderbook": "0x7B8469b5D30b72968185C9D6267759112F468D51",
  "sequencer": "0xdDDCE9768e37C14f14AB8161c251dF6d36375524",
  "pairId": "0xe3fd74b5016b57bf4180a8d977a55d749f0f8f76be8d457de0768c85a6acc816",
  "wbtcPairId": "0xc4a4e865aa0aa1da3eb8811d14d304839f3002161a919075a08340898d445010",
  "solPairId": "0x...",  // 新交易对 ID
  "deployer": "0xB3C259f1235A50Bd0B8aA2E588648c106F6F3816",
  "deploymentBlock": 10105369
}
```

### 3. 计算交易对 ID

交易对 ID 使用 `keccak256` 哈希计算：

```bash
# 使用 cast 计算
cast keccak "SOL/USDC"
# 输出: 0x...

# 或在 Solidity 中
bytes32 pairId = keccak256("SOL/USDC");
```

常用交易对 ID：
- `WETH/USDC`: `0xe3fd74b5016b57bf4180a8d977a55d749f0f8f76be8d457de0768c85a6acc816`
- `WBTC/USDC`: `0xc4a4e865aa0aa1da3eb8811d14d304839f3002161a919075a08340898d445010`

---

## Matcher 配置

### 自动发现交易对（推荐）

**Matcher 现已支持自动发现交易对！** 如果不配置 `trading_pairs`，Matcher 会自动从 Account 合约的 `TradingPairRegistered` 事件中发现所有已注册的交易对。

```toml
[contracts]
sequencer = "0xdDDCE9768e37C14f14AB8161c251dF6d36375524"
orderbook = "0x7B8469b5D30b72968185C9D6267759112F468D51"
account = "0x8EE3a2f7Ba1D0071cD53F06f04E22Ecc35B521dd"

# 不需要配置 trading_pairs，Matcher 会自动发现
```

### 手动配置交易对

如果需要只处理特定的交易对，可以手动配置：

```toml
[contracts]
sequencer = "0xdDDCE9768e37C14f14AB8161c251dF6d36375524"
orderbook = "0x7B8469b5D30b72968185C9D6267759112F468D51"
account = "0x8EE3a2f7Ba1D0071cD53F06f04E22Ecc35B521dd"

# 手动指定支持的交易对列表
trading_pairs = [
    "0xe3fd74b5016b57bf4180a8d977a55d749f0f8f76be8d457de0768c85a6acc816",  # ETH/USDC
    "0xc4a4e865aa0aa1da3eb8811d14d304839f3002161a919075a08340898d445010",  # BTC/USDC
]
```

### 重启 Matcher

```bash
# 重新编译（如果有代码更新）
cd matcher && cargo build --release

# 重启 matcher
tmux send-keys -t matcher 'C-c'
tmux send-keys -t matcher 'RUST_LOG=info ./target/release/matcher' Enter
```

### 向后兼容

如果使用旧的单交易对配置格式，Matcher 仍然支持：

```toml
[contracts]
# 单个交易对（向后兼容）
trading_pair = "0xe3fd74b5016b57bf4180a8d977a55d749f0f8f76be8d457de0768c85a6acc816"
```

### 配置优先级

1. 如果配置了 `trading_pairs` 数组，使用该数组
2. 如果只配置了 `trading_pair` 单个值，使用该值
3. 如果都没配置，尝试从 `../deployments.json` 读取
4. 如果 deployments.json 也没有，**自动从链上发现**

---

## API 端点

### 获取所有交易对

```bash
# 获取所有支持的交易对列表
curl http://<SERVER_IP>:<PORT>/api/v1/trading-pairs
```

响应示例：
```json
{
  "success": true,
  "data": {
    "pairs": [
      {
        "pair_id": "0xe3fd74b5016b57bf4180a8d977a55d749f0f8f76be8d457de0768c85a6acc816",
        "ticker": "WETH/USDC",
        "base_token": "0x51f42ee29aa544cfd34fc8077536701fcb1cf2ba",
        "quote_token": "0x092c283edef672cc791a5dbfb6badc4406a75c48",
        "base_symbol": "WETH",
        "quote_symbol": "USDC",
        "base_decimals": 18,
        "quote_decimals": 6,
        "ask_levels": 5,
        "bid_levels": 3,
        "total_orders": 12
      },
      {
        "pair_id": "0xc4a4e865aa0aa1da3eb8811d14d304839f3002161a919075a08340898d445010",
        "ticker": "WBTC/USDC",
        "base_token": "0xda41b4d98cbdca4ca36b91309cdf2d2ecdd35d15",
        "quote_token": "0x092c283edef672cc791a5dbfb6badc4406a75c48",
        "base_symbol": "WBTC",
        "quote_symbol": "USDC",
        "base_decimals": 8,
        "quote_decimals": 6,
        "ask_levels": 2,
        "bid_levels": 4,
        "total_orders": 8
      }
    ],
    "total_count": 2
  }
}
```

### 获取单个交易对概述

```bash
# 获取特定交易对的详细概述
curl http://<SERVER_IP>:<PORT>/api/v1/trading-pairs/<PAIR_ID>/overview
```

响应示例：
```json
{
  "success": true,
  "data": {
    "pair_id": "0xe3fd74b5016b57bf4180a8d977a55d749f0f8f76be8d457de0768c85a6acc816",
    "ticker": "WETH/USDC",
    "base_token": "0x51f42ee29aa544cfd34fc8077536701fcb1cf2ba",
    "quote_token": "0x092c283edef672cc791a5dbfb6badc4406a75c48",
    "base_decimals": 18,
    "quote_decimals": 6,
    "current_block": 10147954,
    "match_id": "262",
    "pending_requests": [],
    "pending_request_count": 0,
    "asks": [],
    "bids": [],
    "market_orders": {
      "total_buy_amount": "0",
      "total_sell_amount": "0",
      "buy_order_count": 0,
      "sell_order_count": 0
    }
  }
}
```

---

## 前端配置

### 更新 config.ts

在前端项目中添加新交易对的配置：

```typescript
// src/config.ts
export const CONFIG = {
  // ...

  CONTRACTS: {
    ACCOUNT: '0x8EE3a2f7Ba1D0071cD53F06f04E22Ecc35B521dd' as `0x${string}`,
    ORDERBOOK: '0x7B8469b5D30b72968185C9D6267759112F468D51' as `0x${string}`,
    SEQUENCER: '0xdDDCE9768e37C14f14AB8161c251dF6d36375524' as `0x${string}`,
    WETH: '0x51F42ee29aa544CfD34Fc8077536701Fcb1cf2Ba' as `0x${string}`,
    WBTC: '0xdA41B4D98cBDCA4ca36B91309CDF2d2ecdD35d15' as `0x${string}`,
    SOL: '0x...' as `0x${string}`,  // 新代币
    USDC: '0x092C283EDeF672cC791A5DbfB6BAdc4406A75C48' as `0x${string}`,
  },

  TRADING_PAIRS: {
    'ETH/USDC': {
      pairId: '0xe3fd74b5016b57bf4180a8d977a55d749f0f8f76be8d457de0768c85a6acc816',
      baseToken: 'WETH',
      quoteToken: 'USDC',
      baseDecimals: 18,
      quoteDecimals: 6,
    },
    'BTC/USDC': {
      pairId: '0xc4a4e865aa0aa1da3eb8811d14d304839f3002161a919075a08340898d445010',
      baseToken: 'WBTC',
      quoteToken: 'USDC',
      baseDecimals: 8,
      quoteDecimals: 6,
    },
    'SOL/USDC': {  // 新交易对
      pairId: '0x...',
      baseToken: 'SOL',
      quoteToken: 'USDC',
      baseDecimals: 9,
      quoteDecimals: 6,
    },
  },
};
```

---

## 验证部署

### 1. 验证合约注册

```bash
# 检查交易对是否已注册
cast call <ACCOUNT_ADDRESS> "tradingPairs(bytes32)(address,address)" <PAIR_ID> --rpc-url <RPC_URL>
```

### 2. 验证 Matcher 运行

```bash
# 检查 Matcher API
curl http://<SERVER_IP>:<PORT>/health

# 检查订单簿
curl http://<SERVER_IP>:<PORT>/orderbook/<PAIR_ID>
```

### 3. 验证 MongoDB 数据

```bash
# 连接 MongoDB
mongosh

# 查看订单
use orderbook
db.orders.find({ trading_pair: "<PAIR_ID>" }).limit(5)
```

---

## 添加交易对检查清单

- [ ] 部署新代币合约（如需要）
- [ ] 在 Account 合约中注册交易对
- [ ] 更新 `deployments.json`（可选，用于前端）
- [ ] 重启 Matcher（会自动发现新交易对）
- [ ] 验证 Matcher API 正常：`curl http://<IP>:<PORT>/api/v1/trading-pairs`
- [ ] 更新前端 `config.ts`
- [ ] 验证前端显示新交易对
- [ ] 测试下单和撮合功能

---

## 常见问题

### Q: Matcher 现在支持多交易对吗？

A: **是的！** Matcher 已更新为支持多交易对模式。单个 Matcher 实例可以同时处理多个交易对。

### Q: 需要手动配置交易对吗？

A: **不需要！** Matcher 现在支持自动发现交易对。如果不配置 `trading_pairs`，Matcher 会自动从 Account 合约的 `TradingPairRegistered` 事件中发现所有已注册的交易对。

### Q: Matcher 如何知道交易对的 ticker 名称？

A: **自动读取！** Matcher 会：
1. 从 Account 合约读取交易对的 `baseToken` 和 `quoteToken` 地址
2. 调用 ERC20 合约的 `symbol()` 和 `decimals()` 方法获取代币信息
3. 自动组合成 ticker（如 "WETH/USDC"）

日志示例：
```
📡 Loading metadata for 2 configured trading pairs...
  📋 Loaded metadata for pair: WETH/USDC (0xe3fd74b5016b57bf)
  📋 Loaded metadata for pair: WBTC/USDC (0xc4a4e865aa0aa1da)
```

### Q: 多个交易对的数据如何区分？

A:
- 每个交易对在内存中维护独立的 OrderBook Simulator
- MongoDB 中的数据按 `trading_pair` 字段区分
- 事件处理自动根据事件中的 `trading_pair` 字段路由到正确的 orderbook

### Q: 如何查看所有支持的交易对？

A: 使用新的 API 端点：
```bash
curl http://<SERVER_IP>:<PORT>/api/v1/trading-pairs
```

### Q: 如何监控 Matcher？

A: 建议：
1. 使用 supervisor 或 systemd 管理进程
2. 使用 Prometheus + Grafana 监控
3. 设置日志聚合（如 ELK Stack）
4. 通过 `/health` API 检查健康状态
5. 通过 `/api/v1/trading-pairs` 检查支持的交易对

---

## 版本历史

| 日期 | 版本 | 变更内容 |
|------|------|----------|
| 2026-01-29 | v1.3 | 自动读取代币 symbol/decimals，API 返回完整 ticker 信息 |
| 2026-01-29 | v1.2 | 自动发现交易对、新增交易对 API 端点 |
| 2026-01-29 | v1.1 | Matcher 支持多交易对模式 |
| 2026-01-29 | v1.0 | 初始版本 |
