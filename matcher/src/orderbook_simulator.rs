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

/// 常量：价格精度 (10^8) - 对应 TradingConstants.PRICE_DECIMALS
const PRICE_DECIMALS: U256 = U256([100_000_000, 0, 0, 0]);

/// 常量：灰尘阈值 - 剩余未成交价值低于此值时视为完全成交
/// 0.01 USDC with AMOUNT_DECIMALS (10^8) precision = 0.01 * 10^8 = 1_000_000
/// 对应 TradingConstants.DUST_THRESHOLD
const DUST_THRESHOLD: U256 = U256([1_000_000, 0, 0, 0]);

/// 模拟订单 - 对应链上 Order 结构
#[derive(Debug, Clone)]
pub struct SimOrder {
    pub id: U256,
    pub amount: U256,
    pub filled_amount: U256,
    #[allow(dead_code)] // 在模拟器内部未读，但在 sync 中需要
    pub is_market_order: bool,
    pub is_ask: bool,          // 是否为卖单（用于移除订单时确定侧）
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
    /// 模拟插入限价订单
    /// 返回 (insert_after_price, insert_after_order)
    /// - insert_after_price: 价格层级插入位置
    /// - insert_after_order: 该价格层级当前的 tailOrderId（用于 FIFO）
    ///
    /// 参数:
    /// - global_tail_order_id: 可选的全局 tail_order_id，用于跨 trading pair 共享 priceLevels 的场景
    ///   如果提供，将优先使用此值作为 insert_after_order
    pub fn simulate_insert_order(
        &mut self,
        order_id: U256,
        price: U256,
        amount: U256,
        is_ask: bool,
        global_tail_order_id: Option<U256>,
    ) -> (U256, U256) {
        // 1. 计算 insertAfterPrice（在当前状态下）
        let insert_after_price = self.find_insert_position(price, is_ask);

        debug!(
            "Order {} (price={}, is_ask={}): insertAfterPrice={}",
            order_id, price, is_ask, insert_after_price
        );

        // 2. 查找或创建价格层级（对应链上 _findOrCreatePriceLevel）
        self.find_or_create_price_level(price, is_ask, insert_after_price);

        // 3. 获取当前价格层级的 tailOrderId（FIFO：新订单必须插入到尾部）
        // 优先使用全局 tail_order_id（如果提供），否则使用本地 orderbook 的 tail_order_id
        let level_key = Self::get_price_level_key(price, is_ask);
        let local_tail = if let Some(level) = self.price_levels.get(&level_key) {
            level.tail_order_id
        } else {
            EMPTY
        };

        // 使用全局 tail_order_id（如果提供且非零），否则使用本地 tail
        let insert_after_order = match global_tail_order_id {
            Some(global_tail) if !global_tail.is_zero() => {
                debug!(
                    "Order {} using global tail_order_id={} (local={})",
                    order_id, global_tail, local_tail
                );
                global_tail
            }
            _ => local_tail,
        };

        debug!(
            "Order {} (price={}, is_ask={}): insertAfterOrder={} (current tail)",
            order_id, price, is_ask, insert_after_order
        );

        // 4. 创建并插入订单（对应链上的订单创建和 _insertOrderIntoPriceLevel）
        let order = SimOrder {
            id: order_id,
            amount,
            filled_amount: EMPTY,
            is_market_order: false,
            is_ask,
            price_level: price,
            next_order_id: EMPTY,
            prev_order_id: EMPTY,
        };
        self.orders.insert(order_id, order);

        // 插入订单到价格层级的尾部（使用 tailOrderId 作为 insertAfterOrder）
        self.insert_order_into_price_level(price, order_id, insert_after_order, is_ask);

        // 5. 执行撮合（对应链上 _tryMatchAfterInsertion）
        self.try_match_after_insertion();

        (insert_after_price, insert_after_order)
    }

