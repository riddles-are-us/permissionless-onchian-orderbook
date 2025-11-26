# OrderBook Monitor - React Native App

React Native 前端应用，用于实时监控订单簿和队列状态。

## 快速开始

```bash
cd orderbook-app
npm install
./update-config.sh
npm start
```

详细文档请查看: [orderbook-app/README.md](orderbook-app/README.md)

快速开始指南: [orderbook-app/QUICKSTART.md](orderbook-app/QUICKSTART.md)

## 功能特性

### 1. 订单簿深度可视化
- ✅ 实时显示买单和卖单深度
- ✅ 价格层级排序（买单从高到低，卖单从低到高）
- ✅ 成交量柱状图可视化
- ✅ 支持最多 10 层深度显示

### 2. Sequencer 队列状态
- ✅ 显示队列统计（长度、头部 ID、尾部 ID）
- ✅ 列出待处理请求详情
- ✅ 区分下单和撤单请求
- ✅ 显示订单参数（价格、数量、方向）

### 3. 实时事件监听
- ✅ 自动订阅智能合约事件
- ✅ 监听 OrderPlaced、OrderRemoved、OrderRequested
- ✅ 事件触发后自动刷新数据

### 4. 自动刷新
- ✅ 每 3 秒自动刷新数据
- ✅ 支持手动下拉刷新
- ✅ 监听到事件时立即刷新

## 技术架构

### 前端技术栈
- **React Native 0.73.0** - 跨平台移动应用框架
- **Expo** - 开发工具和运行时
- **ethers.js 6.10.0** - 以太坊合约交互
- **WebSocket** - 实时数据订阅

### 项目结构

```
orderbook-app/
├── App.js                          # 主应用组件（标签页、刷新控制）
├── config.js                       # 配置文件（合约地址、RPC、精度）
├── update-config.sh               # 自动更新配置脚本
├── src/
│   ├── components/
│   │   ├── OrderBookDepth.js      # 订单簿深度可视化组件
│   │   └── SequencerStatus.js     # Sequencer 队列状态组件
│   ├── hooks/
│   │   ├── useOrderBook.js        # 订单簿数据管理 Hook
│   │   ├── useSequencer.js        # Sequencer 数据管理 Hook
│   │   └── useRealtimeUpdates.js  # 实时事件订阅 Hook
│   ├── services/
│   │   └── ContractService.js     # 合约交互服务（单例）
│   ├── utils/
│   │   └── format.js              # 格式化工具（价格、数量、地址）
│   └── contracts/
│       ├── OrderBook.json         # OrderBook ABI
│       └── Sequencer.json         # Sequencer ABI
├── README.md                       # 完整文档
└── QUICKSTART.md                  # 快速开始指南
```

## 核心功能实现

### 1. 合约交互服务 (ContractService.js)

```javascript
// 单例模式，管理所有合约交互
class ContractService {
  async init()                       // 初始化连接
  async getTradingPairData()         // 获取交易对数据
  async getPriceLevel(levelId)       // 获取价格层级
  async getOrderBookDepth(isAsk, maxLevels) // 获取深度
  async getSequencerStatus()         // 获取队列状态
  async getQueuedRequests(max)       // 获取队列请求
  subscribeToEvents(callback)        // 订阅事件
  unsubscribeFromEvents()            // 取消订阅
}
```

### 2. 自定义 Hooks

**useOrderBook** - 订单簿数据管理
```javascript
const { bidLevels, askLevels, pairData, loading, error, refresh } = useOrderBook();
```

**useSequencer** - Sequencer 数据管理
```javascript
const { status, requests, loading, error, refresh } = useSequencer();
```

**useRealtimeUpdates** - 实时事件监听
```javascript
useRealtimeUpdates({
  onOrderPlaced: (data) => { /* 处理订单下单事件 */ },
  onOrderRemoved: (data) => { /* 处理订单撤单事件 */ },
  onOrderRequested: (data) => { /* 处理请求事件 */ },
});
```

### 3. 格式化工具 (format.js)

```javascript
formatPrice(price)      // 链上价格 → 人类可读（2 位小数）
formatAmount(amount)    // 链上数量 → 人类可读（4 位小数）
formatTimestamp(ts)     // Unix 时间戳 → HH:MM:SS
shortenAddress(addr)    // 完整地址 → 0x1234...5678
```

## 数据流

```
区块链事件 → WebSocket → ContractService
                              ↓
                         实时事件回调
                              ↓
                    useRealtimeUpdates Hook
                              ↓
                         触发数据刷新
                              ↓
              useOrderBook / useSequencer
                              ↓
                  更新组件状态并重新渲染
                              ↓
          OrderBookDepth / SequencerStatus
```

## 配置说明

### 自动配置（推荐）

