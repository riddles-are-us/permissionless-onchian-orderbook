use crate::config::Config;
use crate::contracts::OrderBook;
use crate::state::GlobalState;
use crate::types::*;
use anyhow::{Context, Result};
use ethers::prelude::*;
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;
use tracing::{debug, error, info, warn};

pub struct MatchingEngine {
    config: Config,
    state: GlobalState,
    orderbook: OrderBook<SignerMiddleware<Arc<Provider<Ws>>, LocalWallet>>,
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

        // 交易对将在 sync 完成后从 GlobalState 获取
        // 不再在这里检查，因为自动发现是在 sync 阶段执行的

        Ok(Self {
            config,
            state,
            orderbook,
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

        // 等待历史同步完成
        info!("⏳ Waiting for historical sync to complete...");
        while !self.state.is_sync_completed() {
            tokio::time::sleep(Duration::from_millis(100)).await;
        }

        // 从 GlobalState 获取交易对（在 sync 完成后）
        let trading_pairs = self.state.get_supported_pairs();
        if trading_pairs.is_empty() {
            return Err(anyhow::anyhow!("No trading pairs discovered or configured"));
        }

        info!("🎯 Discovered {} trading pairs:", trading_pairs.len());
        for (i, pair) in trading_pairs.iter().enumerate() {
            info!("   [{}] 0x{}", i, hex::encode(pair));
        }

        info!("✅ Historical sync completed, starting to process requests");

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

    /// 尝试调用 matchAll() 继续撮合未完成的订单（对所有交易对）
    async fn try_match_all(&self) -> Result<()> {
        let max_iterations = U256::from(self.config.matching.max_iterations);
        let trading_pairs = self.state.get_supported_pairs();

        for trading_pair in &trading_pairs {
            // 检查该交易对是否有可撮合的订单
            let (has_limit, has_market) = self.state.has_matchable_orders_for_pair(trading_pair);

            if !has_limit && !has_market {
                continue;
            }

            info!(
                "🔄 Found matchable orders for pair 0x{} (limit={}, market={}), calling matchAll...",
                hex::encode(&trading_pair[..8]),
                has_limit, has_market
            );

            // 调用 matchAll
            let tx = self
                .orderbook
                .match_all(*trading_pair, max_iterations)
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
    /// 支持多交易对：每个交易对使用独立的 Simulator
    fn calculate_insert_positions_with_simulator(
        &self,
        requests: &[QueuedRequest],
    ) -> Result<MatchResult> {
        let mut result = MatchResult::new();

        // 为每个交易对克隆独立的 simulator
        let mut simulators: HashMap<[u8; 32], crate::orderbook_simulator::OrderBookSimulator> = HashMap::new();
        for request in requests {
            if !simulators.contains_key(&request.trading_pair) {
                if let Some(sim) = self.state.clone_orderbook(&request.trading_pair) {
                    debug!(
                        "📊 Simulator for pair 0x{}: ask_head={}, bid_head={}, {} price_levels, {} orders",
                        hex::encode(&request.trading_pair[..8]),
                        sim.ask_head,
                        sim.bid_head,
                        sim.price_levels.len(),
                        sim.orders.len()
                    );
                    simulators.insert(request.trading_pair, sim);
                } else {
                    warn!(
                        "⚠️ No orderbook simulator for pair 0x{}, skipping request {}",
                        hex::encode(&request.trading_pair[..8]),
                        request.request_id
                    );
                    continue;
                }
            }
        }

        // 对每个请求，模拟执行并获取必要参数
        for request in requests {
            let sim = match simulators.get_mut(&request.trading_pair) {
                Some(s) => s,
                None => continue, // 跳过没有 simulator 的交易对
            };

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
                        // 限价单：使用 simulator 模拟插入，获取 insertAfterPrice 和 insertAfterOrder
                        let (insert_after_price, insert_after_order) = sim.simulate_insert_order(
                            request.request_id,
                            request.price,
                            request.amount,
                            request.is_ask,
                        );

                        debug!(
                            "PlaceOrder {} (limit, price={}, is_ask={}): insertAfterPrice={}, insertAfterOrder={}",
                            request.request_id, request.price, request.is_ask, insert_after_price, insert_after_order
                        );

                        // 添加到结果中（使用 tailOrderId 作为 insertAfterOrder 以保证 FIFO）
                        result.add_order(
                            request.request_id,
                            insert_after_price,
                            insert_after_order,
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

        // 打印详细的交易参数
        info!("📋 Batch parameters:");
        for i in 0..match_result.order_ids.len() {
            info!(
                "   [{}] requestId={}, insertAfterPrice={}, insertAfterOrder={}",
                i,
                match_result.order_ids[i],
                match_result.insert_after_price_levels[i],
                match_result.insert_after_orders[i]
            );
        }

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

        // 先尝试 estimate gas 来检查是否会 revert
        match tx.estimate_gas().await {
            Ok(gas) => {
                info!("⛽ Estimated gas: {}", gas);
            }
            Err(e) => {
                error!("❌ Transaction would revert! Error: {:?}", e);
                // 尝试获取更详细的错误信息
                if let Some(revert) = e.as_revert() {
                    error!("❌ Revert reason: {}", revert);
                }
                return Err(anyhow::anyhow!("Transaction would revert: {:?}", e));
            }
        }

        // 发送交易
        let pending_tx = tx.send().await.context("Failed to send transaction")?;
        let tx_hash = pending_tx.tx_hash();

        info!("📝 Transaction sent: {:?}", tx_hash);

        // 等待交易确认
        match pending_tx.await {
            Ok(Some(receipt)) => {
                if receipt.status != Some(1.into()) {
                    error!("❌ Transaction {:?} failed", tx_hash);
                    error!("❌ Gas used: {:?}", receipt.gas_used);
                    error!("❌ Block number: {:?}", receipt.block_number);
                    // 打印所有日志
                    for (i, log) in receipt.logs.iter().enumerate() {
                        error!("❌ Log[{}]: {:?}", i, log);
                    }
                    return Err(anyhow::anyhow!("Transaction reverted"));
                } else {
                    info!(
                        "✅ Transaction {:?} confirmed in block {:?}, gas used: {:?}, {} events emitted",
                        tx_hash,
                        receipt.block_number,
                        receipt.gas_used,
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

        // 注意：请求的移除和 queue_head 的更新由 sync.rs 通过监听 RequestProcessed 事件完成
        // 这样可以保证状态与链上一致

        Ok(())
    }
}
