mod config;
mod contracts;
mod matcher;
mod orderbook_simulator;
mod state;
mod sync;
mod types;

use anyhow::Result;
use clap::Parser;
use tracing::{info, Level};

use crate::config::Config;
use crate::matcher::MatchingEngine;
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

    // 创建状态同步器（内部包含 GlobalState 和 OrderBookSimulator）
    let synchronizer = StateSynchronizer::new(config.clone()).await?;
    info!("🔮 State synchronizer created");

    // 获取共享状态
    let state = synchronizer.state();

    // 创建匹配引擎（从 GlobalState 获取订单簿状态）
    let matcher = MatchingEngine::new(config.clone(), state).await?;

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

    info!("👋 Matcher shutdown complete");
    Ok(())
}
