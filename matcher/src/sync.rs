use crate::config::Config;
use crate::contracts::{OrderBook, Sequencer};
use crate::orderbook_simulator::{SimOrder, SimPriceLevel};
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
    synced_block: u64,
}

impl StateSynchronizer {
    pub async fn new(config: Config) -> Result<Self> {
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
            synced_block: 0,
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
        // 获取当前区块高度作为同步起点
        let current_block = self.provider.get_block_number().await?.as_u64();

        info!("📚 Syncing historical state at block {}", current_block);

        // 同步 Sequencer 状态（使用 RPC 读取所有 pending requests）
        self.sync_sequencer_state(current_block).await?;

        // 同步 OrderBook 状态到 GlobalState.orderbook
        self.sync_orderbook_state().await?;

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

            let request_type_u8: u8 = request_data.2.try_into().unwrap_or(0);
            let order_type_u8: u8 = request_data.3.try_into().unwrap_or(0);

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

        // 从 state 获取已知的交易对（通过请求中的 trading_pair）
        let trading_pairs: Vec<[u8; 32]> = self.state.queued_requests
            .iter()
            .map(|r| r.trading_pair)
            .collect::<std::collections::HashSet<_>>()
            .into_iter()
            .collect();

        for trading_pair in trading_pairs {
            self.sync_trading_pair_orderbook(&trading_pair).await?;
        }

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
        self.sync_price_levels(ask_head, true).await?;

        // 同步 Bid 价格层级
        self.sync_price_levels(bid_head, false).await?;

        Ok(())
    }

    /// 同步价格层级链表到 GlobalState
    async fn sync_price_levels(&self, head_price: U256, is_ask: bool) -> Result<()> {
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
            let orders_synced = self.sync_orders_at_price_level(&sim_level, is_ask).await?;
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
    async fn sync_orders_at_price_level(&self, level: &SimPriceLevel, is_ask: bool) -> Result<usize> {
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

            // 添加到 GlobalState.orderbook
            {
                let mut orderbook = self.state.orderbook.write();
                orderbook.add_existing_order(sim_order);
            }

            count += 1;
            current_order_id = next_id;
        }

        Ok(count)
    }

    /// 监听事件
    async fn watch_events(&self) -> Result<()> {
        // 使用历史同步时的区块高度，确保不会漏掉事件
        let from_block = self.synced_block;
        info!("👀 Watching for OrderBook and Sequencer events from block {}", from_block);

        // 创建 OrderBook 事件监听任务
        let orderbook_watcher = {
            let orderbook = self.orderbook.clone();
            let state = self.state.clone();

            tokio::spawn(async move {
                Self::watch_orderbook_events(orderbook, state, from_block).await
            })
        };

        // 创建 Sequencer 事件监听任务
        let sequencer_watcher = {
            let sequencer = self.sequencer.clone();
            let state = self.state.clone();

            tokio::spawn(async move {
                Self::watch_sequencer_events(sequencer, state, from_block).await
            })
        };

        // 等待任一任务完成
        tokio::select! {
            result = orderbook_watcher => {
                match result {
                    Ok(Ok(_)) => info!("OrderBook watcher completed"),
                    Ok(Err(e)) => warn!("OrderBook watcher error: {}", e),
                    Err(e) => warn!("OrderBook watcher task error: {}", e),
                }
            }
            result = sequencer_watcher => {
                match result {
                    Ok(Ok(_)) => info!("Sequencer watcher completed"),
                    Ok(Err(e)) => warn!("Sequencer watcher error: {}", e),
                    Err(e) => warn!("Sequencer watcher task error: {}", e),
                }
            }
        }

        Ok(())
    }

