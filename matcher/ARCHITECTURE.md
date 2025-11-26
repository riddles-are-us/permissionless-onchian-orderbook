# Matcher 架构设计文档

## 概述

Matcher 是一个链下撮合引擎，负责：
1. 通过链上事件实时同步订单簿状态
2. 使用本地模拟器计算新订单的正确插入位置
3. 批量调用链上合约完成订单处理

## 核心架构

```
┌─────────────────────────────────────────────────────────────┐
│                        Matcher                               │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────────┐    ┌─────────────────────────────────┐ │
│  │ StateSynchronizer│    │      MatchingEngine             │ │
│  │                 │    │                                 │ │
│  │ • 启动时同步状态  │    │ • 定期处理请求队列               │ │
│  │ • 监听链上事件   │    │ • 计算 insertAfterPrice         │ │
│  │ • 更新 GlobalState│   │ • 执行批量交易                  │ │
│  └────────┬────────┘    └────────────┬────────────────────┘ │
│           │                          │                       │
│           ▼                          ▼                       │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │                    GlobalState                          │ │
│  │  ┌──────────────────┐  ┌────────────────────────────┐  │ │
│  │  │ queued_requests  │  │      orderbook             │  │ │
│  │  │ (Sequencer队列)   │  │   (OrderBookSimulator)     │  │ │
│  │  │                  │  │  • ask_head/tail           │  │ │
│  │  │                  │  │  • bid_head/tail           │  │ │
│  │  │                  │  │  • price_levels: HashMap   │  │ │
│  │  │                  │  │  • orders: HashMap         │  │ │
│  │  └──────────────────┘  └────────────────────────────┘  │ │
│  └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

## 核心设计原则

### 1. 事件驱动状态更新

**唯一真实来源**：`GlobalState.orderbook` 只通过链上事件更新，保证本地状态与链上严格一致。

```rust
// 只有这些事件处理器才能修改 orderbook 状态
fn handle_order_inserted(state: &GlobalState, event: OrderInserted) {
    let mut orderbook = state.orderbook.write();
    orderbook.add_existing_order(order);
}

fn handle_price_level_created(state: &GlobalState, event: PriceLevelCreated) {
    let mut orderbook = state.orderbook.write();
    orderbook.add_existing_price_level(level, is_ask);
}
```

### 2. 深拷贝隔离模拟

**模拟计算不影响原始状态**：每次批处理前，使用 `clone_orderbook()` 创建完整深拷贝。

```rust
fn calculate_insert_positions(&self, requests: &[QueuedRequest]) -> MatchResult {
    // 深拷贝当前状态
    let mut sim = self.state.clone_orderbook();

    // 在拷贝上模拟操作
    for request in requests {
        let insert_after = sim.simulate_insert_order(...);
        // 模拟会更新 sim，但不影响 GlobalState.orderbook
    }
}
```

**深拷贝实现**：Rust 的 `#[derive(Clone)]` 对 `HashMap<U256, SimOrder>` 会递归克隆所有键值对，是真正的深拷贝。

### 3. 请求队列管理

**只有成功后才移除**：交易失败时请求保留在队列中，下轮重试。

```rust
async fn execute_batch(&self, result: &MatchResult) -> Result<()> {
    let receipt = tx.send().await?.await?;

    if receipt.status == Some(1.into()) {
        // 只有交易成功才移除请求
        for request_id in &result.order_ids {
            self.state.remove_request(request_id);
        }
    }
    // 失败时不移除，请求保留在队列中
}
```

## 模块详解

### 1. GlobalState（全局状态）

```rust
pub struct GlobalState {
    /// Sequencer 请求队列: request_id -> QueuedRequest
    pub queued_requests: Arc<DashMap<U256, QueuedRequest>>,

    /// 队列头部指针
    pub queue_head: Arc<RwLock<U256>>,

    /// 订单簿模拟器（与链上结构一致）
    pub orderbook: Arc<RwLock<OrderBookSimulator>>,

    /// 当前同步区块高度
    pub current_block: Arc<RwLock<u64>>,
}
```

**设计要点**：
- 使用 `DashMap` 实现无锁并发访问队列
- 使用 `RwLock` 保护订单簿模拟器
- `clone_orderbook()` 提供深拷贝用于模拟计算

### 2. OrderBookSimulator（订单簿模拟器）

严格按照链上 OrderBook.sol 的逻辑和数据结构实现：

```rust
pub struct OrderBookSimulator {
    // 限价订单簿头尾指针
    pub ask_head: U256,  // 最低卖价
    pub ask_tail: U256,
    pub bid_head: U256,  // 最高买价
    pub bid_tail: U256,

    /// 价格层级: composite_key -> SimPriceLevel
    /// Ask 用 price，Bid 用 price | (1 << 255)
    pub price_levels: HashMap<U256, SimPriceLevel>,

    /// 订单: order_id -> SimOrder
    pub orders: HashMap<U256, SimOrder>,
}
```

**价格层级复合键**：
- Ask 订单使用 `price` 本身
- Bid 订单使用 `price | (1 << 255)` 区分

**核心方法**：
- `simulate_insert_order()`: 模拟插入订单，返回 insertAfterPrice
- `simulate_remove_order()`: 模拟移除订单
- `find_insert_position()`: 计算正确的插入位置

### 3. StateSynchronizer（状态同步器）

