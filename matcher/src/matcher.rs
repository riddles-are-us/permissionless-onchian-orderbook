use crate::config::Config;
use crate::contracts::OrderBook;
use crate::match_simulator::MatchSimulator;
use crate::state::GlobalState;
use crate::types::*;
use anyhow::{Context, Result};
use ethers::prelude::*;
use std::sync::Arc;
use std::time::Duration;
use tracing::{debug, error, info, warn};

pub struct MatchingEngine {
    config: Config,
    state: GlobalState,
    provider: Arc<Provider<Ws>>,
    orderbook: OrderBook<SignerMiddleware<Arc<Provider<Ws>>, LocalWallet>>,
    simulator: Arc<parking_lot::RwLock<MatchSimulator>>,
}

impl MatchingEngine {
    pub async fn new(config: Config, state: GlobalState) -> Result<Self> {
        // 连接到节点
        let ws = Ws::connect(&config.network.rpc_url)
            .await
            .context("Failed to connect to WebSocket")?;
        let provider = Arc::new(Provider::new(ws));

        // 创建钱包
        let wallet: LocalWallet = config
            .executor
            .private_key
            .parse::<LocalWallet>()?
            .with_chain_id(config.network.chain_id);

        // 创建签名中间件
        let client = SignerMiddleware::new(provider.clone(), wallet);

        // 创建 OrderBook 合约实例
        let orderbook_addr: Address = config.contracts.orderbook.parse()?;
        let orderbook = OrderBook::new(orderbook_addr, Arc::new(client));

        // 创建 MatchSimulator
        let simulator = Arc::new(parking_lot::RwLock::new(MatchSimulator::new()));

        Ok(Self {
            config,
            state,
            provider,
            orderbook,
            simulator,
        })
    }

    /// 使用外部提供的 simulator 创建新实例
    pub async fn new_with_simulator(
        config: Config,
        state: GlobalState,
        simulator: Arc<parking_lot::RwLock<MatchSimulator>>,
    ) -> Result<Self> {
        // 连接到节点
        let ws = Ws::connect(&config.network.rpc_url)
            .await
            .context("Failed to connect to WebSocket")?;
        let provider = Arc::new(Provider::new(ws));

        // 创建钱包
        let wallet: LocalWallet = config
            .executor
            .private_key
            .parse::<LocalWallet>()?
            .with_chain_id(config.network.chain_id);

        // 创建签名中间件
        let client = SignerMiddleware::new(provider.clone(), wallet);

        // 创建 OrderBook 合约实例
        let orderbook_addr: Address = config.contracts.orderbook.parse()?;
        let orderbook = OrderBook::new(orderbook_addr, Arc::new(client));

        Ok(Self {
            config,
            state,
            provider,
            orderbook,
            simulator,
        })
    }

    /// 获取 simulator 的引用（用于 sync）
    pub fn simulator(&self) -> Arc<parking_lot::RwLock<MatchSimulator>> {
        self.simulator.clone()
    }

    /// 运行匹配引擎
    pub async fn run(self) -> Result<()> {
        info!("🎯 Starting matching engine");
        info!("  Batch size: {}", self.config.matching.max_batch_size);
        info!(
            "  Interval: {}ms",
            self.config.matching.matching_interval_ms
        );

        let interval = Duration::from_millis(self.config.matching.matching_interval_ms);
        let mut ticker = tokio::time::interval(interval);

        // 清理过期 pending changes 的计数器（每 10 次循环清理一次）
        let mut cleanup_counter = 0;
        let cleanup_timeout = Duration::from_secs(60); // 60 秒超时

        loop {
            ticker.tick().await;

            // 定期清理过期的 pending changes
            cleanup_counter += 1;
            if cleanup_counter >= 10 {
                cleanup_counter = 0;
                let removed = self.simulator.write().cleanup_expired_changes(cleanup_timeout);
                if removed > 0 {
                    warn!("🧹 Cleaned up {} expired pending changes", removed);
                }
            }

            match self.process_batch().await {
                Ok(processed) => {
                    if processed > 0 {
                        info!("✨ Processed {} requests", processed);
                    }
                }
                Err(e) => {
                    warn!("Error processing batch: {}", e);
                }
            }
        }
    }

