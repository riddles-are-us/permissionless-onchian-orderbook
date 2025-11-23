# Matcher 架构设计文档

## 概述

Matcher 是一个链下撮合引擎，负责：
1. 从区块链同步订单簿状态
2. 计算新订单的正确插入位置
3. 批量调用链上合约完成订单插入

## 核心设计原则

### 1. 状态驱动（State-Driven）

所有决策基于本地维护的状态缓存：
- **优点**：快速响应，减少 RPC 调用
- **挑战**：需要保证状态一致性

### 2. 事件驱动（Event-Driven）

通过监听合约事件增量更新状态：
- **优点**：实时性好，资源消耗低
- **挑战**：需要处理事件丢失和重复

### 3. 批量处理（Batch Processing）

批量调用链上合约：
- **优点**：降低 gas 成本，提高吞吐量
- **挑战**：需要权衡批量大小和延迟

## 模块详解

### 1. State（状态管理）

```rust
pub struct GlobalState {
    // Sequencer 请求队列
    queued_requests: DashMap<U256, QueuedRequest>,
    queue_head: RwLock<U256>,

    // OrderBook 缓存
    price_levels: DashMap<TradingPair, PriceLevelCache>,
    orders: DashMap<U256, Order>,
    orderbook_data: DashMap<TradingPair, OrderBookData>,
}
```

**设计要点**：
- 使用 `DashMap` 实现无锁并发访问
- 使用 `RwLock` 保护单值字段
- 按交易对分区存储价格层级

**状态一致性保证**：
1. 单一写入源（事件处理）
2. 原子更新操作
3. 定期状态校验（TODO）

### 2. Sync（状态同步器）

```rust
pub struct StateSynchronizer {
    provider: Provider<Ws>,
    sequencer: Sequencer<Provider<Ws>>,
    orderbook: OrderBook<Provider<Ws>>,
    state: GlobalState,
}
```

**同步流程**：

```
startup()
├─ sync_historical_state()
│   ├─ get_current_block()
│   ├─ sync_sequencer_state()
│   │   ├─ read queue_head
│   │   └─ traverse queue
│   └─ sync_orderbook_state()
│       ├─ read price_levels
│       └─ build price_cache
│
└─ watch_events()
    ├─ subscribe(sequencer.events())
    ├─ subscribe(orderbook.events())
    └─ loop:
        ├─ handle_sequencer_event()
        └─ handle_orderbook_event()
```

**事件处理**：

| 事件 | 来源 | 处理 |
|------|------|------|
| RequestAdded | Sequencer | 添加到队列 |
| RequestProcessed | Sequencer | 从队列移除 |
| PriceLevelCreated | OrderBook | 更新价格索引 |
| OrderInserted | OrderBook | 更新订单状态 |
| OrderRemoved | OrderBook | 移除订单 |

### 3. Matcher（匹配引擎）

```rust
pub struct MatchingEngine {
    orderbook: OrderBook<SignerMiddleware>,
    state: GlobalState,
    config: Config,
}
```

**匹配算法**：

```rust
fn calculate_insert_positions(requests: &[QueuedRequest]) -> MatchResult {
    for request in requests {
        // 1. 获取价格层级缓存
        let cache = get_price_cache(request.trading_pair, request.is_ask);

        // 2. 查找已存在的价格层级
        if let Some(level_id) = cache.get(request.price) {
            return (request.id, level_id, 0);
        }

        // 3. 找到正确的插入位置
        let insert_after = find_position(
            cache,
            request.price,
            request.is_ask
        );

        result.add(request.id, insert_after, 0);
    }
}
```

**插入位置算法**：

对于买单（Bid），价格从高到低：
```
[2000] -> [1950] -> [1900]
  ^         ^         ^
  head               tail

插入 1960:
- 遍历：2000 (1960 < 2000, 继续)
- 遍历：1950 (1960 > 1950, 插入到这里)
- 返回：insertAfter = level_id(2000)
```

对于卖单（Ask），价格从低到高：
```
[2100] -> [2150] -> [2200]
  ^         ^         ^
  head               tail

插入 2140:
- 遍历：2100 (2140 > 2100, 继续)
- 遍历：2150 (2140 < 2150, 插入到这里)
- 返回：insertAfter = level_id(2100)
```

**批量执行**：

```rust
async fn execute_batch(result: &MatchResult) -> Result<()> {
    // 构造交易
    let tx = orderbook.batch_process_requests(
        result.order_ids,
        result.insert_after_price_levels,
        result.insert_after_orders
    )
    .gas_price(config.gas_price * 1e9)
    .gas(config.gas_limit);

    // 发送交易
    let pending = tx.send().await?;

    // 等待确认
    let receipt = pending.await?;

    // 验证结果
    verify_receipt(receipt)?;
}
```

