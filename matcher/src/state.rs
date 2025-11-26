use crate::orderbook_simulator::OrderBookSimulator;
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

    /// OrderBook 模拟器（使用链表结构，与链上一致）
    pub orderbook: Arc<parking_lot::RwLock<OrderBookSimulator>>,

    /// 当前同步到的区块高度
    pub current_block: Arc<parking_lot::RwLock<u64>>,
}

impl GlobalState {
    pub fn new() -> Self {
        Self {
            queued_requests: Arc::new(DashMap::new()),
            queue_head: Arc::new(parking_lot::RwLock::new(U256::zero())),
            orderbook: Arc::new(parking_lot::RwLock::new(OrderBookSimulator::new())),
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

    /// 更新当前区块
    pub fn update_current_block(&self, block: u64) {
        *self.current_block.write() = block;
    }

    /// 克隆当前订单簿状态（用于模拟计算）
    pub fn clone_orderbook(&self) -> OrderBookSimulator {
        self.orderbook.read().clone()
    }
}
