import { ethers } from 'ethers';
import { CONFIG } from '../../config';
import OrderBookABI from '../contracts/OrderBook.json';
import SequencerABI from '../contracts/Sequencer.json';

/**
 * 合约交互服务
 */
class ContractService {
  constructor() {
    this.provider = null;
    this.orderbook = null;
    this.sequencer = null;
    this.pairId = null;
  }

  /**
   * 初始化连接
   */
  async init() {
    try {
      // 连接到节点
      this.provider = new ethers.WebSocketProvider(CONFIG.RPC_URL);

      // 创建合约实例
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

      // 计算交易对 ID
      this.pairId = ethers.id(CONFIG.DEFAULT_PAIR);

      console.log('✅ Contract service initialized');
      console.log('Pair ID:', this.pairId);

      return true;
    } catch (error) {
      console.error('Failed to initialize contract service:', error);
      throw error;
    }
  }

  /**
   * 获取交易对数据
   */
  async getTradingPairData() {
    try {
      const data = await this.orderbook.getTradingPairData(this.pairId);

      return {
        bidHead: data[0].toString(),
        askHead: data[1].toString(),
        lastPrice: data[2].toString(),
        volume24h: data[3].toString(),
      };
    } catch (error) {
      console.error('Failed to get trading pair data:', error);
      throw error;
    }
  }

  /**
   * 获取价格层级信息
   * @param {string} levelId - 价格层级 ID
   */
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

  /**
   * 获取订单簿深度
   * @param {boolean} isAsk - true 为卖单，false 为买单
   * @param {number} maxLevels - 最多返回多少层
   */
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

  /**
   * 获取 Sequencer 队列状态
   */
  async getSequencerStatus() {
    try {
      const queueHead = await this.sequencer.queueHead();
      const queueTail = await this.sequencer.queueTail();

      // 计算队列长度（简单遍历）
      let count = 0;
      let currentId = queueHead;

      // 最多遍历 100 个请求以避免超时
      while (currentId !== 0n && count < 100) {
        const request = await this.sequencer.queuedRequests(currentId);
        currentId = request[10]; // nextRequestId
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

  /**
   * 获取队列中的请求列表
   * @param {number} maxRequests - 最多返回多少个请求
   */
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

        requests.push({
          requestId: request[0].toString(),
          requestType: parseInt(request[1]),
          tradingPair: request[2],
          trader: request[3],
          orderType: parseInt(request[4]),
          isAsk: request[5],
          price: request[6].toString(),
          amount: request[7].toString(),
          orderIdToRemove: request[8].toString(),
          timestamp: parseInt(request[9]),
        });

        currentId = request[10]; // nextRequestId
        count++;
      }

      return requests;
    } catch (error) {
      console.error('Failed to get queued requests:', error);
      throw error;
    }
  }

  /**
   * 订阅合约事件
   * @param {function} onEvent - 事件回调函数
   */
  subscribeToEvents(onEvent) {
    if (!this.orderbook || !this.sequencer) {
      throw new Error('Contract service not initialized');
    }

    // 订阅 OrderBook 事件
    this.orderbook.on('OrderPlaced', (orderId, trader, tradingPair, isAsk, price, amount) => {
      onEvent({
        type: 'OrderPlaced',
        data: {
          orderId: orderId.toString(),
          trader,
          tradingPair,
          isAsk,
          price: price.toString(),
          amount: amount.toString(),
        },
      });
    });

    this.orderbook.on('OrderRemoved', (orderId, trader, tradingPair) => {
      onEvent({
        type: 'OrderRemoved',
        data: {
          orderId: orderId.toString(),
          trader,
          tradingPair,
        },
      });
    });

    // 订阅 Sequencer 事件
    this.sequencer.on('OrderRequested', (requestId, trader, tradingPair, isAsk, price, amount) => {
      onEvent({
        type: 'OrderRequested',
        data: {
          requestId: requestId.toString(),
          trader,
          tradingPair,
          isAsk,
          price: price.toString(),
          amount: amount.toString(),
        },
      });
    });

    console.log('✅ Subscribed to contract events');
  }

  /**
   * 取消事件订阅
   */
  unsubscribeFromEvents() {
    if (this.orderbook) {
      this.orderbook.removeAllListeners();
    }
    if (this.sequencer) {
      this.sequencer.removeAllListeners();
    }
    console.log('✅ Unsubscribed from contract events');
  }

  /**
   * 关闭连接
   */
  async close() {
    this.unsubscribeFromEvents();
    if (this.provider) {
      await this.provider.destroy();
    }
  }
}

// 单例模式
const contractService = new ContractService();
export default contractService;
