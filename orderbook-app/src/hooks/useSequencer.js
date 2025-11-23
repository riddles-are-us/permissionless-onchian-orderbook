import { useState, useEffect, useCallback } from 'react';
import contractService from '../services/ContractService';
import { CONFIG } from '../config';

export function useSequencer() {
  const [status, setStatus] = useState(null);
  const [requests, setRequests] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  const loadSequencer = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);

      const sequencerStatus = await contractService.getSequencerStatus();
      setStatus(sequencerStatus);

      const queuedRequests = await contractService.getQueuedRequests(10);
      setRequests(queuedRequests);

      setLoading(false);
    } catch (err) {
      console.error('Failed to load sequencer:', err);
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

        await loadSequencer();

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
