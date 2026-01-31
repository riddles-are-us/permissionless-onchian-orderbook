use crate::config::ApiConfig;
use crate::state::GlobalState;
use crate::storage::{MatcherStats, MongoStorage, OrderStatus, StoredKline, StoredOrder};
use actix_cors::Cors;
use actix_web::{web, App, HttpResponse, HttpServer, Responder};
use ethers::types::U256;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tracing::info;

/// API 状态
pub struct ApiState {
    pub storage: MongoStorage,
    pub global_state: Option<GlobalState>,
}

/// API 响应包装
#[derive(Serialize)]
pub struct ApiResponse<T> {
    pub success: bool,
    pub data: Option<T>,
    pub error: Option<String>,
}

impl<T: Serialize> ApiResponse<T> {
    pub fn success(data: T) -> Self {
        Self {
            success: true,
            data: Some(data),
            error: None,
        }
    }

    pub fn error(msg: &str) -> ApiResponse<()> {
        ApiResponse {
            success: false,
            data: None,
            error: Some(msg.to_string()),
        }
    }
}

/// 查询参数
#[derive(Deserialize)]
pub struct OrderQuery {
    pub status: Option<String>,
    pub limit: Option<i64>,
    pub offset: Option<u64>,
    pub pair_id: Option<String>,
}

#[derive(Deserialize)]
pub struct TradeQuery {
    pub pair_id: Option<String>,
    pub limit: Option<i64>,
    pub offset: Option<u64>,
}

#[derive(Deserialize)]
pub struct OrderbookQuery {
    pub depth: Option<i64>,
}

#[derive(Deserialize)]
pub struct BatchSubmissionQuery {
    pub submitter: Option<String>,
    pub limit: Option<i64>,
    pub offset: Option<u64>,
}

/// 活跃 Matcher 查询参数
#[derive(Deserialize)]
pub struct ActiveMatchersQuery {
    /// 统计时间范围（小时），默认 24
    pub hours: Option<u64>,
}

/// 活跃 Matcher 统计响应
#[derive(Serialize)]
pub struct ActiveMatchersResponse {
    /// 活跃 matcher 数量
    pub active_count: u64,
    /// 统计时间范围（小时）
    pub hours: u64,
    /// 总提交次数
    pub total_submissions: u64,
    /// 总手续费 (所有 matcher 累计)
    pub total_fees: String,
    /// 各 matcher 的详细统计
    pub matchers: Vec<MatcherStats>,
}

/// K线查询参数
#[derive(Deserialize)]
pub struct KlineQuery {
    /// 时间周期: 1m, 5m, 15m, 1h, 1d, 1M, 1y
    pub interval: String,
    /// 开始时间 (毫秒时间戳)
    pub start_time: Option<i64>,
    /// 结束时间 (毫秒时间戳)
    pub end_time: Option<i64>,
    /// 返回数量限制 (默认100，最大500)
    pub limit: Option<i64>,
}

/// K线响应 (兼容交易所API格式)
#[derive(Serialize)]
pub struct KlineResponse {
    /// 开盘时间 (毫秒)
    pub open_time: i64,
    /// 收盘时间 (毫秒)
    pub close_time: i64,
    /// 开盘价
    pub open: String,
    /// 最高价
    pub high: String,
    /// 最低价
    pub low: String,
    /// 收盘价
    pub close: String,
    /// 成交量 (base token)
    pub volume: String,
    /// 成交额 (quote token)
    pub quote_volume: String,
    /// 成交笔数
    pub trade_count: u64,
}

impl From<StoredKline> for KlineResponse {
    fn from(kline: StoredKline) -> Self {
        KlineResponse {
            open_time: kline.open_time,
            close_time: kline.close_time,
            open: kline.open,
            high: kline.high,
            low: kline.low,
            close: kline.close,
            volume: kline.volume,
            quote_volume: kline.quote_volume,
            trade_count: kline.trade_count,
        }
    }
}

/// 订单簿响应
#[derive(Serialize)]
pub struct OrderbookResponse {
    pub bids: Vec<StoredOrder>,
    pub asks: Vec<StoredOrder>,
}

