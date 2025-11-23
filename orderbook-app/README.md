# OrderBook Monitor App

React Native 应用，用于实时监控 OrderBook 订单簿状态和 Sequencer 队列状态。

## 功能特性

### 📊 订单簿深度展示
- 实时显示买单 (Bid) 和卖单 (Ask) 深度
- 价格层级可视化，带有成交量柱状图
- 支持自动刷新和手动下拉刷新
- 最多显示 10 层深度

### 📦 Sequencer 队列状态
- 显示队列统计信息（长度、头部 ID、尾部 ID）
- 列出待处理的请求详情
- 区分下单和撤单请求
- 显示订单参数（价格、数量、方向等）

### 🔔 实时事件监听
- 自动订阅智能合约事件
- 监听 OrderPlaced、OrderRemoved、OrderRequested 事件
- 事件触发后自动刷新相关数据

## 技术栈

- **React Native** (0.73.0) - 使用 Expo 框架
- **ethers.js** (6.10.0) - 以太坊合约交互
- **WebSocket** - 实时区块链数据订阅

## 前置要求

### 开发环境
- Node.js (>= 16.x)
- npm 或 yarn
- Expo CLI

### 区块链环境
- 已部署的 OrderBook 合约
- 已部署的 Sequencer 合约
- WebSocket RPC 节点（如 Anvil 本地节点）

## 安装和配置

### 1. 安装依赖

```bash
cd orderbook-app
npm install
# 或
yarn install
```

### 2. 配置合约地址

编辑 `config.js` 文件，更新以下配置：

```javascript
export const CONFIG = {
  // RPC 节点地址
  RPC_URL: 'ws://127.0.0.1:8545', // 本地 Anvil 节点
  // RPC_URL: 'wss://mainnet.infura.io/ws/v3/YOUR_KEY', // 主网

  CHAIN_ID: 31337, // Anvil 链 ID

  // 合约地址 - 从部署结果获取
  CONTRACTS: {
    ACCOUNT: '0x5FbDB2315678afecb367f032d93F642f64180aa3',
    ORDERBOOK: '0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512',
    SEQUENCER: '0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0',
  },

  // 交易对
  DEFAULT_PAIR: 'WETH/USDC',

  // 精度
  PRICE_DECIMALS: 8,
  AMOUNT_DECIMALS: 8,

  // 刷新间隔（毫秒）
  REFRESH_INTERVAL: 3000,

  // 订单簿深度显示层级数
  DEPTH_LEVELS: 10,
};
```

**从部署文件自动更新配置：**

如果你使用了 `test_matcher.sh` 部署脚本，可以从 `deployments.json` 获取合约地址：

```bash
# 在项目根目录执行
cd /Users/xingao/orderbook
cat deployments.json

# 更新 config.js 中的合约地址
```

### 3. 更新合约 ABI

如果合约代码有更新，需要重新生成 ABI 文件：

```bash
# 在项目根目录执行
cd /Users/xingao/orderbook

# 编译合约
forge build

# 复制 ABI 到 React Native 项目
jq .abi out/OrderBook.sol/OrderBook.json > orderbook-app/src/contracts/OrderBook.json
jq .abi out/Sequencer.sol/Sequencer.json > orderbook-app/src/contracts/Sequencer.json
```

## 运行应用

### 启动本地区块链节点

首先确保本地 Anvil 节点正在运行：

```bash
# 终端 1
anvil
```

### 部署合约并准备测试数据

```bash
# 终端 2
cd /Users/xingao/orderbook
./test_matcher.sh
```

### 启动 React Native 应用

```bash
# 终端 3
cd orderbook-app
npm start
# 或
expo start
```

### 选择运行平台

- **Web**: 在浏览器中按 `w`
- **iOS 模拟器**: 按 `i`（需要 macOS 和 Xcode）
- **Android 模拟器**: 按 `a`（需要 Android Studio）
- **物理设备**: 扫描二维码使用 Expo Go 应用

## 使用说明

### 订单簿页面

1. **查看深度**:
   - 上半部分显示卖单（红色），价格从低到高
   - 下半部分显示买单（绿色），价格从高到低
   - 每一行显示价格和对应的成交量

