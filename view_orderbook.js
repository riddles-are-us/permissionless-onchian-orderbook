#!/usr/bin/env node

/**
 * 查看当前订单簿状态
 * 用法: node view_orderbook.js
 */

const { ethers } = require('ethers');
const fs = require('fs');

// 读取部署配置
const deployments = JSON.parse(fs.readFileSync('deployments.json', 'utf8'));

// 支持命令行参数选择网络: node view_orderbook.js [sepolia|local]
const network = process.argv[2] || 'sepolia';
const RPC_URL = network === 'local'
  ? 'http://127.0.0.1:8545'
  : 'https://eth-sepolia.g.alchemy.com/v2/P2hms_foHU-rHhmt8hcpU';

const PRICE_DECIMALS = 8;
const AMOUNT_DECIMALS = 8;

// ABI
const ORDERBOOK_ABI = [
  'function orderBooks(bytes32) view returns (uint256 askHead, uint256 askTail, uint256 bidHead, uint256 bidTail, uint256 marketAskHead, uint256 marketAskTail, uint256 marketBidHead, uint256 marketBidTail)',
  'function getPriceLevel(uint256 price, bool isAsk) view returns (tuple(uint256 price, uint256 totalVolume, uint256 headOrderId, uint256 tailOrderId, uint256 nextPrice, uint256 prevPrice))',
  'function orders(uint256) view returns (uint256 id, address trader, uint256 amount, uint256 filledAmount, bool isMarketOrder, uint256 priceLevel, uint256 nextOrderId, uint256 prevOrderId)',
];

const SEQUENCER_ABI = [
  'function queueHead() view returns (uint256)',
  'function queueTail() view returns (uint256)',
  'function queuedRequests(uint256) view returns (bytes32 tradingPair, address trader, uint8 requestType, uint8 orderType, bool isAsk, uint256 price, uint256 amount, uint256 nextRequestId, uint256 prevRequestId)',
];

function formatPrice(price) {
  return (Number(price) / 10 ** PRICE_DECIMALS).toFixed(2);
}

