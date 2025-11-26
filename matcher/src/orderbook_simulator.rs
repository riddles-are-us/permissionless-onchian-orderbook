//! 订单簿模拟器 - 严格按照链上 OrderBook.sol 的逻辑和数据结构实现
//!
//! 数据结构与链上合约完全一致：
//! - Order: 订单结构
//! - PriceLevel: 价格层级，使用链表
//! - OrderBookData: askHead/Tail, bidHead/Tail
//!
//! 执行顺序与链上一致：
//! 1. 计算 insertAfterPrice
//! 2. 插入订单到价格层级
//! 3. 执行撮合（best bid vs best ask）

use ethers::types::U256;
use std::collections::HashMap;
use tracing::debug;

/// 常量：空节点
const EMPTY: U256 = U256::zero();

/// 模拟订单 - 对应链上 Order 结构
#[derive(Debug, Clone)]
pub struct SimOrder {
    pub id: U256,
    pub amount: U256,
    pub filled_amount: U256,
    pub is_market_order: bool,
    pub price_level: U256,     // 该订单所属的价格
    pub next_order_id: U256,
    pub prev_order_id: U256,
}

/// 模拟价格层级 - 对应链上 PriceLevel 结构
#[derive(Debug, Clone)]
pub struct SimPriceLevel {
    pub price: U256,
    pub total_volume: U256,
    pub head_order_id: U256,
    pub tail_order_id: U256,
    pub next_price: U256, // 下一个价格（链上直接存价格值）
    pub prev_price: U256, // 上一个价格
}

/// 模拟订单簿 - 严格按照链上 OrderBook 合约实现
#[derive(Debug, Clone)]
pub struct OrderBookSimulator {
    // 限价订单簿
    pub ask_head: U256, // 最低卖价
    pub ask_tail: U256,
    pub bid_head: U256, // 最高买价
    pub bid_tail: U256,

    // 市价单（暂不实现，保留字段）
    pub market_ask_head: U256,
    pub market_ask_tail: U256,
    pub market_bid_head: U256,
    pub market_bid_tail: U256,

    /// 价格层级: composite_key -> SimPriceLevel
    /// composite_key: Ask 用 price，Bid 用 price | (1 << 255)
    pub price_levels: HashMap<U256, SimPriceLevel>,

    /// 订单: order_id -> SimOrder
    pub orders: HashMap<U256, SimOrder>,
}

impl OrderBookSimulator {
    pub fn new() -> Self {
        Self {
            ask_head: EMPTY,
            ask_tail: EMPTY,
            bid_head: EMPTY,
            bid_tail: EMPTY,
            market_ask_head: EMPTY,
            market_ask_tail: EMPTY,
            market_bid_head: EMPTY,
            market_bid_tail: EMPTY,
            price_levels: HashMap::new(),
            orders: HashMap::new(),
        }
    }

    /// 从链上状态初始化模拟器
    pub fn from_chain_state(
        ask_head: U256,
        ask_tail: U256,
        bid_head: U256,
        bid_tail: U256,
    ) -> Self {
        Self {
            ask_head,
            ask_tail,
            bid_head,
            bid_tail,
            market_ask_head: EMPTY,
            market_ask_tail: EMPTY,
            market_bid_head: EMPTY,
            market_bid_tail: EMPTY,
            price_levels: HashMap::new(),
            orders: HashMap::new(),
        }
    }

    /// 生成价格层级的 composite key（与链上 _getPriceLevelKey 一致）
    /// Ask 订单使用 price 本身
    /// Bid 订单使用 price | (1 << 255)
    fn get_price_level_key(price: U256, is_ask: bool) -> U256 {
        if is_ask {
            price
        } else {
            price | (U256::one() << 255)
        }
    }

    /// 添加链上已存在的价格层级（用于初始化同步）
    pub fn add_existing_price_level(&mut self, level: SimPriceLevel, is_ask: bool) {
        let key = Self::get_price_level_key(level.price, is_ask);
        self.price_levels.insert(key, level);
    }

    /// 添加链上已存在的订单（用于初始化同步）
    pub fn add_existing_order(&mut self, order: SimOrder) {
        self.orders.insert(order.id, order);
    }

    /// 模拟插入限价单并执行撮合，返回 insertAfterPrice
    ///
    /// 严格按照链上逻辑：
    /// 1. 计算 insertAfterPrice（基于当前状态）
    /// 2. 调用 _findOrCreatePriceLevel（插入价格层级）
    /// 3. 调用 _insertOrderIntoPriceLevel（插入订单）
    /// 4. 调用 _tryMatchAfterInsertion（执行撮合）
    pub fn simulate_insert_order(
        &mut self,
        order_id: U256,
        price: U256,
        amount: U256,
        is_ask: bool,
    ) -> U256 {
        // 1. 计算 insertAfterPrice（在当前状态下）
        let insert_after_price = self.find_insert_position(price, is_ask);

        debug!(
            "Order {} (price={}, is_ask={}): insertAfterPrice={}",
            order_id, price, is_ask, insert_after_price
        );

        // 2. 查找或创建价格层级（对应链上 _findOrCreatePriceLevel）
        self.find_or_create_price_level(price, is_ask, insert_after_price);

        // 3. 创建并插入订单（对应链上的订单创建和 _insertOrderIntoPriceLevel）
        let order = SimOrder {
            id: order_id,
            amount,
            filled_amount: EMPTY,
            is_market_order: false,
            price_level: price,
            next_order_id: EMPTY,
            prev_order_id: EMPTY,
        };
        self.orders.insert(order_id, order);

        // 插入订单到价格层级的尾部（简化版，链上支持 insertAfterOrder 参数）
        self.insert_order_into_price_level(price, order_id, EMPTY, is_ask);

        // 4. 执行撮合（对应链上 _tryMatchAfterInsertion）
        self.try_match_after_insertion();

        insert_after_price
    }

