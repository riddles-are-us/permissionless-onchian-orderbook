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

    /// 创建时间 (事件处理时间，用于排序)
    #[serde(with = "bson_datetime_as_iso8601")]
    pub created_at: BsonDateTime,

    /// 最后更新时间
    #[serde(with = "bson_datetime_as_iso8601")]
    pub updated_at: BsonDateTime,

    /// 创建时的区块高度
    pub block_number: u64,

    /// 创建时的交易哈希
    pub tx_hash: Option<String>,

    /// 链上订单创建时间戳 (block.timestamp，秒)
    /// 用于计算 uncancellable_until
    #[serde(default)]
    pub chain_created_at: u64,

    /// 订单不可撤销时长（秒），0表示可立即撤销
    #[serde(default)]
    pub uncancellable_duration: u64,

    /// 订单不可撤销截止时间戳（秒）
    /// = chain_created_at + uncancellable_duration
    /// 如果为 0 或 None，表示可立即撤销
    #[serde(default)]
    pub uncancellable_until: Option<u64>,
}

/// K线时间周期
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "lowercase")]
pub enum KlineInterval {
    #[serde(rename = "1m")]
    OneMinute,
    #[serde(rename = "5m")]
    FiveMinutes,
    #[serde(rename = "15m")]
    FifteenMinutes,
    #[serde(rename = "1h")]
    OneHour,
    #[serde(rename = "1d")]
    OneDay,
    #[serde(rename = "1M")]
    OneMonth,
    #[serde(rename = "1y")]
    OneYear,
}

impl KlineInterval {
    /// 返回该周期的秒数
    pub fn seconds(&self) -> i64 {
        match self {
            KlineInterval::OneMinute => 60,
            KlineInterval::FiveMinutes => 5 * 60,
            KlineInterval::FifteenMinutes => 15 * 60,
            KlineInterval::OneHour => 60 * 60,
            KlineInterval::OneDay => 24 * 60 * 60,
            KlineInterval::OneMonth => 30 * 24 * 60 * 60,  // 近似值
            KlineInterval::OneYear => 365 * 24 * 60 * 60,  // 近似值
        }
    }

    /// 返回该周期的毫秒数
    pub fn millis(&self) -> i64 {
        self.seconds() * 1000
    }

    /// 返回所有周期
    pub fn all() -> Vec<KlineInterval> {
        vec![
            KlineInterval::OneMinute,
            KlineInterval::FiveMinutes,
            KlineInterval::FifteenMinutes,
            KlineInterval::OneHour,
            KlineInterval::OneDay,
            KlineInterval::OneMonth,
            KlineInterval::OneYear,
        ]
    }

    /// 将时间戳对齐到该周期的开始时间
    pub fn align_timestamp(&self, timestamp_ms: i64) -> i64 {
        let interval_ms = self.millis();
        (timestamp_ms / interval_ms) * interval_ms
    }

    /// 返回周期名称 (用于MongoDB集合名)
    pub fn name(&self) -> &'static str {
        match self {
            KlineInterval::OneMinute => "1m",
            KlineInterval::FiveMinutes => "5m",
            KlineInterval::FifteenMinutes => "15m",
            KlineInterval::OneHour => "1h",
            KlineInterval::OneDay => "1d",
            KlineInterval::OneMonth => "1M",
            KlineInterval::OneYear => "1y",
        }
    }
}

impl std::fmt::Display for KlineInterval {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.name())
    }
}

impl std::str::FromStr for KlineInterval {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "1m" => Ok(KlineInterval::OneMinute),
            "5m" => Ok(KlineInterval::FiveMinutes),
            "15m" => Ok(KlineInterval::FifteenMinutes),
            "1h" => Ok(KlineInterval::OneHour),
            "1d" => Ok(KlineInterval::OneDay),
            "1M" => Ok(KlineInterval::OneMonth),
            "1y" => Ok(KlineInterval::OneYear),
            _ => Err(format!("Invalid interval: {}", s)),
        }
    }
}

/// K线数据 (OHLCV 蜡烛图)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredKline {
    /// 唯一ID: trading_pair-interval-open_time
    #[serde(rename = "_id")]
    pub kline_id: String,

    /// 交易对
    pub trading_pair: String,

    /// 时间周期
    pub interval: String,

    /// 开盘时间 (该周期的起始时间戳，毫秒)
    pub open_time: i64,

    /// 收盘时间 (该周期的结束时间戳，毫秒)
    pub close_time: i64,

    /// 开盘价
    pub open: String,

    /// 最高价
    pub high: String,

    /// 最低价
    pub low: String,

    /// 收盘价 (最新价)
    pub close: String,

    /// 成交量 (base token)
    pub volume: String,

    /// 成交额 (quote token = price * volume)
    pub quote_volume: String,

    /// 成交笔数
    pub trade_count: u64,
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

