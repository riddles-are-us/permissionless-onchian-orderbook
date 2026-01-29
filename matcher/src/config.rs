use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::fs;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub network: NetworkConfig,
    pub contracts: ContractsConfig,
    pub sync: SyncConfig,
    pub matching: MatchingConfig,
    pub executor: ExecutorConfig,
    #[serde(default)]
    pub mongodb: MongoDbConfig,
    #[serde(default)]
    pub api: ApiConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NetworkConfig {
    pub rpc_url: String,
    pub chain_id: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ContractsConfig {
    pub sequencer: String,
    pub orderbook: String,
    pub account: String,
    /// 支持的交易对列表（可以是单个字符串或数组）
    /// 单个: trading_pair = "0x..."
    /// 多个: trading_pairs = ["0x...", "0x..."]
    #[serde(default)]
    pub trading_pair: String,
    #[serde(default)]
    pub trading_pairs: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncConfig {
    pub start_block: u64,
    pub sync_historical: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MatchingConfig {
    pub max_batch_size: usize,
    pub matching_interval_ms: u64,
    #[serde(default = "default_max_iterations")]
    pub max_iterations: u64,
}

fn default_max_iterations() -> u64 {
    50
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExecutorConfig {
    pub private_key: String,
    pub gas_price_gwei: u64,
    pub gas_limit: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct MongoDbConfig {
    #[serde(default = "default_mongodb_uri")]
    pub uri: String,
    #[serde(default = "default_mongodb_database")]
    pub database: String,
    #[serde(default)]
    pub enabled: bool,
}

fn default_mongodb_uri() -> String {
    "mongodb://localhost:27017".to_string()
}

fn default_mongodb_database() -> String {
    "orderbook".to_string()
}


#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct ApiConfig {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default = "default_api_host")]
    pub host: String,
    #[serde(default = "default_api_port")]
    pub port: u16,
}

fn default_api_host() -> String {
    "127.0.0.1".to_string()
}

fn default_api_port() -> u16 {
    8080
}

impl Config {
    pub fn from_file(path: &str) -> Result<Self> {
        let content = fs::read_to_string(path)?;
        let mut config: Config = toml::from_str(&content)?;

        // 合并 trading_pair 和 trading_pairs 配置
        // 优先使用 trading_pairs 数组，如果为空则使用 trading_pair 单个值
        if config.contracts.trading_pairs.is_empty() {
            if !config.contracts.trading_pair.is_empty() {
                // 将单个 trading_pair 转换为数组
                config.contracts.trading_pairs = vec![config.contracts.trading_pair.clone()];
            } else {
                // 从 deployments.json 读取所有交易对
                if let Ok(deploy_content) = fs::read_to_string("../deployments.json") {
                    if let Ok(json) = serde_json::from_str::<serde_json::Value>(&deploy_content) {
                        let mut pairs = Vec::new();
                        // 读取 pairId (ETH/USDC)
                        if let Some(pair_id) = json.get("pairId").and_then(|v| v.as_str()) {
                            pairs.push(pair_id.to_string());
                        }
                        // 读取 wbtcPairId (BTC/USDC)
                        if let Some(pair_id) = json.get("wbtcPairId").and_then(|v| v.as_str()) {
                            pairs.push(pair_id.to_string());
                        }
                        config.contracts.trading_pairs = pairs;
                    }
                }
            }
        }

        // 为了向后兼容，也设置 trading_pair 为第一个交易对
        if !config.contracts.trading_pairs.is_empty() && config.contracts.trading_pair.is_empty() {
            config.contracts.trading_pair = config.contracts.trading_pairs[0].clone();
        }

        Ok(config)
    }

    /// 获取所有配置的交易对（解析为 [u8; 32] 格式）
    pub fn get_trading_pairs(&self) -> Vec<[u8; 32]> {
        self.contracts.trading_pairs.iter()
            .filter_map(|pair_str| {
                if pair_str.starts_with("0x") {
                    if let Ok(bytes) = hex::decode(&pair_str[2..]) {
                        if bytes.len() == 32 {
                            let mut arr = [0u8; 32];
                            arr.copy_from_slice(&bytes);
                            return Some(arr);
                        }
                    }
                }
                None
            })
            .collect()
    }
}