    /// 模拟移除订单（对应链上 removeOrder）
    /// 用于处理 RemoveOrder 类型的请求
    pub fn simulate_remove_order(&mut self, order_id: U256, is_ask: bool) -> bool {
        // 检查订单是否存在
        if !self.orders.contains_key(&order_id) {
            debug!("Order {} not found, skip removal", order_id);
            return false;
        }

        // 获取订单的价格层级
        let price_level_id = if let Some(order) = self.orders.get(&order_id) {
            order.price_level
        } else {
            return false;
        };

        debug!(
            "Removing order {} from price level {} (is_ask={})",
            order_id, price_level_id, is_ask
        );

        // 从价格层级中移除订单
        self.remove_order_from_price_level(price_level_id, order_id, is_ask);

        // 检查价格层级是否为空，如果为空则删除
        let level_key = Self::get_price_level_key(price_level_id, is_ask);
        let should_remove_level = if let Some(level) = self.price_levels.get(&level_key) {
            level.head_order_id.is_zero()
        } else {
            false
        };

        if should_remove_level {
            self.remove_price_level(price_level_id, is_ask);
        }

        // 删除订单数据
        self.orders.remove(&order_id);

        true
    }

    /// 找到正确的插入位置（返回 insertAfterPrice）
    fn find_insert_position(&self, price: U256, is_ask: bool) -> U256 {
        let key = Self::get_price_level_key(price, is_ask);

        // 如果价格层级已存在，直接返回该价格
        if self.price_levels.contains_key(&key) {
            return price;
        }

        let head = if is_ask { self.ask_head } else { self.bid_head };

        // 如果订单簿为空，返回 0（插入到头部）
        if head.is_zero() {
            return EMPTY;
        }

        // 遍历价格层级找到正确位置
        let mut current_price = head;
        let mut prev_price = EMPTY;

        while !current_price.is_zero() {
            let current_key = Self::get_price_level_key(current_price, is_ask);
            if let Some(level) = self.price_levels.get(&current_key) {
                let should_insert_here = if is_ask {
                    // Ask: 价格从低到高，如果 price <= current，应插入到 current 之前
                    price <= level.price
                } else {
                    // Bid: 价格从高到低，如果 price >= current，应插入到 current 之前
                    price >= level.price
                };

                if should_insert_here {
                    return prev_price;
                }

                prev_price = current_price;
                current_price = level.next_price;
            } else {
                break;
            }
        }

        // 插入到末尾
        prev_price
    }

    /// 查找或创建价格层级（对应链上 _findOrCreatePriceLevel）
    fn find_or_create_price_level(&mut self, price: U256, is_ask: bool, insert_after_price: U256) {
        let key = Self::get_price_level_key(price, is_ask);

        // 如果已存在，直接返回
        if self.price_levels.contains_key(&key) {
            return;
        }

        // 创建新价格层级
        let new_level = SimPriceLevel {
            price,
            total_volume: EMPTY,
            head_order_id: EMPTY,
            tail_order_id: EMPTY,
            next_price: EMPTY,
            prev_price: EMPTY,
        };
        self.price_levels.insert(key, new_level);

        // 插入到链表中（对应链上 _insertPriceLevelIntoList）
        self.insert_price_level_into_list(price, is_ask, insert_after_price);
    }

    /// 将价格层级插入到链表中（对应链上 _insertPriceLevelIntoList）
    fn insert_price_level_into_list(&mut self, price: U256, is_ask: bool, insert_after_price: U256) {
        let key = Self::get_price_level_key(price, is_ask);

        if insert_after_price.is_zero() {
            // 插入到头部
            let old_head = if is_ask { self.ask_head } else { self.bid_head };

            if !old_head.is_zero() {
                let old_head_key = Self::get_price_level_key(old_head, is_ask);

                // 更新旧头部的 prev_price
                if let Some(old_head_level) = self.price_levels.get_mut(&old_head_key) {
                    old_head_level.prev_price = price;
                }
                // 设置新头部的 next_price
                if let Some(new_level) = self.price_levels.get_mut(&key) {
                    new_level.next_price = old_head;
                }
            } else {
                // 列表为空，同时设置 tail
                if is_ask {
                    self.ask_tail = price;
                } else {
                    self.bid_tail = price;
                }
            }

            // 更新 head
            if is_ask {
                self.ask_head = price;
            } else {
                self.bid_head = price;
            }
        } else {
            // 插入到 insert_after_price 之后
            let insert_after_key = Self::get_price_level_key(insert_after_price, is_ask);

            let next_price = if let Some(prev_level) = self.price_levels.get(&insert_after_key) {
                prev_level.next_price
            } else {
                EMPTY
            };

            // 更新新节点的指针
            if let Some(new_level) = self.price_levels.get_mut(&key) {
                new_level.prev_price = insert_after_price;
                new_level.next_price = next_price;
            }

            // 更新前一个节点的 next_price
            if let Some(prev_level) = self.price_levels.get_mut(&insert_after_key) {
                prev_level.next_price = price;
            }

            // 更新后一个节点的 prev_price
            if !next_price.is_zero() {
                let next_key = Self::get_price_level_key(next_price, is_ask);
                if let Some(next_level) = self.price_levels.get_mut(&next_key) {
                    next_level.prev_price = price;
                }
            } else {
                // 插入到尾部
                if is_ask {
                    self.ask_tail = price;
                } else {
                    self.bid_tail = price;
                }
            }
        }
    }

