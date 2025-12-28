use crate::config::Config;
use crate::contracts::{OrderBook, Sequencer};
use crate::contracts::order_book::OrderBookEvents;
use crate::contracts::sequencer::SequencerEvents;
use crate::orderbook_simulator::{SimOrder, SimPriceLevel};
use crate::state::GlobalState;
use crate::storage::{MongoStorage, OrderStatus, StoredOrder, StoredOrderType, StoredTrade, BatchSubmission};
use crate::types::*;
use anyhow::{Context, Result};
use ethers::prelude::*;
use ethers::abi::RawLog;
use mongodb::bson::DateTime as BsonDateTime;
use futures::stream::StreamExt;
use std::sync::Arc;
use std::collections::HashSet;
use tracing::{debug, info, warn};

pub struct StateSynchronizer {
    config: Config,
    state: GlobalState,
    provider: Arc<Provider<Ws>>,
    sequencer: Sequencer<Provider<Ws>>,
    orderbook: OrderBook<Provider<Ws>>,
    synced_block: u64,
    storage: Option<MongoStorage>,
}

impl StateSynchronizer {
    pub async fn new(config: Config, storage: Option<MongoStorage>) -> Result<Self> {
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

        // 确定起始区块：如果配置为0，则自动检测合约部署区块
        let start_block = if config.sync.start_block == 0 {
            let deployment_block = Self::get_contract_deployment_block(&provider, orderbook_addr).await?;
            info!("🔍 Auto-detected OrderBook deployment block: {}", deployment_block);
            deployment_block
        } else {
            config.sync.start_block
        };

        Ok(Self {
            config,
            state: GlobalState::new(),
            provider,
            sequencer,
            orderbook,
            synced_block: start_block,
            storage,
        })
    }

    /// 获取合约部署区块（通过二分查找）
    async fn get_contract_deployment_block(
        provider: &Provider<Ws>,
        contract_addr: Address,
    ) -> Result<u64> {
        let current_block = provider.get_block_number().await?.as_u64();

        // 检查合约是否存在
        let code = provider.get_code(contract_addr, None).await?;
        if code.is_empty() {
            anyhow::bail!("Contract not deployed at address {:?}", contract_addr);
        }

        // 二分查找部署区块
        let mut low: u64 = 0;
        let mut high = current_block;

        while low < high {
            let mid = (low + high) / 2;
            let code_at_mid = provider
                .get_code(contract_addr, Some(BlockId::Number(mid.into())))
                .await?;

            if code_at_mid.is_empty() {
                low = mid + 1;
            } else {
                high = mid;
            }
        }

        Ok(low)
    }

    /// 获取 storage 的引用
    pub fn storage(&self) -> Option<&MongoStorage> {
        self.storage.as_ref()
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
        } else {
            // 即使不同步历史，也需要同步 matchId 和当前区块
            self.sync_minimal_state().await?;
        }

        // 第二步：监听事件
        self.watch_events().await?;

