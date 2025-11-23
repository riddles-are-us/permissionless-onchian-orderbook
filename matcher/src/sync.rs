use crate::config::Config;
use crate::contracts::{OrderBook, Sequencer};
use crate::state::GlobalState;
use crate::types::*;
use anyhow::{Context, Result};
use ethers::prelude::*;
use std::sync::Arc;
use tracing::{debug, info, warn};

pub struct StateSynchronizer {
    config: Config,
    state: GlobalState,
    provider: Arc<Provider<Ws>>,
    sequencer: Sequencer<Provider<Ws>>,
    orderbook: OrderBook<Provider<Ws>>,
}

impl StateSynchronizer {
    pub async fn new(config: Config) -> Result<Self> {
        // 连接到节点
        let ws = Ws::connect(&config.network.rpc_url)
            .await
            .context("Failed to connect to WebSocket")?;
        let provider = Arc::new(Provider::new(ws));

        // 创建合约实例
        let sequencer_addr: Address = config.contracts.sequencer.parse()?;
        let orderbook_addr: Address = config.contracts.orderbook.parse()?;

        let sequencer = Sequencer::new(sequencer_addr, provider.clone());
        let orderbook = OrderBook::new(orderbook_addr, provider.clone());

        Ok(Self {
            config,
            state: GlobalState::new(),
            provider,
            sequencer,
            orderbook,
        })
    }

    pub fn state(&self) -> GlobalState {
        self.state.clone()
    }

    /// 运行同步器
    pub async fn run(mut self) -> Result<()> {
        info!("🔄 Starting state synchronizer");

        // 第一步：同步历史状态
        if self.config.sync.sync_historical {
            self.sync_historical_state().await?;
        }

        // 第二步：监听事件
        self.watch_events().await?;

        Ok(())
    }

    /// 同步历史状态
    async fn sync_historical_state(&mut self) -> Result<()> {
        let start_block = if self.config.sync.start_block == 0 {
            self.provider.get_block_number().await?.as_u64()
        } else {
            self.config.sync.start_block
        };

        info!("📚 Syncing historical state from block {}", start_block);

        // 同步 Sequencer 状态
        self.sync_sequencer_state(start_block).await?;

        // 同步 OrderBook 状态
        self.sync_orderbook_state(start_block).await?;

        self.state.update_current_block(start_block);
        info!("✅ Historical state synced to block {}", start_block);

        Ok(())
    }

    /// 同步 Sequencer 状态
    async fn sync_sequencer_state(&self, _from_block: u64) -> Result<()> {
        debug!("Syncing Sequencer state...");

        // 获取当前队列头部
        let head_request_id = self.sequencer.queue_head().call().await?;
        self.state.update_queue_head(head_request_id);
        debug!("  Queue head: {}", head_request_id);

        // 如果队列为空，直接返回
        if head_request_id.is_zero() {
            debug!("  Queue is empty");
            return Ok(());
        }

        // 从头部开始遍历整个队列
        let mut current_id = head_request_id;
        let mut count = 0;

        while !current_id.is_zero() {
            // 调用合约获取请求信息（使用 queuedRequests mapping 获取完整数据）
            let request_data = self.sequencer.queued_requests(current_id).call().await?;

            // request_data 是一个 tuple，包含所有字段
            // (requestId, requestType, tradingPair, trader, orderType, isAsk, price, amount, orderIdToRemove, timestamp, nextRequestId, prevRequestId)
            let next_id = request_data.10; // nextRequestId 是第 11 个字段 (index 10)

            let request = QueuedRequest {
                request_id: request_data.0,
                request_type: match request_data.1 {
                    0 => RequestType::PlaceOrder,
                    1 => RequestType::RemoveOrder,
                    _ => {
                        warn!("Unknown request type: {}", request_data.1);
                        break;
                    }
                },
                trading_pair: request_data.2,
                trader: request_data.3,
                order_type: match request_data.4 {
                    0 => OrderType::Limit,
                    1 => OrderType::Market,
                    _ => OrderType::Limit,
                },
                is_ask: request_data.5,
                price: request_data.6,
                amount: request_data.7,
                order_id_to_remove: request_data.8,
                next_request_id: next_id,
            };

            self.state.add_request(request);
            count += 1;

            current_id = next_id;
        }

        debug!("  Loaded {} requests from queue", count);
        Ok(())
    }

    /// 同步 OrderBook 状态
    async fn sync_orderbook_state(&self, _from_block: u64) -> Result<()> {
        debug!("Syncing OrderBook state...");
        // 这里可以同步价格层级、订单等状态
        // 由于状态可能很大，建议按需同步或通过事件重建
        Ok(())
    }

    /// 监听事件
    async fn watch_events(&self) -> Result<()> {
        info!("👀 Watching for contract events");

        // TODO: 实现事件监听
        // 当 abigen 成功生成合约绑定后，可以使用以下代码：
        //
        // let seq_event_filter = self.sequencer.events();
        // let mut seq_stream = seq_event_filter.stream().await?;
        //
        // let ob_event_filter = self.orderbook.events();
        // let mut ob_stream = ob_event_filter.stream().await?;
        //
        // loop {
        //     tokio::select! {
        //         Some(Ok(event)) = seq_stream.next() => {
        //             self.handle_sequencer_event(event).await?;
        //         }
        //         Some(Ok(event)) = ob_stream.next() => {
        //             self.handle_orderbook_event(event).await?;
        //         }
        //         else => {
        //             warn!("Event stream ended");
        //             break;
        //         }
        //     }
        // }

        // 临时实现：简单等待
        warn!("Event watching not yet implemented");
        tokio::time::sleep(tokio::time::Duration::from_secs(3600)).await;

        Ok(())
    }

    /// 处理 Sequencer 事件
    async fn handle_sequencer_event(&self, event: Log) -> Result<()> {
        // TODO: 解析事件并更新状态
        // 需要根据生成的 ABI 绑定来处理不同的事件类型
        debug!("Sequencer event: {:?}", event.topics);
        Ok(())
    }

    /// 处理 OrderBook 事件
    async fn handle_orderbook_event(&self, event: Log) -> Result<()> {
        // TODO: 解析事件并更新状态
        // 需要根据生成的 ABI 绑定来处理不同的事件类型
        debug!("OrderBook event: {:?}", event.topics);
        Ok(())
    }
}
