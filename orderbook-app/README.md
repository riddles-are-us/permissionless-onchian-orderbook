# OrderBook Monitor - React Web App

基于 React + Vite 的订单簿监控 Web 应用。

## 快速开始

### 1. 安装依赖

```bash
npm install
```

### 2. 配置合约地址

编辑 `src/config.js`，确保合约地址正确（已自动从 deployments.json 更新）：

```javascript
export const CONFIG = {
  RPC_URL: 'ws://127.0.0.1:8545',
  CONTRACTS: {
    ORDERBOOK: '0x...',
    SEQUENCER: '0x...',
  },
  // ...
};
```

### 3. 启动开发服务器

```bash
npm run dev
```

应用将在 http://localhost:3000 打开。

## 功能特性

### 📊 订单簿深度
- 实时显示买单和卖单深度（最多 10 层）
- 价格层级排序（买单从高到低，卖单从低到高）
- 成交量柱状图可视化（绿色买单，红色卖单）
- 自动刷新（每 3 秒）

### 📦 Sequencer 队列状态
- 显示队列统计（长度、头部 ID、尾部 ID）
- 列出待处理请求详情（最多 10 个）
- 区分下单和撤单请求
- 显示订单参数（价格、数量、方向、用户）

### 🔔 实时事件监听
- 自动订阅智能合约事件
- 监听 OrderPlaced、OrderRemoved、OrderRequested
- 事件触发后自动刷新数据

## 技术栈

- **React 18.2** - UI 框架
- **Vite 5.0** - 构建工具
- **ethers.js 6.10** - 区块链交互
- **WebSocket** - 实时数据订阅

## 项目结构

```
orderbook-app/
├── index.html                      # HTML 入口
├── vite.config.js                  # Vite 配置
├── package.json                    # 依赖管理
├── src/
│   ├── main.jsx                    # 应用入口
│   ├── App.jsx                     # 主应用组件
│   ├── App.css                     # 全局样式
│   ├── config.js                   # 配置文件
│   ├── components/                 # UI 组件
│   │   ├── OrderBookDepth.jsx     # 订单簿组件
│   │   ├── OrderBookDepth.css
│   │   ├── SequencerStatus.jsx    # 队列状态组件
│   │   └── SequencerStatus.css
│   ├── hooks/                      # 自定义 Hooks
│   │   ├── useOrderBook.js        # 订单簿数据管理
│   │   ├── useSequencer.js        # 队列数据管理
│   │   └── useRealtimeUpdates.js  # 事件订阅
│   ├── services/                   # 服务层
│   │   └── ContractService.js     # 合约交互单例
│   ├── utils/                      # 工具函数
│   │   └── format.js              # 数据格式化
│   └── contracts/                  # ABI 文件
│       ├── OrderBook.json
│       └── Sequencer.json
└── README.md                       # 本文件
```

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

### 终端 4: 启动 Web App

```bash
cd /Users/xingao/orderbook/orderbook-app
npm install
npm run dev
```

在浏览器打开 http://localhost:3000

### 终端 5: 下新订单测试实时更新

```bash
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

观察浏览器：
- ✅ 队列状态页面显示新请求
- ✅ Matcher 处理后订单簿自动刷新
- ✅ 新价格层级出现（1850.00 USDC）

## 预期效果

### 订单簿页面
- ✅ 显示 3 个买单价格层级（2000.00、1950.00、1900.00 USDC）
- ✅ 每层显示数量（1.0000 WETH）
- ✅ 绿色成交量柱状图
- ✅ 实时自动刷新

### 队列状态页面
- ✅ 初始队列长度 > 0（如果 Matcher 未处理）
- ✅ Matcher 处理后队列长度 → 0
- ✅ 显示每个待处理请求的详细信息

## 构建生产版本

```bash
npm run build
```

构建产物在 `dist/` 目录，可以部署到任何静态文件服务器。

### 预览生产构建

```bash
npm run preview
```

## 配置说明

### 开发环境（本地 Anvil）

```javascript
// src/config.js
RPC_URL: 'ws://127.0.0.1:8545'
CHAIN_ID: 31337
```

### 测试网

```javascript
// src/config.js
RPC_URL: 'wss://sepolia.infura.io/ws/v3/YOUR_KEY'
CHAIN_ID: 11155111
```

### 主网

```javascript
// src/config.js
RPC_URL: 'wss://mainnet.infura.io/ws/v3/YOUR_KEY'
CHAIN_ID: 1
```

## 故障排查

### 问题: WebSocket 连接失败

**症状**: `Failed to connect to WebSocket`

**解决**:
1. 确保 Anvil 正在运行
2. 检查 `src/config.js` 中的 `RPC_URL`
3. 确认端口 8545 未被占用

### 问题: 合约调用失败

**症状**: `Failed to get trading pair data`

**解决**:
1. 确认合约已部署
2. 检查 `src/config.js` 中的合约地址
3. 确认交易对已注册

### 问题: 数据不刷新

**症状**: 显示旧数据

**解决**:
1. 检查浏览器控制台错误
2. 点击底部刷新按钮
3. 刷新浏览器页面

### 问题: 实时事件不触发

**症状**: 新订单不自动更新

**解决**:
1. 确认使用 WebSocket 连接（不是 HTTP）
2. 查看控制台 "Subscribed to contract events" 日志
3. 确认合约确实触发了事件

## 性能优化

### 当前配置
- 刷新间隔: 3 秒
- 显示深度: 10 层
- 队列请求: 最多 10 个

### 优化建议

**减少刷新频率**:
```javascript
// src/config.js
REFRESH_INTERVAL: 5000,  // 5 秒
DEPTH_LEVELS: 5,         // 只显示前 5 层
```

**使用事件驱动**:
- 主要依赖实时事件更新
- 减少定时刷新频率

## 许可证

MIT
