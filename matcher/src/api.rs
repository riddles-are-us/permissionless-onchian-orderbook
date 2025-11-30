use crate::config::ApiConfig;
use crate::storage::{MongoStorage, OrderStatus, StoredOrder};
use actix_cors::Cors;
use actix_web::{web, App, HttpResponse, HttpServer, Responder};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tracing::info;

/// API 状态
pub struct ApiState {
    pub storage: MongoStorage,
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

/// 获取用户的交易历史
async fn get_user_trades(
    state: web::Data<Arc<ApiState>>,
    path: web::Path<String>,
    query: web::Query<TradeQuery>,
) -> impl Responder {
    let trader = path.into_inner();
    let limit = query.limit.unwrap_or(50).min(100);
    let offset = query.offset.unwrap_or(0);

    match state.storage.get_trades_by_trader(&trader, limit, offset).await {
        Ok(trades) => HttpResponse::Ok().json(ApiResponse::success(trades)),
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

/// 启动 API 服务器
pub async fn start_api_server(config: ApiConfig, storage: MongoStorage) -> std::io::Result<()> {
    let state = Arc::new(ApiState { storage });
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
            // 用户订单相关
            .route("/api/v1/users/{trader}/orders", web::get().to(get_user_orders))
            .route("/api/v1/users/{trader}/orders/active", web::get().to(get_user_active_orders))
            .route("/api/v1/users/{trader}/trades", web::get().to(get_user_trades))
            // 订单详情
            .route("/api/v1/orders/{order_id}", web::get().to(get_order))
            // 订单簿
            .route("/api/v1/orderbook/{trading_pair}", web::get().to(get_orderbook))
    })
    .bind(&bind_addr)?
    .run()
    .await
}