/// 系统概述中的价格层级
#[derive(Serialize)]
pub struct OverviewPriceLevel {
    pub price: String,
    pub total_volume: String,
    pub order_count: usize,
}

/// 系统概述中的请求信息
#[derive(Serialize)]
pub struct OverviewRequest {
    pub request_id: String,
    pub request_type: String,
    pub trader: String,
    pub order_type: String,
    pub is_ask: bool,
    pub price: String,
    pub amount: String,
}

/// 市价单统计
#[derive(Serialize)]
pub struct MarketOrderStats {
    pub total_buy_amount: String,
    pub total_sell_amount: String,
    pub buy_order_count: usize,
    pub sell_order_count: usize,
}

/// 系统概述响应
#[derive(Serialize)]
pub struct SystemOverviewResponse {
    pub current_block: u64,
    pub match_id: String,
    pub pending_requests: Vec<OverviewRequest>,
    pub pending_request_count: usize,
    pub asks: Vec<OverviewPriceLevel>,
    pub bids: Vec<OverviewPriceLevel>,
    pub market_orders: MarketOrderStats,
}

/// 调试用订单簿状态响应
#[derive(Serialize)]
pub struct DebugOrderbookResponse {
    pub ask_head: String,
    pub ask_tail: String,
    pub bid_head: String,
    pub bid_tail: String,
    pub price_levels_count: usize,
    pub orders_count: usize,
    pub price_level_keys: Vec<String>,
}

/// 交易对信息响应
#[derive(Serialize)]
pub struct TradingPairInfo {
    pub pair_id: String,
    pub ticker: Option<String>,
    pub base_token: Option<String>,
    pub quote_token: Option<String>,
    pub base_symbol: Option<String>,
    pub quote_symbol: Option<String>,
    pub base_decimals: Option<u8>,
    pub quote_decimals: Option<u8>,
    pub ask_levels: usize,
    pub bid_levels: usize,
    pub total_orders: usize,
}

/// 交易对列表响应
#[derive(Serialize)]
pub struct TradingPairsResponse {
    pub pairs: Vec<TradingPairInfo>,
    pub total_count: usize,
}

/// 单个交易对的概述响应
#[derive(Serialize)]
pub struct TradingPairOverviewResponse {
    pub pair_id: String,
    pub ticker: Option<String>,
    pub base_token: Option<String>,
    pub quote_token: Option<String>,
    pub base_decimals: Option<u8>,
    pub quote_decimals: Option<u8>,
    pub current_block: u64,
    pub match_id: String,
    pub pending_requests: Vec<OverviewRequest>,
    pub pending_request_count: usize,
    pub asks: Vec<OverviewPriceLevel>,
    pub bids: Vec<OverviewPriceLevel>,
    pub market_orders: MarketOrderStats,
    /// 流动性 (挂单总价值，quote token)
    pub liquidity: String,
    /// 24h 交易量 (quote token)
    pub volume_24h: String,
    /// 24h 独立交易者数量
    pub traders_24h: u64,
    /// 24h 交易笔数
    pub trades_24h: u64,
}

/// 健康检查
async fn health() -> impl Responder {
    HttpResponse::Ok().json(ApiResponse::success("OK"))
}

/// 获取用户的所有订单
async fn get_user_orders(
    state: web::Data<Arc<ApiState>>,
    path: web::Path<String>,
    query: web::Query<OrderQuery>,
) -> impl Responder {
    let trader = path.into_inner();
    let limit = query.limit.unwrap_or(50).min(100);
    let offset = query.offset.unwrap_or(0);
    let pair_id = query.pair_id.as_deref();

    let status = query.status.as_ref().and_then(|s| match s.to_lowercase().as_str() {
        "pending" => Some(OrderStatus::Pending),
        "active" => Some(OrderStatus::Active),
        "partiallyfilled" => Some(OrderStatus::PartiallyFilled),
        "filled" => Some(OrderStatus::Filled),
        "cancelled" => Some(OrderStatus::Cancelled),
        _ => None,
    });

    match state.storage.get_orders_by_trader(&trader, status, limit, offset, pair_id).await {
        Ok(orders) => HttpResponse::Ok().json(ApiResponse::success(orders)),
        Err(e) => HttpResponse::InternalServerError().json(ApiResponse::<()>::error(&e.to_string())),
    }
}