    /// 将订单插入到价格层级的订单列表中（对应链上 _insertOrderIntoPriceLevel）
    fn insert_order_into_price_level(
        &mut self,
        price_level_id: U256,
        order_id: U256,
        insert_after_order: U256,
        is_ask: bool,
    ) {
        let level_key = Self::get_price_level_key(price_level_id, is_ask);

        let order_amount = if let Some(order) = self.orders.get(&order_id) {
            order.amount
        } else {
            return;
        };

        if insert_after_order.is_zero() {
            // 插入到头部
            let old_head = if let Some(level) = self.price_levels.get(&level_key) {
                level.head_order_id
            } else {
                EMPTY
            };

            if !old_head.is_zero() {
                // 更新旧头部的 prev
                if let Some(old_head_order) = self.orders.get_mut(&old_head) {
                    old_head_order.prev_order_id = order_id;
                }
                // 设置新头部的 next
                if let Some(order) = self.orders.get_mut(&order_id) {
                    order.next_order_id = old_head;
                }
            } else {
                // 列表为空，设置 tail
                if let Some(level) = self.price_levels.get_mut(&level_key) {
                    level.tail_order_id = order_id;
                }
            }

            // 更新 head
            if let Some(level) = self.price_levels.get_mut(&level_key) {
                level.head_order_id = order_id;
            }
        } else {
            // 插入到指定订单后面
            let next_order_id = if let Some(prev_order) = self.orders.get(&insert_after_order) {
                prev_order.next_order_id
            } else {
                EMPTY
            };

            // 更新新订单的指针
            if let Some(order) = self.orders.get_mut(&order_id) {
                order.prev_order_id = insert_after_order;
                order.next_order_id = next_order_id;
            }

            // 更新前一个订单的 next
            if let Some(prev_order) = self.orders.get_mut(&insert_after_order) {
                prev_order.next_order_id = order_id;
            }

            // 更新后一个订单的 prev
            if !next_order_id.is_zero() {
                if let Some(next_order) = self.orders.get_mut(&next_order_id) {
                    next_order.prev_order_id = order_id;
                }
            } else {
                // 插入到尾部
                if let Some(level) = self.price_levels.get_mut(&level_key) {
                    level.tail_order_id = order_id;
                }
            }
        }

        // 更新价格层级的总挂单量
        if let Some(level) = self.price_levels.get_mut(&level_key) {
            level.total_volume = level.total_volume + order_amount;
        }
    }

    /// 插入后尝试撮合（对应链上 _tryMatchAfterInsertion）
    fn try_match_after_insertion(&mut self) {
        let max_iterations = 50;
        // 先匹配限价单
        self.match_orders_internal(max_iterations);
        // 再匹配市价单
        self.match_market_orders_internal(max_iterations);
    }

    /// 内部撮合逻辑（对应链上 _matchOrdersInternal）
    fn match_orders_internal(&mut self, max_iterations: usize) {
        for _ in 0..max_iterations {
            // 获取最优买价和卖价
            let bid_price = self.bid_head;
            let ask_price = self.ask_head;

            // 如果任意一方为空，停止撮合
            if bid_price.is_zero() || ask_price.is_zero() {
                break;
            }

            let bid_key = Self::get_price_level_key(bid_price, false);
            let ask_key = Self::get_price_level_key(ask_price, true);

            // 获取价格层级
            let (bid_level_price, bid_head_order) = if let Some(level) = self.price_levels.get(&bid_key) {
                (level.price, level.head_order_id)
            } else {
                break;
            };

            let (ask_level_price, ask_head_order) = if let Some(level) = self.price_levels.get(&ask_key) {
                (level.price, level.head_order_id)
            } else {
                break;
            };

            // 检查是否可以成交：买价 >= 卖价
            if bid_level_price < ask_level_price {
                break;
            }

            // 获取订单
            if bid_head_order.is_zero() || ask_head_order.is_zero() {
                break;
            }

            // 执行撮合
            let traded = self.execute_trade(bid_head_order, ask_head_order);
            if !traded {
                break;
            }
        }
    }

