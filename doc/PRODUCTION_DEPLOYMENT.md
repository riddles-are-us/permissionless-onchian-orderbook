# 生产环境完整部署指南

本文档描述如何在全新服务器上部署 OrderBook 系统的完整流程，包括智能合约、数据库和后端服务。

## 系统架构

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   Frontend      │────▶│   Caddy (VPS)   │────▶│   Matcher       │
│   (React)       │     │   反向代理       │     │   (Rust)        │
└─────────────────┘     └─────────────────┘     └─────────────────┘
                                                        │
                              ┌─────────────────────────┼─────────────────────────┐
                              │                         │                         │
                              ▼                         ▼                         ▼
                        ┌───────────┐           ┌───────────┐           ┌───────────┐
                        │  MongoDB  │           │  Sepolia  │           │ Sequencer │
                        │  数据库    │           │   RPC     │           │  合约     │
                        └───────────┘           └───────────┘           └───────────┘
```

## 前置要求

### 服务器要求
- Ubuntu 22.04+ / Debian 12+
- 2+ CPU cores
- 4GB+ RAM
- 20GB+ 磁盘空间

### 网络要求
- 公网 IP 或 Tailscale 内网访问
- 开放端口: 8080 (Matcher API), 27017 (MongoDB)

### 账户要求
- Sepolia ETH (用于部署合约和执行交易)
- RPC 端点 (Infura/Alchemy)

---

## 第一部分：服务器环境准备

### 1.1 安装基础工具

```bash
sudo apt-get update
sudo apt-get install -y git curl build-essential
```

### 1.2 安装 Docker

```bash
sudo apt-get install -y docker.io
sudo usermod -aG docker $USER
# 重新登录以生效
```

### 1.3 安装 Rust

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source ~/.cargo/env
```

### 1.4 安装 Foundry

```bash
curl -L https://foundry.paradigm.xyz | bash
source ~/.bashrc
foundryup
```

### 1.5 安装 tmux (用于后台运行服务)

```bash
sudo apt-get install -y tmux
```

---

## 第二部分：克隆代码

```bash
cd ~
git clone https://github.com/riddles-are-us/permissionless-onchian-orderbook.git
cd permissionless-onchian-orderbook
git submodule update --init --recursive
```

---

## 第三部分：部署智能合约

### 3.1 配置环境变量

创建 `.env` 文件：

```bash
cat > .env << 'EOF'
PRIVATE_KEY=0x你的私钥
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/你的API_KEY
EOF
```

### 3.2 编译合约

```bash
forge build
```

### 3.3 部署到 Sepolia

```bash
source .env
forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --legacy
```

部署成功后会生成 `deployments.json`，包含所有合约地址：

```json
{
  "weth": "0x...",
  "usdc": "0x...",
  "account": "0x...",
  "orderbook": "0x...",
  "sequencer": "0x...",
  "pairId": "0x...",
  "deployer": "0x...",
  "deploymentBlock": 10035090
}
```

---

## 第四部分：配置 Matcher 后端

### 4.1 更新配置文件

编辑 `matcher/config.toml`：

```toml
# OrderBook Matcher 配置

[network]
# RPC WebSocket 端点 (推荐使用 Infura，支持大区块范围查询)
rpc_url = "wss://sepolia.infura.io/ws/v3/你的API_KEY"
chain_id = 11155111

[contracts]
# 从 deployments.json 复制合约地址
sequencer = "0x75dF6282f26480d18d3BaF40C5d2Ee8690142B4C"
orderbook = "0x8F4660A163E6553De2606C5929b9A0F28dc731d4"
account = "0xbf32D5FC164D06c42094A44562fA44DccD205f4b"
trading_pair = "0xe3fd74b5016b57bf4180a8d977a55d749f0f8f76be8d457de0768c85a6acc816"

[sync]
# 从 deployments.json 复制部署区块
start_block = 10035090
sync_historical = true

[matching]
max_batch_size = 100
matching_interval_ms = 3000

[executor]
# 执行者私钥 (需要 Sepolia ETH)
private_key = "0x你的私钥"
gas_price_gwei = 2
gas_limit = 5000000

[mongodb]
enabled = true
uri = "mongodb://localhost:27017"
# 数据库名称使用 orderbook 合约地址
database = "orderbook_0x8F4660A163E6553De2606C5929b9A0F28dc731d4"

[api]
enabled = true
host = "0.0.0.0"
port = 8080
```