/// 获取用户的活跃订单
async fn get_user_active_orders(
    state: web::Data<Arc<ApiState>>,
    path: web::Path<String>,
) -> impl Responder {
    let trader = path.into_inner();

    match state.storage.get_active_orders_by_trader(&trader).await {
        Ok(orders) => HttpResponse::Ok().json(ApiResponse::success(orders)),
        Err(e) => HttpResponse::InternalServerError().json(ApiResponse::<()>::error(&e.to_string())),
    }
}

/// 获取单个订单详情
async fn get_order(
    state: web::Data<Arc<ApiState>>,
    path: web::Path<String>,
) -> impl Responder {
    let order_id = path.into_inner();

    match state.storage.get_order_by_id(&order_id).await {
        Ok(Some(order)) => HttpResponse::Ok().json(ApiResponse::success(order)),
        Ok(None) => HttpResponse::NotFound().json(ApiResponse::<()>::error("Order not found")),
        Err(e) => HttpResponse::InternalServerError().json(ApiResponse::<()>::error(&e.to_string())),
    }
}

/// 获取所有交易历史
async fn get_trades(
    state: web::Data<Arc<ApiState>>,
    query: web::Query<TradeQuery>,
) -> impl Responder {
    let limit = query.limit.unwrap_or(50).min(100);
    let offset = query.offset.unwrap_or(0);
    let pair_id = query.pair_id.as_deref();

    match state.storage.get_trades(limit, offset, pair_id).await {
        Ok(trades) => HttpResponse::Ok().json(ApiResponse::success(trades)),
        Err(e) => HttpResponse::InternalServerError().json(ApiResponse::<()>::error(&e.to_string())),
    }
}

/// 获取所有订单（支持状态筛选）
async fn get_orders(
    state: web::Data<Arc<ApiState>>,
    query: web::Query<OrderQuery>,
) -> impl Responder {
    let limit = query.limit.unwrap_or(50).min(100);
    let offset = query.offset.unwrap_or(0);

    let status = query.status.as_ref().and_then(|s| match s.to_lowercase().as_str() {
        "pending" => Some(OrderStatus::Pending),
        "active" => Some(OrderStatus::Active),
        "partiallyfilled" => Some(OrderStatus::PartiallyFilled),
        "filled" => Some(OrderStatus::Filled),
        "cancelled" => Some(OrderStatus::Cancelled),
        _ => None,
    });

    match state.storage.get_orders(status, limit, offset).await {
        Ok(orders) => HttpResponse::Ok().json(ApiResponse::success(orders)),
        Err(e) => HttpResponse::InternalServerError().json(ApiResponse::<()>::error(&e.to_string())),
    }
}

/// 获取订单簿
async fn get_orderbook(
    state: web::Data<Arc<ApiState>>,
    path: web::Path<String>,
    query: web::Query<OrderbookQuery>,
) -> impl Responder {
    let trading_pair = path.into_inner();
    let depth = query.depth.unwrap_or(20).min(100);

    match state.storage.get_orderbook(&trading_pair, depth).await {
        Ok((bids, asks)) => {
            HttpResponse::Ok().json(ApiResponse::success(OrderbookResponse { bids, asks }))
        }
        Err(e) => HttpResponse::InternalServerError().json(ApiResponse::<()>::error(&e.to_string())),
    }
}