    /// 执行单笔交易（对应链上 _executeTrade）
    fn execute_trade(&mut self, bid_order_id: U256, ask_order_id: U256) -> bool {
        // 获取订单信息
        let (bid_remaining, bid_price_level) = if let Some(order) = self.orders.get(&bid_order_id) {
            (order.amount - order.filled_amount, order.price_level)
        } else {
            return false;
        };

        let (ask_remaining, ask_price_level) = if let Some(order) = self.orders.get(&ask_order_id) {
            (order.amount - order.filled_amount, order.price_level)
        } else {
            return false;
        };

        // 计算成交数量
        let trade_amount = bid_remaining.min(ask_remaining);
        if trade_amount.is_zero() {
            return false;
        }

        // 更新订单已成交数量
        if let Some(bid_order) = self.orders.get_mut(&bid_order_id) {
            bid_order.filled_amount = bid_order.filled_amount + trade_amount;
        }
        if let Some(ask_order) = self.orders.get_mut(&ask_order_id) {
            ask_order.filled_amount = ask_order.filled_amount + trade_amount;
        }

        // 更新价格层级的总挂单量
        let bid_key = Self::get_price_level_key(bid_price_level, false);
        if let Some(level) = self.price_levels.get_mut(&bid_key) {
            level.total_volume = level.total_volume.saturating_sub(trade_amount);
        }

        let ask_key = Self::get_price_level_key(ask_price_level, true);
        if let Some(level) = self.price_levels.get_mut(&ask_key) {
            level.total_volume = level.total_volume.saturating_sub(trade_amount);
        }

        // 检查买单是否完全成交
        let bid_fully_filled = if let Some(order) = self.orders.get(&bid_order_id) {
            order.filled_amount >= order.amount
        } else {
            false
        };

        if bid_fully_filled {
            self.remove_filled_order(bid_order_id, false);
        }

        // 检查卖单是否完全成交
        let ask_fully_filled = if let Some(order) = self.orders.get(&ask_order_id) {
            order.filled_amount >= order.amount
        } else {
            false
        };

        if ask_fully_filled {
            self.remove_filled_order(ask_order_id, true);
        }

        true
    }

    /// 移除已完全成交的订单（对应链上 _removeFilledOrder）
    fn remove_filled_order(&mut self, order_id: U256, is_ask: bool) {
        let price_level_id = if let Some(order) = self.orders.get(&order_id) {
            order.price_level
        } else {
            return;
        };

        // 从价格层级中移除订单
        self.remove_order_from_price_level(price_level_id, order_id, is_ask);

        // 如果价格层级没有订单了，删除该价格层级
        let level_key = Self::get_price_level_key(price_level_id, is_ask);
        let should_remove_level = if let Some(level) = self.price_levels.get(&level_key) {
            level.head_order_id.is_zero()
        } else {
            false
        };

        if should_remove_level {
            self.remove_price_level(price_level_id, is_ask);
        }

        // 删除订单数据
        self.orders.remove(&order_id);
    }

    /// 从价格层级的订单列表中移除订单（对应链上 _removeOrderFromPriceLevel）
    fn remove_order_from_price_level(&mut self, price_level_id: U256, order_id: U256, is_ask: bool) {
        let (prev_order_id, next_order_id) = if let Some(order) = self.orders.get(&order_id) {
            (order.prev_order_id, order.next_order_id)
        } else {
            return;
        };

        // 更新前一个订单的 next
        if !prev_order_id.is_zero() {
            if let Some(prev_order) = self.orders.get_mut(&prev_order_id) {
                prev_order.next_order_id = next_order_id;
            }
        } else {
            // 这是头节点
            let level_key = Self::get_price_level_key(price_level_id, is_ask);
            if let Some(level) = self.price_levels.get_mut(&level_key) {
                level.head_order_id = next_order_id;
            }
        }

        // 更新后一个订单的 prev
        if !next_order_id.is_zero() {
            if let Some(next_order) = self.orders.get_mut(&next_order_id) {
                next_order.prev_order_id = prev_order_id;
            }
        } else {
            // 这是尾节点
            let level_key = Self::get_price_level_key(price_level_id, is_ask);
            if let Some(level) = self.price_levels.get_mut(&level_key) {
                level.tail_order_id = prev_order_id;
            }
        }
    }

    /// 从列表中移除价格层级（对应链上 _removePriceLevel）
    fn remove_price_level(&mut self, price_level_id: U256, is_ask: bool) {
        let level_key = Self::get_price_level_key(price_level_id, is_ask);

        let (prev_price, next_price) = if let Some(level) = self.price_levels.get(&level_key) {
            (level.prev_price, level.next_price)
        } else {
            return;
        };

        debug!("Removing empty price level: price={}, is_ask={}", price_level_id, is_ask);

        // 更新前一个价格层级的 next
        if !prev_price.is_zero() {
            let prev_key = Self::get_price_level_key(prev_price, is_ask);
            if let Some(prev_level) = self.price_levels.get_mut(&prev_key) {
                prev_level.next_price = next_price;
            }
        } else {
            // 这是头节点
            if is_ask {
                self.ask_head = next_price;
            } else {
                self.bid_head = next_price;
            }
        }

        // 更新后一个价格层级的 prev
        if !next_price.is_zero() {
            let next_key = Self::get_price_level_key(next_price, is_ask);
            if let Some(next_level) = self.price_levels.get_mut(&next_key) {
                next_level.prev_price = prev_price;
            }
        } else {
            // 这是尾节点
            if is_ask {
                self.ask_tail = prev_price;
            } else {
                self.bid_tail = prev_price;
            }
        }

        // 删除价格层级
        self.price_levels.remove(&level_key);
    }

