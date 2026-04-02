use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::{env, fs};

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
                        // 自动读取所有以 "PairId" 或 "pairId" 结尾的字段
                        if let Some(obj) = json.as_object() {
                            for (key, value) in obj {
                                if (key.ends_with("PairId") || key.ends_with("pairId")) && key != "deployer" {
                                    if let Some(pair_id) = value.as_str() {
                                        pairs.push(pair_id.to_string());
                                    }
                                }
                            }
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

        if let Ok(private_key) = env::var("PRIVATE_KEY") {
            if !private_key.trim().is_empty() {
                config.executor.private_key = private_key;
            }
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

#[cfg(test)]
mod tests {
    use super::Config;
    use std::fs;
    use std::path::PathBuf;
    use std::sync::{Mutex, OnceLock};
    use std::time::{SystemTime, UNIX_EPOCH};

    fn env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    fn write_temp_config(content: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!("matcher-config-test-{nanos}.toml"));
        fs::write(&path, content).unwrap();
        path
    }

    #[test]
    fn from_file_prefers_private_key_from_environment() {
        let _guard = env_lock().lock().unwrap();
        let path = write_temp_config(
            r#"[network]
rpc_url = "ws://127.0.0.1:8545"
chain_id = 31337

[contracts]
sequencer = "0x1111111111111111111111111111111111111111"
orderbook = "0x2222222222222222222222222222222222222222"
account = "0x3333333333333333333333333333333333333333"
trading_pair = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

[sync]
start_block = 0
sync_historical = true

[matching]
max_batch_size = 100
matching_interval_ms = 1000

[executor]
private_key = "from-file"
gas_price_gwei = 1
gas_limit = 15000000
"#,
        );

        let original = std::env::var("PRIVATE_KEY").ok();
        std::env::set_var("PRIVATE_KEY", "from-env");

        let config = Config::from_file(path.to_str().unwrap()).unwrap();

        if let Some(value) = original {
            std::env::set_var("PRIVATE_KEY", value);
        } else {
            std::env::remove_var("PRIVATE_KEY");
        }
        fs::remove_file(path).unwrap();

        assert_eq!(config.executor.private_key, "from-env");
    }
}