/// 获取K线数据
/// GET /api/v1/klines/{trading_pair}?interval=1m&start_time=xxx&end_time=xxx&limit=100
async fn get_klines(
    state: web::Data<Arc<ApiState>>,
    path: web::Path<String>,
    query: web::Query<KlineQuery>,
) -> impl Responder {
    let trading_pair = path.into_inner();
    let limit = query.limit.unwrap_or(100).min(500);

    // 验证 interval 参数
    if !matches!(
        query.interval.as_str(),
        "1m" | "5m" | "15m" | "1h" | "1d" | "1M" | "1y"
    ) {
        return HttpResponse::BadRequest().json(ApiResponse::<()>::error(
            "Invalid interval. Valid values: 1m, 5m, 15m, 1h, 1d, 1M, 1y"
        ));
    }

    match state.storage.get_klines(
        &trading_pair,
        &query.interval,
        query.start_time,
        query.end_time,
        limit,
    ).await {
        Ok(klines) => {
            let response: Vec<KlineResponse> = klines.into_iter().map(|k| k.into()).collect();
            HttpResponse::Ok().json(ApiResponse::success(response))
        }
        Err(e) => HttpResponse::InternalServerError().json(ApiResponse::<()>::error(&e.to_string())),
    }
}

/// 获取系统概述
async fn get_system_overview(
    state: web::Data<Arc<ApiState>>,
) -> impl Responder {
    let global_state = match &state.global_state {
        Some(gs) => gs,
        None => {
            return HttpResponse::ServiceUnavailable()
                .json(ApiResponse::<()>::error("GlobalState not available"));
        }
    };

    // 获取当前区块和 matchId
    let current_block = *global_state.current_block.read();
    let match_id = global_state.get_match_id();

    // 获取待处理请求（最多10个）
    let requests = global_state.get_head_requests(10);
    let pending_request_count = global_state.queued_requests.len();
    let pending_requests: Vec<OverviewRequest> = requests
        .iter()
        .map(|r| OverviewRequest {
            request_id: r.request_id.to_string(),
            request_type: match r.request_type {
                crate::types::RequestType::PlaceOrder => "PlaceOrder".to_string(),
                crate::types::RequestType::RemoveOrder => "RemoveOrder".to_string(),
            },
            trader: format!("{:?}", r.trader).to_lowercase(),
            order_type: match r.order_type {
                crate::types::OrderType::Limit => "Limit".to_string(),
                crate::types::OrderType::Market => "Market".to_string(),
            },
            is_ask: r.is_ask,
            price: r.price.to_string(),
            amount: r.amount.to_string(),
        })
        .collect();

    // 获取订单簿数据（使用第一个交易对）
    let supported_pairs = global_state.get_supported_pairs();
    let first_pair = supported_pairs.first();

    // 获取 asks（最多10个价格层级）
    let mut asks = Vec::new();
    let mut bids = Vec::new();
    let mut total_buy_amount = U256::zero();
    let mut buy_order_count = 0;
    let mut total_sell_amount = U256::zero();
    let mut sell_order_count = 0;

    if let Some(pair) = first_pair {
        if let Some(orderbook) = global_state.get_orderbook(pair) {
            let mut current_price = orderbook.ask_head;
            let mut count = 0;
            while !current_price.is_zero() && count < 10 {
                let key = if true { current_price } else { current_price | (U256::one() << 255) };
                if let Some(level) = orderbook.price_levels.get(&key) {
                    // 统计该价格层级的订单数量和剩余量
                    let mut order_count = 0;
                    let mut remaining_volume = U256::zero();
                    let mut order_id = level.head_order_id;
                    while !order_id.is_zero() {
                        order_count += 1;
                        if let Some(order) = orderbook.orders.get(&order_id) {
                            remaining_volume += order.amount - order.filled_amount;
                            order_id = order.next_order_id;
                        } else {
                            break;
                        }
                    }
                    asks.push(OverviewPriceLevel {
                        price: level.price.to_string(),
                        total_volume: remaining_volume.to_string(),
                        order_count,
                    });
                    current_price = level.next_price;
                } else {
                    break;
                }
                count += 1;
            }

            // 获取 bids（最多10个价格层级）
            let mut current_price = orderbook.bid_head;
            let mut count = 0;
            while !current_price.is_zero() && count < 10 {
                let key = current_price | (U256::one() << 255);
                if let Some(level) = orderbook.price_levels.get(&key) {
                    // 统计该价格层级的订单数量和剩余量
                    let mut order_count = 0;
                    let mut remaining_volume = U256::zero();
                    let mut order_id = level.head_order_id;
                    while !order_id.is_zero() {
                        order_count += 1;
                        if let Some(order) = orderbook.orders.get(&order_id) {
                            remaining_volume += order.amount - order.filled_amount;
                            order_id = order.next_order_id;
                        } else {
                            break;
                        }
                    }
                    bids.push(OverviewPriceLevel {
                        price: level.price.to_string(),
                        total_volume: remaining_volume.to_string(),
                        order_count,
                    });
                    current_price = level.next_price;
                } else {
                    break;
                }
                count += 1;
            }

            // 统计市价单
            let mut order_id = orderbook.market_bid_head;
            while !order_id.is_zero() {
                if let Some(order) = orderbook.orders.get(&order_id) {
                    total_buy_amount += order.amount - order.filled_amount;
                    buy_order_count += 1;
                    order_id = order.next_order_id;
                } else {
                    break;
                }
            }

            let mut order_id = orderbook.market_ask_head;
            while !order_id.is_zero() {
                if let Some(order) = orderbook.orders.get(&order_id) {
                    total_sell_amount += order.amount - order.filled_amount;
                    sell_order_count += 1;
                    order_id = order.next_order_id;
                } else {
                    break;
                }
            }
        }
    }

    let response = SystemOverviewResponse {
        current_block,
        match_id: match_id.to_string(),
        pending_requests,
        pending_request_count,
        asks,
        bids,
        market_orders: MarketOrderStats {
            total_buy_amount: total_buy_amount.to_string(),
            total_sell_amount: total_sell_amount.to_string(),
            buy_order_count,
            sell_order_count,
        },
    };

    HttpResponse::Ok().json(ApiResponse::success(response))
}