/// Batch提交记录
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BatchSubmission {
    /// Batch ID (matchId)
    #[serde(rename = "_id")]
    pub match_id: String,

    /// 提交者地址
    pub submitter: String,

    /// 处理的请求数量
    pub processed_count: u64,

    /// 提交者获得的奖励 (80%的交易费用)
    pub submitter_reward: String,

    /// 提交时间
    #[serde(with = "bson_datetime_as_iso8601")]
    pub submitted_at: BsonDateTime,

    /// 区块高度
    pub block_number: u64,

    /// 交易哈希
    pub tx_hash: String,
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

        // K线索引
        let klines = self.klines_collection();
        let kline_indexes = vec![
            IndexModel::builder()
                .keys(doc! { "trading_pair": 1, "interval": 1, "open_time": -1 })
                .options(IndexOptions::builder().build())
                .build(),
        ];

        klines.create_indexes(kline_indexes, None).await?;

        Ok(())
    }

    fn orders_collection(&self) -> Collection<StoredOrder> {
        self.client.database(&self.database).collection("orders")
    }

    fn trades_collection(&self) -> Collection<StoredTrade> {
        self.client.database(&self.database).collection("trades")
    }

    fn batch_submissions_collection(&self) -> Collection<BatchSubmission> {
        self.client.database(&self.database).collection("batch_submissions")
    }

    fn klines_collection(&self) -> Collection<StoredKline> {
        self.client.database(&self.database).collection("klines")
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

    /// 保存交易记录（使用 upsert 避免重复）
    pub async fn insert_trade(&self, trade: &StoredTrade) -> Result<()> {
        let collection = self.trades_collection();

        let filter = doc! { "_id": &trade.trade_id };
        let update = doc! {
            "$set": mongodb::bson::to_document(trade)?
        };

        collection
            .update_one(filter, update, mongodb::options::UpdateOptions::builder().upsert(true).build())
            .await?;

        Ok(())
    }

    /// 保存batch提交记录（使用 upsert 避免重复）
    pub async fn insert_batch_submission(&self, submission: &BatchSubmission) -> Result<()> {
        let collection = self.batch_submissions_collection();

        let filter = doc! { "_id": &submission.match_id };
        let update = doc! {
            "$set": mongodb::bson::to_document(submission)?
        };

        collection
            .update_one(filter, update, mongodb::options::UpdateOptions::builder().upsert(true).build())
            .await?;

        Ok(())
    }

    /// 查询batch提交记录
    pub async fn get_batch_submissions(
        &self,
        submitter: Option<&str>,
        limit: i64,
        offset: u64,
    ) -> Result<Vec<BatchSubmission>> {
        let collection = self.batch_submissions_collection();

        let filter = match submitter {
            Some(s) => doc! { "submitter": s.to_lowercase() },
            None => doc! {},
        };

        let options = mongodb::options::FindOptions::builder()
            .sort(doc! { "submitted_at": -1 })
            .skip(offset)
            .limit(limit)
            .build();

        let mut cursor = collection.find(filter, options).await?;
        let mut submissions = Vec::new();

        while cursor.advance().await? {
            submissions.push(cursor.deserialize_current()?);
        }

        Ok(submissions)
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

    /// 更新K线数据 (根据交易更新所有时间周期的K线)
    ///
    /// 当收到一笔交易时，调用此方法更新所有时间周期的K线
    /// 使用 U256 进行所有数值计算以保持精度
    pub async fn update_klines(
        &self,
        trading_pair: &str,
        price: ethers::types::U256,
        amount: ethers::types::U256,
        timestamp_ms: i64,
    ) -> Result<()> {
        let collection = self.klines_collection();

        // 计算 quote_volume = price * amount (使用 U256 防止溢出)
        let quote_volume = price.saturating_mul(amount);

        // 对每个时间周期更新K线
        for interval in KlineInterval::all() {
            let open_time = interval.align_timestamp(timestamp_ms);
            let close_time = open_time + interval.millis() - 1;
            let kline_id = format!("{}-{}-{}", trading_pair, interval.name(), open_time);

            // 尝试更新现有K线，如果不存在则创建新的
            let filter = doc! { "_id": &kline_id };

            // 使用 findOneAndUpdate 或 upsert
            let existing = collection.find_one(filter.clone(), None).await?;

            if let Some(kline) = existing {
                // 更新现有K线 - 使用 U256 进行比较和计算
                let current_high = ethers::types::U256::from_dec_str(&kline.high).unwrap_or_default();
                let current_low = ethers::types::U256::from_dec_str(&kline.low).unwrap_or(ethers::types::U256::MAX);
                let current_volume = ethers::types::U256::from_dec_str(&kline.volume).unwrap_or_default();
                let current_quote_volume = ethers::types::U256::from_dec_str(&kline.quote_volume).unwrap_or_default();

                let new_high = if price > current_high { price } else { current_high };
                let new_low = if price < current_low { price } else { current_low };
                let new_volume = current_volume.saturating_add(amount);
                let new_quote_volume = current_quote_volume.saturating_add(quote_volume);

                let update = doc! {
                    "$set": {
                        "high": new_high.to_string(),
                        "low": new_low.to_string(),
                        "close": price.to_string(),
                        "volume": new_volume.to_string(),
                        "quote_volume": new_quote_volume.to_string(),
                    },
                    "$inc": {
                        "trade_count": 1_i64
                    }
                };

                collection.update_one(filter, update, None).await?;
            } else {
                // 创建新K线
                let new_kline = StoredKline {
                    kline_id: kline_id.clone(),
                    trading_pair: trading_pair.to_string(),
                    interval: interval.name().to_string(),
                    open_time,
                    close_time,
                    open: price.to_string(),
                    high: price.to_string(),
                    low: price.to_string(),
                    close: price.to_string(),
                    volume: amount.to_string(),
                    quote_volume: quote_volume.to_string(),
                    trade_count: 1,
                };

                collection.insert_one(&new_kline, None).await?;
            }
        }

        Ok(())
    }

    /// 查询K线数据
    pub async fn get_klines(
        &self,
        trading_pair: &str,
        interval: &str,
        start_time: Option<i64>,
        end_time: Option<i64>,
        limit: i64,
    ) -> Result<Vec<StoredKline>> {
        let collection = self.klines_collection();

        let mut filter = doc! {
            "trading_pair": trading_pair,
            "interval": interval
        };

        // 添加时间范围过滤
        if start_time.is_some() || end_time.is_some() {
            let mut time_filter = doc! {};
            if let Some(start) = start_time {
                time_filter.insert("$gte", start);
            }
            if let Some(end) = end_time {
                time_filter.insert("$lte", end);
            }
            filter.insert("open_time", time_filter);
        }

        let options = mongodb::options::FindOptions::builder()
            .sort(doc! { "open_time": -1 })
            .limit(limit)
            .build();

        let mut cursor = collection.find(filter, options).await?;
        let mut klines = Vec::new();

        while cursor.advance().await? {
            klines.push(cursor.deserialize_current()?);
        }

        // 反转结果，使其按时间正序排列
        klines.reverse();

        Ok(klines)
    }

    /// 获取最新的K线数据 (用于实时显示)
    pub async fn get_latest_kline(
        &self,
        trading_pair: &str,
        interval: &str,
    ) -> Result<Option<StoredKline>> {
        let collection = self.klines_collection();

        let filter = doc! {
            "trading_pair": trading_pair,
            "interval": interval
        };

        let options = mongodb::options::FindOneOptions::builder()
            .sort(doc! { "open_time": -1 })
            .build();

        Ok(collection.find_one(filter, options).await?)
    }

    /// 统计指定时间范围内活跃的 matcher 数量
    ///
    /// 返回：(活跃 matcher 数量, 各 matcher 的统计信息, 总提交次数)
    pub async fn get_active_matchers_stats(
        &self,
        hours: u64,
    ) -> Result<(u64, Vec<MatcherStats>, u64)> {
        use futures::stream::TryStreamExt;

        let collection = self.batch_submissions_collection();

        // 计算时间范围
        let now = chrono::Utc::now();
        let since = now - chrono::Duration::hours(hours as i64);
        let since_bson = BsonDateTime::from_millis(since.timestamp_millis());

        // 使用 aggregation pipeline 统计
        let pipeline = vec![
            // 1. 筛选时间范围内的记录
            doc! {
                "$match": {
                    "submitted_at": { "$gte": since_bson }
                }
            },
            // 2. 按 submitter 分组，统计每个 matcher 的提交次数和总奖励
            doc! {
                "$group": {
                    "_id": "$submitter",
                    "submission_count": { "$sum": 1 },
                    "total_processed": { "$sum": "$processed_count" },
                    "last_submission": { "$max": "$submitted_at" }
                }
            },
            // 3. 按提交次数降序排列
            doc! {
                "$sort": { "submission_count": -1 }
            }
        ];

        let mut cursor = collection.aggregate(pipeline, None).await?;
        let mut matcher_stats: Vec<MatcherStats> = Vec::new();
        let mut total_submissions: u64 = 0;

        while let Some(doc) = cursor.try_next().await? {
            let submitter = doc.get_str("_id").unwrap_or_default().to_string();
            let submission_count = doc.get_i32("submission_count").unwrap_or(0) as u64;
            let total_processed = doc.get_i64("total_processed").unwrap_or(0) as u64;
            let last_submission = doc.get_datetime("last_submission")
                .map(|dt| dt.try_to_rfc3339_string().unwrap_or_default())
                .unwrap_or_default();

            total_submissions += submission_count;

            matcher_stats.push(MatcherStats {
                submitter,
                submission_count,
                total_processed,
                last_submission,
            });
        }

        let active_count = matcher_stats.len() as u64;

        Ok((active_count, matcher_stats, total_submissions))
    }
}

/// Matcher 统计信息
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MatcherStats {
    /// Matcher 地址
    pub submitter: String,
    /// 提交次数
    pub submission_count: u64,
    /// 处理的请求总数
    pub total_processed: u64,
    /// 最后提交时间
    pub last_submission: String,
}