```rust
pub struct StateSynchronizer {
    provider: Arc<Provider<Ws>>,
    sequencer: Sequencer<Arc<Provider<Ws>>>,
    orderbook: OrderBook<Arc<Provider<Ws>>>,
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
│       ├─ read askHead/bidHead
│       ├─ traverse price levels
│       └─ load orders
│
└─ watch_events()
    ├─ subscribe(sequencer.events())
    ├─ subscribe(orderbook.events())
    └─ loop:
        ├─ handle_sequencer_event()
        └─ handle_orderbook_event()
```

### 4. MatchingEngine（匹配引擎）

```rust
pub struct MatchingEngine {
    config: Config,
    state: GlobalState,
    orderbook: OrderBook<SignerMiddleware<...>>,
}
```

**处理流程**：

```rust
async fn process_batch(&self) -> Result<usize> {
    // 1. 获取队列中的请求
    let requests = self.state.get_head_requests(max_batch_size);

    // 2. 使用模拟器计算插入位置
    let result = self.calculate_insert_positions_with_simulator(&requests)?;

    // 3. 执行批量处理
    self.execute_batch(&result).await?;

    Ok(result.len())
}
```

## 数据流

```
链上事件                    本地状态                    交易执行
─────────────────────────────────────────────────────────────────
PlaceOrderRequested ──────► queued_requests.add()
                                   │
                                   ▼
                          MatchingEngine.process_batch()
                                   │
                          clone_orderbook() ──► 深拷贝
                                   │
                          simulate_insert() ──► 计算 insertAfterPrice
                                   │
                          execute_batch() ───► batchProcessRequests tx
                                   │
                                   ▼
OrderInserted ────────────► orderbook.orders.insert()
PriceLevelCreated ────────► orderbook.price_levels.insert()
OrderFilled ──────────────► orderbook.orders.update()
OrderRemoved ─────────────► orderbook.orders.remove()
PriceLevelRemoved ────────► orderbook.price_levels.remove()
```

## 监听的事件

| 事件 | 来源 | 处理 |
|------|------|------|
| `PlaceOrderRequested` | Sequencer | 添加到请求队列 |
| `RemoveOrderRequested` | Sequencer | 添加到请求队列 |
| `OrderInserted` | OrderBook | 更新 orderbook.orders |
| `PriceLevelCreated` | OrderBook | 更新 orderbook.price_levels |
| `PriceLevelRemoved` | OrderBook | 从 orderbook 移除价格层级 |
| `OrderFilled` | OrderBook | 更新订单 filled_amount |
| `OrderRemoved` | OrderBook | 从 orderbook 移除订单 |
| `Trade` | OrderBook | 记录交易日志 |

## 插入位置算法

### Bid（买单）- 价格从高到低

```
[2000] -> [1950] -> [1900]
  ^         ^         ^
  head               tail

插入 1960:
- 遍历：2000 (1960 < 2000, 继续)
- 遍历：1950 (1960 > 1950, 插入到这里)
- 返回：insertAfterPrice = 2000
```

### Ask（卖单）- 价格从低到高

```
[2100] -> [2150] -> [2200]
  ^         ^         ^
  head               tail

插入 2140:
- 遍历：2100 (2140 > 2100, 继续)
- 遍历：2150 (2140 < 2150, 插入到这里)
- 返回：insertAfterPrice = 2100
```

## 状态一致性保证

### 交易失败场景

当 `batchProcessRequests` 交易失败时：

1. **模拟状态隔离**：模拟计算使用深拷贝，不影响 `GlobalState.orderbook`
2. **事件驱动更新**：`GlobalState.orderbook` 只通过链上事件更新
3. **交易失败 = 无事件**：Revert 的交易不会发出事件
4. **请求保留**：`remove_request()` 只在成功后调用
5. **自动重试**：失败的请求保留在队列中，下轮重新处理

```
交易失败流程：
tx.send() -> revert
     │
     ├── 无事件发出
     │     └── GlobalState.orderbook 保持不变
     │
     └── execute_batch() 返回 Err
           └── requests 保留在队列中
                 └── 下一轮重试
```

## 并发模型

```rust
// StateSynchronizer 和 MatchingEngine 并行运行
tokio::spawn(synchronizer.run());  // 事件监听
tokio::spawn(matcher.run());       // 批量处理

// 使用 DashMap 支持并发读写
state.queued_requests  // 多线程安全

// 使用 RwLock 保护订单簿
state.orderbook  // 读多写少场景优化
```

## 性能优化

### 1. 本地模拟器

- 所有 insertAfterPrice 计算在本地完成
- 无需 RPC 调用查询链上状态
- O(n) 遍历价格层级链表

### 2. 深拷贝策略

- 每批处理只克隆一次
- HashMap 克隆是 O(n) 但只在批处理开始时执行
- 避免了多次同步的开销

### 3. 批量处理

- 多个订单打包成一笔交易
- 降低 gas 成本
- 可配置批量大小

## 错误处理

### 1. 网络错误

```rust
// WebSocket 断连后自动重连
loop {
    match watch_events().await {
        Ok(_) => break,
        Err(e) => {
            warn!("Connection lost: {}", e);
            sleep(Duration::from_secs(5)).await;
        }
    }
}
```

### 2. 交易失败

- 交易 revert 时记录错误日志
- 请求保留在队列中
- 下一个周期自动重试

### 3. 状态不一致

- 事件驱动保证最终一致性
- 如果检测到不一致，可重启同步

## 未来改进

- [ ] 实现状态快照和恢复
- [ ] 添加 Prometheus 指标导出
- [ ] 支持多交易对并行处理
- [ ] 实现智能 gas 定价
- [ ] 添加 MEV 保护
- [ ] 支持 WebSocket 断线重连
- [ ] 添加更多单元测试
- [ ] 性能压测和优化
