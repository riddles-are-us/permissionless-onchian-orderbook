use crate::types::*;
use ethers::types::{U256, H256};
use tracing::{debug, info, warn};
use std::time::{Instant, Duration};

/// 匹配模拟器 - 预测订单是否会成交以及成交结果
///
/// 使用待确认状态模式：
/// ```
/// // 1. 预测匹配
/// let prediction = simulator.predict_match(...);
///
/// // 2. 提交到链上
/// let tx_hash = submit_to_chain().await?;
///
/// // 3. 记录为待确认（不立即更新状态）
/// simulator.apply_prediction_pending(prediction, tx_hash);
///
/// // 4. 等待链上确认
/// match wait_for_confirmation(tx_hash).await {
///     Ok(_) => simulator.confirm_changes(tx_hash),  // 确认：应用更改
///     Err(_) => simulator.rollback_changes(tx_hash),  // 失败：回滚更改
/// }
/// ```
#[derive(Clone)]
pub struct MatchSimulator {
    /// 本地订单簿快照
    pub local_orderbook: LocalOrderBook,
    /// 待确认的状态更改
    pub pending_changes: Vec<PendingChange>,
}

/// 待确认的状态更改
#[derive(Debug, Clone)]
pub struct PendingChange {
    /// 交易哈希
    pub tx_hash: H256,
    /// 状态更改列表
    pub changes: Vec<StateChange>,
    /// 创建时间
    pub timestamp: Instant,
}

/// 状态更改类型
#[derive(Debug, Clone)]
pub enum StateChange {
    /// 添加订单
    AddOrder {
        order: LocalOrder,
        is_ask: bool,
    },
    /// 移除订单
    RemoveOrder {
        order_id: U256,
        is_ask: bool,
        is_market: bool,
    },
    /// 更新订单已成交数量
    UpdateFilledAmount {
        order_id: U256,
        filled_amount: U256,
        is_ask: bool,
    },
}

/// 本地订单簿（用于模拟）
#[derive(Debug, Clone)]
pub struct LocalOrderBook {
    /// 买单队列（按价格降序）
    pub bids: Vec<LocalOrder>,
    /// 卖单队列（按价格升序）
    pub asks: Vec<LocalOrder>,
    /// 市价买单队列
    pub market_bids: Vec<LocalOrder>,
    /// 市价卖单队列
    pub market_asks: Vec<LocalOrder>,
}

/// 本地订单（简化版，用于模拟）
#[derive(Debug, Clone)]
pub struct LocalOrder {
    pub id: U256,
    pub price: U256,
    pub amount: U256,
    pub filled_amount: U256,
    pub is_market: bool,
}

/// 匹配预测结果
#[derive(Debug, Clone)]
pub struct MatchPrediction {
    /// 是否会立即成交
    pub will_match: bool,
    /// 预计成交数量
    pub expected_filled_amount: U256,
    /// 是否会完全成交
    pub will_fully_fill: bool,
    /// 匹配的对手方订单 IDs
    pub matched_order_ids: Vec<U256>,
    /// 预计的成交价格
    pub match_prices: Vec<U256>,
}

impl MatchSimulator {
    pub fn new() -> Self {
        Self {
            local_orderbook: LocalOrderBook {
                bids: Vec::new(),
                asks: Vec::new(),
                market_bids: Vec::new(),
                market_asks: Vec::new(),
            },
            pending_changes: Vec::new(),
        }
    }

    /// 预测限价单是否会成交
    pub fn predict_limit_order_match(
        &self,
        price: U256,
        amount: U256,
        is_ask: bool,
    ) -> MatchPrediction {
        if is_ask {
            // 卖单：检查是否有价格 >= price 的买单
            self.predict_ask_match(price, amount, false)
        } else {
            // 买单：检查是否有价格 <= price 的卖单
            self.predict_bid_match(price, amount, false)
        }
    }

    /// 预测市价单是否会成交
    pub fn predict_market_order_match(
        &self,
        amount: U256,
        is_ask: bool,
    ) -> MatchPrediction {
        if is_ask {
            // 市价卖单：与买单队列匹配（先市价买单，再限价买单）
            self.predict_ask_match(U256::zero(), amount, true)
        } else {
            // 市价买单：与卖单队列匹配（先市价卖单，再限价卖单）
            self.predict_bid_match(U256::max_value(), amount, true)
        }
    }

