import { useState, useEffect, useCallback } from 'react';
import contractService from '../services/ContractService';
import { CONFIG } from '../config';

export function useOrderBook() {
  const [bidLevels, setBidLevels] = useState([]);
  const [askLevels, setAskLevels] = useState([]);
  const [pairData, setPairData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  const loadOrderBook = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);

      const data = await contractService.getTradingPairData();
      setPairData(data);

      const bids = await contractService.getOrderBookDepth(false, CONFIG.DEPTH_LEVELS);
      setBidLevels(bids);

      const asks = await contractService.getOrderBookDepth(true, CONFIG.DEPTH_LEVELS);
      setAskLevels(asks);

      setLoading(false);
    } catch (err) {
      console.error('Failed to load order book:', err);
      setError(err.message);
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    let interval;

    const init = async () => {
      try {
        if (!contractService.provider) {
          await contractService.init();
        }

        await loadOrderBook();

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
