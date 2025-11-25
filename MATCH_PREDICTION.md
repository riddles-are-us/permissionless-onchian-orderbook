# 匹配预测功能设计文档

## 核心思想

你提出的优化思路非常好：**只有插在队头的订单才会触发成交**。因此 matcher 可以：

1. 在提交订单前，预测订单是否会成交
2. 如果会成交，在本地模拟匹配，更新本地状态
3. 这样本地状态就能和链上保持同步

## 架构设计

### 当前流程（已实现事件监听）
```
Sequencer 队列 → Matcher 读取 → 提交到 OrderBook → 匹配 → 发出事件 → Matcher 监听事件更新状态
                                                           ↑
                                                     已实现 ✅
```

### 优化流程（预测匹配 + 事件监听）
```
Sequencer 队列 → Matcher 读取 → 本地预测匹配 → 更新本地状态 → 提交到 OrderBook
                                      ↓                              ↓
                              预测结果（可选优化）                 链上实际成交
                                                                      ↓
                                                                  发出事件
                                                                      ↓
                                                          Matcher 监听事件（兜底验证）
                                                                      ↓
                                                              对比预测结果和实际结果
```

## 关键判断逻辑

### 1. 订单是否会插在队头

```rust
// 限价单
if is_ask {
    // 卖单：价格 <= 当前最低卖价 → 插在队头
    price <= best_ask_price
} else {
    // 买单：价格 >= 当前最高买价 → 插在队头
    price >= best_bid_price
}

// 市价单
// 总是立即执行，总是触发匹配
```

### 2. 匹配预测

```rust
// 例：预测卖单是否会成交
fn predict_ask_match(price, amount) -> MatchPrediction {
    // 1. 遍历市价买单队列
    for market_bid in market_bids {
        if can_match {
            fill_amount += min(remaining, available)
        }
    }

    // 2. 遍历限价买单队列（按价格降序）
    for limit_bid in bids {
        if bid.price >= price {  // 价格匹配
            fill_amount += min(remaining, available)
        } else {
            break  // 价格不匹配，后面不会更好
        }
    }

    return MatchPrediction {
        will_match: fill_amount > 0,
        expected_filled_amount: fill_amount,
        will_fully_fill: remaining == 0,
        matched_order_ids: [...],
        match_prices: [...]
    }
}
```

## 使用示例

### 示例 1: 基本预测

```rust
use crate::match_simulator::{MatchSimulator, LocalOrder};

let mut simulator = MatchSimulator::new();

// 添加现有订单到本地订单簿
simulator.add_order(LocalOrder {
    id: U256::from(1),
    price: U256::from(100_000_000),  // 1.0 USDC
    amount: U256::from(50_000_000),  // 0.5 WETH
    filled_amount: U256::zero(),
    is_market: false,
}, false);  // 买单

// 预测新卖单是否会匹配
let prediction = simulator.predict_limit_order_match(
    U256::from(100_000_000),  // 价格: 1.0 USDC
    U256::from(30_000_000),   // 数量: 0.3 WETH
    true                       // 卖单
);

if prediction.will_match {
    println!("✅ 预测会成交！");
    println!("  成交数量: {}", prediction.expected_filled_amount);
    println!("  完全成交: {}", prediction.will_fully_fill);
    println!("  匹配订单: {:?}", prediction.matched_order_ids);

    // 应用预测结果到本地状态
    simulator.apply_prediction(&prediction, true);
}
```

### 示例 2: 集成到 Matcher（待确认状态模式）✅ 推荐

```rust
// 在 matcher.rs 中
use crate::match_simulator::{MatchSimulator, LocalOrder, MatchPrediction};
use std::time::Duration;

pub struct MatchingEngine {
    // ... 现有字段
    simulator: MatchSimulator,
}

impl MatchingEngine {
    pub async fn process_order(&mut self, request: QueuedRequest) -> Result<()> {
        // 1. 预测是否会成交（不修改状态）
        let prediction = if request.order_type == OrderType::Market {
            self.simulator.predict_market_order_match(
                request.amount,
                request.is_ask
            )
        } else {
            self.simulator.predict_limit_order_match(
                request.price,
                request.amount,
                request.is_ask
            )
        };

        // 2. 记录预测结果（用于日志）
        if prediction.will_match {
            info!("📊 Prediction: order {} will match {} amount",
                  request.request_id, prediction.expected_filled_amount);
        } else {
            info!("📋 Prediction: order {} will be added to book",
                  request.request_id);
        }

        // 3. 提交到链上
        match self.submit_to_chain(request).await {
            Ok(tx_hash) => {
                info!("✅ Transaction sent: {:?}", tx_hash);

                // 4. 将预测记录为待确认（不立即更新状态）
                self.simulator.apply_prediction_pending(&prediction, tx_hash, request.is_ask);

                // 5. 等待链上确认
                match self.wait_for_confirmation(tx_hash).await {
                    Ok(_) => {
                        info!("✅ Transaction confirmed: {:?}", tx_hash);
                        // 6. 确认成功：应用待确认的更改
                        self.simulator.confirm_changes(tx_hash);
                    }
                    Err(e) => {
                        warn!("❌ Transaction failed: {}", e);
                        // 7. 确认失败：回滚待确认的更改
                        self.simulator.rollback_changes(tx_hash);
                    }
                }

                Ok(())
            }
            Err(e) => {
                warn!("❌ Failed to submit transaction: {}", e);
                Err(e)
            }
        }
    }

    /// 定期清理过期的待确认更改（可选）
    pub async fn cleanup_loop(&mut self) {
        loop {
            tokio::time::sleep(Duration::from_secs(60)).await;

            // 清理超过 5 分钟未确认的更改
            let removed = self.simulator.cleanup_expired_changes(Duration::from_secs(300));

            if removed > 0 {
                warn!("🧹 Cleaned up {} expired pending changes", removed);
            }
        }
    }
}
```

