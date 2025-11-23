import { useState, useEffect, useCallback } from 'react';
import contractService from '../services/ContractService';
import { CONFIG } from '../../config';

/**
 * Sequencer 队列状态 Hook
 */
export function useSequencer() {
  const [status, setStatus] = useState(null);
  const [requests, setRequests] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  // 加载 Sequencer 数据
  const loadSequencer = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);

      // 获取队列状态
      const sequencerStatus = await contractService.getSequencerStatus();
      setStatus(sequencerStatus);

      // 获取队列中的请求
      const queuedRequests = await contractService.getQueuedRequests(10);
      setRequests(queuedRequests);

      setLoading(false);
    } catch (err) {
      console.error('Failed to load sequencer:', err);
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
        await loadSequencer();

        // 设置定时刷新
        interval = setInterval(loadSequencer, CONFIG.REFRESH_INTERVAL);
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
  }, [loadSequencer]);

  return {
    status,
    requests,
    loading,
    error,
    refresh: loadSequencer,
  };
}