    /// 模拟移除订单（对应链上 removeOrder）
    /// 用于处理 RemoveOrder 类型的请求
    /// 注意：is_ask 参数现在被忽略，从订单本身获取
    pub fn simulate_remove_order(&mut self, order_id: U256, _is_ask: bool) -> bool {
        // 检查订单是否存在并获取信息
        let (price_level_id, is_ask) = if let Some(order) = self.orders.get(&order_id) {
            (order.price_level, order.is_ask)
        } else {
            debug!("Order {} not found, skip removal", order_id);
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
            level.total_volume += order_amount;
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
            bid_order.filled_amount += trade_amount;
        }
        if let Some(ask_order) = self.orders.get_mut(&ask_order_id) {
            ask_order.filled_amount += trade_amount;
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

        // 使用卖单价格作为成交价格（限价单撮合时 bid_price >= ask_price）
        let trade_price = ask_price_level;

        // 检查买单是否完全成交（使用灰尘阈值判断）
        let bid_fully_filled = if let Some(order) = self.orders.get(&bid_order_id) {
            Self::is_order_fully_filled(
                order.amount,
                order.filled_amount,
                false, // is_market_order (限价单)
                false, // is_ask (买单)
                trade_price,
            )
        } else {
            false
        };

        if bid_fully_filled {
            self.remove_filled_order(bid_order_id, false);
        }

        // 检查卖单是否完全成交（使用灰尘阈值判断）
        let ask_fully_filled = if let Some(order) = self.orders.get(&ask_order_id) {
            Self::is_order_fully_filled(
                order.amount,
                order.filled_amount,
                false, // is_market_order (限价单)
                true,  // is_ask (卖单)
                trade_price,
            )
        } else {
            false
        };

        if ask_fully_filled {
            self.remove_filled_order(ask_order_id, true);
        }

        true
    }

    /// 判断订单是否完全成交（使用灰尘阈值）
    /// 当剩余未成交部分的价值低于 DUST_THRESHOLD 时，视为完全成交
    /// 对应链上 _isOrderFullyFilled
    ///
    /// # Arguments
    /// * `amount` - 订单总量
    /// * `filled_amount` - 已成交量
    /// * `is_market_order` - 是否为市价单
    /// * `is_ask` - 是否为卖单
    /// * `trade_price` - 成交价格
    fn is_order_fully_filled(
        amount: U256,
        filled_amount: U256,
        is_market_order: bool,
        is_ask: bool,
        trade_price: U256,
    ) -> bool {
        // 精确相等或已超过时直接返回
        if filled_amount >= amount {
            return true;
        }

        // 计算剩余未成交部分的 quote value
        let remaining_quote_value = if is_market_order && !is_ask {
            // 市价买单：amount 和 filled_amount 都是 quote tokens
            amount - filled_amount
        } else {
            // 限价买单、限价卖单、市价卖单：amount 和 filled_amount 都是 base tokens
            let remaining_base = amount - filled_amount;
            remaining_base * trade_price / PRICE_DECIMALS
        };

        // 如果剩余价值低于灰尘阈值，视为完全成交
        remaining_quote_value < DUST_THRESHOLD
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
    #[cfg(test)]
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
    #[cfg(test)]
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
            is_ask,
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
    ///
    /// 重要语义说明：
    /// - 市价卖单 (is_market_ask=true): amount 表示要卖出的基础代币数量
    /// - 市价买单 (is_market_ask=false): amount 表示要花费的计价代币数量
    fn execute_market_trade(
        &mut self,
        market_order_id: U256,
        limit_order_id: U256,
        is_market_ask: bool,
    ) -> bool {
        // 获取市价单信息
        let (market_amount, market_filled) = if let Some(order) = self.orders.get(&market_order_id) {
            (order.amount, order.filled_amount)
        } else {
            return false;
        };

        // 获取限价单信息
        let (limit_remaining, limit_price_level) = if let Some(order) = self.orders.get(&limit_order_id) {
            (order.amount - order.filled_amount, order.price_level)
        } else {
            return false;
        };

        // 计算成交数量（以 base tokens 为单位）
        let trade_amount = if is_market_ask {
            // 市价卖单：amount 是 base tokens，直接比较
            let market_remaining = market_amount - market_filled;
            market_remaining.min(limit_remaining)
        } else {
            // 市价买单：amount 是 quote tokens（计价代币），需要转换成 base tokens
            // quote_remaining = 剩余可花费的计价代币数量
            let quote_remaining = market_amount - market_filled;
            // base = quote * PRICE_DECIMALS / price
            let market_remaining_base = quote_remaining * PRICE_DECIMALS / limit_price_level;
            market_remaining_base.min(limit_remaining)
        };

        if trade_amount.is_zero() {
            // trade_amount == 0 可能有两种情况：
            // 1. 订单已精确成交完毕（filled_amount == amount）
            // 2. 由于精度问题，剩余数量在转换后向下取整为0（常见于市价买单）
            //
            // 对于情况2，订单可能已成交99.99%但无法继续成交，
            // 如果剩余价值低于 DUST_THRESHOLD（0.01 USDC），应视为完全成交并移除订单

            // 检查市价单是否应该关闭
            let market_should_close = Self::is_order_fully_filled(
                market_amount,
                market_filled,
                true, // is_market_order
                is_market_ask,
                limit_price_level,
            );

            if market_should_close && market_filled < market_amount {
                // 市价单应该关闭但尚未精确成交完毕，移除它
                self.remove_market_order_from_list(market_order_id, is_market_ask);
                self.orders.remove(&market_order_id);
                debug!(
                    "Market order {} closed due to dust threshold (filled={}, amount={})",
                    market_order_id, market_filled, market_amount
                );
            }

            // 检查限价单是否应该关闭
            // 限价单是市价单的对手方：市价卖单 → 限价买单，市价买单 → 限价卖单
            let limit_is_ask = !is_market_ask;
            if let Some(order) = self.orders.get(&limit_order_id) {
                let limit_should_close = Self::is_order_fully_filled(
                    order.amount,
                    order.filled_amount,
                    false, // is_market_order
                    limit_is_ask,
                    limit_price_level,
                );

                if limit_should_close && order.filled_amount < order.amount {
                    self.remove_filled_order(limit_order_id, limit_is_ask);
                    debug!(
                        "Limit order {} closed due to dust threshold",
                        limit_order_id
                    );
                }
            }

            return false;
        }

        debug!(
            "Market trade: market_order={}, limit_order={}, trade_amount={}, is_market_ask={}",
            market_order_id, limit_order_id, trade_amount, is_market_ask
        );

        // 更新市价单已成交数量
        if let Some(order) = self.orders.get_mut(&market_order_id) {
            if is_market_ask {
                // 市价卖单：filled_amount 是 base tokens
                order.filled_amount += trade_amount;
            } else {
                // 市价买单：filled_amount 是 quote tokens（追踪花费的计价代币）
                // quote_spent = trade_amount * price / PRICE_DECIMALS
                let quote_spent = trade_amount * limit_price_level / PRICE_DECIMALS;
                order.filled_amount += quote_spent;
            }
        }

        // 更新限价单已成交数量 (always in base tokens)
        if let Some(order) = self.orders.get_mut(&limit_order_id) {
            order.filled_amount += trade_amount;
        }

        // 更新限价单所在价格层级的总挂单量
        let limit_is_ask = !is_market_ask;
        let limit_key = Self::get_price_level_key(limit_price_level, limit_is_ask);
        if let Some(level) = self.price_levels.get_mut(&limit_key) {
            level.total_volume = level.total_volume.saturating_sub(trade_amount);
        }

        // 检查市价单是否完全成交（使用灰尘阈值判断）
        let market_fully_filled = if let Some(order) = self.orders.get(&market_order_id) {
            Self::is_order_fully_filled(
                order.amount,
                order.filled_amount,
                true, // is_market_order
                is_market_ask,
                limit_price_level,
            )
        } else {
            false
        };

        if market_fully_filled {
            // 从市价单列表中移除
            self.remove_market_order_from_list(market_order_id, is_market_ask);
            // 删除订单数据
            self.orders.remove(&market_order_id);
        }

        // 检查限价单是否完全成交（使用灰尘阈值判断）
        let limit_fully_filled = if let Some(order) = self.orders.get(&limit_order_id) {
            Self::is_order_fully_filled(
                order.amount,
                order.filled_amount,
                false, // is_market_order
                limit_is_ask,
                limit_price_level,
            )
        } else {
            false
        };

        if limit_fully_filled {
            self.remove_filled_order(limit_order_id, limit_is_ask);
        }

        true
    }

    /// 检查是否有可撮合的订单
    /// 返回 (has_matchable_limit_orders, has_matchable_market_orders)
    pub fn has_matchable_orders(&self) -> (bool, bool) {
        // 检查限价单：bid_head >= ask_head
        let has_matchable_limit = if !self.bid_head.is_zero() && !self.ask_head.is_zero() {
            let bid_key = Self::get_price_level_key(self.bid_head, false);
            let ask_key = Self::get_price_level_key(self.ask_head, true);

            if let (Some(bid_level), Some(ask_level)) =
                (self.price_levels.get(&bid_key), self.price_levels.get(&ask_key))
            {
                bid_level.price >= ask_level.price
            } else {
                false
            }
        } else {
            false
        };

        // 检查市价单：有市价买单且有限价卖单，或有市价卖单且有限价买单
        let has_matchable_market = (!self.market_bid_head.is_zero() && !self.ask_head.is_zero())
            || (!self.market_ask_head.is_zero() && !self.bid_head.is_zero());

        (has_matchable_limit, has_matchable_market)
    }

    /// 获取市价单列表（用于调试）
    #[cfg(test)]
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

    /// 测试用的金额单位，确保金额远大于 DUST_THRESHOLD
    /// 1 个单位 = 100 * DUST_THRESHOLD = 100_000_000 (相当于 1 个 token with AMOUNT_DECIMALS)
    const TEST_AMOUNT_UNIT: U256 = U256([100_000_000, 0, 0, 0]);

    /// 测试用的价格（等于 PRICE_DECIMALS，使得 1 base = 1 quote）
    const TEST_PRICE: U256 = PRICE_DECIMALS;

    #[test]
    fn test_insert_single_order() {
        let mut sim = OrderBookSimulator::new();

        // 插入一个买单，使用测试金额单位
        let amount = U256::from(10) * TEST_AMOUNT_UNIT; // 10 个单位
        let insert_after = sim.simulate_insert_order(
            U256::from(1),
            TEST_PRICE,
            amount,
            false, // bid
            None,  // global_tail_order_id
        );

        assert_eq!(insert_after.0, U256::zero()); // 空订单簿，插入头部（检查 insert_after_price_level）
        assert_eq!(sim.bid_head, TEST_PRICE);
        assert_eq!(sim.get_price_levels(false), vec![TEST_PRICE]);
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
            None,
        );
        assert_eq!(insert1.0, U256::zero()); // 检查 insert_after_price_level

        // 插入买单2: price=90 (低于100，应该在100之后)
        let insert2 = sim.simulate_insert_order(
            U256::from(2),
            U256::from(90),
            U256::from(10),
            false,
            None,
        );
        assert_eq!(insert2.0, U256::from(100)); // 插入到100之后（检查 insert_after_price_level）

        // 插入买单3: price=110 (高于100，应该成为新头部)
        let insert3 = sim.simulate_insert_order(
            U256::from(3),
            U256::from(110),
            U256::from(10),
            false,
            None,
        );
        assert_eq!(insert3.0, U256::zero()); // 插入到头部（检查 insert_after_price_level）

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
            None,
        );
        assert_eq!(insert1.0, U256::zero()); // 检查 insert_after_price_level

        // 插入卖单2: price=110 (高于100，应该在100之后)
        let insert2 = sim.simulate_insert_order(
            U256::from(2),
            U256::from(110),
            U256::from(10),
            true,
            None,
        );
        assert_eq!(insert2.0, U256::from(100)); // 插入到100之后（检查 insert_after_price_level）

        // 插入卖单3: price=90 (低于100，应该成为新头部)
        let insert3 = sim.simulate_insert_order(
            U256::from(3),
            U256::from(90),
            U256::from(10),
            true,
            None,
        );
        assert_eq!(insert3.0, U256::zero()); // 插入到头部（检查 insert_after_price_level）

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

        // 使用足够大的金额以避免触发 dust threshold
        let amount_10 = U256::from(10) * TEST_AMOUNT_UNIT;
        let amount_5 = U256::from(5) * TEST_AMOUNT_UNIT;

        // 先插入一个买单: price=TEST_PRICE, amount=10 units
        sim.simulate_insert_order(
            U256::from(1),
            TEST_PRICE,
            amount_10,
            false,
            None,
        );

        // 插入一个卖单: price=TEST_PRICE, amount=5 units (应该匹配)
        sim.simulate_insert_order(
            U256::from(2),
            TEST_PRICE,
            amount_5,
            true,
            None,
        );

        // 卖单完全成交，不应该在订单簿中
        assert!(!sim.orders.contains_key(&U256::from(2)));

        // 买单部分成交，检查剩余
        let bid_order = sim.orders.get(&U256::from(1)).unwrap();
        assert_eq!(bid_order.filled_amount, amount_5);
    }

