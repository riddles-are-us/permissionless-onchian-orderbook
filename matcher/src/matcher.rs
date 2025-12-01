use crate::config::Config;
use crate::contracts::OrderBook;
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
    orderbook: OrderBook<SignerMiddleware<Arc<Provider<Ws>>, LocalWallet>>,
    trading_pair: [u8; 32],
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

        // 解析 trading_pair
        let trading_pair_str = &config.contracts.trading_pair;
        let trading_pair = if trading_pair_str.starts_with("0x") {
            let bytes = hex::decode(&trading_pair_str[2..])
                .context("Failed to decode trading_pair hex")?;
            let mut arr = [0u8; 32];
            if bytes.len() == 32 {
                arr.copy_from_slice(&bytes);
            }
            arr
        } else {
            [0u8; 32]
        };

        Ok(Self {
            config,
            state,
            orderbook,
            trading_pair,
        })
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

        loop {
            ticker.tick().await;

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

    /// 检查 matchId 是否同步
    async fn check_match_id_synced(&self) -> Result<bool> {
        let local_match_id = self.state.get_match_id();
        let chain_match_id = self.orderbook.match_id().call().await?;

        if local_match_id != chain_match_id {
            warn!(
                "⚠️  matchId mismatch: local={}, chain={}. Waiting for sync...",
                local_match_id, chain_match_id
            );
            return Ok(false);
        }
        Ok(true)
    }

    /// 尝试调用 matchAll() 继续撮合未完成的订单
    async fn try_match_all(&self) -> Result<()> {
        // 检查是否有可撮合的订单
        let (has_limit, has_market) = self.state.has_matchable_orders();

        if !has_limit && !has_market {
            return Ok(());
        }

        info!(
            "🔄 Found matchable orders (limit={}, market={}), calling matchAll...",
            has_limit, has_market
        );

        // 调用 matchAll，使用配置中的 max_iterations
        let max_iterations = U256::from(self.config.matching.max_iterations);
        let tx = self
            .orderbook
            .match_all(self.trading_pair, max_iterations)
            .gas_price(self.config.executor.gas_price_gwei * 1_000_000_000)
            .gas(self.config.executor.gas_limit);

        let pending_tx = tx.send().await.context("Failed to send matchAll transaction")?;
        let tx_hash = pending_tx.tx_hash();

        info!("📝 matchAll transaction sent: {:?}", tx_hash);

        match pending_tx.await {
            Ok(Some(receipt)) => {
                if receipt.status == Some(1.into()) {
                    info!(
                        "✅ matchAll confirmed: {:?}, {} events emitted",
                        tx_hash,
                        receipt.logs.len()
                    );
                } else {
                    warn!("❌ matchAll transaction failed: {:?}", tx_hash);
                }
            }
            Ok(None) => {
                warn!("❌ matchAll transaction dropped: {:?}", tx_hash);
            }
            Err(e) => {
                warn!("❌ Error waiting for matchAll transaction: {}", e);
            }
        }

        Ok(())
    }

    /// 处理一批请求
    async fn process_batch(&self) -> Result<usize> {
        // 检查 matchId 是否同步
        if !self.check_match_id_synced().await? {
            return Ok(0);
        }

        // 检查是否有未撮合完的订单（可能是上次 maxIteration 导致的）
        // 如果有，先调用 matchAll() 继续撮合
        if let Err(e) = self.try_match_all().await {
            warn!("Error calling matchAll: {}", e);
            // 继续处理，不阻塞
        }

        // matchAll 可能改变了 matchId，需要重新检查同步状态
        if !self.check_match_id_synced().await? {
            return Ok(0);
        }

        // 获取队列中的请求
        let requests = self
            .state
            .get_head_requests(self.config.matching.max_batch_size);

        if requests.is_empty() {
            debug!("No requests to process");
            return Ok(0);
        }

        debug!("Processing {} requests", requests.len());

        // 使用 Simulator 计算每个订单的 insertAfterPrice
        // Simulator 从 GlobalState 获取当前状态，不再从链上同步
        let match_result = self.calculate_insert_positions_with_simulator(&requests)?;

        if match_result.is_empty() {
            debug!("No valid orders to insert");
            return Ok(0);
        }

        // 执行批量处理
        self.execute_batch(&match_result).await?;

        Ok(match_result.len())
    }

    /// 使用 Simulator 计算插入位置（严格按照链上逻辑）
    /// Simulator 从 GlobalState 获取当前订单簿状态，不再从链上同步
    fn calculate_insert_positions_with_simulator(
        &self,
        requests: &[QueuedRequest],
    ) -> Result<MatchResult> {
        let mut result = MatchResult::new();

        // 从 GlobalState 克隆当前 orderbook 状态
        let mut sim = self.state.clone_orderbook();

        debug!(
            "📊 Simulator state: ask_head={}, bid_head={}, {} price_levels, {} orders",
            sim.ask_head,
            sim.bid_head,
            sim.price_levels.len(),
            sim.orders.len()
        );

        // 对每个请求，模拟执行并获取必要参数
        for request in requests {
            match request.request_type {
                RequestType::RemoveOrder => {
                    // 模拟移除订单，更新本地状态
                    // 这样后续的 insert 订单基于正确的状态计算 insertAfterPrice
                    let removed = sim.simulate_remove_order(
                        request.order_id_to_remove,
                        request.is_ask,
                    );
                    debug!(
                        "RemoveOrder {}: order_id={}, removed={}",
                        request.request_id, request.order_id_to_remove, removed
                    );
                    // RemoveOrder 不需要 insertAfterPrice，但仍需加入批处理
                    result.add_order(
                        request.request_id,
                        U256::zero(),
                        U256::zero(),
                    );
                }
                RequestType::PlaceOrder => {
                    if request.order_type == OrderType::Limit {
                        // 限价单：使用 simulator 模拟插入，获取 insertAfterPrice
                        let insert_after_price = sim.simulate_insert_order(
                            request.request_id,
                            request.price,
                            request.amount,
                            request.is_ask,
                        );

                        debug!(
                            "PlaceOrder {} (limit, price={}, is_ask={}): insertAfterPrice={}",
                            request.request_id, request.price, request.is_ask, insert_after_price
                        );

                        // 添加到结果中
                        result.add_order(
                            request.request_id,
                            insert_after_price,
                            U256::zero(), // insertAfterOrder 设为 0（插入到价格层级头部）
                        );
                    } else {
                        // 市价单：模拟插入市价单队列并撮合
                        // 市价单不需要 insertAfterPrice，但需要模拟以更新订单簿状态
                        sim.simulate_insert_market_order(
                            request.request_id,
                            request.amount,
                            request.is_ask,
                        );

                        debug!(
                            "PlaceOrder {} (market, amount={}, is_ask={}): simulated",
                            request.request_id, request.amount, request.is_ask
                        );

                        // 市价单的 insertAfterPrice 和 insertAfterOrder 都设为 0
                        result.add_order(
                            request.request_id,
                            U256::zero(),
                            U256::zero(),
                        );
                    }
                }
            }
        }

        Ok(result)
    }

    /// 执行批量处理
    async fn execute_batch(&self, match_result: &MatchResult) -> Result<()> {
        info!(
            "📤 Executing batch with {} orders",
            match_result.order_ids.len()
        );

        // 调用合约的 batchProcessRequests 函数
        let tx = self
            .orderbook
            .batch_process_requests(
                match_result.order_ids.clone(),
                match_result.insert_after_price_levels.clone(),
                match_result.insert_after_orders.clone(),
            )
            .gas_price(self.config.executor.gas_price_gwei * 1_000_000_000)
            .gas(self.config.executor.gas_limit);

        // 发送交易
        let pending_tx = tx.send().await.context("Failed to send transaction")?;
        let tx_hash = pending_tx.tx_hash();

        info!("📝 Transaction sent: {:?}", tx_hash);

        // 等待交易确认
        match pending_tx.await {
            Ok(Some(receipt)) => {
                if receipt.status != Some(1.into()) {
                    error!("❌ Transaction {:?} failed", tx_hash);
                    return Err(anyhow::anyhow!("Transaction reverted"));
                } else {
                    info!(
                        "✅ Transaction {:?} confirmed, {} events emitted",
                        tx_hash,
                        receipt.logs.len()
                    );
                }
            }
            Ok(None) => {
                warn!("❌ Transaction {:?} dropped", tx_hash);
                return Err(anyhow::anyhow!("Transaction dropped"));
            }
            Err(e) => {
                error!("❌ Error waiting for transaction {:?}: {}", tx_hash, e);
                return Err(e.into());
            }
        }

        // 更新本地状态：移除已处理的请求
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
