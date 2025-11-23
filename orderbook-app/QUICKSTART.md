# OrderBook App 快速开始 🚀

3 步启动 React Native 监控应用。

## 前置要求

- ✅ Node.js (>= 16.x)
- ✅ 已部署的合约（运行过 `test_matcher.sh`）
- ✅ Anvil 本地节点正在运行

## 快速开始

### 步骤 1: 安装依赖

```bash
cd orderbook-app
npm install
```

### 步骤 2: 更新合约配置

```bash
./update-config.sh
```

这个脚本会自动从 `../deployments.json` 读取合约地址并更新 `config.js`。

### 步骤 3: 启动应用

```bash
npm start
```

然后：
- 按 `w` 在浏览器中打开
- 按 `i` 在 iOS 模拟器中打开（需要 macOS）
- 按 `a` 在 Android 模拟器中打开（需要 Android Studio）

## 完整测试流程

### 终端 1: 启动 Anvil

```bash
anvil
```

### 终端 2: 部署合约

```bash
cd /Users/xingao/orderbook
./test_matcher.sh
```

### 终端 3: 启动 Matcher

```bash
cd /Users/xingao/orderbook/matcher
cargo run -- --log-level debug
```

### 终端 4: 启动 App

```bash
cd /Users/xingao/orderbook/orderbook-app
npm install
./update-config.sh
npm start
```

## 期望效果

### 订单簿页面

你应该看到：
- ✅ 买单 (Bid) 区域显示 3 个价格层级
  - 2000.00 USDC
  - 1950.00 USDC
  - 1900.00 USDC
- ✅ 每个层级显示数量 1.0000 WETH
- ✅ 绿色成交量柱状图
- ✅ 自动刷新（每 3 秒）

### 队列状态页面

如果 Matcher 已处理完所有订单：
- ✅ 队列长度: 0
- ✅ 待处理请求: 队列为空

如果有新订单在队列中：
- ✅ 显示待处理请求数量
- ✅ 列出每个请求的详细信息

## 测试实时更新

### 1. 下一个新订单

在另一个终端运行：

```bash
cd /Users/xingao/orderbook

# 使用 cast 下单
SEQUENCER=$(jq -r '.sequencer' deployments.json)
PAIR_ID=$(cast keccak "WETH/USDC")
USER_KEY="0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"

cast send $SEQUENCER \
  "placeLimitOrder(bytes32,bool,uint256,uint256)" \
  $PAIR_ID \
  false \
  185000000000 \
  100000000 \
  --rpc-url http://127.0.0.1:8545 \
  --private-key $USER_KEY
```

观察 App：
- ✅ 队列状态页面应显示新请求
- ✅ Matcher 处理后，订单簿页面自动刷新
- ✅ 新的价格层级出现（1850.00 USDC）

### 2. 监听实时事件

查看 App 控制台（按 `j` 打开），应该看到：

```
✅ Contract service initialized
Pair ID: 0x...
✅ Subscribed to contract events
📡 Received event: OrderRequested
📝 Order requested: {...}
📡 Received event: OrderPlaced
📌 Order placed: {...}
```

## Web 开发模式

如果你主要在浏览器中测试，可以直接运行：

```bash
npm run web
```

这会自动打开浏览器并启动开发服务器。

## 故障排查

### 问题: "Failed to connect to WebSocket"

**解决**: 确保 Anvil 正在运行

```bash
# 检查 Anvil 是否运行
lsof -i :8545
```

### 问题: "Failed to get trading pair data"

**解决**: 检查合约地址配置

```bash
# 查看 config.js
cat config.js

# 重新生成配置
./update-config.sh
```

### 问题: 页面空白或报错

**解决**: 清除缓存并重启

```bash
# 清除缓存
npm start -- --clear

# 或强制重新安装
rm -rf node_modules package-lock.json
npm install
npm start
```

## 自定义配置

编辑 `config.js` 修改：

```javascript
export const CONFIG = {
  // 修改刷新间隔（毫秒）
  REFRESH_INTERVAL: 5000, // 5 秒

  // 修改显示深度
  DEPTH_LEVELS: 5, // 只显示前 5 层

  // 切换到主网或测试网
  RPC_URL: 'wss://sepolia.infura.io/ws/v3/YOUR_KEY',
  CHAIN_ID: 11155111, // Sepolia
};
```

## 下一步

- 📖 查看完整文档: [README.md](README.md)
- 🔧 了解项目结构和技术细节
- 🚀 扩展功能：添加下单、撤单等交互功能

## 清理

停止所有进程 (Ctrl+C)，重新开始：

```bash
# 重启 Anvil（会创建新链）
anvil

# 重新部署
cd /Users/xingao/orderbook
./test_matcher.sh

# 更新 App 配置
cd orderbook-app
./update-config.sh

# 重新运行 App
npm start
```