### 4.2 RPC 选择说明

| RPC 提供商 | 区块范围限制 | 推荐用途 |
|-----------|-------------|---------|
| Infura | 无限制 | **推荐用于 Matcher** |
| Alchemy Free | 10 区块 | 不推荐 |
| PublicNode | 50000 区块 | 备选 |

---

## 第五部分：启动服务

### 5.1 启动 MongoDB

```bash
docker run -d \
  --name orderbook-mongodb \
  -p 27017:27017 \
  -v mongodb_data:/data/db \
  --restart unless-stopped \
  mongo:7.0
```

验证 MongoDB 运行状态：

```bash
docker ps | grep mongodb
```

### 5.2 编译 Matcher

```bash
cd matcher
cargo build --release
```

### 5.3 启动 Matcher (使用 tmux)

```bash
tmux new-session -d -s matcher 'cd ~/permissionless-onchian-orderbook/matcher && ./target/release/matcher -l info'
```

查看 Matcher 日志：

```bash
tmux attach -t matcher
# 按 Ctrl+B 然后 D 退出 tmux
```

### 5.4 验证服务状态

```bash
# 检查 MongoDB
docker ps | grep mongodb

# 检查 Matcher
curl http://localhost:8080/health
# 应返回: {"success":true,"data":"OK","error":null}

# 检查 Orderbook API
curl "http://localhost:8080/api/v1/orderbook/0xe3fd74b5016b57bf4180a8d977a55d749f0f8f76be8d457de0768c85a6acc816"
```

---

## 第六部分：配置公网访问

### 方案 A：使用 Caddy 反向代理 (推荐)

如果你有 VPS 和域名，可以配置 Caddy 反向代理。

在 VPS 的 `/etc/caddy/Caddyfile` 中添加：

```
matcher.你的域名.com {
    reverse_proxy 服务器IP:8080
}
```

重载 Caddy：

```bash
systemctl reload caddy
```

### 方案 B：使用 Cloudflare Tunnel

```bash
# 安装 cloudflared
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o cloudflared
chmod +x cloudflared
sudo mv cloudflared /usr/local/bin/

# 启动临时隧道
cloudflared tunnel --url http://localhost:8080
```

### 方案 C：直接开放端口

```bash
# 开放防火墙端口 (不推荐用于生产)
sudo ufw allow 8080/tcp
```

---

## 第七部分：配置前端

### 7.1 更新合约地址

编辑前端的 `src/config.ts`：

```typescript
export const CONFIG = {
  RPC_URL: 'wss://ethereum-sepolia-rpc.publicnode.com',
  RPC_HTTP_URL: 'https://ethereum-sepolia-rpc.publicnode.com',
  CHAIN_ID: 11155111,

  CONTRACTS: {
    ACCOUNT: '0xbf32D5FC164D06c42094A44562fA44DccD205f4b' as `0x${string}`,
    ORDERBOOK: '0x8F4660A163E6553De2606C5929b9A0F28dc731d4' as `0x${string}`,
    SEQUENCER: '0x75dF6282f26480d18d3BaF40C5d2Ee8690142B4C' as `0x${string}`,
    WETH: '0x2260B58e71918BcABAae6575BD4Aec8b4E27808a' as `0x${string}`,
    USDC: '0x03f0204385231CDD9FF7DDd60916915890e575c7' as `0x${string}`,
  },

  PAIR_ID: '0xe3fd74b5016b57bf4180a8d977a55d749f0f8f76be8d457de0768c85a6acc816' as `0x${string}`,
  // ...
};
```

### 7.2 更新 Matcher API URL

编辑前端的 `.env`：

