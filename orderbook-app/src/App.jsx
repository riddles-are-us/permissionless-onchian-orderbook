import React, { useState } from 'react';
import OrderBookDepth from './components/OrderBookDepth';
import SequencerStatus from './components/SequencerStatus';
import { useOrderBook } from './hooks/useOrderBook';
import { useSequencer } from './hooks/useSequencer';
import { useRealtimeUpdates } from './hooks/useRealtimeUpdates';
import { CONFIG } from './config';
import './App.css';

export default function App() {
  const [activeTab, setActiveTab] = useState('orderbook');

  const {
    bidLevels,
    askLevels,
    pairData,
    loading: orderbookLoading,
    error: orderbookError,
    refresh: refreshOrderbook,
  } = useOrderBook();

  const {
    status,
    requests,
    loading: sequencerLoading,
    error: sequencerError,
    refresh: refreshSequencer,
  } = useSequencer();

  useRealtimeUpdates({
    onOrderInserted: (data) => {
      console.log('📌 Order inserted:', data);
      setTimeout(() => refreshOrderbook(), 1000);
    },
    onOrderRemoved: (data) => {
      console.log('🗑️ Order removed:', data);
      setTimeout(() => refreshOrderbook(), 1000);
    },
    onPlaceOrderRequested: (data) => {
      console.log('📝 Place order requested:', data);
      setTimeout(() => refreshSequencer(), 1000);
    },
  });

  const handleRefresh = () => {
    if (activeTab === 'orderbook') {
      refreshOrderbook();
    } else {
      refreshSequencer();
    }
  };

  return (
    <div className="app">
      {/* 头部 */}
      <header className="header">
        <h1 className="title">OrderBook Monitor</h1>
        <p className="subtitle">{CONFIG.DEFAULT_PAIR}</p>
      </header>

      {/* 标签页切换 */}
      <div className="tab-bar">
        <button
          className={`tab ${activeTab === 'orderbook' ? 'active' : ''}`}
          onClick={() => setActiveTab('orderbook')}
        >
          订单簿
        </button>
        <button
          className={`tab ${activeTab === 'sequencer' ? 'active' : ''}`}
          onClick={() => setActiveTab('sequencer')}
        >
          队列状态
        </button>
      </div>

      {/* 内容区域 */}
      <main className="content">
        {activeTab === 'orderbook' ? (
          <OrderBookDepth
            bidLevels={bidLevels}
            askLevels={askLevels}
            loading={orderbookLoading}
            error={orderbookError}
          />
        ) : (
          <SequencerStatus
            status={status}
            requests={requests}
            loading={sequencerLoading}
            error={sequencerError}
          />
        )}
      </main>

      {/* 底部信息栏 */}
      <footer className="footer">
        <div className="footer-info">
          {activeTab === 'orderbook' ? (
            <span>买单: {bidLevels.length} | 卖单: {askLevels.length}</span>
          ) : (
            <span>待处理: {status?.queueLength || 0} 个请求</span>
          )}
        </div>
        <button className="refresh-btn" onClick={handleRefresh}>
          🔄 刷新
        </button>
        <div className="status-dot"></div>
      </footer>
    </div>
  );
}