/// 调试：获取原始订单簿状态
async fn get_debug_orderbook(state: web::Data<Arc<ApiState>>) -> impl Responder {
    let global_state = match &state.global_state {
        Some(gs) => gs,
        None => {
            return HttpResponse::ServiceUnavailable()
                .json(ApiResponse::<()>::error("GlobalState not available"));
        }
    };

    // 使用第一个交易对
    let supported_pairs = global_state.get_supported_pairs();
    let first_pair = supported_pairs.first();

    let response = if let Some(pair) = first_pair {
        if let Some(orderbook) = global_state.get_orderbook(pair) {
            // 收集所有 price_level keys
            let mut price_level_keys: Vec<String> = orderbook.price_levels.keys()
                .map(|k| format!("{}", k))
                .collect();
            price_level_keys.sort();

            DebugOrderbookResponse {
                ask_head: orderbook.ask_head.to_string(),
                ask_tail: orderbook.ask_tail.to_string(),
                bid_head: orderbook.bid_head.to_string(),
                bid_tail: orderbook.bid_tail.to_string(),
                price_levels_count: orderbook.price_levels.len(),
                orders_count: orderbook.orders.len(),
                price_level_keys,
            }
        } else {
            DebugOrderbookResponse {
                ask_head: "0".to_string(),
                ask_tail: "0".to_string(),
                bid_head: "0".to_string(),
                bid_tail: "0".to_string(),
                price_levels_count: 0,
                orders_count: 0,
                price_level_keys: vec![],
            }
        }
    } else {
        DebugOrderbookResponse {
            ask_head: "0".to_string(),
            ask_tail: "0".to_string(),
            bid_head: "0".to_string(),
            bid_tail: "0".to_string(),
            price_levels_count: 0,
            orders_count: 0,
            price_level_keys: vec![],
        }
    };

    HttpResponse::Ok().json(ApiResponse::success(response))
}