    /// 获取所有价格层级（用于调试）
    pub fn get_price_levels(&self, is_ask: bool) -> Vec<U256> {
        let mut prices = Vec::new();
        let mut current = if is_ask { self.ask_head } else { self.bid_head };

        while !current.is_zero() {
            prices.push(current);
            let key = Self::get_price_level_key(current, is_ask);
            if let Some(level) = self.price_levels.get(&key) {
                current = level.next_price;
            } else {
                break;
            }
        }

        prices
    }

    /// 获取指定价格层级的订单列表（用于调试）
    pub fn get_orders_at_price(&self, price: U256, is_ask: bool) -> Vec<U256> {
        let mut order_ids = Vec::new();
        let key = Self::get_price_level_key(price, is_ask);

        if let Some(level) = self.price_levels.get(&key) {
            let mut current = level.head_order_id;
            while !current.is_zero() {
                order_ids.push(current);
                if let Some(order) = self.orders.get(&current) {
                    current = order.next_order_id;
                } else {
                    break;
                }
            }
        }

        order_ids
    }

    // ============ 市价单相关方法 ============

    /// 模拟插入市价单（对应链上 insertMarketOrder）
    /// 市价单总是插入到队尾（FIFO），不需要 insertAfterPrice
    pub fn simulate_insert_market_order(&mut self, order_id: U256, amount: U256, is_ask: bool) {
        debug!(
            "Inserting market order {} (amount={}, is_ask={})",
            order_id, amount, is_ask
        );

        // 创建市价单
        let order = SimOrder {
            id: order_id,
            amount,
            filled_amount: EMPTY,
            is_market_order: true,
            price_level: EMPTY, // 市价单不需要价格层级
            next_order_id: EMPTY,
            prev_order_id: EMPTY,
        };
        self.orders.insert(order_id, order);

        // 插入到市价单队列尾部
        self.insert_market_order_at_tail(order_id, is_ask);

        // 执行撮合
        self.try_match_after_insertion();
    }

    /// 将市价单插入到队尾（对应链上 _insertMarketOrderAtTail）
    fn insert_market_order_at_tail(&mut self, order_id: U256, is_ask: bool) {
        let old_tail = if is_ask {
            self.market_ask_tail
        } else {
            self.market_bid_tail
        };

        if old_tail.is_zero() {
            // 列表为空，设置为 head 和 tail
            if is_ask {
                self.market_ask_head = order_id;
                self.market_ask_tail = order_id;
            } else {
                self.market_bid_head = order_id;
                self.market_bid_tail = order_id;
            }
        } else {
            // 插入到尾部
            if let Some(tail_order) = self.orders.get_mut(&old_tail) {
                tail_order.next_order_id = order_id;
            }
            if let Some(new_order) = self.orders.get_mut(&order_id) {
                new_order.prev_order_id = old_tail;
            }

            // 更新 tail
            if is_ask {
                self.market_ask_tail = order_id;
            } else {
                self.market_bid_tail = order_id;
            }
        }
    }

    /// 从市价单列表中移除订单（对应链上 _removeMarketOrderFromList）
    fn remove_market_order_from_list(&mut self, order_id: U256, is_ask: bool) {
        let (prev_order_id, next_order_id) = if let Some(order) = self.orders.get(&order_id) {
            (order.prev_order_id, order.next_order_id)
        } else {
            return;
        };

        // 更新前一个订单的 next
        if !prev_order_id.is_zero() {
            if let Some(prev_order) = self.orders.get_mut(&prev_order_id) {
                prev_order.next_order_id = next_order_id;
            }
        } else {
            // 这是头节点
            if is_ask {
                self.market_ask_head = next_order_id;
            } else {
                self.market_bid_head = next_order_id;
            }
        }

        // 更新后一个订单的 prev
        if !next_order_id.is_zero() {
            if let Some(next_order) = self.orders.get_mut(&next_order_id) {
                next_order.prev_order_id = prev_order_id;
            }
        } else {
            // 这是尾节点
            if is_ask {
                self.market_ask_tail = prev_order_id;
            } else {
                self.market_bid_tail = prev_order_id;
            }
        }
    }

    /// 市价单撮合逻辑（对应链上 _matchMarketOrdersInternal）
    fn match_market_orders_internal(&mut self, max_iterations: usize) {
        let mut iterations = 0;

        // 1. 匹配市价买单与最优卖价（限价单）
        while iterations < max_iterations {
            let market_bid_head = self.market_bid_head;
            let ask_head = self.ask_head;

            // 如果任意一方为空，跳出
            if market_bid_head.is_zero() || ask_head.is_zero() {
                break;
            }

            // 获取限价卖单队列头部订单
            let ask_key = Self::get_price_level_key(ask_head, true);
            let ask_head_order = if let Some(level) = self.price_levels.get(&ask_key) {
                level.head_order_id
            } else {
                break;
            };

            if ask_head_order.is_zero() {
                break;
            }

            // 执行市价买单与限价卖单的撮合
            let traded = self.execute_market_trade(market_bid_head, ask_head_order, false);
            if !traded {
                break;
            }

            iterations += 1;
        }

        // 2. 匹配市价卖单与最优买价（限价单）
        while iterations < max_iterations {
            let market_ask_head = self.market_ask_head;
            let bid_head = self.bid_head;

            // 如果任意一方为空，跳出
            if market_ask_head.is_zero() || bid_head.is_zero() {
                break;
            }

            // 获取限价买单队列头部订单
            let bid_key = Self::get_price_level_key(bid_head, false);
            let bid_head_order = if let Some(level) = self.price_levels.get(&bid_key) {
                level.head_order_id
            } else {
                break;
            };

            if bid_head_order.is_zero() {
                break;
            }

            // 执行市价卖单与限价买单的撮合
            let traded = self.execute_market_trade(market_ask_head, bid_head_order, true);
            if !traded {
                break;
            }

            iterations += 1;
        }
    }