## 关键设计：待确认状态模式 (Pending State Pattern) ✅

### 为什么需要待确认状态？

**问题 1**：提交到链上可能失败
- 网络错误
- Gas 不足
- 交易 revert
- 交易被 dropped

**问题 2**：预测更新和事件更新冲突
- 如果预测时就更新状态，链上事件到达时订单已不存在
- 导致事件处理器无法正确更新状态
- 状态不一致！

**解决方案**：待确认状态模式
```rust
// ✅ 正确做法：三阶段更新
// 1. 预测（不修改状态）
let prediction = simulator.predict_match(...);

// 2. 提交并记录为待确认
let tx_hash = submit_to_chain().await?;
simulator.apply_prediction_pending(prediction, tx_hash);

// 3. 根据链上结果决定
match wait_for_confirmation(tx_hash).await {
    Ok(_) => simulator.confirm_changes(tx_hash),   // 确认：应用更改
    Err(_) => simulator.rollback_changes(tx_hash), // 失败：丢弃更改
}
```

### 实现对比

#### ❌ 方式 1: Clone (已弃用 - 有状态冲突bug)
```rust
#[derive(Clone)]  // MatchSimulator 需要实现 Clone
pub struct MatchSimulator { ... }

// 使用
let mut snapshot = self.simulator.clone();
snapshot.apply_changes();

match submit().await {
    Ok(_) => self.simulator = snapshot,  // 成功：替换
    Err(_) => {}  // 失败：snapshot 被 drop
}
```

#### 方式 2: Copy-on-Write (高效)
```rust
use std::sync::Arc;

pub struct MatchSimulator {
    orderbook: Arc<LocalOrderBook>,  // 使用 Arc 共享
}

impl MatchSimulator {
    fn create_snapshot(&self) -> Self {
        Self {
            orderbook: Arc::clone(&self.orderbook)  // 只复制引用
        }
    }

    fn make_mut(&mut self) {
        Arc::make_mut(&mut self.orderbook);  // 需要修改时才真正复制
    }
}
```

#### 方式 3: Transaction Log (灵活)
```rust
pub struct MatchSimulator {
    orderbook: LocalOrderBook,
    pending_changes: Vec<StateChange>,  // 记录待应用的变更
}

enum StateChange {
    AddOrder(LocalOrder),
    RemoveOrder(U256),
    UpdateFilledAmount(U256, U256),
}

impl MatchSimulator {
    fn apply_changes(&mut self) {
        for change in self.pending_changes.drain(..) {
            match change {
                StateChange::AddOrder(order) => { /* 应用 */ }
                StateChange::RemoveOrder(id) => { /* 应用 */ }
                StateChange::UpdateFilledAmount(id, amt) => { /* 应用 */ }
            }
        }
    }

    fn discard_changes(&mut self) {
        self.pending_changes.clear();
    }
}
```

### 推荐方案

对于 `MatchSimulator`，推荐使用 **方式 1 (Clone)**：
- 简单直观
- LocalOrderBook 数据量不大（几百个订单）
- Clone 成本可接受
- Rust 的 `Clone` 优化已经很好

```rust
// MatchSimulator 已经实现 Clone（通过 derive）
#[derive(Clone)]
pub struct LocalOrderBook { ... }

// 使用非常简单
let mut snapshot = matcher.simulator.clone();
// ... 在 snapshot 上操作 ...
if success {
    matcher.simulator = snapshot;  // 成功：替换
}
// 失败：什么都不做，snapshot 自动清理
```

## 完整工作流程