    /// 处理一批请求
    async fn process_batch(&self) -> Result<usize> {
        // 获取队列中的请求
        let requests = self
            .state
            .get_head_requests(self.config.matching.max_batch_size);

        if requests.is_empty() {
            debug!("No requests to process");
            return Ok(0);
        }

        debug!("Processing {} requests", requests.len());

        // 计算匹配结果（找到每个订单的正确插入位置）
        let match_result = self.calculate_insert_positions(&requests).await?;

        if match_result.is_empty() {
            debug!("No valid orders to insert");
            return Ok(0);
        }

        // 执行批量处理
        self.execute_batch(&match_result).await?;

        Ok(match_result.len())
    }

    /// 计算插入位置
    async fn calculate_insert_positions(&self, requests: &[QueuedRequest]) -> Result<MatchResult> {
        let mut result = MatchResult::new();

        for request in requests {
            // 只处理限价单
            if request.request_type != RequestType::PlaceOrder
                || request.order_type != OrderType::Limit
            {
                continue;
            }

            // 获取交易对的价格层级缓存
            let (mut bid_cache, mut ask_cache) =
                self.state.get_or_create_price_cache(&request.trading_pair);

            let cache = if request.is_ask {
                &mut ask_cache
            } else {
                &mut bid_cache
            };

            // 查找或计算插入位置
            let insert_after_price_level = self
                .find_insert_position(
                    &request.trading_pair,
                    request.price,
                    request.is_ask,
                    cache,
                )
                .await?;

            // 添加到结果中
            result.add_order(
                request.request_id,
                insert_after_price_level,
                U256::zero(), // insertAfterOrder 设为 0（插入到价格层级头部）
            );
        }

        Ok(result)
    }

    /// 找到正确的插入位置
    async fn find_insert_position(
        &self,
        trading_pair: &[u8; 32],
        price: U256,
        is_ask: bool,
        cache: &mut PriceLevelCache,
    ) -> Result<U256> {
        // 如果已经存在该价格的层级，返回它
        if let Some(level_id) = cache.get_level_by_price(&price) {
            return Ok(level_id);
        }

        // 从合约获取最新的订单簿数据（不使用缓存）
        let orderbook_data = self.orderbook.order_books(*trading_pair).call().await?;

        let head = if is_ask {
            orderbook_data.0  // askHead
        } else {
            orderbook_data.2  // bidHead
        };

        // 如果订单簿为空，返回 0（插入到头部）
        if head.is_zero() {
            return Ok(U256::zero());
        }

        // 遍历价格层级找到正确位置
        let mut current_level_id = head;
        let mut prev_level_id = U256::zero();

        while !current_level_id.is_zero() {
            // 从缓存或链上获取价格层级
            let level = if let Some(l) = cache.get_level(&current_level_id) {
                l.clone()
            } else {
                // 从链上读取
                let level_data = self.orderbook.price_levels(current_level_id).call().await?;
                let level = PriceLevel {
                    price: level_data.0,
                    total_volume: level_data.1,
                    head_order_id: level_data.2,
                    tail_order_id: level_data.3,
                    next_price_level: level_data.4,
                    prev_price_level: level_data.5,
                };
                cache.insert(current_level_id, level.clone());
                level
            };

            // 比较价格
            let should_insert_here = if is_ask {
                // Ask: 价格从低到高
                price <= level.price
            } else {
                // Bid: 价格从高到低
                price >= level.price
            };

            if should_insert_here {
                // 应该插入到 current_level 之前
                return Ok(prev_level_id);
            }

            prev_level_id = current_level_id;
            current_level_id = level.next_price_level;
        }

        // 应该插入到末尾
        Ok(prev_level_id)
    }

