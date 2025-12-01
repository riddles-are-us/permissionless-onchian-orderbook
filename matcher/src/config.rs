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
    #[serde(default)]
    pub trading_pair: String,
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

        // 从 deployments.json 读取 trading_pair (如果未配置)
        if config.contracts.trading_pair.is_empty() {
            if let Ok(deploy_content) = fs::read_to_string("../deployments.json") {
                if let Ok(json) = serde_json::from_str::<serde_json::Value>(&deploy_content) {
                    if let Some(pair_id) = json.get("pairId").and_then(|v| v.as_str()) {
                        config.contracts.trading_pair = pair_id.to_string();
                    }
                }
            }
        }

        Ok(config)
    }
}
