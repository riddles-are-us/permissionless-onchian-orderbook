use crate::config::Config;
use crate::contracts::{OrderBook, Sequencer};
use crate::orderbook_simulator::{SimOrder, SimPriceLevel};
use crate::state::GlobalState;
use crate::storage::{MongoStorage, OrderStatus, StoredOrder, StoredOrderType};
use crate::types::*;
use anyhow::{Context, Result};
use chrono::Utc;
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
        }

        // 第二步：监听事件
        self.watch_events().await?;

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
        self.sync_orderbook_state().await?;

        // 同步 matchId
        self.sync_match_id().await?;

        // 记录同步的区块高度，后续 event 监听从这个区块开始
        self.synced_block = current_block;
        self.state.update_current_block(current_block);

        info!("✅ Historical state synced at block {}", current_block);
        info!("   Event monitoring will start from block {}", current_block);

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

            let next_id = request_data.7;

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
                    created_at: Utc::now(),
                    updated_at: Utc::now(),
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
    async fn watch_events(&self) -> Result<()> {
        // 使用历史同步时的区块高度，确保不会漏掉事件
        let from_block = self.synced_block;

        loop {
            info!("👀 Watching for OrderBook and Sequencer events from block {}", from_block);

            // 创建 OrderBook 事件监听任务
            let orderbook_watcher = {
                let orderbook = self.orderbook.clone();
                let state = self.state.clone();
                let storage = self.storage.clone();

                tokio::spawn(async move {
                    Self::watch_orderbook_events(orderbook, state, storage, from_block).await
                })
            };

            // 创建 Sequencer 事件监听任务
            let sequencer_watcher = {
                let sequencer = self.sequencer.clone();
                let state = self.state.clone();
                let storage = self.storage.clone();

                tokio::spawn(async move {
                    Self::watch_sequencer_events(sequencer, state, storage, from_block).await
                })
            };

            // 等待任一任务完成
            tokio::select! {
                result = orderbook_watcher => {
                    match result {
                        Ok(Ok(_)) => info!("OrderBook watcher completed normally"),
                        Ok(Err(e)) => warn!("OrderBook watcher error: {}", e),
                        Err(e) => warn!("OrderBook watcher task error: {}", e),
                    }
                }
                result = sequencer_watcher => {
                    match result {
                        Ok(Ok(_)) => info!("Sequencer watcher completed normally"),
                        Ok(Err(e)) => warn!("Sequencer watcher error: {}", e),
                        Err(e) => warn!("Sequencer watcher task error: {}", e),
                    }
                }
            }

            // 任一 watcher 退出后，等待一段时间再重试
            warn!("⚠️ Event watcher stopped, restarting in 5 seconds...");
            tokio::time::sleep(tokio::time::Duration::from_secs(5)).await;

            // 重新连接 WebSocket（可能连接已断开）
            info!("🔄 Reconnecting event watchers...");
        }
    }

    /// 监听 OrderBook 事件并更新 GlobalState
    async fn watch_orderbook_events(
        orderbook: OrderBook<Provider<Ws>>,
        state: GlobalState,
        storage: Option<MongoStorage>,
        from_block: u64,
    ) -> Result<()> {
        info!("📡 Starting OrderBook event listener from block {}", from_block);

        // 使用 from_block + 1 避免重复处理已同步的状态
        let event_start_block = from_block + 1;

        // 使用 events() 监听所有事件，带重试逻辑
        loop {
            let events_filter = orderbook.events().from_block(event_start_block);

            let mut event_stream = match events_filter.stream().await {
                Ok(stream) => stream,
                Err(e) => {
                    debug!(
                        "OrderBook event stream creation failed (block {} may not exist yet): {}, retrying in 2s...",
                        event_start_block, e
                    );
                    tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;
                    continue;
                }
            };

            info!("📡 OrderBook event stream created successfully from block {}", event_start_block);

            // 处理事件流
            while let Some(event_result) = event_stream.next().await {
                match event_result {
                    Ok(event) => {
                        Self::handle_orderbook_event(event, &state, &storage).await;
                    }
                    Err(e) => {
                        warn!("Error receiving OrderBook event: {}, will retry...", e);
                        break; // 跳出内层循环，重新创建事件流
                    }
                }
            }

            warn!("OrderBook event stream ended, reconnecting in 2s...");
            tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;
        }
    }

    /// 处理单个 OrderBook 事件
    async fn handle_orderbook_event(
        event: crate::contracts::order_book::OrderBookEvents,
        state: &GlobalState,
        storage: &Option<MongoStorage>,
    ) {
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

                if created.is_ask {
                    let old_head = orderbook.ask_head;
                    if old_head.is_zero() || created.price < old_head {
                        if !old_head.is_zero() {
                            let old_head_key = old_head;
                            if let Some(old_head_level) = orderbook.price_levels.get_mut(&old_head_key) {
                                old_head_level.prev_price = created.price;
                            }
                            if let Some(new_level) = orderbook.price_levels.get_mut(&level_key) {
                                new_level.next_price = old_head;
                            }
                        }
                        orderbook.ask_head = created.price;
                    }
                    let old_tail = orderbook.ask_tail;
                    if old_tail.is_zero() || created.price > old_tail {
                        orderbook.ask_tail = created.price;
                    }
                } else {
                    let old_head = orderbook.bid_head;
                    if old_head.is_zero() || created.price > old_head {
                        if !old_head.is_zero() {
                            let old_head_key = old_head | (U256::one() << 255);
                            if let Some(old_head_level) = orderbook.price_levels.get_mut(&old_head_key) {
                                old_head_level.prev_price = created.price;
                            }
                            if let Some(new_level) = orderbook.price_levels.get_mut(&level_key) {
                                new_level.next_price = old_head;
                            }
                        }
                        orderbook.bid_head = created.price;
                    }
                    let old_tail = orderbook.bid_tail;
                    if old_tail.is_zero() || created.price < old_tail {
                        orderbook.bid_tail = created.price;
                    }
                }

                debug!(
                    "  Created price level {} (is_ask={})",
                    created.price, created.is_ask
                );
            }

            OrderBookEvents::PriceLevelRemovedFilter(removed) => {
                info!("🗑️  PriceLevelRemoved: price={}", removed.price);
                let mut orderbook = state.orderbook.write();
                let ask_key = removed.price;
                let bid_key = removed.price | (U256::one() << 255);

                if orderbook.price_levels.contains_key(&ask_key) {
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
                } else if orderbook.price_levels.contains_key(&bid_key) {
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
            }

            OrderBookEvents::OrderFilledFilter(filled) => {
                info!(
                    "✅ OrderFilled: order={}, filled={}, fully_filled={}",
                    filled.order_id,
                    filled.filled_amount,
                    filled.is_fully_filled
                );

                {
                    let mut orderbook = state.orderbook.write();
                    if filled.is_fully_filled {
                        orderbook.orders.remove(&filled.order_id);
                    } else {
                        if let Some(order) = orderbook.orders.get_mut(&filled.order_id) {
                            order.filled_amount = filled.filled_amount;
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
                        Some(&filled.filled_amount.to_string()),
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

            OrderBookEvents::MatchIdChangedFilter(changed) => {
                info!("🔄 MatchIdChanged: newMatchId={}", changed.new_match_id);
                state.update_match_id(changed.new_match_id);
            }

            // 忽略其他事件
            _ => {
                debug!("Received unhandled OrderBook event");
            }
        }
    }

    /// 监听 Sequencer 事件并更新 GlobalState
    /// 注意：启动时已通过 RPC 读取了所有 pending requests
    /// 这里只监听新产生的事件，不再使用 RPC 读取 request
    async fn watch_sequencer_events(
        sequencer: Sequencer<Provider<Ws>>,
        state: GlobalState,
        storage: Option<MongoStorage>,
        from_block: u64,
    ) -> Result<()> {
        info!("📡 Starting Sequencer event listener from block {}", from_block);

        // 使用 from_block + 1 因为 from_block 的状态已经通过 RPC 同步了
        let event_start_block = from_block + 1;

        // 使用 events() 监听所有事件，带重试逻辑
        loop {
            let events_filter = sequencer.events().from_block(event_start_block);

            let mut event_stream = match events_filter.stream().await {
                Ok(stream) => stream,
                Err(e) => {
                    debug!(
                        "Sequencer event stream creation failed (block {} may not exist yet): {}, retrying in 2s...",
                        event_start_block, e
                    );
                    tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;
                    continue;
                }
            };

            info!("📡 Sequencer event stream created successfully from block {}", event_start_block);

            // 处理事件流
            while let Some(event_result) = event_stream.next().await {
                match event_result {
                    Ok(event) => {
                        Self::handle_sequencer_event(event, &state, &storage, from_block).await;
                    }
                    Err(e) => {
                        warn!("Error receiving Sequencer event: {}, will retry...", e);
                        break; // 跳出内层循环，重新创建事件流
                    }
                }
            }

            warn!("Sequencer event stream ended, reconnecting in 2s...");
            tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;
        }
    }

    /// 处理单个 Sequencer 事件
    async fn handle_sequencer_event(
        event: crate::contracts::sequencer::SequencerEvents,
        state: &GlobalState,
        storage: &Option<MongoStorage>,
        from_block: u64,
    ) {
        use crate::contracts::sequencer::SequencerEvents;

        match event {
            SequencerEvents::PlaceOrderRequestedFilter(place_order) => {
                info!(
                    "📥 PlaceOrderRequested: requestId={}, price={}, amount={}, isAsk={}",
                    place_order.request_id,
                    place_order.price,
                    place_order.amount,
                    place_order.is_ask
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
                        created_at: Utc::now(),
                        updated_at: Utc::now(),
                        block_number: from_block,
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
                    order_id_to_remove: remove_order.order_id_to_remove,
                    next_request_id: U256::zero(),
                };

                // 添加到队列尾部，维护链表结构
                state.add_request_to_tail(request);
            }

            // 忽略其他事件
            _ => {
                debug!("Received unhandled Sequencer event");
            }
        }
    }
}
