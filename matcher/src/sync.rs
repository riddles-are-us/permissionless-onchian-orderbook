use crate::config::Config;
use crate::contracts::{OrderBook, Sequencer};
use crate::match_simulator::MatchSimulator;
use crate::state::GlobalState;
use crate::types::*;
use anyhow::{Context, Result};
use ethers::prelude::*;
use futures::stream::StreamExt;
use std::sync::Arc;
use tracing::{debug, info, warn};

pub struct StateSynchronizer {
    config: Config,
    state: GlobalState,
    provider: Arc<Provider<Ws>>,
    sequencer: Sequencer<Provider<Ws>>,
    orderbook: OrderBook<Provider<Ws>>,
    simulator: Arc<parking_lot::RwLock<MatchSimulator>>,
}

impl StateSynchronizer {
    pub async fn new(
        config: Config,
        simulator: Arc<parking_lot::RwLock<MatchSimulator>>,
    ) -> Result<Self> {
        // 连接到节点
        let ws = Ws::connect(&config.network.rpc_url)
            .await
            .context("Failed to connect to WebSocket")?;
        let provider = Arc::new(Provider::new(ws));

        // 创建合约实例
        let sequencer_addr: Address = config.contracts.sequencer.parse()?;
        let orderbook_addr: Address = config.contracts.orderbook.parse()?;

        let sequencer = Sequencer::new(sequencer_addr, provider.clone());
        let orderbook = OrderBook::new(orderbook_addr, provider.clone());

        Ok(Self {
            config,
            state: GlobalState::new(),
            provider,
            sequencer,
            orderbook,
            simulator,
        })
    }

    pub fn state(&self) -> GlobalState {
        self.state.clone()
    }

    /// 运行同步器
    pub async fn run(mut self) -> Result<()> {
        info!("🔄 Starting state synchronizer");

        // 第一步：同步历史状态
        if self.config.sync.sync_historical {
            self.sync_historical_state().await?;
        }

        // 第二步：监听事件
        self.watch_events().await?;

        Ok(())
    }

    /// 同步历史状态
    async fn sync_historical_state(&mut self) -> Result<()> {
        let start_block = if self.config.sync.start_block == 0 {
            self.provider.get_block_number().await?.as_u64()
        } else {
            self.config.sync.start_block
        };

        info!("📚 Syncing historical state from block {}", start_block);

        // 同步 Sequencer 状态
        self.sync_sequencer_state(start_block).await?;

        // 同步 OrderBook 状态
        self.sync_orderbook_state(start_block).await?;

        self.state.update_current_block(start_block);
        info!("✅ Historical state synced to block {}", start_block);

        Ok(())
    }

    /// 同步 Sequencer 状态
    async fn sync_sequencer_state(&self, _from_block: u64) -> Result<()> {
        debug!("Syncing Sequencer state...");

        // 获取当前队列头部
        let head_request_id = self.sequencer.queue_head().call().await?;
        self.state.update_queue_head(head_request_id);
        debug!("  Queue head: {}", head_request_id);

        // 如果队列为空，直接返回
        if head_request_id.is_zero() {
            debug!("  Queue is empty");
            return Ok(());
        }

        // 从头部开始遍历整个队列
        let mut current_id = head_request_id;
        let mut count = 0;

        while !current_id.is_zero() {
            // 调用合约获取请求信息（使用 queuedRequests mapping 获取完整数据）
            let request_data = self.sequencer.queued_requests(current_id).call().await?;

            // 优化后的 request_data tuple 字段（按新结构体顺序）：
            // 0: tradingPair (bytes32)
            // 1: trader (address)
            // 2: requestType (uint8)
            // 3: orderType (uint8)
            // 4: isAsk (bool)
            // 5: price (uint256)
            // 6: amount (uint256)
            // 7: nextRequestId (uint256)
            // 8: prevRequestId (uint256)
            let next_id = request_data.7; // nextRequestId 是第 8 个字段 (index 7)

            // requestType 从 uint8 转换
            let request_type_u8: u8 = request_data.2.try_into().unwrap_or(0);
            // orderType 从 uint8 转换
            let order_type_u8: u8 = request_data.3.try_into().unwrap_or(0);

            let request = QueuedRequest {
                request_id: current_id,  // 使用 mapping key 作为 requestId
                request_type: match request_type_u8 {
                    0 => RequestType::PlaceOrder,
                    1 => RequestType::RemoveOrder,
                    _ => {
                        warn!("Unknown request type: {}", request_type_u8);
                        break;
                    }
                },
                trading_pair: request_data.0,  // tradingPair
                trader: request_data.1,         // trader
                order_type: match order_type_u8 {
                    0 => OrderType::Limit,
                    1 => OrderType::Market,
                    _ => OrderType::Limit,
                },
                is_ask: request_data.4,
                price: request_data.5,
                amount: request_data.6,
                // orderIdToRemove: 对于 RemoveOrder，存储在 price 字段中
                order_id_to_remove: if request_type_u8 == 1 { request_data.5 } else { ethers::types::U256::zero() },
                next_request_id: next_id,
            };

            self.state.add_request(request);
            count += 1;

            current_id = next_id;
        }

        debug!("  Loaded {} requests from queue", count);
        Ok(())
    }

