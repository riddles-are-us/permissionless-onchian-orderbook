import { useEffect, useCallback } from 'react';
import contractService from '../services/ContractService';

export function useRealtimeUpdates({ onOrderInserted, onOrderRemoved, onPlaceOrderRequested }) {
  const handleEvent = useCallback(
    (event) => {
      console.log('📡 Received event:', event.type);

      switch (event.type) {
        case 'OrderInserted':
          if (onOrderInserted) {
            onOrderInserted(event.data);
          }
          break;
        case 'OrderRemoved':
          if (onOrderRemoved) {
            onOrderRemoved(event.data);
          }
          break;
        case 'PlaceOrderRequested':
          if (onPlaceOrderRequested) {
            onPlaceOrderRequested(event.data);
          }
          break;
        default:
          console.log('Unknown event type:', event.type);
      }
    },
    [onOrderInserted, onOrderRemoved, onPlaceOrderRequested]
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