function formatAmount(amount) {
  return (Number(amount) / 10 ** AMOUNT_DECIMALS).toFixed(4);
}

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC_URL);

  const orderbook = new ethers.Contract(deployments.orderbook, ORDERBOOK_ABI, provider);
  const sequencer = new ethers.Contract(deployments.sequencer, SEQUENCER_ABI, provider);

  console.log('\n========================================');
  console.log('        📊 OrderBook 状态查看器');
  console.log(`        Network: ${network.toUpperCase()}`);
  console.log('========================================\n');

  // 获取订单簿数据
  const pairData = await orderbook.orderBooks(deployments.pairId);

  console.log('📋 交易对信息:');
  console.log(`   Pair ID: ${deployments.pairId.substring(0, 18)}...`);
  console.log(`   Ask Head: ${pairData.askHead}`);
  console.log(`   Bid Head: ${pairData.bidHead}`);
  console.log(`   Market Ask Head: ${pairData.marketAskHead}`);
  console.log(`   Market Bid Head: ${pairData.marketBidHead}`);
  console.log('');

  // 显示卖单
  console.log('🔴 卖单 (Ask) - 从低到高:');
  console.log('   价格 (USDC)    |  数量 (WETH)  |  订单数');
  console.log('   --------------|--------------|--------');

  let currentPrice = pairData.askHead;
  let askCount = 0;
  while (currentPrice > 0n && askCount < 10) {
    try {
      const level = await orderbook.getPriceLevel(currentPrice, true);
      const orderCount = await countOrdersAtLevel(orderbook, level.headOrderId);
      console.log(`   ${formatPrice(level.price).padStart(12)} | ${formatAmount(level.totalVolume).padStart(12)} | ${orderCount}`);
      currentPrice = level.nextPrice;
      askCount++;
    } catch (e) {
      break;
    }
  }
  if (askCount === 0) console.log('   (空)');

  console.log('');

  // 显示买单
  console.log('🟢 买单 (Bid) - 从高到低:');
  console.log('   价格 (USDC)    |  数量 (WETH)  |  订单数');
  console.log('   --------------|--------------|--------');

  currentPrice = pairData.bidHead;
  let bidCount = 0;
  while (currentPrice > 0n && bidCount < 10) {
    try {
      const level = await orderbook.getPriceLevel(currentPrice, false);
      const orderCount = await countOrdersAtLevel(orderbook, level.headOrderId);
      console.log(`   ${formatPrice(level.price).padStart(12)} | ${formatAmount(level.totalVolume).padStart(12)} | ${orderCount}`);
      currentPrice = level.nextPrice;
      bidCount++;
    } catch (e) {
      break;
    }
  }
  if (bidCount === 0) console.log('   (空)');

  console.log('');

  // 显示市价卖单
  console.log('🔴 市价卖单 (Market Ask):');
  console.log('   订单ID        |  数量 (WETH)  |  已成交      |  剩余');
  console.log('   --------------|--------------|--------------|------------');

  let marketAskId = pairData.marketAskHead;
  let marketAskCount = 0;
  while (marketAskId > 0n && marketAskCount < 10) {
    try {
      const order = await orderbook.orders(marketAskId);
      const remaining = order.amount - order.filledAmount;
      console.log(`   ${marketAskId.toString().padStart(13)} | ${formatAmount(order.amount).padStart(12)} | ${formatAmount(order.filledAmount).padStart(12)} | ${formatAmount(remaining).padStart(10)}`);
      marketAskId = order.nextOrderId;
      marketAskCount++;
    } catch (e) {
      break;
    }
  }
  if (marketAskCount === 0) console.log('   (空)');

  console.log('');

  // 显示市价买单
  console.log('🟢 市价买单 (Market Bid):');
  console.log('   订单ID        |  数量 (USDC)  |  已成交      |  剩余');
  console.log('   --------------|--------------|--------------|------------');

  let marketBidId = pairData.marketBidHead;
  let marketBidCount = 0;
  while (marketBidId > 0n && marketBidCount < 10) {
    try {
      const order = await orderbook.orders(marketBidId);
      const remaining = order.amount - order.filledAmount;
      console.log(`   ${marketBidId.toString().padStart(13)} | ${formatAmount(order.amount).padStart(12)} | ${formatAmount(order.filledAmount).padStart(12)} | ${formatAmount(remaining).padStart(10)}`);
      marketBidId = order.nextOrderId;
      marketBidCount++;
    } catch (e) {
      break;
    }
  }
  if (marketBidCount === 0) console.log('   (空)');

  console.log('');

  // 显示 Sequencer 队列
  console.log('⏳ Sequencer 队列:');
  const queueHead = await sequencer.queueHead();
  const queueTail = await sequencer.queueTail();

  let queueLength = 0;
  let currentId = queueHead;
  while (currentId > 0n && queueLength < 100) {
    const req = await sequencer.queuedRequests(currentId);
    currentId = req.nextRequestId;
    queueLength++;
  }

  console.log(`   队列长度: ${queueLength}`);
  console.log(`   队列头部: ${queueHead}`);
  console.log(`   队列尾部: ${queueTail}`);

  if (queueLength > 0) {
    console.log('\n   待处理请求:');
    currentId = queueHead;
    let count = 0;
    while (currentId > 0n && count < 5) {
      const req = await sequencer.queuedRequests(currentId);
      const reqType = req.requestType === 0 ? '下单' : '撤单';
      const side = req.isAsk ? '卖' : '买';
      console.log(`   #${currentId}: [${reqType}] ${side} @ ${formatPrice(req.price)} x ${formatAmount(req.amount)}`);
      currentId = req.nextRequestId;
      count++;
    }
    if (queueLength > 5) {
      console.log(`   ... 还有 ${queueLength - 5} 个请求`);
    }
  }

  console.log('\n========================================\n');
}

async function countOrdersAtLevel(orderbook, headOrderId) {
  let count = 0;
  let currentId = headOrderId;
  while (currentId > 0n && count < 100) {
    const order = await orderbook.orders(currentId);
    currentId = order.nextOrderId;
    count++;
  }
  return count;
}

main().catch(console.error);