/// 获取所有支持的交易对列表
/// GET /api/v1/trading-pairs
async fn get_trading_pairs(
    state: web::Data<Arc<ApiState>>,
) -> impl Responder {
    let global_state = match &state.global_state {
        Some(gs) => gs,
        None => {
            return HttpResponse::ServiceUnavailable()
                .json(ApiResponse::<()>::error("GlobalState not available"));
        }
    };

    let supported_pairs = global_state.get_supported_pairs();
    let mut pairs: Vec<TradingPairInfo> = Vec::new();

    for pair in &supported_pairs {
        let pair_id = format!("0x{}", hex::encode(pair));

        // 获取元数据
        let metadata = global_state.get_pair_metadata(pair);

        let (ask_levels, bid_levels, total_orders) = if let Some(orderbook) = global_state.get_orderbook(pair) {
            // 计算 ask 价格层级数量
            let mut ask_count = 0;
            let mut current = orderbook.ask_head;
            while !current.is_zero() {
                ask_count += 1;
                if let Some(level) = orderbook.price_levels.get(&current) {
                    current = level.next_price;
                } else {
                    break;
                }
            }

            // 计算 bid 价格层级数量
            let mut bid_count = 0;
            let mut current = orderbook.bid_head;
            while !current.is_zero() {
                bid_count += 1;
                let key = current | (U256::one() << 255);
                if let Some(level) = orderbook.price_levels.get(&key) {
                    current = level.next_price;
                } else {
                    break;
                }
            }

            (ask_count, bid_count, orderbook.orders.len())
        } else {
            (0, 0, 0)
        };

        pairs.push(TradingPairInfo {
            pair_id,
            ticker: metadata.as_ref().map(|m| m.ticker.clone()),
            base_token: metadata.as_ref().map(|m| format!("{:?}", m.base_token)),
            quote_token: metadata.as_ref().map(|m| format!("{:?}", m.quote_token)),
            base_symbol: metadata.as_ref().map(|m| m.base_symbol.clone()),
            quote_symbol: metadata.as_ref().map(|m| m.quote_symbol.clone()),
            base_decimals: metadata.as_ref().map(|m| m.base_decimals),
            quote_decimals: metadata.as_ref().map(|m| m.quote_decimals),
            ask_levels,
            bid_levels,
            total_orders,
        });
    }

    let total_count = pairs.len();
    HttpResponse::Ok().json(ApiResponse::success(TradingPairsResponse { pairs, total_count }))
}

