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

// 1. Matcher 配置通过 build.rs 自动更新
console.log('\n🔧 Matcher config will be auto-updated on next cargo build');
console.log('   (via matcher/build.rs)');

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