    /// 执行市价单与限价单的交易
    /// is_market_ask: true 表示市价卖单与限价买单撮合，false 表示市价买单与限价卖单撮合
    fn execute_market_trade(
        &mut self,
        market_order_id: U256,
        limit_order_id: U256,
        is_market_ask: bool,
    ) -> bool {
        // 获取市价单信息
        let market_remaining = if let Some(order) = self.orders.get(&market_order_id) {
            order.amount - order.filled_amount
        } else {
            return false;
        };

        // 获取限价单信息
        let (limit_remaining, limit_price_level) = if let Some(order) = self.orders.get(&limit_order_id) {
            (order.amount - order.filled_amount, order.price_level)
        } else {
            return false;
        };

        // 计算成交数量
        let trade_amount = market_remaining.min(limit_remaining);
        if trade_amount.is_zero() {
            return false;
        }

        debug!(
            "Market trade: market_order={}, limit_order={}, amount={}",
            market_order_id, limit_order_id, trade_amount
        );

        // 更新市价单已成交数量
        if let Some(order) = self.orders.get_mut(&market_order_id) {
            order.filled_amount = order.filled_amount + trade_amount;
        }

        // 更新限价单已成交数量
        if let Some(order) = self.orders.get_mut(&limit_order_id) {
            order.filled_amount = order.filled_amount + trade_amount;
        }

        // 更新限价单所在价格层级的总挂单量
        let limit_is_ask = !is_market_ask;
        let limit_key = Self::get_price_level_key(limit_price_level, limit_is_ask);
        if let Some(level) = self.price_levels.get_mut(&limit_key) {
            level.total_volume = level.total_volume.saturating_sub(trade_amount);
        }

        // 检查市价单是否完全成交
        let market_fully_filled = if let Some(order) = self.orders.get(&market_order_id) {
            order.filled_amount >= order.amount
        } else {
            false
        };

        if market_fully_filled {
            // 从市价单列表中移除
            self.remove_market_order_from_list(market_order_id, is_market_ask);
            // 删除订单数据
            self.orders.remove(&market_order_id);
        }

        // 检查限价单是否完全成交
        let limit_fully_filled = if let Some(order) = self.orders.get(&limit_order_id) {
            order.filled_amount >= order.amount
        } else {
            false
        };

        if limit_fully_filled {
            self.remove_filled_order(limit_order_id, limit_is_ask);
        }

        true
    }

