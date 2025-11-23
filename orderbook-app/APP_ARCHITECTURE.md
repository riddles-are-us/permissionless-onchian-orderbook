# OrderBook App 架构文档

## 概述

这是一个基于 React Native + Expo 的订单簿监控应用，通过 ethers.js 与智能合约交互，实时显示订单簿深度和 Sequencer 队列状态。

## 技术选型

### 前端框架
- **React Native 0.73.0**: 跨平台移动应用框架
- **Expo ~50.0.0**: 简化开发和部署流程
- **React 18.2.0**: UI 组件库

### 区块链交互
- **ethers.js 6.10.0**: 以太坊合约交互库
  - 支持 WebSocket 实时订阅
  - 提供完整的合约调用和事件监听
  - 类型安全的 ABI 绑定

### 开发工具
- **Babel**: JavaScript 编译器
- **React Native Reanimated**: 动画库
- **Async Storage**: 本地存储（未来扩展用）

## 架构设计

### 分层架构

```
┌─────────────────────────────────────────┐
│           App.js (主应用)                │
│  - 标签页管理                            │
│  - 全局刷新控制                          │
│  - 路由和导航                            │
└─────────────────────────────────────────┘
              ↓
┌─────────────────────────────────────────┐
│         Components (组件层)              │
│  - OrderBookDepth: 订单簿可视化          │
│  - SequencerStatus: 队列状态显示         │
└─────────────────────────────────────────┘
              ↓
┌─────────────────────────────────────────┐
│          Hooks (业务逻辑层)              │
│  - useOrderBook: 订单簿数据管理          │
│  - useSequencer: 队列数据管理            │
│  - useRealtimeUpdates: 事件订阅          │
└─────────────────────────────────────────┘
              ↓
┌─────────────────────────────────────────┐
│        Services (服务层)                 │
│  - ContractService: 合约交互单例         │
│    * 连接管理                            │
│    * 合约调用                            │
│    * 事件订阅                            │
└─────────────────────────────────────────┘
              ↓
┌─────────────────────────────────────────┐
│        Utils (工具层)                    │
│  - format.js: 数据格式化工具             │
└─────────────────────────────────────────┘
              ↓
┌─────────────────────────────────────────┐
│     Smart Contracts (合约层)             │
│  - OrderBook.sol                         │
│  - Sequencer.sol                         │
│  - Account.sol                           │
└─────────────────────────────────────────┘
```

## 核心模块详解

### 1. ContractService (服务单例)

**职责**: 管理所有区块链交互

**生命周期**:
```javascript
// 初始化（应用启动时）
await contractService.init();

// 使用阶段
const pairData = await contractService.getTradingPairData();
const depth = await contractService.getOrderBookDepth(false, 10);

// 清理（应用关闭时）
await contractService.close();
```

**核心方法**:
```javascript
class ContractService {
  // 初始化
  async init() {
    this.provider = new ethers.WebSocketProvider(RPC_URL);
    this.orderbook = new ethers.Contract(address, abi, provider);
    this.sequencer = new ethers.Contract(address, abi, provider);
    this.pairId = ethers.id(DEFAULT_PAIR);
  }

  // 获取交易对数据
  async getTradingPairData() {
    // 调用: orderbook.getTradingPairData(pairId)
    // 返回: { bidHead, askHead, lastPrice, volume24h }
  }

  // 获取价格层级
  async getPriceLevel(levelId) {
    // 调用: orderbook.priceLevels(levelId)
    // 返回: { price, totalVolume, headOrderId, ... }
  }

  // 遍历获取深度
  async getOrderBookDepth(isAsk, maxLevels) {
    // 1. 获取头部层级 ID
    // 2. 遍历链表获取所有层级
    // 3. 返回层级数组
  }

  // 获取队列状态
  async getSequencerStatus() {
    // 调用: sequencer.queueHead(), queueTail()
    // 遍历队列计算长度
    // 返回: { queueHead, queueTail, queueLength }
  }

  // 订阅事件
  subscribeToEvents(callback) {
    this.orderbook.on('OrderPlaced', (...args) => {
      callback({ type: 'OrderPlaced', data: {...} });
    });
    // 订阅其他事件...
  }
}
```

