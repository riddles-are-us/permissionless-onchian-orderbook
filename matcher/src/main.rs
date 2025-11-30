mod api;
mod config;
mod contracts;
mod matcher;
mod orderbook_simulator;
mod state;
mod storage;
mod sync;
mod types;

use anyhow::Result;
use clap::Parser;
use tracing::{info, Level};

use crate::api::start_api_server;
use crate::config::Config;
use crate::matcher::MatchingEngine;
use crate::storage::MongoStorage;
use crate::sync::StateSynchronizer;

#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
struct Args {
    /// 配置文件路径
    #[arg(short, long, default_value = "config.toml")]
    config: String,

    /// 日志级别
    #[arg(short, long, default_value = "info")]
    log_level: String,

    /// 起始区块号（覆盖配置文件）
    #[arg(short, long)]
    start_block: Option<u64>,

    /// 禁用 RPC/API 服务器（用于纯撮合节点）
    #[arg(long)]
    disable_rpc: bool,
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();

    // 初始化日志
    let level = match args.log_level.as_str() {
        "trace" => Level::TRACE,
        "debug" => Level::DEBUG,
        "info" => Level::INFO,
        "warn" => Level::WARN,
        "error" => Level::ERROR,
        _ => Level::INFO,
    };

    tracing_subscriber::fmt()
        .with_max_level(level)
        .with_target(false)
        .init();

    info!("🚀 Starting OrderBook Matcher");

    // 加载配置
    let mut config = Config::from_file(&args.config)?;
    if let Some(start_block) = args.start_block {
        config.sync.start_block = start_block;
    }

    info!("📋 Configuration loaded:");
    info!("  RPC: {}", config.network.rpc_url);
    info!("  Sequencer: {}", config.contracts.sequencer);
    info!("  OrderBook: {}", config.contracts.orderbook);
    info!("  Start Block: {}", config.sync.start_block);

    // 初始化 MongoDB（如果启用）
    let storage = if config.mongodb.enabled {
        info!("📦 Connecting to MongoDB...");
        match MongoStorage::new(&config.mongodb.uri, &config.mongodb.database).await {
            Ok(s) => {
                info!("  Database: {}", config.mongodb.database);
                Some(s)
            }
            Err(e) => {
                tracing::warn!("Failed to connect to MongoDB: {}. Running without storage.", e);
                None
            }
        }
    } else {
        info!("📦 MongoDB disabled");
        None
    };

    // 创建状态同步器（内部包含 GlobalState 和 OrderBookSimulator）
    let synchronizer = StateSynchronizer::new(config.clone(), storage.clone()).await?;
    info!("🔮 State synchronizer created");

    // 获取共享状态
    let state = synchronizer.state();

    // 创建匹配引擎（从 GlobalState 获取订单簿状态）
    let matcher = MatchingEngine::new(config.clone(), state).await?;

    // 启动 API 服务器（如果启用且未禁用 RPC）
    let api_handle = if args.disable_rpc {
        info!("🌐 RPC/API server disabled (--disable-rpc)");
        None
    } else if config.api.enabled {
        if let Some(ref storage) = storage {
            let api_config = config.api.clone();
            let api_storage = storage.clone();
            Some(std::thread::spawn(move || {
                let rt = tokio::runtime::Runtime::new().unwrap();
                rt.block_on(async {
                    if let Err(e) = start_api_server(api_config, api_storage).await {
                        tracing::error!("API server error: {}", e);
                    }
                });
            }))
        } else {
            tracing::warn!("API enabled but MongoDB is not available. API server will not start.");
            None
        }
    } else {
        info!("🌐 API server disabled");
        None
    };

    // 启动同步器（在后台运行）
    let sync_handle = tokio::spawn(async move {
        if let Err(e) = synchronizer.run().await {
            tracing::error!("Synchronizer error: {}", e);
        }
    });

    // 启动匹配引擎（在后台运行）
    let match_handle = tokio::spawn(async move {
        if let Err(e) = matcher.run().await {
            tracing::error!("Matcher error: {}", e);
        }
    });

    // 等待所有任务
    tokio::select! {
        _ = sync_handle => {
            info!("Synchronizer stopped");
        }
        _ = match_handle => {
            info!("Matcher stopped");
        }
        _ = tokio::signal::ctrl_c() => {
            info!("Received shutdown signal");
        }
    }

    // 等待 API 服务器线程结束（如果存在）
    if let Some(handle) = api_handle {
        let _ = handle.join();
    }

    info!("👋 Matcher shutdown complete");
    Ok(())
}
