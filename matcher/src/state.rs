use crate::orderbook_simulator::OrderBookSimulator;
use crate::types::*;
use dashmap::DashMap;
use ethers::types::{Address, U256};
use std::collections::HashSet;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

/// 交易对元数据
#[derive(Clone, Debug)]
pub struct TradingPairMetadata {
    pub pair_id: [u8; 32],
    pub base_token: Address,
    pub quote_token: Address,
    pub base_symbol: String,
    pub quote_symbol: String,
    pub base_decimals: u8,
    pub quote_decimals: u8,
    pub ticker: String,  // e.g., "ETH/USDC"
}

/// 全局状态（线程安全）
#[derive(Clone)]
pub struct GlobalState {
    /// Sequencer 请求队列
    /// request_id -> QueuedRequest
    pub queued_requests: Arc<DashMap<U256, QueuedRequest>>,

    /// Sequencer 队列头部
    pub queue_head: Arc<parking_lot::RwLock<U256>>,

    /// 每个交易对的 OrderBook 模拟器
    /// trading_pair -> OrderBookSimulator
    pub orderbooks: Arc<DashMap<[u8; 32], OrderBookSimulator>>,

    /// 支持的交易对集合（用于快速过滤）
    pub supported_pairs: Arc<parking_lot::RwLock<HashSet<[u8; 32]>>>,

    /// 交易对元数据
    /// trading_pair -> TradingPairMetadata
    pub pair_metadata: Arc<DashMap<[u8; 32], TradingPairMetadata>>,

    /// 当前同步到的区块高度
    pub current_block: Arc<parking_lot::RwLock<u64>>,

    /// 链上 matchId，用于检测状态同步
    pub match_id: Arc<parking_lot::RwLock<U256>>,

    /// 历史同步是否完成（MatchingEngine 需要等待此标志）
    pub sync_completed: Arc<AtomicBool>,
}

impl GlobalState {
    pub fn new() -> Self {
        Self {
            queued_requests: Arc::new(DashMap::new()),
            queue_head: Arc::new(parking_lot::RwLock::new(U256::zero())),
            orderbooks: Arc::new(DashMap::new()),
            supported_pairs: Arc::new(parking_lot::RwLock::new(HashSet::new())),
            pair_metadata: Arc::new(DashMap::new()),
            current_block: Arc::new(parking_lot::RwLock::new(0)),
            match_id: Arc::new(parking_lot::RwLock::new(U256::zero())),
            sync_completed: Arc::new(AtomicBool::new(false)),
        }
    }

    /// 初始化支持的交易对
    pub fn init_trading_pairs(&self, pairs: Vec<[u8; 32]>) {
        let mut supported = self.supported_pairs.write();
        for pair in pairs {
            supported.insert(pair);
            // 为每个交易对创建独立的 OrderBookSimulator
            self.orderbooks.insert(pair, OrderBookSimulator::new());
        }
    }

    /// 添加交易对元数据
    pub fn add_pair_metadata(&self, metadata: TradingPairMetadata) {
        let pair_id = metadata.pair_id;
        self.pair_metadata.insert(pair_id, metadata);
    }

    /// 获取交易对元数据
    pub fn get_pair_metadata(&self, pair_id: &[u8; 32]) -> Option<TradingPairMetadata> {
        self.pair_metadata.get(pair_id).map(|m| m.clone())
    }

    /// 获取所有交易对元数据
    pub fn get_all_pair_metadata(&self) -> Vec<TradingPairMetadata> {
        self.pair_metadata.iter().map(|entry| entry.value().clone()).collect()
    }

    /// 检查交易对是否被支持
    pub fn is_pair_supported(&self, pair: &[u8; 32]) -> bool {
        self.supported_pairs.read().contains(pair)
    }

    /// 标记历史同步已完成
    pub fn mark_sync_completed(&self) {
        self.sync_completed.store(true, Ordering::SeqCst);
    }

    /// 检查历史同步是否已完成
    pub fn is_sync_completed(&self) -> bool {
        self.sync_completed.load(Ordering::SeqCst)
    }