    /// 预测卖单匹配
    fn predict_ask_match(
        &self,
        price: U256,
        amount: U256,
        is_market: bool,
    ) -> MatchPrediction {
        let mut remaining = amount;
        let mut matched_order_ids = Vec::new();
        let mut match_prices = Vec::new();

        // 1. 先匹配市价买单
        for bid in &self.local_orderbook.market_bids {
            if remaining.is_zero() {
                break;
            }

            let available = bid.amount - bid.filled_amount;
            if available.is_zero() {
                continue;
            }

            let trade_amount = remaining.min(available);
            remaining -= trade_amount;

            matched_order_ids.push(bid.id);
            match_prices.push(price); // 市价单使用卖单价格

            debug!(
                "Predicted match with market bid {}: {} @ {}",
                bid.id, trade_amount, price
            );
        }

        // 2. 再匹配限价买单（按价格降序）
        for bid in &self.local_orderbook.bids {
            if remaining.is_zero() {
                break;
            }

            // 检查价格是否匹配
            if !is_market && bid.price < price {
                break; // 价格不匹配，后面的买单价格更低，无需继续
            }

            let available = bid.amount - bid.filled_amount;
            if available.is_zero() {
                continue;
            }

            let trade_amount = remaining.min(available);
            remaining -= trade_amount;

            matched_order_ids.push(bid.id);
            match_prices.push(bid.price); // 使用买单价格（买单价格优先）

            debug!(
                "Predicted match with limit bid {}: {} @ {}",
                bid.id, trade_amount, bid.price
            );
        }

        let filled_amount = amount - remaining;
        let will_match = !filled_amount.is_zero();
        let will_fully_fill = remaining.is_zero();

        MatchPrediction {
            will_match,
            expected_filled_amount: filled_amount,
            will_fully_fill,
            matched_order_ids,
            match_prices,
        }
    }

    /// 预测买单匹配
    fn predict_bid_match(
        &self,
        price: U256,
        amount: U256,
        is_market: bool,
    ) -> MatchPrediction {
        let mut remaining = amount;
        let mut matched_order_ids = Vec::new();
        let mut match_prices = Vec::new();

        // 1. 先匹配市价卖单
        for ask in &self.local_orderbook.market_asks {
            if remaining.is_zero() {
                break;
            }

            let available = ask.amount - ask.filled_amount;
            if available.is_zero() {
                continue;
            }

            let trade_amount = remaining.min(available);
            remaining -= trade_amount;

            matched_order_ids.push(ask.id);
            match_prices.push(price); // 市价单使用买单价格

            debug!(
                "Predicted match with market ask {}: {} @ {}",
                ask.id, trade_amount, price
            );
        }

        // 2. 再匹配限价卖单（按价格升序）
        for ask in &self.local_orderbook.asks {
            if remaining.is_zero() {
                break;
            }

            // 检查价格是否匹配
            if !is_market && ask.price > price {
                break; // 价格不匹配，后面的卖单价格更高，无需继续
            }

            let available = ask.amount - ask.filled_amount;
            if available.is_zero() {
                continue;
            }

            let trade_amount = remaining.min(available);
            remaining -= trade_amount;

            matched_order_ids.push(ask.id);
            match_prices.push(ask.price); // 使用卖单价格（卖单价格优先）

            debug!(
                "Predicted match with limit ask {}: {} @ {}",
                ask.id, trade_amount, ask.price
            );
        }

        let filled_amount = amount - remaining;
        let will_match = !filled_amount.is_zero();
        let will_fully_fill = remaining.is_zero();

        MatchPrediction {
            will_match,
            expected_filled_amount: filled_amount,
            will_fully_fill,
            matched_order_ids,
            match_prices,
        }
    }

    /// 应用预测结果到本地状态（在提交到链上之前）
    pub fn apply_prediction(&mut self, prediction: &MatchPrediction, is_ask: bool) {
        if !prediction.will_match {
            return;
        }

        info!(
            "📊 Applying predicted match: {} orders will be affected, filled amount: {}",
            prediction.matched_order_ids.len(),
            prediction.expected_filled_amount
        );

        // 更新匹配到的订单
        for order_id in &prediction.matched_order_ids {
            self.update_order_filled_amount(*order_id, is_ask);
        }
    }

    /// 更新订单的已成交数量
    fn update_order_filled_amount(&mut self, order_id: U256, is_counterparty_ask: bool) {
        // 根据对手方是买还是卖，在相应的队列中查找并更新
        let orders = if is_counterparty_ask {
            // 对手方是卖单，说明我们是买单
            &mut self.local_orderbook.bids
        } else {
            // 对手方是买单，说明我们是卖单
            &mut self.local_orderbook.asks
        };

        for order in orders.iter_mut() {
            if order.id == order_id {
                // 简化处理：假设完全成交
                order.filled_amount = order.amount;
                debug!("Updated local order {} filled_amount to {}", order_id, order.amount);
                break;
            }
        }

        // 同样检查市价单队列
        let market_orders = if is_counterparty_ask {
            &mut self.local_orderbook.market_bids
        } else {
            &mut self.local_orderbook.market_asks
        };

        for order in market_orders.iter_mut() {
            if order.id == order_id {
                order.filled_amount = order.amount;
                debug!("Updated local market order {} filled_amount to {}", order_id, order.amount);
                break;
            }
        }
    }