    /// 同步 OrderBook 状态
    async fn sync_orderbook_state(&self, _from_block: u64) -> Result<()> {
        debug!("Syncing OrderBook state...");
        // 这里可以同步价格层级、订单等状态
        // 由于状态可能很大，建议按需同步或通过事件重建
        Ok(())
    }

    /// 监听事件
    async fn watch_events(&self) -> Result<()> {
        info!("👀 Watching for OrderBook and Sequencer events");

        // 创建 OrderBook 事件监听任务
        let orderbook_watcher = {
            let orderbook = self.orderbook.clone();
            let state = self.state.clone();
            let provider = self.provider.clone();
            let simulator = self.simulator.clone();

            tokio::spawn(async move {
                Self::watch_orderbook_events(orderbook, state, provider, simulator).await
            })
        };

        // 创建 Sequencer 轮询任务（保持原有的轮询机制）
        let sequencer_poller = {
            let provider = self.provider.clone();
            let sequencer = self.sequencer.clone();
            let state = self.state.clone();
            let start_block = self.config.sync.start_block;

            tokio::spawn(async move {
                Self::poll_sequencer_state(provider, sequencer, state, start_block).await
            })
        };

        // 等待任一任务完成（或失败）
        tokio::select! {
            result = orderbook_watcher => {
                match result {
                    Ok(Ok(_)) => info!("OrderBook watcher completed"),
                    Ok(Err(e)) => warn!("OrderBook watcher error: {}", e),
                    Err(e) => warn!("OrderBook watcher task error: {}", e),
                }
            }
            result = sequencer_poller => {
                match result {
                    Ok(Ok(_)) => info!("Sequencer poller completed"),
                    Ok(Err(e)) => warn!("Sequencer poller error: {}", e),
                    Err(e) => warn!("Sequencer poller task error: {}", e),
                }
            }
        }

        Ok(())
    }

