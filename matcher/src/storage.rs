use anyhow::Result;
use mongodb::{
    bson::{doc, DateTime as BsonDateTime},
    options::{ClientOptions, IndexOptions},
    Client, Collection, IndexModel,
};
use serde::{Deserialize, Serialize};
use tracing::info;

/// 自定义序列化模块：将 BsonDateTime 序列化为 ISO 8601 字符串
mod bson_datetime_as_iso8601 {
    use mongodb::bson::DateTime as BsonDateTime;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S>(date: &BsonDateTime, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        // 使用 try_to_rfc3339_string 转换为 ISO 8601 格式
        let iso_string = date
            .try_to_rfc3339_string()
            .map_err(serde::ser::Error::custom)?;
        serializer.serialize_str(&iso_string)
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<BsonDateTime, D::Error>
    where
        D: Deserializer<'de>,
    {
        // 尝试从 ISO 8601 字符串或 BSON DateTime 反序列化
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum DateTimeFormat {
            String(String),
            Bson(BsonDateTime),
        }

        match DateTimeFormat::deserialize(deserializer)? {
            DateTimeFormat::String(s) => {
                BsonDateTime::parse_rfc3339_str(&s).map_err(serde::de::Error::custom)
            }
            DateTimeFormat::Bson(dt) => Ok(dt),
        }
    }
}

/// 订单状态
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum OrderStatus {
    Pending,    // 在 Sequencer 队列中等待处理
    Active,     // 已插入 OrderBook，等待成交
    PartiallyFilled, // 部分成交
    Filled,     // 完全成交
    Cancelled,  // 已取消
}

/// 订单类型
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum StoredOrderType {
    Limit,
    Market,
}

/// 存储在 MongoDB 中的订单
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredOrder {
    /// 订单ID (来自 Sequencer)
    #[serde(rename = "_id")]
    pub order_id: String,

    /// 交易对 (hex string)
    pub trading_pair: String,

    /// 交易者地址
    pub trader: String,

    /// 订单类型
    pub order_type: StoredOrderType,

    /// 是否是卖单
    pub is_ask: bool,

    /// 价格 (string to preserve precision)
    pub price: String,

    /// 数量
    pub amount: String,

    /// 已成交数量
    pub filled_amount: String,

    /// 订单状态
    pub status: OrderStatus,

    /// 创建时间 (区块时间戳或事件时间)
    #[serde(with = "bson_datetime_as_iso8601")]
    pub created_at: BsonDateTime,

    /// 最后更新时间
    #[serde(with = "bson_datetime_as_iso8601")]
    pub updated_at: BsonDateTime,

    /// 创建时的区块高度
    pub block_number: u64,

    /// 创建时的交易哈希
    pub tx_hash: Option<String>,
}

/// 交易记录
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredTrade {
    /// 交易ID (自动生成)
    #[serde(rename = "_id")]
    pub trade_id: String,

    /// 交易对
    pub trading_pair: String,

    /// 买单ID
    pub buy_order_id: String,

    /// 卖单ID
    pub sell_order_id: String,

    /// 买方地址
    pub buyer: String,

    /// 卖方地址
    pub seller: String,

    /// 成交价格
    pub price: String,

    /// 成交数量
    pub amount: String,

    /// 成交时间
    #[serde(with = "bson_datetime_as_iso8601")]
    pub traded_at: BsonDateTime,

    /// 区块高度
    pub block_number: u64,

    /// 交易哈希
    pub tx_hash: Option<String>,
}

/// MongoDB 存储服务
#[derive(Clone)]
pub struct MongoStorage {
    client: Client,
    database: String,
}

impl MongoStorage {
    /// 创建新的 MongoDB 存储连接
    pub async fn new(uri: &str, database: &str) -> Result<Self> {
        let client_options = ClientOptions::parse(uri).await?;
        let client = Client::with_options(client_options)?;

        // 测试连接
        client
            .database("admin")
            .run_command(doc! { "ping": 1 }, None)
            .await?;

        let storage = Self {
            client,
            database: database.to_string(),
        };

        // 创建索引
        storage.create_indexes().await?;

        info!("📦 MongoDB connected: {}", uri);

        Ok(storage)
    }