    /// 执行批量处理
    async fn execute_batch(&self, match_result: &MatchResult) -> Result<()> {
        info!(
            "📤 Executing batch with {} orders",
            match_result.order_ids.len()
        );

        // 步骤 1: 预测每个订单的匹配结果
        let mut predictions = Vec::new();
        {
            let simulator = self.simulator.read();
            for request_id in &match_result.order_ids {
                if let Some(request) = self.state.get_request(request_id) {
                    // 只预测限价单和市价单
                    if request.request_type == RequestType::PlaceOrder {
                        let prediction = match request.order_type {
                            OrderType::Limit => simulator.predict_limit_order_match(
                                request.price,
                                request.amount,
                                request.is_ask,
                            ),
                            OrderType::Market => simulator.predict_market_order_match(
                                request.amount,
                                request.is_ask,
                            ),
                        };

                        if !prediction.matched_order_ids.is_empty() {
                            info!("  🔮 Predicted {} matches for request {}",
                                prediction.matched_order_ids.len(), request_id);
                        }

                        predictions.push((request_id, prediction, request.is_ask));
                    }
                }
            }
        }

        // 步骤 2: 调用合约的 batchProcessRequests 函数
        let tx = self
            .orderbook
            .batch_process_requests(
                match_result.order_ids.clone(),
                match_result.insert_after_price_levels.clone(),
                match_result.insert_after_orders.clone(),
            )
            .gas_price(self.config.executor.gas_price_gwei * 1_000_000_000)
            .gas(self.config.executor.gas_limit);

        // 步骤 3: 发送交易
        let pending_tx = tx.send().await.context("Failed to send transaction")?;
        let tx_hash = pending_tx.tx_hash();

        info!("📝 Transaction sent: {:?}", tx_hash);

        // 步骤 4: 记录预测为 pending（不立即应用）
        {
            let mut simulator = self.simulator.write();
            for (_request_id, prediction, is_ask) in predictions {
                simulator.apply_prediction_pending(&prediction, tx_hash, is_ask);
            }
            let pending_count = simulator.pending_changes_count();
            if pending_count > 0 {
                info!("  📋 Recorded {} pending changes for tx {:?}", pending_count, tx_hash);
            }
        }

        // 步骤 5: 等待交易确认（仅用于检测失败并回滚）
        match pending_tx.await {
            Ok(Some(receipt)) => {
                if receipt.status != Some(1.into()) {
                    error!("❌ Transaction {:?} failed, rolling back pending changes", tx_hash);
                    self.simulator.write().rollback_changes(tx_hash);
                    return Err(anyhow::anyhow!("Transaction reverted"));
                } else {
                    info!("✅ Transaction {:?} confirmed, {} events emitted", tx_hash, receipt.logs.len());
                    info!("  ⏳ Waiting for events to confirm pending changes...");
                    // 注意：不在这里 confirm pending changes！
                    // 事件处理器会通过 find_pending_tx_for_removed_order 来确认
                }
            }
            Ok(None) => {
                warn!("❌ Transaction {:?} dropped, rolling back", tx_hash);
                self.simulator.write().rollback_changes(tx_hash);
                return Err(anyhow::anyhow!("Transaction dropped"));
            }
            Err(e) => {
                error!("❌ Error waiting for transaction {:?}: {}, rolling back", tx_hash, e);
                self.simulator.write().rollback_changes(tx_hash);
                return Err(e.into());
            }
        }

        // 步骤 6: 更新本地状态：移除已处理的请求
        // 注意：订单簿状态的更新由事件处理器通过 confirm_changes 完成
        for request_id in &match_result.order_ids {
            self.state.remove_request(request_id);
            debug!("  Removed request {} from local state", request_id);
        }

        // 更新队列头部
        if let Some(first_remaining) = self.state.get_head_requests(1).first() {
            self.state.update_queue_head(first_remaining.request_id);
        } else {
            self.state.update_queue_head(U256::zero());
        }

        Ok(())
    }
}