```
1. Matcher 读取 Sequencer 队列
   ↓
2. 创建 MatchSimulator 快照
   snapshot = simulator.clone()
   ↓
3. 在快照上预测匹配
   prediction = snapshot.predict_match(...)
   ↓
4. 在快照上应用预测
   snapshot.apply_prediction(prediction)
   ↓
5. 提交到链上
   result = submit_to_chain().await
   ↓
   ├─ 成功 ─→ simulator = snapshot (应用快照)
   │             ↓
   │          事件监听验证
   │             ↓
   │          如果不一致 → 事件监听器纠正状态
   │
   └─ 失败 ─→ 丢弃快照 (snapshot drop)
                ↓
             原状态不受影响（自动回滚）
```

## 优势和挑战

### ✅ 优势

1. **状态准确性提升**
   - 本地状态和链上状态保持同步
   - 避免使用过期数据进行匹配

2. **更好的用户体验**
   - 可以立即告诉用户订单是否会成交
   - 可以显示预期成交价格和数量

3. **优化潜力**
   - 可以基于预测结果优化批量提交策略
   - 可以避免提交明显无法成交的订单（节省 gas）

4. **双重保障**
   - 预测提供快速的本地更新
   - 事件监听提供链上结果验证
   - 如果预测错误，事件监听会纠正

### ⚠️ 挑战

1. **模拟精度**
   - 必须完全复制链上匹配逻辑
   - 价格计算必须一致
   - 订单执行顺序必须一致

2. **状态同步**
   - 本地订单簿需要实时更新
   - 必须处理并发订单情况
   - 需要处理链重组

3. **复杂度增加**
   - 需要维护完整的本地订单簿
   - 需要实现完整的匹配引擎逻辑
   - 调试难度增加

## 实现建议

### 阶段 1: 基础预测（已完成 ✅）

- [x] 实现 `MatchSimulator` 基础框架
- [x] 实现限价单匹配预测
- [x] 实现市价单匹配预测
- [x] 添加基础测试

### 阶段 2: 集成到 Matcher（可选）

- [ ] 在 MatchingEngine 中集成 MatchSimulator
- [ ] 在处理订单前进行预测
- [ ] 应用预测结果到本地状态
- [ ] 记录预测结果用于验证

### 阶段 3: 预测验证（可选）

- [ ] 在收到事件时对比预测结果
- [ ] 记录预测准确率
- [ ] 如果预测错误，记录日志并纠正
- [ ] 添加预测准确率监控

### 阶段 4: 高级优化（未来）

- [ ] 基于预测优化批量提交
- [ ] 实现订单路由策略
- [ ] 添加价格影响估算
- [ ] 实现滑点保护

## 测试策略

### 单元测试

```rust
#[test]
fn test_prediction_accuracy() {
    let mut sim = MatchSimulator::new();

    // 设置初始状态
    sim.add_order(buy_order_100, false);
    sim.add_order(buy_order_90, false);
    sim.add_order(sell_order_110, true);

    // 预测
    let pred = sim.predict_limit_order_match(95, 10, true);

    // 验证
    assert!(pred.will_match);
    assert_eq!(pred.expected_filled_amount, 10);
    assert_eq!(pred.matched_order_ids[0], buy_order_100.id);
}
```

### 集成测试

```rust
#[tokio::test]
async fn test_prediction_vs_actual() {
    // 1. 预测匹配
    let prediction = simulator.predict_match(...);

    // 2. 提交到链上
    submit_order_to_chain(...).await;

    // 3. 等待事件
    let events = wait_for_trade_events().await;

    // 4. 对比预测和实际
    assert_eq!(prediction.expected_filled_amount, actual_filled);
    assert_eq!(prediction.matched_order_ids, actual_matched_ids);
}
```

## 配置选项（建议）

```toml
[matching]
# 是否启用匹配预测
enable_prediction = true

# 是否记录预测准确率
log_prediction_accuracy = true

# 预测失败时的处理策略
# "log" - 仅记录日志
# "alert" - 发送告警
# "halt" - 暂停 matcher
prediction_mismatch_action = "log"
```

## 监控指标（建议）

```
matcher_prediction_total         # 总预测次数
matcher_prediction_correct       # 正确预测次数
matcher_prediction_accuracy      # 准确率 = correct / total
matcher_prediction_match_count   # 预测会成交的订单数
matcher_actual_match_count       # 实际成交的订单数
matcher_prediction_latency       # 预测耗时
```

## 结论

这个优化方案非常有价值！主要收益：

1. **准确性**: 本地状态更准确，避免基于过期数据匹配
2. **性能**: 可以提前知道结果，优化批量提交
3. **用户体验**: 可以立即反馈预期结果

建议采用**渐进式实现**：
1. 先完善事件监听（已完成 ✅）
2. 再添加预测功能（框架已完成 ✅）
3. 最后集成并优化（根据需要）

关键是要确保预测逻辑和链上逻辑完全一致！