    /// 创建必要的索引
    async fn create_indexes(&self) -> Result<()> {
        let orders = self.orders_collection();
        let trades = self.trades_collection();

        // 订单索引
        let order_indexes = vec![
            IndexModel::builder()
                .keys(doc! { "trader": 1, "status": 1 })
                .options(IndexOptions::builder().build())
                .build(),
            IndexModel::builder()
                .keys(doc! { "trading_pair": 1, "status": 1 })
                .options(IndexOptions::builder().build())
                .build(),
            IndexModel::builder()
                .keys(doc! { "trader": 1, "created_at": -1 })
                .options(IndexOptions::builder().build())
                .build(),
            IndexModel::builder()
                .keys(doc! { "trading_pair": 1, "is_ask": 1, "price": 1 })
                .options(IndexOptions::builder().build())
                .build(),
        ];

        orders.create_indexes(order_indexes, None).await?;

        // 交易索引
        let trade_indexes = vec![
            IndexModel::builder()
                .keys(doc! { "trading_pair": 1, "traded_at": -1 })
                .options(IndexOptions::builder().build())
                .build(),
            IndexModel::builder()
                .keys(doc! { "buyer": 1, "traded_at": -1 })
                .options(IndexOptions::builder().build())
                .build(),
            IndexModel::builder()
                .keys(doc! { "seller": 1, "traded_at": -1 })
                .options(IndexOptions::builder().build())
                .build(),
        ];

        trades.create_indexes(trade_indexes, None).await?;

        Ok(())
    }

    fn orders_collection(&self) -> Collection<StoredOrder> {
        self.client.database(&self.database).collection("orders")
    }

    fn trades_collection(&self) -> Collection<StoredTrade> {
        self.client.database(&self.database).collection("trades")
    }

    /// 保存或更新订单
    pub async fn upsert_order(&self, order: &StoredOrder) -> Result<()> {
        let collection = self.orders_collection();

        let filter = doc! { "_id": &order.order_id };
        let update = doc! {
            "$set": mongodb::bson::to_document(order)?
        };

        collection
            .update_one(filter, update, mongodb::options::UpdateOptions::builder().upsert(true).build())
            .await?;

        Ok(())
    }

    /// 更新订单状态
    pub async fn update_order_status(
        &self,
        order_id: &str,
        status: OrderStatus,
        filled_amount: Option<&str>,
    ) -> Result<()> {
        let collection = self.orders_collection();

        let filter = doc! { "_id": order_id };
        let mut update_doc = doc! {
            "status": mongodb::bson::to_bson(&status)?,
            "updated_at": mongodb::bson::DateTime::now(),
        };

        if let Some(filled) = filled_amount {
            update_doc.insert("filled_amount", filled);
        }

        collection
            .update_one(filter, doc! { "$set": update_doc }, None)
            .await?;

        Ok(())
    }

    /// 保存交易记录
    pub async fn insert_trade(&self, trade: &StoredTrade) -> Result<()> {
        let collection = self.trades_collection();
        collection.insert_one(trade, None).await?;
        Ok(())
    }

    /// 根据交易者地址查询订单
    pub async fn get_orders_by_trader(
        &self,
        trader: &str,
        status: Option<OrderStatus>,
        limit: i64,
        offset: u64,
    ) -> Result<Vec<StoredOrder>> {
        let collection = self.orders_collection();

        let mut filter = doc! { "trader": trader.to_lowercase() };
        if let Some(s) = status {
            filter.insert("status", mongodb::bson::to_bson(&s)?);
        }

        let options = mongodb::options::FindOptions::builder()
            .sort(doc! { "created_at": -1 })
            .skip(offset)
            .limit(limit)
            .build();

        let mut cursor = collection.find(filter, options).await?;
        let mut orders = Vec::new();

        while cursor.advance().await? {
            orders.push(cursor.deserialize_current()?);
        }

        Ok(orders)
    }