    /// 获取市价单列表（用于调试）
    pub fn get_market_orders(&self, is_ask: bool) -> Vec<U256> {
        let mut order_ids = Vec::new();
        let mut current = if is_ask {
            self.market_ask_head
        } else {
            self.market_bid_head
        };

        while !current.is_zero() {
            order_ids.push(current);
            if let Some(order) = self.orders.get(&current) {
                current = order.next_order_id;
            } else {
                break;
            }
        }

        order_ids
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_insert_single_order() {
        let mut sim = OrderBookSimulator::new();

        // 插入一个买单
        let insert_after = sim.simulate_insert_order(
            U256::from(1),
            U256::from(100),
            U256::from(10),
            false, // bid
        );

        assert_eq!(insert_after, U256::zero()); // 空订单簿，插入头部
        assert_eq!(sim.bid_head, U256::from(100));
        assert_eq!(sim.get_price_levels(false), vec![U256::from(100)]);
    }

    #[test]
    fn test_insert_multiple_orders_same_side() {
        let mut sim = OrderBookSimulator::new();

        // 插入买单1: price=100
        let insert1 = sim.simulate_insert_order(
            U256::from(1),
            U256::from(100),
            U256::from(10),
            false,
        );
        assert_eq!(insert1, U256::zero());

        // 插入买单2: price=90 (低于100，应该在100之后)
        let insert2 = sim.simulate_insert_order(
            U256::from(2),
            U256::from(90),
            U256::from(10),
            false,
        );
        assert_eq!(insert2, U256::from(100)); // 插入到100之后

        // 插入买单3: price=110 (高于100，应该成为新头部)
        let insert3 = sim.simulate_insert_order(
            U256::from(3),
            U256::from(110),
            U256::from(10),
            false,
        );
        assert_eq!(insert3, U256::zero()); // 插入到头部

        // 验证顺序: 110 -> 100 -> 90
        assert_eq!(sim.get_price_levels(false), vec![
            U256::from(110),
            U256::from(100),
            U256::from(90),
        ]);
    }

    #[test]
    fn test_insert_ask_orders() {
        let mut sim = OrderBookSimulator::new();

        // 插入卖单1: price=100
        let insert1 = sim.simulate_insert_order(
            U256::from(1),
            U256::from(100),
            U256::from(10),
            true, // ask
        );
        assert_eq!(insert1, U256::zero());

        // 插入卖单2: price=110 (高于100，应该在100之后)
        let insert2 = sim.simulate_insert_order(
            U256::from(2),
            U256::from(110),
            U256::from(10),
            true,
        );
        assert_eq!(insert2, U256::from(100)); // 插入到100之后

        // 插入卖单3: price=90 (低于100，应该成为新头部)
        let insert3 = sim.simulate_insert_order(
            U256::from(3),
            U256::from(90),
            U256::from(10),
            true,
        );
        assert_eq!(insert3, U256::zero()); // 插入到头部

        // 验证顺序: 90 -> 100 -> 110 (ask 从低到高)
        assert_eq!(sim.get_price_levels(true), vec![
            U256::from(90),
            U256::from(100),
            U256::from(110),
        ]);
    }

    #[test]
    fn test_matching_after_insertion() {
        let mut sim = OrderBookSimulator::new();

        // 先插入一个买单: price=100, amount=10
        sim.simulate_insert_order(
            U256::from(1),
            U256::from(100),
            U256::from(10),
            false,
        );

        // 插入一个卖单: price=100, amount=5 (应该匹配)
        sim.simulate_insert_order(
            U256::from(2),
            U256::from(100),
            U256::from(5),
            true,
        );

        // 卖单完全成交，不应该在订单簿中
        assert!(!sim.orders.contains_key(&U256::from(2)));

        // 买单部分成交，检查剩余
        let bid_order = sim.orders.get(&U256::from(1)).unwrap();
        assert_eq!(bid_order.filled_amount, U256::from(5));
    }

    #[test]
    fn test_full_match_removes_price_level() {
        let mut sim = OrderBookSimulator::new();

        // 插入买单: price=100, amount=10
        sim.simulate_insert_order(
            U256::from(1),
            U256::from(100),
            U256::from(10),
            false,
        );

        // 插入卖单: price=100, amount=10 (完全匹配)
        sim.simulate_insert_order(
            U256::from(2),
            U256::from(100),
            U256::from(10),
            true,
        );

        // 买单价格层级应该被移除
        assert_eq!(sim.bid_head, U256::zero());
        assert!(sim.get_price_levels(false).is_empty());

        // 卖单价格层级也应该被移除（因为完全匹配后才插入）
        assert_eq!(sim.ask_head, U256::zero());
        assert!(sim.get_price_levels(true).is_empty());
    }

    #[test]
    fn test_cross_price_matching() {
        let mut sim = OrderBookSimulator::new();

        // 插入买单: price=100, amount=10
        sim.simulate_insert_order(
            U256::from(1),
            U256::from(100),
            U256::from(10),
            false,
        );

        // 插入卖单: price=90 (低于买单价格，会被撮合)
        let insert_after = sim.simulate_insert_order(
            U256::from(2),
            U256::from(90),
            U256::from(5),
            true,
        );

        // insertAfterPrice 应该基于插入前的状态（ask 侧为空）
        assert_eq!(insert_after, U256::zero());

        // 卖单完全成交
        assert!(!sim.orders.contains_key(&U256::from(2)));

        // 买单部分成交
        let bid_order = sim.orders.get(&U256::from(1)).unwrap();
        assert_eq!(bid_order.filled_amount, U256::from(5));
    }

    #[test]
    fn test_batch_orders_with_matching() {
        let mut sim = OrderBookSimulator::new();

        // 模拟批处理场景：
        // 1. 买单 @ 100
        // 2. 卖单 @ 100 (会匹配)
        // 3. 买单 @ 95 (应该正确计算 insertAfterPrice)

        sim.simulate_insert_order(U256::from(1), U256::from(100), U256::from(10), false);
        sim.simulate_insert_order(U256::from(2), U256::from(100), U256::from(10), true);

        // 买单和卖单完全匹配后，订单簿为空
        assert!(sim.get_price_levels(false).is_empty());

        // 新买单应该插入到头部
        let insert_after = sim.simulate_insert_order(U256::from(3), U256::from(95), U256::from(10), false);
        assert_eq!(insert_after, U256::zero());
    }

    // ============ 市价单测试 ============

    #[test]
    fn test_market_order_insertion() {
        let mut sim = OrderBookSimulator::new();

        // 插入一个限价卖单: price=100, amount=10
        sim.simulate_insert_order(U256::from(1), U256::from(100), U256::from(10), true);

        // 插入一个市价买单，应该立即与卖单撮合
        sim.simulate_insert_market_order(U256::from(2), U256::from(5), false);

        // 市价买单完全成交，不应该在订单簿中
        assert!(!sim.orders.contains_key(&U256::from(2)));

        // 限价卖单部分成交
        let ask_order = sim.orders.get(&U256::from(1)).unwrap();
        assert_eq!(ask_order.filled_amount, U256::from(5));
    }

    #[test]
    fn test_market_order_fully_matches_limit() {
        let mut sim = OrderBookSimulator::new();

        // 插入限价卖单: price=100, amount=10
        sim.simulate_insert_order(U256::from(1), U256::from(100), U256::from(10), true);

        // 插入市价买单，amount=10，完全撮合
        sim.simulate_insert_market_order(U256::from(2), U256::from(10), false);

        // 两个订单都应该被移除
        assert!(!sim.orders.contains_key(&U256::from(1)));
        assert!(!sim.orders.contains_key(&U256::from(2)));

        // 价格层级也应该被移除
        assert!(sim.get_price_levels(true).is_empty());
    }

    #[test]
    fn test_market_order_partial_fill() {
        let mut sim = OrderBookSimulator::new();

        // 插入限价卖单: price=100, amount=5
        sim.simulate_insert_order(U256::from(1), U256::from(100), U256::from(5), true);

        // 插入市价买单，amount=10，部分成交
        sim.simulate_insert_market_order(U256::from(2), U256::from(10), false);

        // 限价卖单完全成交，被移除
        assert!(!sim.orders.contains_key(&U256::from(1)));

        // 市价买单部分成交，保留在队列中
        let market_order = sim.orders.get(&U256::from(2)).unwrap();
        assert_eq!(market_order.filled_amount, U256::from(5));
        assert_eq!(market_order.is_market_order, true);

        // 市价买单应该在队列中
        assert_eq!(sim.get_market_orders(false), vec![U256::from(2)]);
    }

    #[test]
    fn test_market_sell_order() {
        let mut sim = OrderBookSimulator::new();

        // 插入限价买单: price=100, amount=10
        sim.simulate_insert_order(U256::from(1), U256::from(100), U256::from(10), false);

        // 插入市价卖单
        sim.simulate_insert_market_order(U256::from(2), U256::from(5), true);

        // 市价卖单完全成交
        assert!(!sim.orders.contains_key(&U256::from(2)));

        // 限价买单部分成交
        let bid_order = sim.orders.get(&U256::from(1)).unwrap();
        assert_eq!(bid_order.filled_amount, U256::from(5));
    }

    #[test]
    fn test_market_order_affects_subsequent_limit_order() {
        let mut sim = OrderBookSimulator::new();

        // 场景：批处理中市价单在限价单之前，市价单的撮合会影响后续限价单的 insertAfterPrice
        //
        // 初始状态：
        // Asks: [100, 101, 102]
        //
        // 批处理：
        // 1. Market Buy (amount=全部@100) - 会移除价格层 100
        // 2. Limit Sell @ 100.5 - 应该 insertAfterPrice = 101（因为 100 已被移除）

        // 设置初始订单簿
        sim.simulate_insert_order(U256::from(1), U256::from(100), U256::from(10), true); // ask@100
        sim.simulate_insert_order(U256::from(2), U256::from(101), U256::from(10), true); // ask@101
        sim.simulate_insert_order(U256::from(3), U256::from(102), U256::from(10), true); // ask@102

        assert_eq!(sim.get_price_levels(true), vec![
            U256::from(100),
            U256::from(101),
            U256::from(102),
        ]);

        // 市价买单，消耗掉价格层 100 的所有订单
        sim.simulate_insert_market_order(U256::from(10), U256::from(10), false);

        // 价格层 100 应该被移除
        assert_eq!(sim.get_price_levels(true), vec![
            U256::from(101),
            U256::from(102),
        ]);

        // 现在插入限价卖单 @ 100（比 101 低）
        // 应该 insertAfterPrice = 0（插入到头部）
        let insert_after = sim.simulate_insert_order(
            U256::from(11),
            U256::from(100),
            U256::from(10),
            true,
        );
        assert_eq!(insert_after, U256::zero()); // 正确！插入到头部

        // 验证新状态
        assert_eq!(sim.get_price_levels(true), vec![
            U256::from(100),
            U256::from(101),
            U256::from(102),
        ]);
    }

    #[test]
    fn test_market_order_queue_fifo() {
        let mut sim = OrderBookSimulator::new();

        // 市价单应该按 FIFO 顺序排列
        // 先插入市价买单（没有卖单可撮合）
        sim.simulate_insert_market_order(U256::from(1), U256::from(10), false);
        sim.simulate_insert_market_order(U256::from(2), U256::from(10), false);
        sim.simulate_insert_market_order(U256::from(3), U256::from(10), false);

        // 验证 FIFO 顺序
        assert_eq!(sim.get_market_orders(false), vec![
            U256::from(1),
            U256::from(2),
            U256::from(3),
        ]);
        assert_eq!(sim.market_bid_head, U256::from(1));
        assert_eq!(sim.market_bid_tail, U256::from(3));
    }

    #[test]
    fn test_multiple_market_orders_match_one_limit() {
        let mut sim = OrderBookSimulator::new();

        // 插入一个大额限价卖单
        sim.simulate_insert_order(U256::from(1), U256::from(100), U256::from(30), true);

        // 插入多个市价买单
        sim.simulate_insert_market_order(U256::from(10), U256::from(10), false);
        sim.simulate_insert_market_order(U256::from(11), U256::from(10), false);
        sim.simulate_insert_market_order(U256::from(12), U256::from(10), false);

        // 所有市价买单应该已成交
        assert!(!sim.orders.contains_key(&U256::from(10)));
        assert!(!sim.orders.contains_key(&U256::from(11)));
        assert!(!sim.orders.contains_key(&U256::from(12)));

        // 限价卖单也应该完全成交
        assert!(!sim.orders.contains_key(&U256::from(1)));

        // 价格层级也应该被移除
        assert!(sim.get_price_levels(true).is_empty());
    }
}
