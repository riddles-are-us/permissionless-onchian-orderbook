#!/usr/bin/env node

/**
 * 自动更新配置文件
 * 从 deployments.json 读取地址并更新：
 * 1. matcher/config.toml
 * 2. orderbook-app/src/config.js
 */

const fs = require('fs');
const path = require('path');

// 读取 deployments.json
const deploymentsPath = path.join(__dirname, 'deployments.json');
if (!fs.existsSync(deploymentsPath)) {
  console.error('❌ deployments.json not found. Please deploy contracts first.');
  process.exit(1);
}

const deployments = JSON.parse(fs.readFileSync(deploymentsPath, 'utf8'));

console.log('📋 Reading deployments:');
console.log(`  WETH:      ${deployments.weth}`);
console.log(`  USDC:      ${deployments.usdc}`);
console.log(`  Account:   ${deployments.account}`);
console.log(`  OrderBook: ${deployments.orderbook}`);
console.log(`  Sequencer: ${deployments.sequencer}`);
console.log(`  Pair ID:   ${deployments.pairId}`);

// 1. 更新 matcher/config.toml
console.log('\n🔧 Updating matcher/config.toml...');
const matcherConfigPath = path.join(__dirname, 'matcher', 'config.toml');
const matcherConfigContent = `# OrderBook Matcher 配置
# 自动生成自 deployments.json

[network]
# RPC WebSocket 端点
rpc_url = "ws://127.0.0.1:8545"

# 链 ID (Anvil)
chain_id = 31337

[contracts]
# Sequencer 合约地址
sequencer = "${deployments.sequencer}"

# OrderBook 合约地址
orderbook = "${deployments.orderbook}"

# Account 合约地址
account = "${deployments.account}"

[sync]
# 初始同步的起始区块
start_block = 0

# 是否同步历史区块数据
sync_historical = true

[matching]
# 每批最多处理的请求数
max_batch_size = 100

# 匹配间隔（毫秒）
matching_interval_ms = 1000

[executor]
# 执行者私钥（Anvil Account #0）
private_key = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

# Gas 价格（gwei）
gas_price_gwei = 1

# Gas 限制
gas_limit = 5000000
`;

fs.writeFileSync(matcherConfigPath, matcherConfigContent);
console.log('✅ matcher/config.toml updated');

// 2. 更新 orderbook-app/src/config.js
console.log('\n🔧 Updating orderbook-app/src/config.js...');
const frontendConfigPath = path.join(__dirname, 'orderbook-app', 'src', 'config.js');
let frontendConfig = fs.readFileSync(frontendConfigPath, 'utf8');

// 更新 CONTRACTS 对象
frontendConfig = frontendConfig.replace(
  /ACCOUNT: '0x[a-fA-F0-9]{40}'/,
  `ACCOUNT: '${deployments.account}'`
);
frontendConfig = frontendConfig.replace(
  /ORDERBOOK: '0x[a-fA-F0-9]{40}'/,
  `ORDERBOOK: '${deployments.orderbook}'`
);
frontendConfig = frontendConfig.replace(
  /SEQUENCER: '0x[a-fA-F0-9]{40}'/,
  `SEQUENCER: '${deployments.sequencer}'`
);
frontendConfig = frontendConfig.replace(
  /WETH: '0x[a-fA-F0-9]{40}'/g,
  `WETH: '${deployments.weth}'`
);
frontendConfig = frontendConfig.replace(
  /USDC: '0x[a-fA-F0-9]{40}'/g,
  `USDC: '${deployments.usdc}'`
);

// 更新 PAIR_ID
frontendConfig = frontendConfig.replace(
  /PAIR_ID: '0x[a-fA-F0-9]{64}'/,
  `PAIR_ID: '${deployments.pairId}'`
);

fs.writeFileSync(frontendConfigPath, frontendConfig);
console.log('✅ orderbook-app/src/config.js updated');

console.log('\n✨ All configurations updated successfully!');
console.log('\n💡 Tip: You can also add this to package.json scripts:');
console.log('   "update-config": "node update_config.js"');