    /// 查询用户的活跃订单 (Active 或 PartiallyFilled)
    pub async fn get_active_orders_by_trader(&self, trader: &str) -> Result<Vec<StoredOrder>> {
        let collection = self.orders_collection();

        let filter = doc! {
            "trader": trader.to_lowercase(),
            "status": { "$in": ["active", "partiallyfilled"] }
        };

        let options = mongodb::options::FindOptions::builder()
            .sort(doc! { "created_at": -1 })
            .build();

        let mut cursor = collection.find(filter, options).await?;
        let mut orders = Vec::new();

        while cursor.advance().await? {
            orders.push(cursor.deserialize_current()?);
        }

        Ok(orders)
    }

    /// 根据订单ID查询订单
    pub async fn get_order_by_id(&self, order_id: &str) -> Result<Option<StoredOrder>> {
        let collection = self.orders_collection();
        let filter = doc! { "_id": order_id };
        Ok(collection.find_one(filter, None).await?)
    }

    /// 查询所有交易历史
    pub async fn get_trades(
        &self,
        limit: i64,
        offset: u64,
    ) -> Result<Vec<StoredTrade>> {
        let collection = self.trades_collection();

        let options = mongodb::options::FindOptions::builder()
            .sort(doc! { "traded_at": -1 })
            .skip(offset)
            .limit(limit)
            .build();

        let mut cursor = collection.find(doc! {}, options).await?;
        let mut trades = Vec::new();

        while cursor.advance().await? {
            trades.push(cursor.deserialize_current()?);
        }

        Ok(trades)
    }

    /// 查询所有订单（可选按状态筛选）
    pub async fn get_orders(
        &self,
        status: Option<OrderStatus>,
        limit: i64,
        offset: u64,
    ) -> Result<Vec<StoredOrder>> {
        let collection = self.orders_collection();

        let filter = match status {
            Some(s) => doc! { "status": mongodb::bson::to_bson(&s)? },
            None => doc! {},
        };

        let options = mongodb::options::FindOptions::builder()
            .sort(doc! { "created_at": -1 })
            .skip(offset)
            .limit(limit)
            .build();

        let mut cursor = collection.find(filter, options).await?;
        let mut orders = Vec::new();

        while cursor.advance().await? {
            orders.push(cursor.deserialize_current()?);
        }

        Ok(orders)
    }

    /// 根据交易对查询订单簿 (活跃的限价单)
    pub async fn get_orderbook(
        &self,
        trading_pair: &str,
        depth: i64,
    ) -> Result<(Vec<StoredOrder>, Vec<StoredOrder>)> {
        let collection = self.orders_collection();

        // 买单 (bids) - 按价格降序
        let bid_filter = doc! {
            "trading_pair": trading_pair,
            "is_ask": false,
            "status": { "$in": ["active", "partiallyfilled"] },
            "order_type": "limit"
        };
        let bid_options = mongodb::options::FindOptions::builder()
            .sort(doc! { "price": -1 })
            .limit(depth)
            .build();

        let mut bid_cursor = collection.find(bid_filter, bid_options).await?;
        let mut bids = Vec::new();
        while bid_cursor.advance().await? {
            bids.push(bid_cursor.deserialize_current()?);
        }

        // 卖单 (asks) - 按价格升序
        let ask_filter = doc! {
            "trading_pair": trading_pair,
            "is_ask": true,
            "status": { "$in": ["active", "partiallyfilled"] },
            "order_type": "limit"
        };
        let ask_options = mongodb::options::FindOptions::builder()
            .sort(doc! { "price": 1 })
            .limit(depth)
            .build();

        let mut ask_cursor = collection.find(ask_filter, ask_options).await?;
        let mut asks = Vec::new();
        while ask_cursor.advance().await? {
            asks.push(ask_cursor.deserialize_current()?);
        }

        Ok((bids, asks))
    }
}