    /// 添加订单到本地订单簿
    pub fn add_order(&mut self, order: LocalOrder, is_ask: bool) {
        if order.is_market {
            if is_ask {
                self.local_orderbook.market_asks.push(order);
            } else {
                self.local_orderbook.market_bids.push(order);
            }
        } else {
            if is_ask {
                self.local_orderbook.asks.push(order.clone());
                // 保持卖单按价格升序排列
                self.local_orderbook.asks.sort_by(|a, b| a.price.cmp(&b.price));
            } else {
                self.local_orderbook.bids.push(order.clone());
                // 保持买单按价格降序排列
                self.local_orderbook.bids.sort_by(|a, b| b.price.cmp(&a.price));
            }
        }
    }

    /// 从本地订单簿移除订单
    pub fn remove_order(&mut self, order_id: U256, is_ask: bool, is_market: bool) {
        if is_market {
            if is_ask {
                self.local_orderbook.market_asks.retain(|o| o.id != order_id);
            } else {
                self.local_orderbook.market_bids.retain(|o| o.id != order_id);
            }
        } else {
            if is_ask {
                self.local_orderbook.asks.retain(|o| o.id != order_id);
            } else {
                self.local_orderbook.bids.retain(|o| o.id != order_id);
            }
        }
    }

    /// 检查订单是否会插在队头（用于判断是否会立即匹配）
    pub fn will_be_at_head(&self, price: U256, is_ask: bool, is_market: bool) -> bool {
        if is_market {
            // 市价单总是会立即执行
            return true;
        }

        if is_ask {
            // 卖单：如果价格 <= 当前最低卖价，会插在队头
            match self.local_orderbook.asks.first() {
                Some(best_ask) => price <= best_ask.price,
                None => true, // 队列为空，会插在队头
            }
        } else {
            // 买单：如果价格 >= 当前最高买价，会插在队头
            match self.local_orderbook.bids.first() {
                Some(best_bid) => price >= best_bid.price,
                None => true, // 队列为空，会插在队头
            }
        }
    }

    /// 将预测结果记录为待确认（不立即应用到状态）
    ///
    /// # 参数
    /// * `prediction` - 匹配预测结果
    /// * `tx_hash` - 交易哈希
    /// * `is_ask` - 是否是卖单
    pub fn apply_prediction_pending(&mut self, prediction: &MatchPrediction, tx_hash: H256, is_ask: bool) {
        if !prediction.will_match {
            return;
        }

        let mut changes = Vec::new();

        // 记录每个匹配订单的状态更改
        for order_id in &prediction.matched_order_ids {
            changes.push(StateChange::UpdateFilledAmount {
                order_id: *order_id,
                filled_amount: prediction.expected_filled_amount,
                is_ask: !is_ask, // 对手方
            });
        }

        // 如果完全成交，记录移除操作
        if prediction.will_fully_fill {
            for order_id in &prediction.matched_order_ids {
                // 这里简化处理，实际应该从订单信息中获取 is_market
                changes.push(StateChange::RemoveOrder {
                    order_id: *order_id,
                    is_ask: !is_ask,
                    is_market: false,
                });
            }
        }

        let changes_count = changes.len();
        let pending = PendingChange {
            tx_hash,
            changes,
            timestamp: Instant::now(),
        };

        self.pending_changes.push(pending);

        info!(
            "📝 Recorded pending changes for tx {:?}: {} changes",
            tx_hash,
            changes_count
        );
    }

    /// 确认并应用待确认的更改
    ///
    /// # 参数
    /// * `tx_hash` - 已确认的交易哈希
    pub fn confirm_changes(&mut self, tx_hash: H256) {
        if let Some(pos) = self.pending_changes.iter().position(|c| c.tx_hash == tx_hash) {
            let pending = self.pending_changes.remove(pos);

            info!(
                "✅ Confirming changes for tx {:?}: {} changes",
                tx_hash,
                pending.changes.len()
            );

            // 应用所有状态更改
            for change in pending.changes {
                self.apply_state_change(change);
            }
        } else {
            debug!("No pending changes found for tx {:?}", tx_hash);
        }
    }

    /// 回滚失败的待确认更改
    ///
    /// # 参数
    /// * `tx_hash` - 失败的交易哈希
    pub fn rollback_changes(&mut self, tx_hash: H256) {
        if let Some(pos) = self.pending_changes.iter().position(|c| c.tx_hash == tx_hash) {
            let pending = self.pending_changes.remove(pos);

            warn!(
                "🔄 Rolling back changes for tx {:?}: {} changes discarded",
                tx_hash,
                pending.changes.len()
            );
        } else {
            debug!("No pending changes to rollback for tx {:?}", tx_hash);
        }
    }