    /// 监听 OrderBook 事件并更新 GlobalState
    async fn watch_orderbook_events(
        orderbook: OrderBook<Provider<Ws>>,
        state: GlobalState,
        from_block: u64,
    ) -> Result<()> {
        use crate::contracts::order_book::*;

        info!("📡 Starting OrderBook event listener from block {}", from_block);

        // 创建事件过滤器（从同步的区块开始）
        // 使用 from_block + 1 避免重复处理已同步的状态
        let event_start_block = from_block + 1;
        let trade_filter = orderbook.event::<TradeFilter>().from_block(event_start_block);
        let order_filled_filter = orderbook.event::<OrderFilledFilter>().from_block(event_start_block);
        let order_removed_filter = orderbook.event::<OrderRemovedFilter>().from_block(event_start_block);
        let order_inserted_filter = orderbook.event::<OrderInsertedFilter>().from_block(event_start_block);
        let price_level_created_filter = orderbook.event::<PriceLevelCreatedFilter>().from_block(event_start_block);
        let price_level_removed_filter = orderbook.event::<PriceLevelRemovedFilter>().from_block(event_start_block);

        // 创建事件流
        let mut trade_stream = trade_filter.stream().await?.take(10000);
        let mut order_filled_stream = order_filled_filter.stream().await?.take(10000);
        let mut order_removed_stream = order_removed_filter.stream().await?.take(10000);
        let mut order_inserted_stream = order_inserted_filter.stream().await?.take(10000);
        let mut price_level_created_stream = price_level_created_filter.stream().await?.take(10000);
        let mut price_level_removed_stream = price_level_removed_filter.stream().await?.take(10000);

        loop {
            tokio::select! {
                Some(event) = order_inserted_stream.next() => {
                    match event {
                        Ok(inserted) => {
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

                            // 先读取需要的信息
                            let old_tail = orderbook.price_levels.get(&level_key)
                                .map(|l| l.tail_order_id)
                                .unwrap_or(U256::zero());

                            // 更新旧尾部订单的 next_order_id
                            if !old_tail.is_zero() {
                                if let Some(tail_order) = orderbook.orders.get_mut(&old_tail) {
                                    tail_order.next_order_id = inserted.order_id;
                                }
                            }

                            // 更新价格层级
                            if let Some(level) = orderbook.price_levels.get_mut(&level_key) {
                                if old_tail.is_zero() {
                                    level.head_order_id = inserted.order_id;
                                }
                                level.tail_order_id = inserted.order_id;
                                level.total_volume = level.total_volume + inserted.amount;
                            }

                            // 创建并插入新订单
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
                        Err(e) => warn!("Error receiving OrderInserted event: {}", e),
                    }
                }

                Some(event) = price_level_created_stream.next() => {
                    match event {
                        Ok(created) => {
                            info!(
                                "📊 PriceLevelCreated: price={}, isAsk={}",
                                created.price,
                                created.is_ask
                            );

                            // 创建新的价格层级
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

                            // 更新链表指针 - 需要找到正确的位置插入
                            // 简化处理：直接更新 head/tail
                            let level_key = if created.is_ask {
                                created.price
                            } else {
                                created.price | (U256::one() << 255)
                            };

                            if created.is_ask {
                                let old_head = orderbook.ask_head;
                                if old_head.is_zero() || created.price < old_head {
                                    // 更新旧 head 的 prev_price
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
                                    // 更新旧 head 的 prev_price
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
                        Err(e) => warn!("Error receiving PriceLevelCreated event: {}", e),
                    }
                }

                Some(event) = price_level_removed_stream.next() => {
                    match event {
                        Ok(removed) => {
                            info!("🗑️  PriceLevelRemoved: price={}", removed.price);
                            // 从 GlobalState.orderbook 中移除价格层级
                            // 注意：需要知道 is_ask，但事件中没有这个字段
                            // 尝试两个 key
                            let mut orderbook = state.orderbook.write();
                            let ask_key = removed.price;
                            let bid_key = removed.price | (U256::one() << 255);

                            if orderbook.price_levels.contains_key(&ask_key) {
                                // 更新链表指针
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
                                // 更新链表指针
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
                        Err(e) => warn!("Error receiving PriceLevelRemoved event: {}", e),
                    }
                }

                Some(event) = trade_stream.next() => {
                    match event {
                        Ok(trade) => {
                            info!(
                                "🔄 Trade: buy={}, sell={}, price={}, amount={}",
                                trade.buy_order_id,
                                trade.sell_order_id,
                                trade.price,
                                trade.amount
                            );
                            // Trade 事件后会有 OrderFilled 事件来更新订单状态
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

                            // 更新 GlobalState.orderbook 中的订单状态
                            let mut orderbook = state.orderbook.write();
                            if filled.is_fully_filled {
                                // 移除完全成交的订单
                                orderbook.orders.remove(&filled.order_id);
                            } else {
                                // 更新部分成交
                                if let Some(order) = orderbook.orders.get_mut(&filled.order_id) {
                                    order.filled_amount = filled.filled_amount;
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
                            // 从 GlobalState.orderbook 中移除订单
                            let mut orderbook = state.orderbook.write();
                            orderbook.orders.remove(&removed.order_id);
                        }
                        Err(e) => warn!("Error receiving order removed event: {}", e),
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

    /// 监听 Sequencer 事件并更新 GlobalState
    /// 注意：启动时已通过 RPC 读取了所有 pending requests
    /// 这里只监听新产生的事件，不再使用 RPC 读取 request
    async fn watch_sequencer_events(
        sequencer: Sequencer<Provider<Ws>>,
        state: GlobalState,
        from_block: u64,
    ) -> Result<()> {
        use crate::contracts::sequencer::*;

        info!("📡 Starting Sequencer event listener from block {}", from_block);

        // 创建事件过滤器（从同步的区块之后开始，避免重复处理）
        // 使用 from_block + 1 因为 from_block 的状态已经通过 RPC 同步了
        let event_start_block = from_block + 1;
        let place_order_filter = sequencer.event::<PlaceOrderRequestedFilter>().from_block(event_start_block);
        let remove_order_filter = sequencer.event::<RemoveOrderRequestedFilter>().from_block(event_start_block);

        // 创建事件流
        let mut place_order_stream = place_order_filter.stream().await?.take(10000);
        let mut remove_order_stream = remove_order_filter.stream().await?.take(10000);

        loop {
            tokio::select! {
                Some(event) = place_order_stream.next() => {
                    match event {
                        Ok(place_order) => {
                            info!(
                                "📥 PlaceOrderRequested: requestId={}, price={}, amount={}, isAsk={}",
                                place_order.request_id,
                                place_order.price,
                                place_order.amount,
                                place_order.is_ask
                            );

                            // 创建请求并添加到 GlobalState
                            let request = QueuedRequest {
                                request_id: place_order.request_id,
                                request_type: RequestType::PlaceOrder,
                                trading_pair: place_order.trading_pair,
                                trader: place_order.trader,
                                order_type: match place_order.order_type {
                                    0 => OrderType::Limit,
                                    1 => OrderType::Market,
                                    _ => OrderType::Limit,
                                },
                                is_ask: place_order.is_ask,
                                price: place_order.price,
                                amount: place_order.amount,
                                order_id_to_remove: U256::zero(),
                                next_request_id: U256::zero(), // 将在处理时更新
                            };

                            state.add_request(request);
                            state.update_queue_head(place_order.request_id);
                        }
                        Err(e) => warn!("Error receiving PlaceOrderRequested event: {}", e),
                    }
                }

                Some(event) = remove_order_stream.next() => {
                    match event {
                        Ok(remove_order) => {
                            info!(
                                "📥 RemoveOrderRequested: requestId={}, orderIdToRemove={}",
                                remove_order.request_id,
                                remove_order.order_id_to_remove
                            );

                            // 创建请求并添加到 GlobalState
                            let request = QueuedRequest {
                                request_id: remove_order.request_id,
                                request_type: RequestType::RemoveOrder,
                                trading_pair: remove_order.trading_pair,
                                trader: remove_order.trader,
                                order_type: OrderType::Limit, // RemoveOrder 不关心 orderType
                                is_ask: false, // 将从链上获取
                                price: U256::zero(),
                                amount: U256::zero(),
                                order_id_to_remove: remove_order.order_id_to_remove,
                                next_request_id: U256::zero(),
                            };

                            state.add_request(request);
                            state.update_queue_head(remove_order.request_id);
                        }
                        Err(e) => warn!("Error receiving RemoveOrderRequested event: {}", e),
                    }
                }

                else => {
                    warn!("All Sequencer event streams ended, restarting...");
                    tokio::time::sleep(tokio::time::Duration::from_secs(1)).await;
                    return Ok(());
                }
            }
        }
    }
}