/// 获取单个交易对的概述
/// GET /api/v1/trading-pairs/{trading_pair}/overview
async fn get_trading_pair_overview(
    state: web::Data<Arc<ApiState>>,
    path: web::Path<String>,
) -> impl Responder {
    let trading_pair_str = path.into_inner();
    let global_state = match &state.global_state {
        Some(gs) => gs,
        None => {
            return HttpResponse::ServiceUnavailable()
                .json(ApiResponse::<()>::error("GlobalState not available"));
        }
    };

    // 解析交易对 ID
    let trading_pair: [u8; 32] = if trading_pair_str.starts_with("0x") {
        match hex::decode(&trading_pair_str[2..]) {
            Ok(bytes) if bytes.len() == 32 => {
                let mut arr = [0u8; 32];
                arr.copy_from_slice(&bytes);
                arr
            }
            _ => {
                return HttpResponse::BadRequest()
                    .json(ApiResponse::<()>::error("Invalid trading pair format"));
            }
        }
    } else {
        return HttpResponse::BadRequest()
            .json(ApiResponse::<()>::error("Trading pair must start with 0x"));
    };

    // 检查交易对是否支持
    if !global_state.is_pair_supported(&trading_pair) {
        return HttpResponse::NotFound()
            .json(ApiResponse::<()>::error("Trading pair not supported"));
    }

    // 获取当前区块和 matchId
    let current_block = *global_state.current_block.read();
    let match_id = global_state.get_match_id();

    // 获取该交易对的待处理请求
    let all_requests = global_state.get_head_requests(100);
    let pair_requests: Vec<_> = all_requests
        .iter()
        .filter(|r| r.trading_pair == trading_pair)
        .take(10)
        .collect();

    let pending_request_count = all_requests
        .iter()
        .filter(|r| r.trading_pair == trading_pair)
        .count();

    let pending_requests: Vec<OverviewRequest> = pair_requests
        .iter()
        .map(|r| OverviewRequest {
            request_id: r.request_id.to_string(),
            request_type: match r.request_type {
                crate::types::RequestType::PlaceOrder => "PlaceOrder".to_string(),
                crate::types::RequestType::RemoveOrder => "RemoveOrder".to_string(),
            },
            trader: format!("{:?}", r.trader).to_lowercase(),
            order_type: match r.order_type {
                crate::types::OrderType::Limit => "Limit".to_string(),
                crate::types::OrderType::Market => "Market".to_string(),
            },
            is_ask: r.is_ask,
            price: r.price.to_string(),
            amount: r.amount.to_string(),
        })
        .collect();

    // 获取订单簿数据
    let mut asks = Vec::new();
    let mut bids = Vec::new();
    let mut total_buy_amount = U256::zero();
    let mut buy_order_count = 0;
    let mut total_sell_amount = U256::zero();
    let mut sell_order_count = 0;

    if let Some(orderbook) = global_state.get_orderbook(&trading_pair) {
        // 获取 asks（最多10个价格层级）
        let mut current_price = orderbook.ask_head;
        let mut count = 0;
        while !current_price.is_zero() && count < 10 {
            let key = current_price;
            if let Some(level) = orderbook.price_levels.get(&key) {
                let mut order_count = 0;
                let mut remaining_volume = U256::zero();
                let mut order_id = level.head_order_id;
                while !order_id.is_zero() {
                    order_count += 1;
                    if let Some(order) = orderbook.orders.get(&order_id) {
                        remaining_volume += order.amount - order.filled_amount;
                        order_id = order.next_order_id;
                    } else {
                        break;
                    }
                }
                asks.push(OverviewPriceLevel {
                    price: level.price.to_string(),
                    total_volume: remaining_volume.to_string(),
                    order_count,
                });
                current_price = level.next_price;
            } else {
                break;
            }
            count += 1;
        }

        // 获取 bids（最多10个价格层级）
        let mut current_price = orderbook.bid_head;
        let mut count = 0;
        while !current_price.is_zero() && count < 10 {
            let key = current_price | (U256::one() << 255);
            if let Some(level) = orderbook.price_levels.get(&key) {
                let mut order_count = 0;
                let mut remaining_volume = U256::zero();
                let mut order_id = level.head_order_id;
                while !order_id.is_zero() {
                    order_count += 1;
                    if let Some(order) = orderbook.orders.get(&order_id) {
                        remaining_volume += order.amount - order.filled_amount;
                        order_id = order.next_order_id;
                    } else {
                        break;
                    }
                }
                bids.push(OverviewPriceLevel {
                    price: level.price.to_string(),
                    total_volume: remaining_volume.to_string(),
                    order_count,
                });
                current_price = level.next_price;
            } else {
                break;
            }
            count += 1;
        }

        // 统计市价单
        let mut order_id = orderbook.market_bid_head;
        while !order_id.is_zero() {
            if let Some(order) = orderbook.orders.get(&order_id) {
                total_buy_amount += order.amount - order.filled_amount;
                buy_order_count += 1;
                order_id = order.next_order_id;
            } else {
                break;
            }
        }

        let mut order_id = orderbook.market_ask_head;
        while !order_id.is_zero() {
            if let Some(order) = orderbook.orders.get(&order_id) {
                total_sell_amount += order.amount - order.filled_amount;
                sell_order_count += 1;
                order_id = order.next_order_id;
            } else {
                break;
            }
        }
    }

    // 获取元数据
    let metadata = global_state.get_pair_metadata(&trading_pair);

    // 获取统计数据 (liquidity, volume_24h, traders_24h, trades_24h)
    let stats = state.storage.get_trading_pair_stats(&trading_pair_str).await.unwrap_or_default();

    let response = TradingPairOverviewResponse {
        pair_id: trading_pair_str,
        ticker: metadata.as_ref().map(|m| m.ticker.clone()),
        base_token: metadata.as_ref().map(|m| format!("{:?}", m.base_token)),
        quote_token: metadata.as_ref().map(|m| format!("{:?}", m.quote_token)),
        base_decimals: metadata.as_ref().map(|m| m.base_decimals),
        quote_decimals: metadata.as_ref().map(|m| m.quote_decimals),
        current_block,
        match_id: match_id.to_string(),
        pending_requests,
        pending_request_count,
        asks,
        bids,
        market_orders: MarketOrderStats {
            total_buy_amount: total_buy_amount.to_string(),
            total_sell_amount: total_sell_amount.to_string(),
            buy_order_count,
            sell_order_count,
        },
        liquidity: stats.liquidity,
        volume_24h: stats.volume_24h,
        traders_24h: stats.traders_24h,
        trades_24h: stats.trades_24h,
    };

    HttpResponse::Ok().json(ApiResponse::success(response))
}