**设计模式**: 单例模式
- 全局只有一个实例
- 避免重复创建 WebSocket 连接
- 统一管理合约实例

### 2. Custom Hooks

#### useOrderBook

**职责**: 管理订单簿数据的获取和刷新

```javascript
export function useOrderBook() {
  const [bidLevels, setBidLevels] = useState([]);
  const [askLevels, setAskLevels] = useState([]);
  const [loading, setLoading] = useState(true);

  const loadOrderBook = useCallback(async () => {
    const data = await contractService.getTradingPairData();
    const bids = await contractService.getOrderBookDepth(false, 10);
    const asks = await contractService.getOrderBookDepth(true, 10);
    setBidLevels(bids);
    setAskLevels(asks);
  }, []);

  useEffect(() => {
    loadOrderBook();
    const interval = setInterval(loadOrderBook, REFRESH_INTERVAL);
    return () => clearInterval(interval);
  }, [loadOrderBook]);

  return { bidLevels, askLevels, loading, refresh: loadOrderBook };
}
```

**关键特性**:
- 初始化时自动加载数据
- 定时自动刷新（3 秒间隔）
- 提供手动刷新方法
- 清理定时器防止内存泄漏

#### useSequencer

**职责**: 管理 Sequencer 队列数据

```javascript
export function useSequencer() {
  const [status, setStatus] = useState(null);
  const [requests, setRequests] = useState([]);

  const loadSequencer = useCallback(async () => {
    const status = await contractService.getSequencerStatus();
    const requests = await contractService.getQueuedRequests(10);
    setStatus(status);
    setRequests(requests);
  }, []);

  // 初始化和定时刷新逻辑与 useOrderBook 相同
  return { status, requests, loading, refresh: loadSequencer };
}
```

#### useRealtimeUpdates

**职责**: 管理实时事件订阅

```javascript
export function useRealtimeUpdates({ onOrderPlaced, onOrderRemoved, onOrderRequested }) {
  const handleEvent = useCallback((event) => {
    switch (event.type) {
      case 'OrderPlaced':
        onOrderPlaced?.(event.data);
        break;
      case 'OrderRemoved':
        onOrderRemoved?.(event.data);
        break;
      case 'OrderRequested':
        onOrderRequested?.(event.data);
        break;
    }
  }, [onOrderPlaced, onOrderRemoved, onOrderRequested]);

  useEffect(() => {
    contractService.subscribeToEvents(handleEvent);
    return () => contractService.unsubscribeFromEvents();
  }, [handleEvent]);
}
```

**关键特性**:
- 组件挂载时自动订阅
- 组件卸载时自动清理
- 通过回调将事件传递给父组件

### 3. Components

#### OrderBookDepth

**职责**: 可视化订单簿深度

**UI 结构**:
```
┌──────────────────────────────────┐
│  卖单 (Ask) - 红色               │
│  ┌────────────────────────────┐  │
│  │ 2050.00  1.5000  ░░░░░░    │  │
│  │ 2040.00  2.0000  ░░░░░░░░  │  │
│  └────────────────────────────┘  │
├──────────────────────────────────┤
│  最新价: 2000.00                 │
├──────────────────────────────────┤
│  买单 (Bid) - 绿色               │
│  ┌────────────────────────────┐  │
│  │ 2000.00  1.0000  ████████  │  │
│  │ 1950.00  1.0000  ████████  │  │
│  └────────────────────────────┘  │
└──────────────────────────────────┘
```

