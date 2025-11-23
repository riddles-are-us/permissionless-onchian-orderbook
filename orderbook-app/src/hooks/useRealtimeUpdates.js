import { useEffect, useCallback } from 'react';
import contractService from '../services/ContractService';

/**
 * 实时事件更新 Hook
 */
export function useRealtimeUpdates({ onOrderPlaced, onOrderRemoved, onOrderRequested }) {
  // 事件处理函数
  const handleEvent = useCallback(
    (event) => {
      console.log('📡 Received event:', event.type);

      switch (event.type) {
        case 'OrderPlaced':
          if (onOrderPlaced) {
            onOrderPlaced(event.data);
          }
          break;
        case 'OrderRemoved':
          if (onOrderRemoved) {
            onOrderRemoved(event.data);
          }
          break;
        case 'OrderRequested':
          if (onOrderRequested) {
            onOrderRequested(event.data);
          }
          break;
        default:
          console.log('Unknown event type:', event.type);
      }
    },
    [onOrderPlaced, onOrderRemoved, onOrderRequested]
  );

  useEffect(() => {
    let subscribed = false;

    const subscribe = async () => {
      try {
        // 初始化合约服务（如果还没初始化）
        if (!contractService.provider) {
          await contractService.init();
        }

        // 订阅事件
        contractService.subscribeToEvents(handleEvent);
        subscribed = true;

        console.log('✅ Subscribed to realtime updates');
      } catch (err) {
        console.error('Failed to subscribe to events:', err);
      }
    };

    subscribe();

    return () => {
      if (subscribed) {
        contractService.unsubscribeFromEvents();
        console.log('✅ Unsubscribed from realtime updates');
      }
    };
  }, [handleEvent]);
}