    #[test]
    fn test_full_match_removes_price_level() {
        let mut sim = OrderBookSimulator::new();

        let amount_10 = U256::from(10) * TEST_AMOUNT_UNIT;

        // 插入买单: price=TEST_PRICE, amount=10 units
        sim.simulate_insert_order(
            U256::from(1),
            TEST_PRICE,
            amount_10,
            false,
            None,
        );

        // 插入卖单: price=TEST_PRICE, amount=10 units (完全匹配)
        sim.simulate_insert_order(
            U256::from(2),
            TEST_PRICE,
            amount_10,
            true,
            None,
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

        let amount_10 = U256::from(10) * TEST_AMOUNT_UNIT;
        let amount_5 = U256::from(5) * TEST_AMOUNT_UNIT;

        // 使用不同的价格来测试跨价撮合
        let bid_price = TEST_PRICE + U256::from(10_000_000); // 略高于 TEST_PRICE
        let ask_price = TEST_PRICE; // 低于买价，会被撮合

        // 插入买单: price=bid_price, amount=10 units
        sim.simulate_insert_order(
            U256::from(1),
            bid_price,
            amount_10,
            false,
            None,
        );

        // 插入卖单: price=ask_price (低于买单价格，会被撮合)
        let insert_after = sim.simulate_insert_order(
            U256::from(2),
            ask_price,
            amount_5,
            true,
            None,
        );

        // insertAfterPrice 应该基于插入前的状态（ask 侧为空）
        assert_eq!(insert_after.0, U256::zero()); // 检查 insert_after_price_level

        // 卖单完全成交
        assert!(!sim.orders.contains_key(&U256::from(2)));

        // 买单部分成交
        let bid_order = sim.orders.get(&U256::from(1)).unwrap();
        assert_eq!(bid_order.filled_amount, amount_5);
    }

    #[test]
    fn test_batch_orders_with_matching() {
        let mut sim = OrderBookSimulator::new();

        let amount_10 = U256::from(10) * TEST_AMOUNT_UNIT;
        let price_100 = TEST_PRICE;
        let price_95 = TEST_PRICE - U256::from(5_000_000);

        // 模拟批处理场景：
        // 1. 买单 @ price_100
        // 2. 卖单 @ price_100 (会匹配)
        // 3. 买单 @ price_95 (应该正确计算 insertAfterPrice)

        sim.simulate_insert_order(U256::from(1), price_100, amount_10, false, None);
        sim.simulate_insert_order(U256::from(2), price_100, amount_10, true, None);

        // 买单和卖单完全匹配后，订单簿为空
        assert!(sim.get_price_levels(false).is_empty());

        // 新买单应该插入到头部
        let insert_after = sim.simulate_insert_order(U256::from(3), price_95, amount_10, false, None);
        assert_eq!(insert_after.0, U256::zero()); // 检查 insert_after_price_level
    }

    // ============ 市价单测试 ============
    //
    // 注意：市价买单的 amount 表示要花费的计价代币数量（quote tokens）
    // 市价卖单的 amount 表示要卖出的基础代币数量（base tokens）
    //
    // 使用 price = PRICE_DECIMALS (100_000_000) 时，quote_amount = base_amount
    // 使用 TEST_AMOUNT_UNIT 确保金额足够大以避免触发 dust threshold

    #[test]
    fn test_market_order_insertion() {
        let mut sim = OrderBookSimulator::new();

        let amount_10 = U256::from(10) * TEST_AMOUNT_UNIT;
        let amount_5 = U256::from(5) * TEST_AMOUNT_UNIT;

        // 使用 price = PRICE_DECIMALS，这样 quote_amount = base_amount
        let price = PRICE_DECIMALS;

        // 插入一个限价卖单: price=PRICE_DECIMALS, amount=10 units
        sim.simulate_insert_order(U256::from(1), price, amount_10, true, None);

        // 插入一个市价买单，花费 5 units quote tokens
        // 由于 price = PRICE_DECIMALS，5 quote = 5 base
        sim.simulate_insert_market_order(U256::from(2), amount_5, false);

        // 市价买单完全成交，不应该在订单簿中
        assert!(!sim.orders.contains_key(&U256::from(2)));

        // 限价卖单部分成交（5 units base tokens）
        let ask_order = sim.orders.get(&U256::from(1)).unwrap();
        assert_eq!(ask_order.filled_amount, amount_5);
    }

    #[test]
    fn test_market_order_fully_matches_limit() {
        let mut sim = OrderBookSimulator::new();

        let amount_10 = U256::from(10) * TEST_AMOUNT_UNIT;

        // 使用 price = PRICE_DECIMALS，这样 quote_amount = base_amount
        let price = PRICE_DECIMALS;

        // 插入限价卖单: price=PRICE_DECIMALS, amount=10 units
        sim.simulate_insert_order(U256::from(1), price, amount_10, true, None);

        // 插入市价买单，花费 10 units quote tokens = 10 units base tokens
        sim.simulate_insert_market_order(U256::from(2), amount_10, false);

        // 两个订单都应该被移除
        assert!(!sim.orders.contains_key(&U256::from(1)));
        assert!(!sim.orders.contains_key(&U256::from(2)));

        // 价格层级也应该被移除
        assert!(sim.get_price_levels(true).is_empty());
    }

    #[test]
    fn test_market_order_partial_fill() {
        let mut sim = OrderBookSimulator::new();

        let amount_10 = U256::from(10) * TEST_AMOUNT_UNIT;
        let amount_5 = U256::from(5) * TEST_AMOUNT_UNIT;

        // 使用 price = PRICE_DECIMALS，这样 quote_amount = base_amount
        let price = PRICE_DECIMALS;

        // 插入限价卖单: price=PRICE_DECIMALS, amount=5 units
        sim.simulate_insert_order(U256::from(1), price, amount_5, true, None);

        // 插入市价买单，花费 10 units quote tokens
        // 但只有 5 units base tokens 可买，所以只花费 5 units quote tokens
        sim.simulate_insert_market_order(U256::from(2), amount_10, false);

        // 限价卖单完全成交，被移除
        assert!(!sim.orders.contains_key(&U256::from(1)));

        // 市价买单部分成交，保留在队列中
        // filled_amount 是花费的 quote tokens = 5 units
        let market_order = sim.orders.get(&U256::from(2)).unwrap();
        assert_eq!(market_order.filled_amount, amount_5);
        assert_eq!(market_order.is_market_order, true);

        // 市价买单应该在队列中
        assert_eq!(sim.get_market_orders(false), vec![U256::from(2)]);
    }

    #[test]
    fn test_market_sell_order() {
        let mut sim = OrderBookSimulator::new();

        let amount_10 = U256::from(10) * TEST_AMOUNT_UNIT;
        let amount_5 = U256::from(5) * TEST_AMOUNT_UNIT;

        // 插入限价买单: price=TEST_PRICE, amount=10 units
        sim.simulate_insert_order(U256::from(1), TEST_PRICE, amount_10, false, None);

        // 插入市价卖单
        sim.simulate_insert_market_order(U256::from(2), amount_5, true);

        // 市价卖单完全成交
        assert!(!sim.orders.contains_key(&U256::from(2)));

        // 限价买单部分成交
        let bid_order = sim.orders.get(&U256::from(1)).unwrap();
        assert_eq!(bid_order.filled_amount, amount_5);
    }

    #[test]
    fn test_market_order_affects_subsequent_limit_order() {
        let mut sim = OrderBookSimulator::new();

        let amount_10 = U256::from(10) * TEST_AMOUNT_UNIT;

        // 场景：批处理中市价单在限价单之前，市价单的撮合会影响后续限价单的 insertAfterPrice
        //
        // 初始状态：
        // Asks: [PRICE_DECIMALS, PRICE_DECIMALS+1, PRICE_DECIMALS+2]
        //
        // 批处理：
        // 1. Market Buy (花费 10 units quote，购买 10 units base @ PRICE_DECIMALS) - 会移除价格层
        // 2. Limit Sell @ PRICE_DECIMALS - 应该 insertAfterPrice = 0（插入到头部）

        let price_100 = PRICE_DECIMALS;
        let price_101 = PRICE_DECIMALS + U256::from(1);
        let price_102 = PRICE_DECIMALS + U256::from(2);

        // 设置初始订单簿
        sim.simulate_insert_order(U256::from(1), price_100, amount_10, true, None); // ask@PRICE_DECIMALS
        sim.simulate_insert_order(U256::from(2), price_101, amount_10, true, None); // ask@PRICE_DECIMALS+1
        sim.simulate_insert_order(U256::from(3), price_102, amount_10, true, None); // ask@PRICE_DECIMALS+2

        assert_eq!(sim.get_price_levels(true), vec![
            price_100,
            price_101,
            price_102,
        ]);

        // 市价买单，花费 10 units quote tokens 消耗掉价格层的所有订单
        // 由于 price = PRICE_DECIMALS，10 units quote = 10 units base
        sim.simulate_insert_market_order(U256::from(10), amount_10, false);

        // 价格层 PRICE_DECIMALS 应该被移除
        assert_eq!(sim.get_price_levels(true), vec![
            price_101,
            price_102,
        ]);

        // 现在插入限价卖单 @ PRICE_DECIMALS（比 PRICE_DECIMALS+1 低）
        // 应该 insertAfterPrice = 0（插入到头部）
        let insert_after = sim.simulate_insert_order(
            U256::from(11),
            price_100,
            amount_10,
            true,
            None,
        );
        assert_eq!(insert_after.0, U256::zero()); // 正确！插入到头部（检查 insert_after_price_level）

        // 验证新状态
        assert_eq!(sim.get_price_levels(true), vec![
            price_100,
            price_101,
            price_102,
        ]);
    }

    #[test]
    fn test_market_order_queue_fifo() {
        let mut sim = OrderBookSimulator::new();

        let amount_10 = U256::from(10) * TEST_AMOUNT_UNIT;

        // 市价单应该按 FIFO 顺序排列
        // 先插入市价买单（没有卖单可撮合）
        sim.simulate_insert_market_order(U256::from(1), amount_10, false);
        sim.simulate_insert_market_order(U256::from(2), amount_10, false);
        sim.simulate_insert_market_order(U256::from(3), amount_10, false);

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

        let amount_10 = U256::from(10) * TEST_AMOUNT_UNIT;
        let amount_30 = U256::from(30) * TEST_AMOUNT_UNIT;

        // 使用 price = PRICE_DECIMALS，这样 quote_amount = base_amount
        let price = PRICE_DECIMALS;

        // 插入一个大额限价卖单: 30 units base tokens
        sim.simulate_insert_order(U256::from(1), price, amount_30, true, None);

        // 插入多个市价买单，每个花费 10 units quote tokens = 10 units base tokens
        sim.simulate_insert_market_order(U256::from(10), amount_10, false);
        sim.simulate_insert_market_order(U256::from(11), amount_10, false);
        sim.simulate_insert_market_order(U256::from(12), amount_10, false);

        // 所有市价买单应该已成交（共消费 30 units base tokens）
        assert!(!sim.orders.contains_key(&U256::from(10)));
        assert!(!sim.orders.contains_key(&U256::from(11)));
        assert!(!sim.orders.contains_key(&U256::from(12)));

        // 限价卖单也应该完全成交
        assert!(!sim.orders.contains_key(&U256::from(1)));

        // 价格层级也应该被移除
        assert!(sim.get_price_levels(true).is_empty());
    }
}