    /// 获取队列中的前 N 个请求（只返回支持的交易对的请求）
    pub fn get_head_requests(&self, n: usize) -> Vec<QueuedRequest> {
        let mut result = Vec::new();
        let head = *self.queue_head.read();
        let supported = self.supported_pairs.read();

        if head.is_zero() {
            return result;
        }

        let mut current = head;
        while result.len() < n && !current.is_zero() {
            if let Some(request) = self.queued_requests.get(&current) {
                // 只返回支持的交易对的请求
                if supported.contains(&request.trading_pair) {
                    result.push(request.clone());
                }
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

    /// 添加请求到队列尾部（维护链表结构）
    /// 如果队列为空，同时更新 queue_head
    pub fn add_request_to_tail(&self, request: QueuedRequest) {
        let request_id = request.request_id;

        // 如果队列为空，设置为队列头部
        let current_head = *self.queue_head.read();
        if current_head.is_zero() {
            *self.queue_head.write() = request_id;
            self.queued_requests.insert(request_id, request);
            return;
        }

        // 找到队列尾部，更新链表
        // 遍历找到尾部请求
        let mut current = current_head;
        let mut tail = current_head;
        while !current.is_zero() {
            tail = current;
            if let Some(req) = self.queued_requests.get(&current) {
                current = req.next_request_id;
            } else {
                break;
            }
        }

        // 更新尾部请求的 next_request_id
        if let Some(mut tail_request) = self.queued_requests.get_mut(&tail) {
            tail_request.next_request_id = request_id;
        }

        // 添加新请求
        self.queued_requests.insert(request_id, request);
    }

    /// 添加请求到队列（不维护链表，用于历史同步）
    pub fn add_request(&self, request: QueuedRequest) {
        self.queued_requests.insert(request.request_id, request);
    }

    /// 从队列中移除请求
    pub fn remove_request(&self, request_id: &U256) {
        self.queued_requests.remove(request_id);
    }

    /// 更新当前区块
    pub fn update_current_block(&self, block: u64) {
        *self.current_block.write() = block;
    }

    /// 获取指定交易对的订单簿模拟器（克隆）
    pub fn clone_orderbook(&self, trading_pair: &[u8; 32]) -> Option<OrderBookSimulator> {
        self.orderbooks.get(trading_pair).map(|ob| ob.clone())
    }

    /// 获取指定交易对的订单簿模拟器的可写引用
    pub fn get_orderbook_mut(&self, trading_pair: &[u8; 32]) -> Option<dashmap::mapref::one::RefMut<'_, [u8; 32], OrderBookSimulator>> {
        self.orderbooks.get_mut(trading_pair)
    }

    /// 获取指定交易对的订单簿模拟器的只读引用
    pub fn get_orderbook(&self, trading_pair: &[u8; 32]) -> Option<dashmap::mapref::one::Ref<'_, [u8; 32], OrderBookSimulator>> {
        self.orderbooks.get(trading_pair)
    }

    /// 获取当前 matchId
    pub fn get_match_id(&self) -> U256 {
        *self.match_id.read()
    }

    /// 更新 matchId
    pub fn update_match_id(&self, new_match_id: U256) {
        *self.match_id.write() = new_match_id;
    }

    /// 检查是否有可撮合的订单（检查所有支持的交易对）
    /// 返回 (has_matchable_limit_orders, has_matchable_market_orders)
    pub fn has_matchable_orders(&self) -> (bool, bool) {
        let mut has_limit = false;
        let mut has_market = false;

        for entry in self.orderbooks.iter() {
            let (limit, market) = entry.value().has_matchable_orders();
            has_limit = has_limit || limit;
            has_market = has_market || market;
            if has_limit && has_market {
                break;
            }
        }

        (has_limit, has_market)
    }

    /// 检查指定交易对是否有可撮合的订单
    pub fn has_matchable_orders_for_pair(&self, trading_pair: &[u8; 32]) -> (bool, bool) {
        if let Some(orderbook) = self.orderbooks.get(trading_pair) {
            orderbook.has_matchable_orders()
        } else {
            (false, false)
        }
    }

    /// 获取所有支持的交易对
    pub fn get_supported_pairs(&self) -> Vec<[u8; 32]> {
        self.supported_pairs.read().iter().cloned().collect()
    }
}
