#!/usr/bin/env node

/**
 * 查看 OrderBook 的批处理交易
 * 使用方法: node view_batch_txs.js [network] [blocks]
 * 例如: node view_batch_txs.js sepolia 1000
 */

const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');

// 从命令行参数获取网络和区块范围
const network = process.argv[2] || 'sepolia';
const blocksToScan = parseInt(process.argv[3] || '1000');

// 读取部署配置
const deployments = JSON.parse(
  fs.readFileSync(path.join(__dirname, 'deployments.json'), 'utf8')
);

// RPC URLs
const RPC_URLS = {
  local: 'http://127.0.0.1:8545',
  sepolia: 'https://eth-sepolia.g.alchemy.com/v2/P2hms_foHU-rHhmt8hcpU',
};

// Explorer URLs
const EXPLORER_URLS = {
  local: 'http://localhost:8545',
  sepolia: 'https://sepolia.etherscan.io',
};

const RPC_URL = RPC_URLS[network];
const EXPLORER_URL = EXPLORER_URLS[network];

if (!RPC_URL) {
  console.error(`Unknown network: ${network}. Use 'local' or 'sepolia'`);
  process.exit(1);
}

// OrderBook ABI - 只需要事件定义
const ORDERBOOK_ABI = [
  'event OrderInserted(bytes32 indexed tradingPair, uint256 indexed orderId, bool isAsk, uint256 price, uint256 amount)',
  'event MarketOrderInserted(bytes32 indexed tradingPair, uint256 indexed orderId, bool isAsk, uint256 amount)',
  'event Trade(bytes32 indexed tradingPair, uint256 indexed bidOrderId, uint256 indexed askOrderId, uint256 price, uint256 baseAmount, uint256 quoteAmount, address buyer, address seller)',
  'event OrderFilled(bytes32 indexed tradingPair, uint256 indexed orderId, uint256 filledAmount, bool isFullyFilled)',
  'event OrderRemoved(bytes32 indexed tradingPair, uint256 indexed orderId)',
];

async function main() {
  console.log(`\n🔍 Scanning for batch transactions on ${network}...`);
  console.log(`📊 OrderBook: ${deployments.orderbook}`);
  console.log(`📦 Scanning last ${blocksToScan} blocks\n`);

  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const orderbook = new ethers.Contract(deployments.orderbook, ORDERBOOK_ABI, provider);

  // 获取当前区块号
  const currentBlock = await provider.getBlockNumber();
  const fromBlock = Math.max(0, currentBlock - blocksToScan);

  console.log(`Current block: ${currentBlock}`);
  console.log(`Scanning from block: ${fromBlock}\n`);

  // 获取所有相关事件
  const eventNames = [
    'OrderInserted',
    'MarketOrderInserted',
    'Trade',
    'OrderFilled',
    'OrderRemoved',
  ];

  const allLogs = [];

  for (const eventName of eventNames) {
    try {
      const filter = orderbook.filters[eventName]();
      const logs = await orderbook.queryFilter(filter, fromBlock, currentBlock);
      allLogs.push(...logs.map((log) => ({ ...log, eventName })));
      console.log(`✅ Found ${logs.length} ${eventName} events`);
    } catch (error) {
      console.error(`❌ Error fetching ${eventName} events:`, error.message);
    }
  }

  console.log(`\n📊 Total events found: ${allLogs.length}\n`);

  // 按交易哈希分组
  const txMap = new Map();

  for (const log of allLogs) {
    const txHash = log.transactionHash;
    if (!txMap.has(txHash)) {
      txMap.set(txHash, {
        hash: txHash,
        blockNumber: log.blockNumber,
        events: [],
      });
    }
    txMap.get(txHash).events.push({
      name: log.eventName,
      args: log.args,
    });
  }

  // 只显示包含多个事件的交易（批处理）
  const batchTxs = Array.from(txMap.values()).filter((tx) => tx.events.length > 1);

  console.log(`🎯 Found ${batchTxs.length} batch transactions (with multiple events)\n`);

  if (batchTxs.length === 0) {
    console.log('No batch transactions found in the specified range.');
    return;
  }

  // 按区块号排序（最新的在前）
  batchTxs.sort((a, b) => b.blockNumber - a.blockNumber);

  // 显示每个批处理交易
  for (let i = 0; i < Math.min(batchTxs.length, 20); i++) {
    const tx = batchTxs[i];

    // 获取交易详情
    let timestamp = 'Unknown';
    try {
      const block = await provider.getBlock(tx.blockNumber);
      const date = new Date(block.timestamp * 1000);
      timestamp = date.toLocaleString();
    } catch (error) {
      // Ignore
    }

    console.log(`\n${'='.repeat(80)}`);
    console.log(`📦 Batch Transaction #${i + 1}`);
    console.log(`${'='.repeat(80)}`);
    console.log(`Hash:       ${tx.hash}`);
    console.log(`Block:      ${tx.blockNumber}`);
    console.log(`Time:       ${timestamp}`);
    console.log(`Events:     ${tx.events.length}`);
    console.log(`Explorer:   ${EXPLORER_URL}/tx/${tx.hash}`);
    console.log(`\nEvent Details:`);

    // 显示事件详情
    const eventCounts = {};
    tx.events.forEach((event) => {
      eventCounts[event.name] = (eventCounts[event.name] || 0) + 1;
    });

    Object.entries(eventCounts).forEach(([name, count]) => {
      console.log(`  - ${name}: ${count}`);
    });

    // 如果有 Trade 事件，显示交易详情
    const trades = tx.events.filter((e) => e.name === 'Trade');
    if (trades.length > 0) {
      console.log(`\n  Trades:`);
      trades.forEach((trade, idx) => {
        const { price, baseAmount, quoteAmount } = trade.args;
        const priceFormatted = ethers.formatUnits(price, 8);
        const baseFormatted = ethers.formatUnits(baseAmount, 8);
        const quoteFormatted = ethers.formatUnits(quoteAmount, 8);
        console.log(
          `    [${idx + 1}] Price: ${priceFormatted} | Base: ${baseFormatted} | Quote: ${quoteFormatted}`
        );
      });
    }

    // 如果有 OrderInserted 事件，显示订单详情
    const inserts = tx.events.filter((e) => e.name === 'OrderInserted');
    if (inserts.length > 0) {
      console.log(`\n  Orders Inserted: ${inserts.length}`);
    }

    const marketInserts = tx.events.filter((e) => e.name === 'MarketOrderInserted');
    if (marketInserts.length > 0) {
      console.log(`  Market Orders Inserted: ${marketInserts.length}`);
    }
  }

  console.log(`\n${'='.repeat(80)}\n`);
  console.log(`✅ Displayed ${Math.min(batchTxs.length, 20)} of ${batchTxs.length} batch transactions`);
  console.log(`\nTo view all transactions, increase the block range or use Etherscan:`);
  console.log(`${EXPLORER_URL}/address/${deployments.orderbook}#events\n`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error('Error:', error);
    process.exit(1);
  });