        Ok(())
    }

    /// 最小化同步：只同步 matchId 和当前区块高度
    /// 注意：当 sync_historical = false 时，WebSocket 订阅从当前区块 + 1 开始
    /// 这意味着历史事件不会被同步到 MongoDB，只有新的事件会被处理
    async fn sync_minimal_state(&mut self) -> Result<()> {
        let current_block = self.provider.get_block_number().await?.as_u64();
        info!("📚 Minimal sync: getting current matchId at block {}", current_block);

        // 同步 matchId
        self.sync_match_id().await?;

        // 同步 OrderBook 状态到 GlobalState.orderbook
        // TODO: 临时注释掉，改用 event sync 来重建订单簿状态以验证 event sync 逻辑
        // self.sync_orderbook_state().await?;

        // 更新 synced_block 为当前区块，watch_events 会从 current_block + 1 开始监听
        // 在 minimal sync 模式下，不处理历史事件
        self.synced_block = current_block;
        self.state.update_current_block(current_block);

        info!("✅ Minimal sync completed at block {}", current_block);
        info!("   WebSocket subscription will start from block {}", self.synced_block + 1);

        // 标记同步完成，允许 MatchingEngine 开始处理
        self.state.mark_sync_completed();
        info!("🟢 Sync completed, MatchingEngine can start processing");

        Ok(())
    }

    /// 同步历史状态
    async fn sync_historical_state(&mut self) -> Result<()> {
        // 获取当前区块高度作为同步起点
        let current_block = self.provider.get_block_number().await?.as_u64();

        info!("📚 Syncing historical state at block {}", current_block);

        // 同步 Sequencer 状态（使用 RPC 读取所有 pending requests）
        self.sync_sequencer_state(current_block).await?;

        // 同步 OrderBook 状态到 GlobalState.orderbook
        // TODO: 临时注释掉，改用 event sync 来重建订单簿状态以验证 event sync 逻辑
        // self.sync_orderbook_state().await?;

        // 同步 matchId
        self.sync_match_id().await?;

        // 同步历史事件到 MongoDB（包括已完成的订单和交易）
        if self.storage.is_some() {
            self.sync_historical_events(current_block).await?;
        }

        // 记录同步的区块高度，后续 event 监听从这个区块开始
        // 更新 synced_block 为当前区块，这样 watch_events 会从 current_block + 1 开始监听
        // 避免历史同步过的事件被 WebSocket 重复处理
        self.synced_block = current_block;
        self.state.update_current_block(current_block);

        info!("✅ Historical state synced at block {}", current_block);
        info!("   WebSocket subscription will start from block {}", self.synced_block + 1);

        // 标记历史同步完成，允许 MatchingEngine 开始处理
        self.state.mark_sync_completed();
        info!("🟢 Sync completed, MatchingEngine can start processing");

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
            // 调用合约获取请求信息
            let request_data = self.sequencer.queued_requests(current_id).call().await?;

            // 合约结构: tradingPair(0), trader(1), requestType(2), orderType(3), isAsk(4),
            //          price(5), amount(6), uncancellableDuration(7), nextRequestId(8), prevRequestId(9)
            let next_id = request_data.8;

            let request_type_u8: u8 = request_data.2;
            let order_type_u8: u8 = request_data.3;

            let request = QueuedRequest {
                request_id: current_id,
                request_type: match request_type_u8 {
                    0 => RequestType::PlaceOrder,
                    1 => RequestType::RemoveOrder,
                    _ => {
                        warn!("Unknown request type: {}", request_type_u8);
                        break;
                    }
                },
                trading_pair: request_data.0,
                trader: request_data.1,
                order_type: match order_type_u8 {
                    0 => OrderType::Limit,
                    1 => OrderType::Market,
                    _ => OrderType::Limit,
                },
                is_ask: request_data.4,
                price: request_data.5,
                amount: request_data.6,
                uncancellable_duration: request_data.7,
                order_id_to_remove: if request_type_u8 == 1 { request_data.5 } else { U256::zero() },
                next_request_id: next_id,
            };

            self.state.add_request(request);
            count += 1;

            current_id = next_id;
        }

        debug!("  Loaded {} requests from queue", count);
        Ok(())
    }

    /// 同步 OrderBook 状态到 GlobalState.orderbook
    async fn sync_orderbook_state(&self) -> Result<()> {
        debug!("Syncing OrderBook state to GlobalState...");

        // 从配置中读取交易对
        let pair_id = &self.config.contracts.trading_pair;
        if pair_id.is_empty() {
            warn!("No trading pair configured");
            return Ok(());
        }

        if let Ok(bytes) = hex::decode(pair_id.trim_start_matches("0x")) {
            if bytes.len() == 32 {
                let mut trading_pair = [0u8; 32];
                trading_pair.copy_from_slice(&bytes);
                self.sync_trading_pair_orderbook(&trading_pair).await?;
            } else {
                warn!("Invalid trading pair length: {}", bytes.len());
            }
        } else {
            warn!("Failed to decode trading pair: {}", pair_id);
        }

        Ok(())
    }

    /// 同步 matchId
    async fn sync_match_id(&self) -> Result<()> {
        let match_id = self.orderbook.match_id().call().await?;
        self.state.update_match_id(match_id);
        info!("  matchId: {}", match_id);
        Ok(())
    }

    /// 同步历史事件到 MongoDB（包括已完成的订单和交易记录）
    /// 事件按照 emit 时间（block_number, log_index）排序后处理，确保状态更新顺序正确
    async fn sync_historical_events(&self, to_block: u64) -> Result<()> {
        let storage = match &self.storage {
            Some(s) => s,
            None => return Ok(()),
        };

        let from_block = self.config.sync.start_block;
        info!("📜 Syncing historical events from block {} to {}", from_block, to_block);

        // 定义统一的事件枚举，用于排序
        #[derive(Debug)]
        enum HistoricalEvent {
            PlaceOrder(crate::contracts::sequencer::PlaceOrderRequestedFilter, u64, u64), // event, block, log_index
            Trade(crate::contracts::order_book::TradeFilter, u64, u64),
            OrderFilled(crate::contracts::order_book::OrderFilledFilter, u64, u64),
            OrderRemoved(crate::contracts::order_book::OrderRemovedFilter, u64, u64),
            BatchProcessed(crate::contracts::order_book::BatchProcessedFilter, u64, u64, H256), // event, block, log_index, tx_hash
        }

        let mut all_events: Vec<HistoricalEvent> = Vec::new();

        // 获取 PlaceOrderRequested 事件（带元数据）
        let place_order_events = self.sequencer
            .place_order_requested_filter()
            .from_block(from_block)
            .to_block(to_block)
            .query_with_meta()
            .await?;

        info!("  Found {} PlaceOrderRequested events", place_order_events.len());

        for (event, meta) in place_order_events {
            let block_number = meta.block_number.as_u64();
            let log_index = meta.log_index.as_u64();
            all_events.push(HistoricalEvent::PlaceOrder(event, block_number, log_index));
        }

        // 获取 Trade 事件（带元数据）
        let trade_events = self.orderbook
            .trade_filter()
            .from_block(from_block)
            .to_block(to_block)
            .query_with_meta()
            .await?;

        info!("  Found {} Trade events", trade_events.len());

        for (event, meta) in trade_events {
            let block_number = meta.block_number.as_u64();
            let log_index = meta.log_index.as_u64();
            all_events.push(HistoricalEvent::Trade(event, block_number, log_index));
        }

        // 获取 OrderFilled 事件（带元数据）
        let order_filled_events = self.orderbook
            .order_filled_filter()
            .from_block(from_block)
            .to_block(to_block)
            .query_with_meta()
            .await?;

        info!("  Found {} OrderFilled events", order_filled_events.len());

        for (event, meta) in order_filled_events {
            let block_number = meta.block_number.as_u64();
            let log_index = meta.log_index.as_u64();
            all_events.push(HistoricalEvent::OrderFilled(event, block_number, log_index));
        }

        // 获取 OrderRemoved 事件（带元数据）
        let order_removed_events = self.orderbook
            .order_removed_filter()
            .from_block(from_block)
            .to_block(to_block)
            .query_with_meta()
            .await?;

        info!("  Found {} OrderRemoved events", order_removed_events.len());

        for (event, meta) in order_removed_events {
            let block_number = meta.block_number.as_u64();
            let log_index = meta.log_index.as_u64();
            all_events.push(HistoricalEvent::OrderRemoved(event, block_number, log_index));
        }

        // 获取 BatchProcessed 事件（带元数据）
        let batch_processed_events = self.orderbook
            .batch_processed_filter()
            .from_block(from_block)
            .to_block(to_block)
            .query_with_meta()
            .await?;

        info!("  Found {} BatchProcessed events", batch_processed_events.len());

        for (event, meta) in batch_processed_events {
            let block_number = meta.block_number.as_u64();
            let log_index = meta.log_index.as_u64();
            let tx_hash = meta.transaction_hash;
            all_events.push(HistoricalEvent::BatchProcessed(event, block_number, log_index, tx_hash));
        }

        // 按照 (block_number, log_index) 排序，确保按 emit 时间顺序处理
        all_events.sort_by(|a, b| {
            let (block_a, log_a) = match a {
                HistoricalEvent::PlaceOrder(_, block, log) => (*block, *log),
                HistoricalEvent::Trade(_, block, log) => (*block, *log),
                HistoricalEvent::OrderFilled(_, block, log) => (*block, *log),
                HistoricalEvent::OrderRemoved(_, block, log) => (*block, *log),
                HistoricalEvent::BatchProcessed(_, block, log, _) => (*block, *log),
            };
            let (block_b, log_b) = match b {
                HistoricalEvent::PlaceOrder(_, block, log) => (*block, *log),
                HistoricalEvent::Trade(_, block, log) => (*block, *log),
                HistoricalEvent::OrderFilled(_, block, log) => (*block, *log),
                HistoricalEvent::OrderRemoved(_, block, log) => (*block, *log),
                HistoricalEvent::BatchProcessed(_, block, log, _) => (*block, *log),
            };
            (block_a, log_a).cmp(&(block_b, log_b))
        });

        info!("  Processing {} events in chronological order", all_events.len());

        // 按时间顺序处理所有事件
        for event in all_events {
            match event {
                HistoricalEvent::PlaceOrder(place_order, block_number, _) => {
                    let order_type = match place_order.order_type {
                        0 => StoredOrderType::Limit,
                        1 => StoredOrderType::Market,
                        _ => StoredOrderType::Limit,
                    };

                    let stored_order = StoredOrder {
                        order_id: place_order.request_id.to_string(),
                        trading_pair: format!("0x{}", hex::encode(place_order.trading_pair)),
                        trader: format!("{:?}", place_order.trader).to_lowercase(),
                        order_type,
                        is_ask: place_order.is_ask,
                        price: place_order.price.to_string(),
                        amount: place_order.amount.to_string(),
                        filled_amount: "0".to_string(),
                        status: OrderStatus::Pending,
                        created_at: BsonDateTime::now(),
                        updated_at: BsonDateTime::now(),
                        block_number,
                        tx_hash: None,
                    };

                    if let Err(e) = storage.upsert_order(&stored_order).await {
                        warn!("Failed to save historical order to MongoDB: {}", e);
                    }
                }

                HistoricalEvent::Trade(trade, block_number, _) => {
                    let trading_pair_hex = format!("0x{}", hex::encode(trade.trading_pair));
                    let price_str = trade.price.to_string();
                    let amount_str = trade.amount.to_string();
                    let timestamp_ms = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap()
                        .as_millis() as i64;

                    let stored_trade = StoredTrade {
                        trade_id: format!(
                            "{}-{}-{}",
                            trading_pair_hex,
                            trade.buy_order_id,
                            trade.sell_order_id
                        ),
                        trading_pair: trading_pair_hex.clone(),
                        buy_order_id: trade.buy_order_id.to_string(),
                        sell_order_id: trade.sell_order_id.to_string(),
                        buyer: format!("{:?}", trade.buyer).to_lowercase(),
                        seller: format!("{:?}", trade.seller).to_lowercase(),
                        price: price_str.clone(),
                        amount: amount_str.clone(),
                        traded_at: BsonDateTime::now(),
                        block_number,
                        tx_hash: None,
                    };

                    storage.insert_trade(&stored_trade).await?;

                    // 更新K线数据 - 直接使用 U256 进行精确计算
                    if let Err(e) = storage.update_klines(
                        &trading_pair_hex,
                        trade.price,
                        trade.amount,
                        timestamp_ms,
                    ).await {
                        warn!("Failed to update klines for historical trade: {}", e);
                    }
                }

                HistoricalEvent::OrderFilled(filled, _, _) => {
                    let status = if filled.is_fully_filled {
                        OrderStatus::Filled
                    } else {
                        OrderStatus::PartiallyFilled
                    };

                    // 查询订单来判断是否是市价买单
                    // 市价买单：filled_amount 对应 quote_amount
                    // 其他订单：filled_amount 对应 base_amount
                    let order = storage.get_order_by_id(&filled.order_id.to_string()).await
                        .expect("Failed to query order from MongoDB")
                        .expect(&format!("Order {} must exist in DB before OrderFilled event", filled.order_id));

                    let is_market_bid = matches!(order.order_type, StoredOrderType::Market) && !order.is_ask;
                    let filled_amount = if is_market_bid {
                        filled.quote_amount.to_string()
                    } else {
                        filled.base_amount.to_string()
                    };

                    if let Err(e) = storage.update_order_status(
                        &filled.order_id.to_string(),
                        status,
                        Some(&filled_amount),
                    ).await {
                        warn!("Failed to update historical order status: {}", e);
                    }
                }

                HistoricalEvent::OrderRemoved(removed, _, _) => {
                    if let Err(e) = storage.update_order_status(
                        &removed.order_id.to_string(),
                        OrderStatus::Cancelled,
                        None,
                    ).await {
                        warn!("Failed to update historical order status to cancelled: {}", e);
                    }
                }

                HistoricalEvent::BatchProcessed(batch, block_number, _, tx_hash) => {
                    let submission = BatchSubmission {
                        match_id: batch.match_id.to_string(),
                        submitter: format!("{:?}", batch.submitter).to_lowercase(),
                        processed_count: batch.processed_count.as_u64(),
                        submitter_reward: batch.total_fees.to_string(),
                        submitted_at: BsonDateTime::now(),
                        block_number,
                        tx_hash: format!("{:?}", tx_hash),
                    };

                    storage.insert_batch_submission(&submission).await?;
                }
            }
        }

        info!("✅ Historical events synced to MongoDB");
        Ok(())
    }

    /// 同步单个交易对的订单簿到 GlobalState
    async fn sync_trading_pair_orderbook(&self, trading_pair: &[u8; 32]) -> Result<()> {
        // 获取订单簿数据
        let orderbook_data = self.orderbook.order_books(*trading_pair).call().await?;
        let ask_head = orderbook_data.0;
        let ask_tail = orderbook_data.1;
        let bid_head = orderbook_data.2;
        let bid_tail = orderbook_data.3;

        info!(
            "📊 Trading pair: askHead={}, askTail={}, bidHead={}, bidTail={}",
            ask_head, ask_tail, bid_head, bid_tail
        );

        // 更新 GlobalState.orderbook 的头尾指针
        {
            let mut orderbook = self.state.orderbook.write();
            orderbook.ask_head = ask_head;
            orderbook.ask_tail = ask_tail;
            orderbook.bid_head = bid_head;
            orderbook.bid_tail = bid_tail;
        }

        // 同步 Ask 价格层级
        self.sync_price_levels(ask_head, true, trading_pair).await?;

        // 同步 Bid 价格层级
        self.sync_price_levels(bid_head, false, trading_pair).await?;

        Ok(())
    }

    /// 同步价格层级链表到 GlobalState
    async fn sync_price_levels(&self, head_price: U256, is_ask: bool, trading_pair: &[u8; 32]) -> Result<()> {
        let mut current_price = head_price;
        let mut level_count = 0;
        let mut order_count = 0;

        while !current_price.is_zero() {
            // 获取价格层级数据
            let level_data = self.orderbook.get_price_level(current_price, is_ask).call().await?;

            let sim_level = SimPriceLevel {
                price: level_data.price,
                total_volume: level_data.total_volume,
                head_order_id: level_data.head_order_id,
                tail_order_id: level_data.tail_order_id,
                next_price: level_data.next_price,
                prev_price: level_data.prev_price,
            };

            // 同步该价格层级的订单
            let orders_synced = self.sync_orders_at_price_level(&sim_level, is_ask, trading_pair).await?;
            order_count += orders_synced;

            // 添加到 GlobalState.orderbook
            {
                let mut orderbook = self.state.orderbook.write();
                orderbook.add_existing_price_level(sim_level.clone(), is_ask);
            }

            level_count += 1;
            current_price = sim_level.next_price;
        }

        if level_count > 0 {
            info!(
                "  {} side: {} price levels, {} orders",
                if is_ask { "Ask" } else { "Bid" },
                level_count,
                order_count
            );
        }

        Ok(())
    }

    /// 同步指定价格层级的所有订单到 GlobalState
    async fn sync_orders_at_price_level(&self, level: &SimPriceLevel, is_ask: bool, trading_pair: &[u8; 32]) -> Result<usize> {
        let mut current_order_id = level.head_order_id;
        let mut count = 0;

        while !current_order_id.is_zero() {
            // 获取订单数据
            let order_data = self.orderbook.orders(current_order_id).call().await?;

            let sim_order = SimOrder {
                id: order_data.0,
                amount: order_data.2,
                filled_amount: order_data.3,
                is_market_order: order_data.4,
                is_ask,
                price_level: order_data.5,
                next_order_id: order_data.6,
                prev_order_id: order_data.7,
            };

            let next_id = sim_order.next_order_id;
            let trader = order_data.1; // trader address

            // 添加到 GlobalState.orderbook
            {
                let mut orderbook = self.state.orderbook.write();
                orderbook.add_existing_order(sim_order.clone());
            }

            // 保存到 MongoDB
            if let Some(ref storage) = self.storage {
                let status = if sim_order.filled_amount.is_zero() {
                    OrderStatus::Active
                } else if sim_order.filled_amount < sim_order.amount {
                    OrderStatus::PartiallyFilled
                } else {
                    OrderStatus::Filled
                };

                let stored_order = StoredOrder {
                    order_id: current_order_id.to_string(),
                    trading_pair: format!("0x{}", hex::encode(trading_pair)),
                    trader: format!("{:?}", trader).to_lowercase(),
                    order_type: if sim_order.is_market_order {
                        StoredOrderType::Market
                    } else {
                        StoredOrderType::Limit
                    },
                    is_ask,
                    price: level.price.to_string(),
                    amount: sim_order.amount.to_string(),
                    filled_amount: sim_order.filled_amount.to_string(),
                    status,
                    created_at: BsonDateTime::now(),
                    updated_at: BsonDateTime::now(),
                    block_number: self.synced_block,
                    tx_hash: None,
                };

                if let Err(e) = storage.upsert_order(&stored_order).await {
                    warn!("Failed to save order to MongoDB: {}", e);
                }
            }

            count += 1;
            current_order_id = next_id;
        }

        Ok(count)
    }

    /// 监听事件（带重试逻辑）
    /// 使用单一进程按照 block_number + log_index 顺序处理所有事件
    async fn watch_events(&self) -> Result<()> {
        let mut retry_count = 0u32;
        const MAX_RETRY_DELAY: u64 = 30;
        let mut last_processed_block = self.synced_block;

        // 事件去重：使用 (tx_hash, log_index) 作为唯一标识
        // 保留最近处理过的事件ID，防止 WebSocket 重复推送
        let mut processed_events: HashSet<(H256, U256)> = HashSet::new();
        let mut last_cleanup_block = last_processed_block;

        loop {
            // 使用 last_processed_block + 1 避免重复处理已同步的状态
            let event_start_block = last_processed_block + 1;

            info!("👀 Watching for OrderBook and Sequencer events from block {} (retry: {})", event_start_block, retry_count);

            // 创建合并的事件 filter，同时监听 OrderBook 和 Sequencer 的事件
            let orderbook_addr: Address = self.orderbook.address();
            let sequencer_addr: Address = self.sequencer.address();

            let filter = ethers::types::Filter::new()
                .address(vec![orderbook_addr, sequencer_addr])
                .from_block(event_start_block);

            let client = self.provider.clone();

            let mut subscription = match client.subscribe_logs(&filter).await {
                Ok(sub) => {
                    retry_count = 0;
                    info!("📡 Unified WebSocket subscription created successfully from block {}", event_start_block);
                    sub
                }
                Err(e) => {
                    retry_count += 1;
                    let delay = std::cmp::min(2u64.pow(retry_count.min(5)), MAX_RETRY_DELAY);
                    warn!("Failed to subscribe to logs: {}, retrying in {} seconds...", e, delay);
                    tokio::time::sleep(tokio::time::Duration::from_secs(delay)).await;
                    continue;
                }
            };

            // 处理订阅的日志
            while let Some(log) = subscription.next().await {
                // 事件去重检查
                let tx_hash = log.transaction_hash.unwrap_or_default();
                let log_index = log.log_index.unwrap_or_default();
                let event_id = (tx_hash, log_index);

                if processed_events.contains(&event_id) {
                    debug!("Skipping duplicate event: tx={:?}, log_index={}", tx_hash, log_index);
                    continue;
                }
                processed_events.insert(event_id);

                // 更新已处理的区块号
                if let Some(block_num) = log.block_number {
                    if block_num.as_u64() > last_processed_block {
                        last_processed_block = block_num.as_u64();
                    }

                    // 每100个区块清理一次已处理事件集合，防止内存泄漏
                    if block_num.as_u64() > last_cleanup_block + 100 {
                        processed_events.clear();
                        last_cleanup_block = block_num.as_u64();
                        debug!("Cleared processed events cache at block {}", block_num);
                    }
                }

                let raw_log = RawLog {
                    topics: log.topics.clone(),
                    data: log.data.to_vec(),
                };

                // 根据日志来源地址解析事件
                if log.address == orderbook_addr {
                    if let Ok(event) = OrderBookEvents::decode_log(&raw_log) {
                        let block_num = log.block_number.map(|b| b.as_u64()).unwrap_or(0);
                        Self::handle_orderbook_event(event, &self.state, &self.storage, block_num, tx_hash).await?;
                    } else {
                        debug!("Failed to parse OrderBook log: {:?}", log);
                    }
                } else if log.address == sequencer_addr {
                    if let Ok(event) = SequencerEvents::decode_log(&raw_log) {
                        let block_num = log.block_number.map(|b| b.as_u64()).unwrap_or(0);
                        Self::handle_sequencer_event(event, &self.state, &self.storage, block_num).await;
                    } else {
                        debug!("Failed to parse Sequencer log: {:?}", log);
                    }
                }
            }

            // 订阅结束，准备重连
            warn!("⚠️ WebSocket subscription ended, reconnecting...");
            retry_count += 1;
            let delay = std::cmp::min(2u64.pow(retry_count.min(5)), MAX_RETRY_DELAY);
            tokio::time::sleep(tokio::time::Duration::from_secs(delay)).await;
            info!("🔄 Reconnecting event watcher...");
        }
    }

    /// 处理单个 OrderBook 事件
    async fn handle_orderbook_event(
        event: crate::contracts::order_book::OrderBookEvents,
        state: &GlobalState,
        storage: &Option<MongoStorage>,
        block_number: u64,
        tx_hash: H256,
    ) -> Result<()> {
        use crate::contracts::order_book::OrderBookEvents;

        match event {
            OrderBookEvents::OrderInsertedFilter(inserted) => {
                info!(
                    "📦 OrderInserted: orderId={}, price={}, amount={}, isAsk={}",
                    inserted.order_id,
                    inserted.price,
                    inserted.amount,
                    inserted.is_ask
                );

                let mut orderbook = state.orderbook.write();
                let level_key = if inserted.is_ask {
                    inserted.price
                } else {
                    inserted.price | (U256::one() << 255)
                };

                let old_tail = orderbook.price_levels.get(&level_key)
                    .map(|l| l.tail_order_id)
                    .unwrap_or(U256::zero());

                if !old_tail.is_zero() {
                    if let Some(tail_order) = orderbook.orders.get_mut(&old_tail) {
                        tail_order.next_order_id = inserted.order_id;
                    }
                }

                if let Some(level) = orderbook.price_levels.get_mut(&level_key) {
                    if old_tail.is_zero() {
                        level.head_order_id = inserted.order_id;
                    }
                    level.tail_order_id = inserted.order_id;
                    level.total_volume += inserted.amount;
                }

                let sim_order = SimOrder {
                    id: inserted.order_id,
                    amount: inserted.amount,
                    filled_amount: U256::zero(),
                    is_market_order: false,
                    is_ask: inserted.is_ask,
                    price_level: inserted.price,
                    next_order_id: U256::zero(),
                    prev_order_id: old_tail,
                };
                orderbook.orders.insert(inserted.order_id, sim_order);

                debug!(
                    "  Added order {} to simulator (price={}, is_ask={})",
                    inserted.order_id, inserted.price, inserted.is_ask
                );
            }

            OrderBookEvents::PriceLevelCreatedFilter(created) => {
                info!(
                    "📊 PriceLevelCreated: price={}, isAsk={}",
                    created.price,
                    created.is_ask
                );

                let new_level = SimPriceLevel {
                    price: created.price,
                    total_volume: U256::zero(),
                    head_order_id: U256::zero(),
                    tail_order_id: U256::zero(),
                    next_price: U256::zero(),
                    prev_price: U256::zero(),
                };

                let mut orderbook = state.orderbook.write();
                orderbook.add_existing_price_level(new_level, created.is_ask);

                let level_key = if created.is_ask {
                    created.price
                } else {
                    created.price | (U256::one() << 255)
                };

                // Find the correct insert position by traversing the linked list
                // For Ask: prices are sorted low to high (head = lowest)
                // For Bid: prices are sorted high to low (head = highest)
                let (head, get_key): (U256, Box<dyn Fn(U256) -> U256>) = if created.is_ask {
                    (orderbook.ask_head, Box::new(|p| p))
                } else {
                    (orderbook.bid_head, Box::new(|p| p | (U256::one() << 255)))
                };

                if head.is_zero() {
                    // Empty list - this becomes both head and tail
                    if created.is_ask {
                        orderbook.ask_head = created.price;
                        orderbook.ask_tail = created.price;
                    } else {
                        orderbook.bid_head = created.price;
                        orderbook.bid_tail = created.price;
                    }
                } else {
                    // Find insert position
                    let mut current = head;
                    let mut prev = U256::zero();
                    let mut insert_after = U256::zero();

                    while !current.is_zero() {
                        let current_key = get_key(current);
                        if let Some(level) = orderbook.price_levels.get(&current_key) {
                            let should_insert_before = if created.is_ask {
                                // Ask: insert before first level with price > new price
                                current > created.price
                            } else {
                                // Bid: insert before first level with price < new price
                                current < created.price
                            };

                            if should_insert_before {
                                insert_after = prev;
                                break;
                            }

                            prev = current;
                            current = level.next_price;
                        } else {
                            break;
                        }
                    }

                    // If we reached the end without finding insert point, insert at tail
                    if current.is_zero() {
                        insert_after = prev;
                    }

                    if insert_after.is_zero() {
                        // Insert at head
                        let old_head = head;
                        let old_head_key = get_key(old_head);
                        if let Some(old_head_level) = orderbook.price_levels.get_mut(&old_head_key) {
                            old_head_level.prev_price = created.price;
                        }
                        if let Some(new_level) = orderbook.price_levels.get_mut(&level_key) {
                            new_level.next_price = old_head;
                        }
                        if created.is_ask {
                            orderbook.ask_head = created.price;
                        } else {
                            orderbook.bid_head = created.price;
                        }
                    } else {
                        // Insert after insert_after
                        let insert_after_key = get_key(insert_after);
                        let next_price = orderbook.price_levels.get(&insert_after_key)
                            .map(|l| l.next_price)
                            .unwrap_or(U256::zero());

                        // Update new level's pointers
                        if let Some(new_level) = orderbook.price_levels.get_mut(&level_key) {
                            new_level.prev_price = insert_after;
                            new_level.next_price = next_price;
                        }

                        // Update insert_after's next pointer
                        if let Some(prev_level) = orderbook.price_levels.get_mut(&insert_after_key) {
                            prev_level.next_price = created.price;
                        }

                        // Update next level's prev pointer
                        if !next_price.is_zero() {
                            let next_key = get_key(next_price);
                            if let Some(next_level) = orderbook.price_levels.get_mut(&next_key) {
                                next_level.prev_price = created.price;
                            }
                        } else {
                            // Insert at tail
                            if created.is_ask {
                                orderbook.ask_tail = created.price;
                            } else {
                                orderbook.bid_tail = created.price;
                            }
                        }
                    }
                }

                debug!(
                    "  Created price level {} (is_ask={})",
                    created.price, created.is_ask
                );
            }

            OrderBookEvents::PriceLevelRemovedFilter(removed) => {
                info!("🗑️  PriceLevelRemoved: price={}, isAsk={}", removed.price, removed.is_ask);
                let mut orderbook = state.orderbook.write();

                // 直接使用 event 中的 is_ask 字段
                if removed.is_ask {
                    let ask_key = removed.price;
                    if let Some(level) = orderbook.price_levels.get(&ask_key) {
                        let prev = level.prev_price;
                        let next = level.next_price;
                        if !prev.is_zero() {
                            if let Some(prev_level) = orderbook.price_levels.get_mut(&prev) {
                                prev_level.next_price = next;
                            }
                        } else {
                            orderbook.ask_head = next;
                        }
                        if !next.is_zero() {
                            if let Some(next_level) = orderbook.price_levels.get_mut(&next) {
                                next_level.prev_price = prev;
                            }
                        } else {
                            orderbook.ask_tail = prev;
                        }
                    }
                    orderbook.price_levels.remove(&ask_key);
                    debug!("  Removed ask price level at {}", removed.price);
                } else {
                    let bid_key = removed.price | (U256::one() << 255);
                    if let Some(level) = orderbook.price_levels.get(&bid_key) {
                        let prev = level.prev_price;
                        let next = level.next_price;
                        let prev_key = prev | (U256::one() << 255);
                        let next_key = next | (U256::one() << 255);
                        if !prev.is_zero() {
                            if let Some(prev_level) = orderbook.price_levels.get_mut(&prev_key) {
                                prev_level.next_price = next;
                            }
                        } else {
                            orderbook.bid_head = next;
                        }
                        if !next.is_zero() {
                            if let Some(next_level) = orderbook.price_levels.get_mut(&next_key) {
                                next_level.prev_price = prev;
                            }
                        } else {
                            orderbook.bid_tail = prev;
                        }
                    }
                    orderbook.price_levels.remove(&bid_key);
                    debug!("  Removed bid price level at {}", removed.price);
                }
            }

            OrderBookEvents::TradeFilter(trade) => {
                info!(
                    "🔄 Trade: buy={}, sell={}, price={}, amount={}",
                    trade.buy_order_id,
                    trade.sell_order_id,
                    trade.price,
                    trade.amount
                );

                // Save trade to MongoDB and update klines
                if let Some(ref storage) = storage {
                    let trading_pair_hex = format!("0x{}", hex::encode(trade.trading_pair));
                    let price_str = trade.price.to_string();
                    let amount_str = trade.amount.to_string();
                    let timestamp_ms = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap()
                        .as_millis() as i64;

                    let stored_trade = StoredTrade {
                        trade_id: format!(
                            "{}-{}-{}",
                            trading_pair_hex,
                            trade.buy_order_id,
                            trade.sell_order_id
                        ),
                        trading_pair: trading_pair_hex.clone(),
                        buy_order_id: trade.buy_order_id.to_string(),
                        sell_order_id: trade.sell_order_id.to_string(),
                        buyer: format!("{:?}", trade.buyer),
                        seller: format!("{:?}", trade.seller),
                        price: price_str.clone(),
                        amount: amount_str.clone(),
                        traded_at: BsonDateTime::now(),
                        block_number: 0, // Not available from event stream directly
                        tx_hash: None,
                    };

                    if let Err(e) = storage.insert_trade(&stored_trade).await {
                        warn!("Failed to save trade to MongoDB: {}", e);
                    } else {
                        info!(
                            "💾 Trade saved: buy={}, sell={}",
                            trade.buy_order_id, trade.sell_order_id
                        );
                    }

                    // 更新K线数据 - 直接使用 U256 进行精确计算
                    if let Err(e) = storage.update_klines(
                        &trading_pair_hex,
                        trade.price,
                        trade.amount,
                        timestamp_ms,
                    ).await {
                        warn!("Failed to update klines: {}", e);
                    } else {
                        debug!("📊 Klines updated for trading pair {}", trading_pair_hex);
                    }
                }
            }

            OrderBookEvents::OrderFilledFilter(filled) => {
                info!(
                    "✅ OrderFilled: order={}, quote={}, base={}, fully_filled={}",
                    filled.order_id,
                    filled.quote_amount,
                    filled.base_amount,
                    filled.is_fully_filled
                );

                // 根据订单类型决定 filled_amount 使用 quote 还是 base
                // 市价买单：filled_amount 对应 quote_amount
                // 其他订单：filled_amount 对应 base_amount
                // 注意：市价单不在 state.orderbook 中，必须从 MongoDB 查询
                let filled_increment = if let Some(ref storage) = storage {
                    let order = storage.get_order_by_id(&filled.order_id.to_string()).await
                        .expect("Failed to query order from MongoDB")
                        .expect(&format!("Order {} must exist in DB before OrderFilled event", filled.order_id));

                    let is_market_bid = matches!(order.order_type, StoredOrderType::Market) && !order.is_ask;
                    if is_market_bid {
                        filled.quote_amount
                    } else {
                        filled.base_amount
                    }
                } else {
                    // 没有 MongoDB 时，从内存查询（仅限价单）
                    let orderbook = state.orderbook.read();
                    let is_market_bid = orderbook.orders.get(&filled.order_id)
                        .map(|o| o.is_market_order && !o.is_ask)
                        .unwrap_or(false);
                    if is_market_bid {
                        filled.quote_amount
                    } else {
                        filled.base_amount
                    }
                };

                {
                    let mut orderbook = state.orderbook.write();
                    if filled.is_fully_filled {
                        // Before removing the order, update the linked list in the price level
                        if let Some(order) = orderbook.orders.get(&filled.order_id) {
                            let is_ask = order.is_ask;
                            let price = order.price_level;
                            let prev_order_id = order.prev_order_id;
                            let next_order_id = order.next_order_id;

                            let level_key = if is_ask {
                                price
                            } else {
                                price | (U256::one() << 255)
                            };

                            // Update prev order's next pointer
                            if !prev_order_id.is_zero() {
                                if let Some(prev_order) = orderbook.orders.get_mut(&prev_order_id) {
                                    prev_order.next_order_id = next_order_id;
                                }
                            }

                            // Update next order's prev pointer
                            if !next_order_id.is_zero() {
                                if let Some(next_order) = orderbook.orders.get_mut(&next_order_id) {
                                    next_order.prev_order_id = prev_order_id;
                                }
                            }

                            // Update price level's head/tail if needed
                            if let Some(level) = orderbook.price_levels.get_mut(&level_key) {
                                if level.head_order_id == filled.order_id {
                                    level.head_order_id = next_order_id;
                                }
                                if level.tail_order_id == filled.order_id {
                                    level.tail_order_id = prev_order_id;
                                }
                            }
                        }
                        orderbook.orders.remove(&filled.order_id);
                    } else {
                        if let Some(order) = orderbook.orders.get_mut(&filled.order_id) {
                            order.filled_amount += filled_increment;
                        }
                    }
                }

                if let Some(ref storage) = storage {
                    let status = if filled.is_fully_filled {
                        OrderStatus::Filled
                    } else {
                        OrderStatus::PartiallyFilled
                    };
                    if let Err(e) = storage.update_order_status(
                        &filled.order_id.to_string(),
                        status,
                        Some(&filled_increment.to_string()),
                    ).await {
                        warn!("Failed to update order in MongoDB: {}", e);
                    }
                }
            }

            OrderBookEvents::OrderRemovedFilter(removed) => {
                info!("🗑️  OrderRemoved: order={}", removed.order_id);
                {
                    let mut orderbook = state.orderbook.write();
                    orderbook.orders.remove(&removed.order_id);
                }

                if let Some(ref storage) = storage {
                    if let Err(e) = storage.update_order_status(
                        &removed.order_id.to_string(),
                        OrderStatus::Cancelled,
                        None,
                    ).await {
                        warn!("Failed to update order in MongoDB: {}", e);
                    }
                }
            }

            OrderBookEvents::BatchProcessedFilter(batch) => {
                info!(
                    "📦 BatchProcessed: submitter={:?}, matchId={}, processedCount={}, totalFees={}",
                    batch.submitter,
                    batch.match_id,
                    batch.processed_count,
                    batch.total_fees
                );

                // Update matchId in state
                state.update_match_id(batch.match_id);

                if let Some(ref storage) = storage {
                    let submission = BatchSubmission {
                        match_id: batch.match_id.to_string(),
                        submitter: format!("{:?}", batch.submitter).to_lowercase(),
                        processed_count: batch.processed_count.as_u64(),
                        submitter_reward: batch.total_fees.to_string(),
                        submitted_at: BsonDateTime::now(),
                        block_number,
                        tx_hash: format!("{:?}", tx_hash),
                    };

                    storage.insert_batch_submission(&submission).await?;
                    info!(
                        "💾 BatchSubmission saved: matchId={}, submitter={:?}, reward={}",
                        batch.match_id, batch.submitter, batch.total_fees
                    );
                }
            }

            // 忽略其他事件
            _ => {
                debug!("Received unhandled OrderBook event");
            }
        }
        Ok(())
    }

    /// 处理单个 Sequencer 事件
    async fn handle_sequencer_event(
        event: crate::contracts::sequencer::SequencerEvents,
        state: &GlobalState,
        storage: &Option<MongoStorage>,
        block_number: u64,
    ) {
        use crate::contracts::sequencer::SequencerEvents;

        match event {
            SequencerEvents::PlaceOrderRequestedFilter(place_order) => {
                info!(
                    "📥 PlaceOrderRequested: requestId={}, price={}, amount={}, isAsk={}, uncancellableDuration={}",
                    place_order.request_id,
                    place_order.price,
                    place_order.amount,
                    place_order.is_ask,
                    place_order.uncancellable_duration
                );

                let order_type = match place_order.order_type {
                    0 => OrderType::Limit,
                    1 => OrderType::Market,
                    _ => OrderType::Limit,
                };

                let request = QueuedRequest {
                    request_id: place_order.request_id,
                    request_type: RequestType::PlaceOrder,
                    trading_pair: place_order.trading_pair,
                    trader: place_order.trader,
                    order_type: order_type.clone(),
                    is_ask: place_order.is_ask,
                    price: place_order.price,
                    amount: place_order.amount,
                    uncancellable_duration: place_order.uncancellable_duration,
                    order_id_to_remove: U256::zero(),
                    next_request_id: U256::zero(),
                };

                // 添加到队列尾部，维护链表结构
                state.add_request_to_tail(request);

                if let Some(ref storage) = storage {
                    let stored_order = StoredOrder {
                        order_id: place_order.request_id.to_string(),
                        trading_pair: format!("0x{}", hex::encode(place_order.trading_pair)),
                        trader: format!("{:?}", place_order.trader).to_lowercase(),
                        order_type: match order_type {
                            OrderType::Limit => StoredOrderType::Limit,
                            OrderType::Market => StoredOrderType::Market,
                        },
                        is_ask: place_order.is_ask,
                        price: place_order.price.to_string(),
                        amount: place_order.amount.to_string(),
                        filled_amount: "0".to_string(),
                        status: OrderStatus::Pending,
                        created_at: BsonDateTime::now(),
                        updated_at: BsonDateTime::now(),
                        block_number,
                        tx_hash: None,
                    };

                    if let Err(e) = storage.upsert_order(&stored_order).await {
                        warn!("Failed to save order to MongoDB: {}", e);
                    }
                }
            }

            SequencerEvents::RemoveOrderRequestedFilter(remove_order) => {
                info!(
                    "📥 RemoveOrderRequested: requestId={}, orderIdToRemove={}",
                    remove_order.request_id,
                    remove_order.order_id_to_remove
                );

                let request = QueuedRequest {
                    request_id: remove_order.request_id,
                    request_type: RequestType::RemoveOrder,
                    trading_pair: remove_order.trading_pair,
                    trader: remove_order.trader,
                    order_type: OrderType::Limit,
                    is_ask: false,
                    price: U256::zero(),
                    amount: U256::zero(),
                    uncancellable_duration: U256::zero(),  // 撤单请求不需要此字段
                    order_id_to_remove: remove_order.order_id_to_remove,
                    next_request_id: U256::zero(),
                };

                // 添加到队列尾部，维护链表结构
                state.add_request_to_tail(request);
            }

            SequencerEvents::RequestProcessedFilter(processed) => {
                info!(
                    "✅ RequestProcessed: requestId={}, requestType={:?}",
                    processed.request_id,
                    processed.request_type
                );

                // 获取当前请求的 next_request_id，用于更新 queue_head
                let next_request_id = state.queued_requests
                    .get(&processed.request_id)
                    .map(|r| r.next_request_id)
                    .unwrap_or(U256::zero());

                // 从队列中移除已处理的请求
                state.remove_request(&processed.request_id);

                // 如果被移除的是 queue_head，更新 queue_head 为下一个请求
                let current_head = *state.queue_head.read();
                if current_head == processed.request_id {
                    state.update_queue_head(next_request_id);
                    debug!(
                        "  Updated queue_head from {} to {}",
                        processed.request_id, next_request_id
                    );
                }
            }

            // 忽略其他事件
            _ => {
                debug!("Received unhandled Sequencer event");
            }
        }
    }
}