/// 获取批量提交记录
async fn get_batch_submissions(
    state: web::Data<Arc<ApiState>>,
    query: web::Query<BatchSubmissionQuery>,
) -> impl Responder {
    let limit = query.limit.unwrap_or(50).min(100);
    let offset = query.offset.unwrap_or(0);

    match state.storage.get_batch_submissions(query.submitter.as_deref(), limit, offset).await {
        Ok(submissions) => HttpResponse::Ok().json(ApiResponse::success(submissions)),
        Err(e) => HttpResponse::InternalServerError().json(ApiResponse::<()>::error(&e.to_string())),
    }
}

/// 获取活跃 Matcher 统计
/// GET /api/v1/stats/active-matchers?hours=24
async fn get_active_matchers(
    state: web::Data<Arc<ApiState>>,
    query: web::Query<ActiveMatchersQuery>,
) -> impl Responder {
    let hours = query.hours.unwrap_or(24).min(168); // 最多统计 7 天

    match state.storage.get_active_matchers_stats(hours).await {
        Ok((active_count, matchers, total_submissions)) => {
            // 计算所有 matcher 的总手续费
            let total_fees: u128 = matchers.iter()
                .filter_map(|m| m.total_fees.parse::<u128>().ok())
                .sum();

            let response = ActiveMatchersResponse {
                active_count,
                hours,
                total_submissions,
                total_fees: total_fees.to_string(),
                matchers,
            };
            HttpResponse::Ok().json(ApiResponse::success(response))
        }
        Err(e) => HttpResponse::InternalServerError().json(ApiResponse::<()>::error(&e.to_string())),
    }
}

/// 启动 API 服务器
pub async fn start_api_server(config: ApiConfig, storage: MongoStorage, global_state: Option<GlobalState>) -> std::io::Result<()> {
    let state = Arc::new(ApiState { storage, global_state });
    let bind_addr = format!("{}:{}", config.host, config.port);

    info!("🌐 Starting API server at http://{}", bind_addr);

    HttpServer::new(move || {
        let cors = Cors::default()
            .allow_any_origin()
            .allow_any_method()
            .allow_any_header()
            .max_age(3600);

        App::new()
            .wrap(cors)
            .app_data(web::Data::new(state.clone()))
            // 健康检查
            .route("/health", web::get().to(health))
            // 全局订单和交易
            .route("/api/v1/orders", web::get().to(get_orders))
            .route("/api/v1/orders/{order_id}", web::get().to(get_order))
            .route("/api/v1/trades", web::get().to(get_trades))
            // 用户订单相关
            .route("/api/v1/users/{trader}/orders", web::get().to(get_user_orders))
            .route("/api/v1/users/{trader}/orders/active", web::get().to(get_user_active_orders))
            // 交易对相关
            .route("/api/v1/trading-pairs", web::get().to(get_trading_pairs))
            .route("/api/v1/trading-pairs/{trading_pair}/overview", web::get().to(get_trading_pair_overview))
            // 订单簿
            .route("/api/v1/orderbook/{trading_pair}", web::get().to(get_orderbook))
            // K线数据
            .route("/api/v1/klines/{trading_pair}", web::get().to(get_klines))
            // 系统概述
            .route("/api/v1/overview", web::get().to(get_system_overview))
            // 批量提交记录
            .route("/api/v1/batch-submissions", web::get().to(get_batch_submissions))
            // 活跃 Matcher 统计
            .route("/api/v1/stats/active-matchers", web::get().to(get_active_matchers))
            // 调试接口
            .route("/api/v1/debug/orderbook", web::get().to(get_debug_orderbook))
    })
    .bind(&bind_addr)?
    .run()
    .await
}
