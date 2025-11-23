use crate::types::*;
use dashmap::DashMap;
use ethers::types::U256;
use std::sync::Arc;

/// 全局状态（线程安全）
#[derive(Clone)]
pub struct GlobalState {
    /// Sequencer 请求队列
    /// request_id -> QueuedRequest
    pub queued_requests: Arc<DashMap<U256, QueuedRequest>>,

    /// Sequencer 队列头部
    pub queue_head: Arc<parking_lot::RwLock<U256>>,

    /// OrderBook 价格层级缓存（按交易对）
    /// trading_pair -> (bid_cache, ask_cache)
    pub price_levels: Arc<DashMap<[u8; 32], (PriceLevelCache, PriceLevelCache)>>,

    /// OrderBook 订单数据
    /// order_id -> Order
    pub orders: Arc<DashMap<U256, Order>>,

    /// OrderBook 数据（按交易对）
    /// trading_pair -> OrderBookData
    pub orderbook_data: Arc<DashMap<[u8; 32], OrderBookData>>,

    /// 当前同步到的区块高度
    pub current_block: Arc<parking_lot::RwLock<u64>>,
}

impl GlobalState {
    pub fn new() -> Self {
        Self {
            queued_requests: Arc::new(DashMap::new()),
            queue_head: Arc::new(parking_lot::RwLock::new(U256::zero())),
            price_levels: Arc::new(DashMap::new()),
            orders: Arc::new(DashMap::new()),
            orderbook_data: Arc::new(DashMap::new()),
            current_block: Arc::new(parking_lot::RwLock::new(0)),
        }
    }

    /// 获取队列中的前 N 个请求
    pub fn get_head_requests(&self, n: usize) -> Vec<QueuedRequest> {
        let mut result = Vec::new();
        let head = *self.queue_head.read();

        if head.is_zero() {
            return result;
        }

        let mut current = head;
        for _ in 0..n {
            if current.is_zero() {
                break;
            }

            if let Some(request) = self.queued_requests.get(&current) {
                result.push(request.clone());
                current = request.next_request_id;
            } else {
                break;
            }
        }

        result
    }

    /// 更新队列头部
    pub fn update_queue_head(&self, new_head: U256) {
        *self.queue_head.write() = new_head;
    }

    /// 添加请求到队列
    pub fn add_request(&self, request: QueuedRequest) {
        self.queued_requests.insert(request.request_id, request);
    }

    /// 从队列中移除请求
    pub fn remove_request(&self, request_id: &U256) {
        self.queued_requests.remove(request_id);
    }

    /// 获取或创建交易对的价格层级缓存
    pub fn get_or_create_price_cache(&self, trading_pair: &[u8; 32]) -> (PriceLevelCache, PriceLevelCache) {
        self.price_levels
            .entry(*trading_pair)
            .or_insert((PriceLevelCache::new(), PriceLevelCache::new()))
            .clone()
    }

    /// 更新价格层级缓存
    pub fn update_price_cache(&self, trading_pair: &[u8; 32], bid_cache: PriceLevelCache, ask_cache: PriceLevelCache) {
        self.price_levels.insert(*trading_pair, (bid_cache, ask_cache));
    }

    /// 添加订单
    pub fn add_order(&self, order: Order) {
        self.orders.insert(order.id, order);
    }

    /// 移除订单
    pub fn remove_order(&self, order_id: &U256) {
        self.orders.remove(order_id);
    }

    /// 更新订单簿数据
    pub fn update_orderbook_data(&self, trading_pair: &[u8; 32], data: OrderBookData) {
        self.orderbook_data.insert(*trading_pair, data);
    }

    /// 获取订单簿数据
    pub fn get_orderbook_data(&self, trading_pair: &[u8; 32]) -> Option<OrderBookData> {
        self.orderbook_data.get(trading_pair).map(|entry| entry.clone())
    }

    /// 更新当前区块
    pub fn update_current_block(&self, block: u64) {
        *self.current_block.write() = block;
    }

    /// 获取当前区块
    pub fn get_current_block(&self) -> u64 {
        *self.current_block.read()
    }
}