**渲染逻辑**:
```javascript
const renderLevel = ({ item }, isBid) => (
  <View style={styles.levelRow}>
    {/* 价格和数量 */}
    <Text style={isBid ? styles.bidPrice : styles.askPrice}>
      {formatPrice(item.price)}
    </Text>
    <Text>{formatAmount(item.volume)}</Text>

    {/* 成交量柱状图 */}
    <View style={[
      styles.volumeBar,
      { width: `${calculateBarWidth(item.volume)}%` },
      isBid ? styles.bidBar : styles.askBar,
    ]} />
  </View>
);
```

**关键特性**:
- 买单绿色、卖单红色
- 成交量用柱状图表示
- 支持空状态显示
- 支持下拉刷新

#### SequencerStatus

**职责**: 显示队列状态和待处理请求

**UI 结构**:
```
┌────────────────────────────────────┐
│ 统计卡片区                          │
│ ┌────────┐ ┌────────┐ ┌────────┐  │
│ │队列长度│ │头部 ID │ │尾部 ID │  │
│ │   3    │ │   5    │ │   7    │  │
│ └────────┘ └────────┘ └────────┘  │
├────────────────────────────────────┤
│ 待处理请求                          │
│ ┌────────────────────────────────┐ │
│ │ #5 [下单]                       │ │
│ │ 类型: 限价                      │ │
│ │ 方向: 买入 (绿色)               │ │
│ │ 价格: 2000.00 USDC              │ │
│ │ 数量: 1.0000 WETH               │ │
│ │ 用户: 0x1234...5678             │ │
│ └────────────────────────────────┘ │
└────────────────────────────────────┘
```

**关键特性**:
- 队列头高亮显示（绿色边框）
- 区分下单和撤单请求
- 显示完整订单参数
- 支持滚动查看更多请求

### 4. Utils

#### format.js

**职责**: 数据格式化工具

```javascript
// 价格格式化 (10^8 精度 → 2 位小数)
formatPrice('200000000000') → '2000.00'

// 数量格式化 (10^8 精度 → 4 位小数)
formatAmount('100000000') → '1.0000'

// 时间戳格式化
formatTimestamp(1700000000) → '12:34:56'

// 地址缩短
shortenAddress('0x1234...abcd') → '0x1234...abcd'
```

**实现细节**:
```javascript
export function formatPrice(price) {
  const priceNum = BigInt(price);
  const decimals = BigInt(10 ** 8);
  const integerPart = priceNum / decimals;
  const fractionalPart = priceNum % decimals;
  const fraction = fractionalPart.toString().padStart(8, '0').substring(0, 2);
  return `${integerPart}.${fraction}`;
}
```

## 数据流

### 初始化流程

```
App 启动
  ↓
App.js useEffect
  ↓
useOrderBook / useSequencer 初始化
  ↓
ContractService.init()
  ↓
创建 WebSocket Provider
  ↓
创建 Contract 实例
  ↓
首次加载数据
  ↓
启动定时刷新
  ↓
订阅实时事件
```

### 数据刷新流程

```
定时器触发 (3秒)
  ↓
loadOrderBook()
  ↓
contractService.getTradingPairData()
  ↓
contractService.getOrderBookDepth(false, 10)  // 买单
  ↓
contractService.getOrderBookDepth(true, 10)   // 卖单
  ↓
setState 更新组件
  ↓
OrderBookDepth 重新渲染
```

### 事件订阅流程

```
useRealtimeUpdates 初始化
  ↓
contractService.subscribeToEvents(callback)
  ↓
orderbook.on('OrderPlaced', handler)
sequencer.on('OrderRequested', handler)
  ↓
事件触发
  ↓
执行回调 (onOrderPlaced, onOrderRequested)
  ↓
延迟 1 秒后触发刷新
  ↓
自动更新 UI
```

## 状态管理

### 全局状态

**ContractService** (单例)
- `provider`: WebSocket Provider 实例
- `orderbook`: OrderBook 合约实例
- `sequencer`: Sequencer 合约实例
- `pairId`: 当前交易对 ID

### 组件状态