2. **成交量可视化**:
   - 每行右侧的彩色条表示成交量大小
   - 买单为绿色，卖单为红色

3. **刷新数据**:
   - 下拉刷新手动更新
   - 每 3 秒自动刷新
   - 监听到新事件时自动刷新

### 队列状态页面

1. **队列统计**:
   - 队列长度：当前待处理请求数量
   - 队列头部 ID：下一个要处理的请求 ID
   - 队列尾部 ID：最新加入的请求 ID

2. **请求列表**:
   - 显示最多 10 个待处理请求
   - 第一个请求（队列头）有绿色边框高亮
   - 显示请求类型（下单/撤单）、订单详情、用户地址、时间戳

3. **请求详情**:
   - **下单请求**: 显示订单类型、方向、价格、数量
   - **撤单请求**: 显示要取消的订单 ID

## 项目结构

```
orderbook-app/
├── App.js                          # 主应用组件
├── config.js                       # 配置文件
├── package.json                    # 依赖管理
├── app.json                        # Expo 配置
├── babel.config.js                 # Babel 配置
├── src/
│   ├── components/
│   │   ├── OrderBookDepth.js      # 订单簿深度组件
│   │   └── SequencerStatus.js     # Sequencer 状态组件
│   ├── hooks/
│   │   ├── useOrderBook.js        # 订单簿数据 Hook
│   │   ├── useSequencer.js        # Sequencer 数据 Hook
│   │   └── useRealtimeUpdates.js  # 实时更新 Hook
│   ├── services/
│   │   └── ContractService.js     # 合约交互服务
│   ├── utils/
│   │   └── format.js              # 格式化工具函数
│   └── contracts/
│       ├── OrderBook.json         # OrderBook ABI
│       └── Sequencer.json         # Sequencer ABI
└── README.md                       # 本文件
```

## 数据格式说明

### 价格精度
- 链上价格使用 8 位小数精度
- 显示时格式化为 2 位小数
- 例如: 链上 `200000000000` = 显示 `2000.00 USDC`

### 数量精度
- 链上数量使用 8 位小数精度
- 显示时格式化为 4 位小数
- 例如: 链上 `100000000` = 显示 `1.0000 WETH`

## 故障排查

### 问题 1: 无法连接到节点

**症状**: `Failed to connect to WebSocket`

**解决方案**:
1. 确保 Anvil 正在运行 (`anvil`)
2. 检查 `config.js` 中的 `RPC_URL` 是否正确
3. 确认端口 8545 未被占用

### 问题 2: 合约调用失败

**症状**: `Failed to get trading pair data`

**解决方案**:
1. 确认合约已正确部署
2. 检查 `config.js` 中的合约地址是否正确
3. 确认交易对已在 Account 合约中注册

### 问题 3: ABI 文件错误

**症状**: `Cannot read properties of undefined`

**解决方案**:
1. 重新编译合约: `forge build`
2. 重新复制 ABI 文件到 `src/contracts/`
3. 清除缓存并重启: `expo start -c`

### 问题 4: 数据不刷新

**症状**: 页面显示旧数据

**解决方案**:
1. 检查网络连接
2. 手动下拉刷新
3. 查看控制台是否有错误日志
4. 重启应用

### 问题 5: 实时事件不触发

**症状**: 新订单不自动更新

**解决方案**:
1. 确认使用 WebSocket 连接（不是 HTTP）
2. 检查事件订阅是否成功（查看 "Subscribed to contract events" 日志）
3. 确认合约确实触发了事件

## 性能优化建议

1. **降低刷新频率**: 修改 `REFRESH_INTERVAL` 为更大的值（如 5000ms）
2. **减少深度层级**: 修改 `DEPTH_LEVELS` 为更小的值（如 5）
3. **限制队列请求数**: 在 `ContractService.js` 中调整 `maxRequests` 参数

## 下一步功能

- [ ] 添加订单撮合历史记录
- [ ] 显示 24 小时成交量和价格走势图
- [ ] 支持切换不同交易对
- [ ] 添加用户钱包连接功能
- [ ] 实现下单和撤单功能
- [ ] 添加价格提醒功能
- [ ] 支持多链切换

## 许可证

MIT
