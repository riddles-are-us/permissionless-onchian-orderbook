use crate::config::ApiConfig;
use crate::state::GlobalState;
use crate::storage::{MongoStorage, OrderStatus, StoredOrder};
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
}

#[derive(Deserialize)]
pub struct TradeQuery {
    pub limit: Option<i64>,
    pub offset: Option<u64>,
}

#[derive(Deserialize)]
pub struct OrderbookQuery {
    pub depth: Option<i64>,
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

    let status = query.status.as_ref().and_then(|s| match s.to_lowercase().as_str() {
        "pending" => Some(OrderStatus::Pending),
        "active" => Some(OrderStatus::Active),
        "partiallyfilled" => Some(OrderStatus::PartiallyFilled),
        "filled" => Some(OrderStatus::Filled),
        "cancelled" => Some(OrderStatus::Cancelled),
        _ => None,
    });

    match state.storage.get_orders_by_trader(&trader, status, limit, offset).await {
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

    match state.storage.get_trades(limit, offset).await {
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

    // 获取订单簿数据
    let orderbook = global_state.orderbook.read();

    // 获取 asks（最多10个价格层级）
    let mut asks = Vec::new();
    let mut current_price = orderbook.ask_head;
    let mut count = 0;
    while !current_price.is_zero() && count < 10 {
        let key = if true { current_price } else { current_price | (U256::one() << 255) };
        if let Some(level) = orderbook.price_levels.get(&key) {
            // 统计该价格层级的订单数量
            let mut order_count = 0;
            let mut order_id = level.head_order_id;
            while !order_id.is_zero() {
                order_count += 1;
                if let Some(order) = orderbook.orders.get(&order_id) {
                    order_id = order.next_order_id;
                } else {
                    break;
                }
            }
            asks.push(OverviewPriceLevel {
                price: level.price.to_string(),
                total_volume: level.total_volume.to_string(),
                order_count,
            });
            current_price = level.next_price;
        } else {
            break;
        }
        count += 1;
    }

    // 获取 bids（最多10个价格层级）
    let mut bids = Vec::new();
    let mut current_price = orderbook.bid_head;
    let mut count = 0;
    while !current_price.is_zero() && count < 10 {
        let key = current_price | (U256::one() << 255);
        if let Some(level) = orderbook.price_levels.get(&key) {
            let mut order_count = 0;
            let mut order_id = level.head_order_id;
            while !order_id.is_zero() {
                order_count += 1;
                if let Some(order) = orderbook.orders.get(&order_id) {
                    order_id = order.next_order_id;
                } else {
                    break;
                }
            }
            bids.push(OverviewPriceLevel {
                price: level.price.to_string(),
                total_volume: level.total_volume.to_string(),
                order_count,
            });
            current_price = level.next_price;
        } else {
            break;
        }
        count += 1;
    }

    // 统计市价单
    let mut total_buy_amount = U256::zero();
    let mut buy_order_count = 0;
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

    let mut total_sell_amount = U256::zero();
    let mut sell_order_count = 0;
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
            // 订单簿
            .route("/api/v1/orderbook/{trading_pair}", web::get().to(get_orderbook))
            // 系统概述
            .route("/api/v1/overview", web::get().to(get_system_overview))
    })
    .bind(&bind_addr)?
    .run()
    .await
}