**useOrderBook**
- `bidLevels`: 买单价格层级数组
- `askLevels`: 卖单价格层级数组
- `pairData`: 交易对数据
- `loading`: 加载状态
- `error`: 错误信息

**useSequencer**
- `status`: 队列状态 (queueHead, queueTail, queueLength)
- `requests`: 待处理请求数组
- `loading`: 加载状态
- `error`: 错误信息

**App.js**
- `activeTab`: 当前激活的标签页 ('orderbook' | 'sequencer')

## 性能优化

### 1. 单例模式
- ContractService 使用单例
- 避免重复创建 WebSocket 连接
- 复用合约实例

### 2. 按需加载
- 只加载当前标签页数据
- 切换标签页时才加载对应数据

### 3. 缓存策略
- 价格层级数据可以缓存（未来优化）
- 减少重复的链上读取

### 4. 防抖和节流
- 事件触发后延迟 1 秒刷新
- 避免短时间内多次刷新

### 5. 限制数据量
- 订单簿深度最多 10 层
- 队列请求最多 10 个
- 避免一次性加载过多数据

## 错误处理

### 网络错误
```javascript
try {
  const data = await contractService.getTradingPairData();
} catch (error) {
  console.error('Failed to load data:', error);
  setError(error.message);
}
```

### 显示错误
```javascript
{error && (
  <View style={styles.errorContainer}>
    <Text style={styles.errorText}>错误: {error}</Text>
  </View>
)}
```

### 降级处理
- 网络失败时显示错误信息
- 数据为空时显示"暂无数据"
- 加载中显示 Loading 状态

## 测试策略

### 单元测试 (未实现)
- 测试 format.js 工具函数
- 测试 ContractService 方法

### 集成测试
- 使用 Anvil 本地节点
- 部署测试合约
- 运行 App 验证功能

### 端到端测试
```bash
# 1. 启动 Anvil
anvil

# 2. 部署合约
./test_matcher.sh

# 3. 启动 Matcher
cd matcher && cargo run

# 4. 启动 App
cd orderbook-app && npm start

# 5. 下新订单测试
cast send $SEQUENCER placeLimitOrder(...)

# 6. 验证 App 显示更新
```

## 部署

### Web 部署
```bash
npm run web
# 构建生产版本
expo build:web
```

### iOS 部署
```bash
# 开发版本
npm run ios

# 生产版本
expo build:ios
```

### Android 部署
```bash
# 开发版本
npm run android

# 生产版本
expo build:android
```

## 配置管理

### 开发环境
```javascript
RPC_URL: 'ws://127.0.0.1:8545'
CHAIN_ID: 31337
```

### 测试网
```javascript
RPC_URL: 'wss://sepolia.infura.io/ws/v3/YOUR_KEY'
CHAIN_ID: 11155111
```

### 主网
```javascript
RPC_URL: 'wss://mainnet.infura.io/ws/v3/YOUR_KEY'
CHAIN_ID: 1
```

## 安全考虑

### 1. RPC 端点安全
- 不在代码中硬编码私钥
- 使用环境变量管理敏感配置

### 2. 合约地址验证
- 确认合约地址正确
- 避免连接到恶意合约

### 3. 数据校验
- 验证链上返回的数据格式
- 防止显示异常数据

## 未来扩展

### 功能扩展
- 钱包连接 (MetaMask, WalletConnect)
- 下单和撤单功能
- 用户持仓管理
- 交易历史记录

### 性能优化
- 实现数据缓存
- 使用 Redux 统一状态管理
- 优化大列表渲染 (VirtualizedList)

### UI/UX 改进
- 深度图可视化
- K 线图展示
- 价格提醒
- 暗黑模式切换

## 参考资料

- [React Native 文档](https://reactnative.dev/)
- [Expo 文档](https://docs.expo.dev/)
- [ethers.js 文档](https://docs.ethers.org/)
- [Solidity 文档](https://docs.soliditylang.org/)