```bash
# 运行部署脚本后自动更新配置
./update-config.sh
```

### 手动配置

编辑 `config.js`:

```javascript
export const CONFIG = {
  RPC_URL: 'ws://127.0.0.1:8545',  // WebSocket RPC
  CHAIN_ID: 31337,                  // 链 ID
  CONTRACTS: {
    ORDERBOOK: '0x...',             // OrderBook 地址
    SEQUENCER: '0x...',             // Sequencer 地址
  },
  DEFAULT_PAIR: 'WETH/USDC',        // 交易对
  PRICE_DECIMALS: 8,                // 价格精度
  AMOUNT_DECIMALS: 8,               // 数量精度
  REFRESH_INTERVAL: 3000,           // 刷新间隔（毫秒）
  DEPTH_LEVELS: 10,                 // 显示深度层级
};
```

## 使用场景

### 场景 1: 监控订单簿状态
1. 启动 App，进入"订单簿"页面
2. 查看买单和卖单深度
3. 观察价格层级和成交量
4. 下拉刷新获取最新数据

### 场景 2: 监控 Matcher 处理进度
1. 切换到"队列状态"页面
2. 查看待处理请求数量
3. 观察 Matcher 处理队列的速度
4. 查看请求详情（价格、数量、用户）

### 场景 3: 实时监控新订单
1. App 自动订阅合约事件
2. 用户下新订单时，队列状态自动更新
3. Matcher 处理后，订单簿自动刷新
4. 无需手动刷新，实时看到变化

## 测试流程

### 完整端到端测试

```bash
# 终端 1: 启动本地节点
anvil

# 终端 2: 部署合约并下测试订单
./test_matcher.sh

# 终端 3: 启动 Matcher
cd matcher && cargo run -- --log-level debug

# 终端 4: 启动 App
cd orderbook-app
npm install
./update-config.sh
npm start
# 按 'w' 在浏览器打开

# 终端 5: 下新订单测试实时更新
SEQUENCER=$(jq -r '.sequencer' deployments.json)
PAIR_ID=$(cast keccak "WETH/USDC")
cast send $SEQUENCER \
  "placeLimitOrder(bytes32,bool,uint256,uint256)" \
  $PAIR_ID false 185000000000 100000000 \
  --rpc-url http://127.0.0.1:8545 \
  --private-key 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
```

### 预期结果

**订单簿页面**:
- ✅ 显示 3-4 个买单价格层级
- ✅ 每层显示价格和数量
- ✅ 绿色成交量柱状图
- ✅ 底部显示 "买单: X | 卖单: Y"

**队列状态页面**:
- ✅ 初始队列长度 > 0
- ✅ Matcher 处理后队列长度 → 0
- ✅ 下新订单后队列长度增加
- ✅ 显示请求详细信息

## 性能优化

### 当前配置
- 刷新间隔: 3 秒
- 显示深度: 10 层
- 队列请求: 最多 10 个

### 优化建议

**减少网络请求频率**:
```javascript
REFRESH_INTERVAL: 5000,  // 5 秒刷新一次
DEPTH_LEVELS: 5,         // 只显示前 5 层
```

**使用事件驱动更新**:
- 依赖实时事件而非定时刷新
- 只在事件触发时更新数据

**缓存价格层级数据**:
- ContractService 已实现本地缓存
- 减少重复的链上读取

## 扩展功能建议

### 短期扩展
- [ ] 添加最新成交价显示
- [ ] 添加 24 小时成交量统计
- [ ] 支持切换不同交易对
- [ ] 添加价格变动百分比

### 中期扩展
- [ ] K 线图展示
- [ ] 深度图可视化
- [ ] 订单撮合历史记录
- [ ] 价格提醒功能

### 长期扩展
- [ ] 连接钱包（MetaMask、WalletConnect）
- [ ] 实现下单和撤单功能
- [ ] 用户持仓和订单管理
- [ ] 多链支持

## 故障排查

### WebSocket 连接失败
```bash
# 确认 Anvil 运行
lsof -i :8545

# 检查 RPC_URL 配置
cat config.js | grep RPC_URL
```

### 合约调用失败
```bash
# 检查合约地址
cat config.js | grep CONTRACTS

# 重新生成配置
./update-config.sh
```

### 数据不刷新
```bash
# 清除缓存
npm start -- --clear

# 重新安装依赖
rm -rf node_modules && npm install
```

## 相关文档

- [README.md](orderbook-app/README.md) - 完整文档
- [QUICKSTART.md](orderbook-app/QUICKSTART.md) - 快速开始
- [TESTING_GUIDE.md](TESTING_GUIDE.md) - 测试指南
- [matcher/USAGE.md](matcher/USAGE.md) - Matcher 使用

## 许可证

MIT
