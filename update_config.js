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
console.log(`  USDC:      ${deployments.usdc}`);
console.log(`  Tokens:    ${Object.keys(deployments.tokens).length} RWA assets`);
console.log(`  Pairs:     ${Object.keys(deployments.pairIds).length} trading pairs`);
console.log(`  Account:   ${deployments.contracts.account}`);
console.log(`  OrderBook: ${deployments.contracts.orderbook}`);
console.log(`  Sequencer: ${deployments.contracts.sequencer}`);

// 1. 更新 matcher/config.toml
console.log('\n🔧 Updating matcher/config.toml...');
const matcherConfigPath = path.join(__dirname, 'matcher', 'config.toml');

// 生成 trading_pairs 配置
const tradingPairsConfig = Object.entries(deployments.pairIds)
  .map(([pairName, pairId]) => {
    const [baseToken, quoteToken] = pairName.split('/');
    return `[[trading_pairs]]
pair_id = "${pairId}"
name = "${pairName}"
base_token = "${deployments.tokens[baseToken]}"
quote_token = "${deployments.usdc}"`;
  })
  .join('\n\n');

const matcherConfigContent = `# OrderBook Matcher 配置
# 自动生成自 deployments.json

[network]
# RPC WebSocket 端点
rpc_url = "ws://127.0.0.1:8545"

# 链 ID (Anvil)
chain_id = 31337

[contracts]
# Sequencer 合约地址
sequencer = "${deployments.contracts.sequencer}"

# OrderBook 合约地址
orderbook = "${deployments.contracts.orderbook}"

# Account 合约地址
account = "${deployments.contracts.account}"

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
gas_limit = 15000000

# 交易对配置
${tradingPairsConfig}
`;

fs.writeFileSync(matcherConfigPath, matcherConfigContent);
console.log('✅ matcher/config.toml updated');

// 2. 更新 orderbook-app/src/config.js
console.log('\n🔧 Updating orderbook-app/src/config.js...');
const frontendConfigPath = path.join(__dirname, 'orderbook-app', 'src', 'config.js');

// 生成前端配置
const tokensConfig = Object.entries(deployments.tokens)
  .map(([symbol, address]) => `  ${symbol}: '${address}'`)
  .join(',\n');

const pairIdsConfig = Object.entries(deployments.pairIds)
  .map(([pairName, pairId]) => `  '${pairName}': '${pairId}'`)
  .join(',\n');

const frontendConfigContent = `// 自动生成自 deployments.json
export const CONTRACTS = {
  ACCOUNT: '${deployments.contracts.account}',
  ORDERBOOK: '${deployments.contracts.orderbook}',
  SEQUENCER: '${deployments.contracts.sequencer}',
  USDC: '${deployments.usdc}',
};

export const TOKENS = {
${tokensConfig}
};

export const PAIR_IDS = {
${pairIdsConfig}
};

export const DEPLOYER = '${deployments.deployer}';
export const DEPLOYMENT_BLOCK = ${deployments.deploymentBlock};
`;

fs.writeFileSync(frontendConfigPath, frontendConfigContent);
console.log('✅ orderbook-app/src/config.js updated');

console.log('\n✨ All configurations updated successfully!');
console.log('\n💡 Next steps:');
console.log('   1. Start Anvil: anvil');
console.log('   2. Start Matcher: cd matcher && cargo run');
console.log('   3. Start Frontend: cd orderbook-app && npm run dev');