    /// 清理过期的待确认更改（超过指定时间未确认）
    ///
    /// # 参数
    /// * `timeout` - 超时时间
    ///
    /// # 返回
    /// 清理的更改数量
    pub fn cleanup_expired_changes(&mut self, timeout: Duration) -> usize {
        let now = Instant::now();
        let original_len = self.pending_changes.len();

        self.pending_changes.retain(|change| {
            let age = now.duration_since(change.timestamp);
            if age > timeout {
                warn!(
                    "⏰ Expired pending change for tx {:?} (age: {:?})",
                    change.tx_hash, age
                );
                false
            } else {
                true
            }
        });

        let removed = original_len - self.pending_changes.len();
        if removed > 0 {
            info!("🧹 Cleaned up {} expired pending changes", removed);
        }
        removed
    }

    /// 应用单个状态更改
    fn apply_state_change(&mut self, change: StateChange) {
        match change {
            StateChange::AddOrder { order, is_ask } => {
                self.add_order(order, is_ask);
                debug!("Applied: AddOrder");
            }
            StateChange::RemoveOrder { order_id, is_ask, is_market } => {
                self.remove_order(order_id, is_ask, is_market);
                debug!("Applied: RemoveOrder {}", order_id);
            }
            StateChange::UpdateFilledAmount { order_id, filled_amount, is_ask } => {
                self.update_order_filled_amount(order_id, is_ask);
                debug!("Applied: UpdateFilledAmount {} -> {}", order_id, filled_amount);
            }
        }
    }

    /// 获取待确认更改的数量
    pub fn pending_changes_count(&self) -> usize {
        self.pending_changes.len()
    }

    /// 检查某个交易哈希是否有待确认的更改
    ///
    /// # 参数
    /// * `tx_hash` - 要检查的交易哈希
    ///
    /// # 返回
    /// * `true` - 如果存在该交易的待确认更改
    /// * `false` - 如果不存在
    pub fn is_pending_change(&self, tx_hash: H256) -> bool {
        self.pending_changes.iter().any(|c| c.tx_hash == tx_hash)
    }

    /// 获取待确认更改的交易哈希列表
    ///
    /// # 返回
    /// * 所有待确认更改的交易哈希
    pub fn get_pending_tx_hashes(&self) -> Vec<H256> {
        self.pending_changes.iter().map(|c| c.tx_hash).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_predict_simple_match() {
        let mut simulator = MatchSimulator::new();

        // 添加一个买单：价格 100, 数量 10
        simulator.add_order(
            LocalOrder {
                id: U256::from(1),
                price: U256::from(100),
                amount: U256::from(10),
                filled_amount: U256::zero(),
                is_market: false,
            },
            false,
        );

        // 预测卖单：价格 100, 数量 5 -> 应该匹配
        let prediction = simulator.predict_limit_order_match(
            U256::from(100),
            U256::from(5),
            true,
        );

        assert!(prediction.will_match);
        assert_eq!(prediction.expected_filled_amount, U256::from(5));
        assert!(prediction.will_fully_fill);
        assert_eq!(prediction.matched_order_ids.len(), 1);
    }

    #[test]
    fn test_predict_no_match() {
        let mut simulator = MatchSimulator::new();

        // 添加一个买单：价格 100, 数量 10
        simulator.add_order(
            LocalOrder {
                id: U256::from(1),
                price: U256::from(100),
                amount: U256::from(10),
                filled_amount: U256::zero(),
                is_market: false,
            },
            false,
        );

        // 预测卖单：价格 101, 数量 5 -> 不应该匹配（价格太高）
        let prediction = simulator.predict_limit_order_match(
            U256::from(101),
            U256::from(5),
            true,
        );

        assert!(!prediction.will_match);
        assert_eq!(prediction.expected_filled_amount, U256::zero());
    }

    #[test]
    fn test_market_order_always_matches() {
        let mut simulator = MatchSimulator::new();

        // 添加一个卖单：价格 100, 数量 10
        simulator.add_order(
            LocalOrder {
                id: U256::from(1),
                price: U256::from(100),
                amount: U256::from(10),
                filled_amount: U256::zero(),
                is_market: false,
            },
            true,
        );

        // 预测市价买单：数量 5 -> 应该匹配
        let prediction = simulator.predict_market_order_match(U256::from(5), false);

        assert!(prediction.will_match);
        assert_eq!(prediction.expected_filled_amount, U256::from(5));
        assert!(prediction.will_fully_fill);
    }
}
