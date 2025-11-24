import { ethers } from 'ethers';
import { CONFIG } from '../config';
import OrderBookABI from '../contracts/OrderBook.json';
import SequencerABI from '../contracts/Sequencer.json';

class ContractService {
  constructor() {
    this.provider = null;
    this.orderbook = null;
    this.sequencer = null;
    this.pairId = null;
  }

  async init() {
    try {
      this.provider = new ethers.WebSocketProvider(CONFIG.RPC_URL);

      this.orderbook = new ethers.Contract(
        CONFIG.CONTRACTS.ORDERBOOK,
        OrderBookABI,
        this.provider
      );

      this.sequencer = new ethers.Contract(
        CONFIG.CONTRACTS.SEQUENCER,
        SequencerABI,
        this.provider
      );

      this.pairId = ethers.id(CONFIG.DEFAULT_PAIR);

      console.log('✅ Contract service initialized');
      console.log('Pair ID:', this.pairId);

      return true;
    } catch (error) {
      console.error('Failed to initialize contract service:', error);
      throw error;
    }
  }

  async getTradingPairData() {
    try {
      const data = await this.orderbook.orderBooks(this.pairId);

      return {
        askHead: data[0].toString(),
        askTail: data[1].toString(),
        bidHead: data[2].toString(),
        bidTail: data[3].toString(),
        marketAskHead: data[4].toString(),
        marketAskTail: data[5].toString(),
        marketBidHead: data[6].toString(),
        marketBidTail: data[7].toString(),
      };
    } catch (error) {
      console.error('Failed to get trading pair data:', error);
      throw error;
    }
  }

  async getPriceLevel(levelId) {
    try {
      const level = await this.orderbook.priceLevels(levelId);

      return {
        price: level[0].toString(),
        totalVolume: level[1].toString(),
        headOrderId: level[2].toString(),
        tailOrderId: level[3].toString(),
        nextPriceLevel: level[4].toString(),
        prevPriceLevel: level[5].toString(),
      };
    } catch (error) {
      console.error('Failed to get price level:', error);
      throw error;
    }
  }

  async getOrderBookDepth(isAsk, maxLevels = 10) {
    try {
      const pairData = await this.getTradingPairData();
      const headLevelId = isAsk ? pairData.askHead : pairData.bidHead;

      if (headLevelId === '0') {
        return [];
      }

      const levels = [];
      let currentLevelId = headLevelId;
      let count = 0;

      while (currentLevelId !== '0' && count < maxLevels) {
        const level = await this.getPriceLevel(currentLevelId);
        levels.push({
          levelId: currentLevelId,
          price: level.price,
          volume: level.totalVolume,
        });

        currentLevelId = level.nextPriceLevel;
        count++;
      }

      return levels;
    } catch (error) {
      console.error('Failed to get order book depth:', error);
      throw error;
    }
  }

  async getSequencerStatus() {
    try {
      const queueHead = await this.sequencer.queueHead();
      const queueTail = await this.sequencer.queueTail();

      let count = 0;
      let currentId = queueHead;

      while (currentId !== 0n && count < 100) {
        const request = await this.sequencer.queuedRequests(currentId);
        currentId = request[7]; // nextRequestId is at index 7 after optimization
        count++;
      }

      return {
        queueHead: queueHead.toString(),
        queueTail: queueTail.toString(),
        queueLength: count,
      };
    } catch (error) {
      console.error('Failed to get sequencer status:', error);
      throw error;
    }
  }

  async getQueuedRequests(maxRequests = 10) {
    try {
      const queueHead = await this.sequencer.queueHead();

      if (queueHead === 0n) {
        return [];
      }

      const requests = [];
      let currentId = queueHead;
      let count = 0;

      while (currentId !== 0n && count < maxRequests) {
        const request = await this.sequencer.queuedRequests(currentId);

        // 优化后的结构体字段顺序：
        // 0: tradingPair, 1: trader, 2: requestType (uint8), 3: orderType (uint8),
        // 4: isAsk, 5: price, 6: amount, 7: nextRequestId, 8: prevRequestId
        const requestType = parseInt(request[2]);
        requests.push({
          requestId: currentId.toString(),  // 使用 mapping key 作为 requestId
          requestType: requestType,
          tradingPair: request[0],
          trader: request[1],
          orderType: parseInt(request[3]),
          isAsk: request[4],
          price: request[5].toString(),
          amount: request[6].toString(),
          // orderIdToRemove: 对于 RemoveOrder (requestType=1)，存储在 price 字段中
          orderIdToRemove: requestType === 1 ? request[5].toString() : '0',
          // timestamp: 已移除，可从事件获取
        });

        currentId = request[7];  // nextRequestId
        count++;
      }

      return requests;
    } catch (error) {
      console.error('Failed to get queued requests:', error);
      throw error;
    }
  }

  subscribeToEvents(onEvent) {
    if (!this.orderbook || !this.sequencer) {
      throw new Error('Contract service not initialized');
    }

    // OrderBook.OrderInserted(tradingPair, orderId, isAsk, price, amount)
    this.orderbook.on('OrderInserted', (tradingPair, orderId, isAsk, price, amount) => {
      onEvent({
        type: 'OrderInserted',
        data: {
          tradingPair,
          orderId: orderId.toString(),
          isAsk,
          price: price.toString(),
          amount: amount.toString(),
        },
      });
    });

    // OrderBook.OrderRemoved(tradingPair, orderId)
    this.orderbook.on('OrderRemoved', (tradingPair, orderId) => {
      onEvent({
        type: 'OrderRemoved',
        data: {
          tradingPair,
          orderId: orderId.toString(),
        },
      });
    });

    // Sequencer.PlaceOrderRequested(requestId, orderId, tradingPair, trader, orderType, isAsk, price, amount, timestamp)
    this.sequencer.on('PlaceOrderRequested', (requestId, orderId, tradingPair, trader, orderType, isAsk, price, amount, timestamp) => {
      onEvent({
        type: 'PlaceOrderRequested',
        data: {
          requestId: requestId.toString(),
          orderId: orderId.toString(),
          tradingPair,
          trader,
          orderType: parseInt(orderType),
          isAsk,
          price: price.toString(),
          amount: amount.toString(),
          timestamp: parseInt(timestamp),
        },
      });
    });

    console.log('✅ Subscribed to contract events');
  }

  unsubscribeFromEvents() {
    if (this.orderbook) {
      this.orderbook.removeAllListeners();
    }
    if (this.sequencer) {
      this.sequencer.removeAllListeners();
    }
    console.log('✅ Unsubscribed from contract events');
  }

  async close() {
    this.unsubscribeFromEvents();
    if (this.provider) {
      await this.provider.destroy();
    }
  }
}

const contractService = new ContractService();
export default contractService;
