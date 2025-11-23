# OrderBook App 快速开始 ⚡

## 3 步启动

### 1. 安装依赖

```bash
cd orderbook-app
npm install
```

### 2. 启动开发服务器

```bash
npm run dev
```

### 3. 打开浏览器

访问 http://localhost:3000

## 完整测试流程

需要同时运行 5 个终端：

### 终端 1: Anvil 本地节点

```bash
anvil
```

### 终端 2: 部署合约

```bash
cd /Users/xingao/orderbook
./test_matcher.sh
```

### 终端 3: Matcher 引擎

```bash
cd /Users/xingao/orderbook/matcher
cargo run -- --log-level debug
```

### 终端 4: Web App

```bash
cd /Users/xingao/orderbook/orderbook-app
npm run dev
```

### 终端 5: 测试下单

```bash
cd /Users/xingao/orderbook

SEQUENCER=$(jq -r '.sequencer' deployments.json)
PAIR_ID=$(cast keccak "WETH/USDC")
USER_KEY="0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"

# 下一个买单
cast send $SEQUENCER \
  "placeLimitOrder(bytes32,bool,uint256,uint256)" \
  $PAIR_ID \
  false \
  185000000000 \
  100000000 \
  --rpc-url http://127.0.0.1:8545 \
  --private-key $USER_KEY
```

## 预期效果

### 订单簿页面
- ✅ 显示 3 个买单：2000.00, 1950.00, 1900.00 USDC
- ✅ 每层显示 1.0000 WETH
- ✅ 绿色成交量柱状图
- ✅ 每 3 秒自动刷新

### 队列状态页面
- ✅ 队列长度：初始 > 0，Matcher 处理后 → 0
- ✅ 显示待处理请求详情

### 实时更新
- ✅ 下新订单后，队列状态立即更新
- ✅ Matcher 处理后，订单簿自动刷新
- ✅ 控制台显示事件日志

## 配置

编辑 `src/config.js` 修改配置：

```javascript
export const CONFIG = {
  RPC_URL: 'ws://127.0.0.1:8545',  // WebSocket RPC
  REFRESH_INTERVAL: 3000,           // 刷新间隔（毫秒）
  DEPTH_LEVELS: 10,                 // 显示深度
};
```

## 构建生产版本

```bash
npm run build
# 构建产物在 dist/ 目录

npm run preview
# 预览生产版本
```

## 故障排查

### WebSocket 连接失败
- 确保 Anvil 正在运行
- 检查 RPC_URL 配置

### 数据不显示
- 确认合约已部署
- 检查浏览器控制台错误
- 点击底部刷新按钮

### 实时更新不工作
- 确认使用 WebSocket（不是 HTTP）
- 查看控制台 "Subscribed to contract events" 日志

## 详细文档

查看完整文档: [README.md](README.md)