```bash
VITE_USE_MATCHER_API=true
VITE_MATCHER_API_URL=https://matcher.你的域名.com
```

---

## 第八部分：API 端点参考

| 端点 | 方法 | 说明 |
|------|------|------|
| `/health` | GET | 健康检查 |
| `/api/v1/orderbook/{pair_id}` | GET | 获取订单簿 |
| `/api/v1/orders` | GET | 获取所有订单 |
| `/api/v1/orders/{order_id}` | GET | 获取单个订单 |
| `/api/v1/trades` | GET | 获取交易记录 |
| `/api/v1/users/{address}/orders` | GET | 获取用户订单 |
| `/api/v1/users/{address}/orders/active` | GET | 获取用户活跃订单 |
| `/api/v1/klines/{pair_id}` | GET | 获取 K 线数据 |
| `/api/v1/overview` | GET | 系统概览 |

---

## 第九部分：运维命令

### 查看服务状态

```bash
# MongoDB
docker ps | grep mongodb
docker logs orderbook-mongodb

# Matcher
tmux attach -t matcher
```

### 重启服务

```bash
# 重启 MongoDB
docker restart orderbook-mongodb

# 重启 Matcher
tmux kill-session -t matcher
tmux new-session -d -s matcher 'cd ~/permissionless-onchian-orderbook/matcher && ./target/release/matcher -l info'
```

### 查看日志

```bash
# Matcher 日志
tmux capture-pane -t matcher -p | tail -50

# MongoDB 日志
docker logs --tail 50 orderbook-mongodb
```

### 清理数据 (重新同步)

```bash
# 停止 Matcher
tmux kill-session -t matcher

# 清理 MongoDB 数据
docker exec -it orderbook-mongodb mongosh --eval "db.dropDatabase()" orderbook_0x8F4660A163E6553De2606C5929b9A0F28dc731d4

# 重启 Matcher
tmux new-session -d -s matcher 'cd ~/permissionless-onchian-orderbook/matcher && ./target/release/matcher -l info'
```

---

## 第十部分：故障排除

### 问题：Matcher 同步失败，提示区块范围超限

**原因**：RPC 提供商限制了 `eth_getLogs` 的区块范围

**解决方案**：
1. 使用 Infura (无限制)
2. 或修改 `start_block` 为接近当前区块的值
3. 或设置 `sync_historical = false` 禁用历史同步

### 问题：MongoDB 连接失败

**检查**：
```bash
docker ps | grep mongodb
docker logs orderbook-mongodb
```

**解决方案**：
```bash
docker restart orderbook-mongodb
```

### 问题：API 返回空数据

**原因**：新部署的合约没有交易历史

**验证**：这是正常的，等待用户下单后会有数据

### 问题：Gas 不足

**解决方案**：确保执行者钱包有足够的 Sepolia ETH

---

## 当前部署信息 (2026-01-13)

### 合约地址 (Sepolia)

| 合约 | 地址 |
|------|------|
| WETH | `0x2260B58e71918BcABAae6575BD4Aec8b4E27808a` |
| USDC | `0x03f0204385231CDD9FF7DDd60916915890e575c7` |
| Account | `0xbf32D5FC164D06c42094A44562fA44DccD205f4b` |
| OrderBook | `0x8F4660A163E6553De2606C5929b9A0F28dc731d4` |
| Sequencer | `0x75dF6282f26480d18d3BaF40C5d2Ee8690142B4C` |
| 部署区块 | `10035090` |

### 服务地址

| 服务 | 地址 |
|------|------|
| Matcher API (公网) | `https://matcher.app.zkwasm.ai` |
| Matcher API (内网) | `http://100.109.156.120:8080` |
| MongoDB | `mongodb://100.109.156.120:27017` |

### 配置文件

| 文件 | 用途 |
|------|------|
| `deployments.json` | 合约部署信息 |
| `matcher/config.toml` | Matcher 配置 |
| `前端/src/config.ts` | 前端合约配置 |
| `前端/.env` | 前端环境变量 |
