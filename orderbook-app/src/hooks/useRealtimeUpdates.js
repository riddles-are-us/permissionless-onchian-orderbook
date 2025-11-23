import { useEffect, useCallback } from 'react';
import contractService from '../services/ContractService';

export function useRealtimeUpdates({ onOrderPlaced, onOrderRemoved, onOrderRequested }) {
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
        if (!contractService.provider) {
          await contractService.init();
        }

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