    /// 监听 OrderBook 事件
    async fn watch_orderbook_events(
        orderbook: OrderBook<Provider<Ws>>,
        state: GlobalState,
        provider: Arc<Provider<Ws>>,
        _simulator: Arc<parking_lot::RwLock<MatchSimulator>>,
    ) -> Result<()> {
        use crate::contracts::order_book::*;

        info!("📡 Starting OrderBook event listener");

        let current_block = provider.get_block_number().await?.as_u64();

        // 创建事件过滤器（从当前区块开始）
        let trade_filter = orderbook.event::<TradeFilter>().from_block(current_block);
        let order_filled_filter = orderbook.event::<OrderFilledFilter>().from_block(current_block);
        let order_removed_filter = orderbook.event::<OrderRemovedFilter>().from_block(current_block);
        let market_order_removed_filter = orderbook.event::<MarketOrderRemovedFilter>().from_block(current_block);

        // 创建事件流
        let mut trade_stream = trade_filter.stream().await?.take(1000);
        let mut order_filled_stream = order_filled_filter.stream().await?.take(1000);
        let mut order_removed_stream = order_removed_filter.stream().await?.take(1000);
        let mut market_order_removed_stream = market_order_removed_filter.stream().await?.take(1000);

        loop {
            tokio::select! {
                Some(event) = trade_stream.next() => {
                    match event {
                        Ok(trade) => {
                            debug!(
                                "🔄 Trade: pair={:?}, buy={}, sell={}, price={}, amount={}",
                                trade.trading_pair,
                                trade.buy_order_id,
                                trade.sell_order_id,
                                trade.price,
                                trade.amount
                            );
                            // Trade 事件本身不需要更新状态，OrderFilled 会处理
                            // Pending changes 由 execute_batch 在交易确认时处理
                        }
                        Err(e) => warn!("Error receiving trade event: {}", e),
                    }
                }

                Some(event) = order_filled_stream.next() => {
                    match event {
                        Ok(filled) => {
                            info!(
                                "✅ OrderFilled: order={}, filled={}, fully_filled={}",
                                filled.order_id,
                                filled.filled_amount,
                                filled.is_fully_filled
                            );

                            // 如果订单完全成交，从本地状态中移除
                            if filled.is_fully_filled {
                                state.remove_order(&filled.order_id);
                                debug!("  Removed fully filled order {} from local state", filled.order_id);
                            } else {
                                // 部分成交，更新订单的 filledAmount
                                if let Some(mut order) = state.orders.get_mut(&filled.order_id) {
                                    order.filled_amount = filled.filled_amount;
                                    debug!("  Updated order {} filled amount to {}", filled.order_id, filled.filled_amount);
                                }
                            }
                        }
                        Err(e) => warn!("Error receiving order filled event: {}", e),
                    }
                }

                Some(event) = order_removed_stream.next() => {
                    match event {
                        Ok(removed) => {
                            info!("🗑️  OrderRemoved: order={}", removed.order_id);
                            state.remove_order(&removed.order_id);
                        }
                        Err(e) => warn!("Error receiving order removed event: {}", e),
                    }
                }

                Some(event) = market_order_removed_stream.next() => {
                    match event {
                        Ok(removed) => {
                            info!("🗑️  MarketOrderRemoved: order={}", removed.order_id);
                            state.remove_order(&removed.order_id);
                        }
                        Err(e) => warn!("Error receiving market order removed event: {}", e),
                    }
                }

                else => {
                    warn!("All event streams ended, restarting...");
                    tokio::time::sleep(tokio::time::Duration::from_secs(1)).await;
                    return Ok(());
                }
            }
        }
    }

    /// 轮询 Sequencer 状态（保持原有功能）
    async fn poll_sequencer_state(
        provider: Arc<Provider<Ws>>,
        sequencer: Sequencer<Provider<Ws>>,
        state: GlobalState,
        _start_block: u64,
    ) -> Result<()> {
        info!("🔄 Starting Sequencer state poller");

        let poll_interval = tokio::time::Duration::from_secs(5);
        let mut interval = tokio::time::interval(poll_interval);

        loop {
            interval.tick().await;

            // 获取当前区块号
            let current_block = match provider.get_block_number().await {
                Ok(block) => block.as_u64(),
                Err(e) => {
                    warn!("Failed to get current block: {}", e);
                    continue;
                }
            };

            // 重新同步 Sequencer 状态
            // 注意：这里创建一个临时的 StateSynchronizer 实例来复用 sync_sequencer_state 方法
            // 实际上我们只需要轮询队列头部
            let head_request_id = match sequencer.queue_head().call().await {
                Ok(head) => head,
                Err(e) => {
                    warn!("Failed to get queue head: {}", e);
                    continue;
                }
            };

            state.update_queue_head(head_request_id);
            state.update_current_block(current_block);

            // 检查队列长度
            if !head_request_id.is_zero() {
                let queue_size = state.queued_requests.len();
                if queue_size > 0 {
                    debug!("📋 Queue status: {} pending requests", queue_size);
                }
            }
        }
    }

}
