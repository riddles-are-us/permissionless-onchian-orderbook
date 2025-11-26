use ethers::types::{Address, U256};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// 请求类型
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum RequestType {
    PlaceOrder = 0,
    RemoveOrder = 1,
}

/// 订单类型
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum OrderType {
    Limit = 0,
    Market = 1,
}

/// 排队中的请求
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QueuedRequest {
    pub request_id: U256,
    pub request_type: RequestType,
    pub trading_pair: [u8; 32],
    pub trader: Address,
    pub order_type: OrderType,
    pub is_ask: bool,
    pub price: U256,
    pub amount: U256,
    pub order_id_to_remove: U256,
    pub next_request_id: U256,
}

/// 价格层级
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PriceLevel {
    pub price: U256,
    pub total_volume: U256,
    pub head_order_id: U256,
    pub tail_order_id: U256,
    pub next_price: U256,
    pub prev_price: U256,
}

/// 订单
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Order {
    pub id: U256,
    pub trader: Address,
    pub amount: U256,
    pub filled_amount: U256,
    pub is_market_order: bool,
    pub price_level: U256,
    pub next_order_id: U256,
    pub prev_order_id: U256,
}

/// 订单簿数据
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OrderBookData {
    pub ask_head: U256,
    pub ask_tail: U256,
    pub bid_head: U256,
    pub bid_tail: U256,
    pub market_ask_head: U256,
    pub market_ask_tail: U256,
    pub market_bid_head: U256,
    pub market_bid_tail: U256,
}

/// 匹配结果
#[derive(Debug, Clone)]
pub struct MatchResult {
    /// 需要插入的订单 ID 列表
    pub order_ids: Vec<U256>,
    /// 每个订单的插入位置（价格层级）
    pub insert_after_price_levels: Vec<U256>,
    /// 每个订单的插入位置（订单）
    pub insert_after_orders: Vec<U256>,
}

impl MatchResult {
    pub fn new() -> Self {
        Self {
            order_ids: Vec::new(),
            insert_after_price_levels: Vec::new(),
            insert_after_orders: Vec::new(),
        }
    }

    pub fn is_empty(&self) -> bool {
        self.order_ids.is_empty()
    }

    pub fn len(&self) -> usize {
        self.order_ids.len()
    }

    pub fn add_order(&mut self, order_id: U256, price_level: U256, order: U256) {
        self.order_ids.push(order_id);
        self.insert_after_price_levels.push(price_level);
        self.insert_after_orders.push(order);
    }
}

/// 价格层级缓存（用于快速查找）
#[derive(Debug, Clone)]
pub struct PriceLevelCache {
    /// 价格 -> 价格层级ID
    pub price_to_level: BTreeMap<U256, U256>,
    /// 价格层级ID -> 价格层级数据
    pub levels: BTreeMap<U256, PriceLevel>,
}

impl PriceLevelCache {
    pub fn new() -> Self {
        Self {
            price_to_level: BTreeMap::new(),
            levels: BTreeMap::new(),
        }
    }

    pub fn insert(&mut self, level_id: U256, level: PriceLevel) {
        self.price_to_level.insert(level.price, level_id);
        self.levels.insert(level_id, level);
    }

    pub fn get_level_by_price(&self, price: &U256) -> Option<U256> {
        self.price_to_level.get(price).copied()
    }

    pub fn get_level(&self, level_id: &U256) -> Option<&PriceLevel> {
        self.levels.get(level_id)
    }
}
