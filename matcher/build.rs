use std::fs;
use std::path::Path;

fn main() {
    println!("cargo:rerun-if-changed=../deployments.json");
    println!("cargo:rerun-if-changed=config.toml");

    // 读取 deployments.json
    let deployments_path = Path::new("../deployments.json");

    if !deployments_path.exists() {
        println!("cargo:warning=deployments.json not found, skipping config update");
        return;
    }

    let deployments_content = match fs::read_to_string(deployments_path) {
        Ok(content) => content,
        Err(e) => {
            println!("cargo:warning=Failed to read deployments.json: {}", e);
            return;
        }
    };

    // 解析 JSON
    let deployments: serde_json::Value = match serde_json::from_str(&deployments_content) {
        Ok(v) => v,
        Err(e) => {
            println!("cargo:warning=Failed to parse deployments.json: {}", e);
            return;
        }
    };

    // 提取地址
    let account = deployments["account"].as_str().unwrap_or("");
    let orderbook = deployments["orderbook"].as_str().unwrap_or("");
    let sequencer = deployments["sequencer"].as_str().unwrap_or("");

    if account.is_empty() || orderbook.is_empty() || sequencer.is_empty() {
        println!("cargo:warning=Missing contract addresses in deployments.json");
        return;
    }

    // 读取现有的 config.toml
    let config_path = Path::new("config.toml");
    let config_content = match fs::read_to_string(config_path) {
        Ok(content) => content,
        Err(e) => {
            println!("cargo:warning=Failed to read config.toml: {}", e);
            return;
        }
    };

    // 更新地址
    let updated_config = update_contract_addresses(&config_content, account, orderbook, sequencer);

    // 写回 config.toml
    if let Err(e) = fs::write(config_path, updated_config) {
        println!("cargo:warning=Failed to write config.toml: {}", e);
        return;
    }

    println!("cargo:warning=✅ Config updated from deployments.json");
    println!("cargo:warning=  Account:   {}", account);
    println!("cargo:warning=  OrderBook: {}", orderbook);
    println!("cargo:warning=  Sequencer: {}", sequencer);
}

fn update_contract_addresses(config: &str, account: &str, orderbook: &str, sequencer: &str) -> String {
    let mut result = String::new();

    for line in config.lines() {
        if line.trim_start().starts_with("account =") {
            result.push_str(&format!("account = \"{}\"\n", account));
        } else if line.trim_start().starts_with("orderbook =") {
            result.push_str(&format!("orderbook = \"{}\"\n", orderbook));
        } else if line.trim_start().starts_with("sequencer =") {
            result.push_str(&format!("sequencer = \"{}\"\n", sequencer));
        } else {
            result.push_str(line);
            result.push('\n');
        }
    }

    result
}