## 性能优化

### 1. 缓存策略

**价格层级缓存**：
```rust
struct PriceLevelCache {
    price_to_level: BTreeMap<U256, U256>,  // 价格 -> 层级ID
    levels: BTreeMap<U256, PriceLevel>,    // 层级ID -> 数据
}
```

**优势**：
- O(log n) 查找时间
- 自动排序
- 减少 RPC 调用

**更新策略**：
- 监听 PriceLevelCreated 事件
- 定期全量刷新（TODO）
- LRU 淘汰策略（TODO）

### 2. 并发处理

```rust
// 状态同步和匹配引擎并行运行
tokio::spawn(synchronizer.run());
tokio::spawn(matcher.run());

// 使用 DashMap 支持并发读写
state.queued_requests  // 多线程安全
state.price_levels     // 多线程安全
```

### 3. 批量大小优化

**权衡**：
- 批量大 → gas 高，吞吐量高，延迟高
- 批量小 → gas 低，吞吐量低，延迟低

**动态调整**（TODO）：
```rust
match queue_size {
    0..10 => batch_size = 10,
    10..50 => batch_size = 50,
    50.. => batch_size = 100,
}
```

## 错误处理

### 1. 网络错误

```rust
// WebSocket 断连重连
loop {
    match watch_events().await {
        Ok(_) => break,
        Err(e) => {
            warn!("Connection lost: {}", e);
            sleep(Duration::from_secs(5)).await;
            // 重新连接
        }
    }
}
```

### 2. 交易失败

```rust
// 交易重试机制
for retry in 0..MAX_RETRIES {
    match execute_batch(result).await {
        Ok(_) => break,
        Err(e) if is_retriable(&e) => {
            warn!("Retry {}/{}: {}", retry, MAX_RETRIES, e);
            increase_gas_price();
        }
        Err(e) => return Err(e),
    }
}
```

### 3. 状态不一致

```rust
// 定期状态校验
async fn verify_state() {
    let chain_head = sequencer.queue_head().await?;
    let local_head = state.queue_head.read();

    if chain_head != *local_head {
        warn!("State mismatch, resyncing...");
        resync_state().await?;
    }
}
```

## 监控指标

### 1. 性能指标

- `matching_latency`: 匹配延迟
- `batch_size`: 批量大小
- `gas_used`: Gas 消耗
- `throughput`: 吞吐量（订单/秒）

### 2. 健康指标

- `sync_lag`: 同步延迟（区块）
- `event_backlog`: 待处理事件数
- `state_size`: 状态大小

### 3. 错误指标

- `tx_failure_rate`: 交易失败率
- `connection_errors`: 连接错误次数
- `state_mismatches`: 状态不一致次数

## 扩展性设计

### 1. 多交易对支持

```rust
// 每个交易对独立处理
for trading_pair in config.trading_pairs {
    tokio::spawn(async move {
        let matcher = MatchingEngine::new(trading_pair);
        matcher.run().await
    });
}
```

### 2. 分布式部署

```rust
// 使用 Redis 共享状态
struct DistributedState {
    redis: RedisClient,
    local_cache: GlobalState,
}

// 通过 Pub/Sub 同步
redis.subscribe("orderbook.events")
```

### 3. 负载均衡

```rust
// 多个 Matcher 实例
// 通过租约机制选主
struct LeaderElection {
    coordinator: ZooKeeper,
}

if leader_election.is_leader() {
    matcher.run().await
} else {
    standby().await
}
```

## 安全考虑

### 1. 私钥管理

```rust
// 使用密钥管理服务
let wallet = load_wallet_from_kms()?;

// 或环境变量
let pk = env::var("PRIVATE_KEY")?;
```

### 2. 访问控制

```rust
// 检查执行者权限
require(
    msg.sender == authorized_matcher,
    "Unauthorized"
);
```

### 3. 速率限制

```rust
// 限制交易频率
let rate_limiter = RateLimiter::new(10, Duration::from_secs(1));
rate_limiter.check().await?;
```

## 未来改进

- [ ] 实现状态快照和恢复
- [ ] 添加 Prometheus 指标导出
- [ ] 支持多链部署
- [ ] 实现智能 gas 定价
- [ ] 添加 MEV 保护
- [ ] 支持订单路由和拆分
- [ ] 实现 L2 集成
- [ ] 添加测试覆盖率
- [ ] 性能压测和优化
