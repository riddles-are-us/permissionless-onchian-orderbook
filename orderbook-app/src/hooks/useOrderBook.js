import { useState, useEffect, useCallback } from 'react';
import contractService from '../services/ContractService';
import { CONFIG } from '../../config';

/**
 * 订单簿数据 Hook
 */
export function useOrderBook() {
  const [bidLevels, setBidLevels] = useState([]);
  const [askLevels, setAskLevels] = useState([]);
  const [pairData, setPairData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  // 加载订单簿数据
  const loadOrderBook = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);

      // 获取交易对数据
      const data = await contractService.getTradingPairData();
      setPairData(data);

      // 获取买单深度
      const bids = await contractService.getOrderBookDepth(false, CONFIG.DEPTH_LEVELS);
      setBidLevels(bids);

      // 获取卖单深度
      const asks = await contractService.getOrderBookDepth(true, CONFIG.DEPTH_LEVELS);
      setAskLevels(asks);

      setLoading(false);
    } catch (err) {
      console.error('Failed to load order book:', err);
      setError(err.message);
      setLoading(false);
    }
  }, []);

  // 初始化和定时刷新
  useEffect(() => {
    let interval;

    const init = async () => {
      try {
        // 初始化合约服务（如果还没初始化）
        if (!contractService.provider) {
          await contractService.init();
        }

        // 首次加载
        await loadOrderBook();

        // 设置定时刷新
        interval = setInterval(loadOrderBook, CONFIG.REFRESH_INTERVAL);
      } catch (err) {
        console.error('Failed to initialize:', err);
        setError(err.message);
        setLoading(false);
      }
    };

    init();

    return () => {
      if (interval) {
        clearInterval(interval);
      }
    };
  }, [loadOrderBook]);

  return {
    bidLevels,
    askLevels,
    pairData,
    loading,
    error,
    refresh: loadOrderBook,
  };
}
