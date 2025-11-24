import React, { useState } from 'react';
import OrderBookDepth from './components/OrderBookDepth';
import SequencerStatus from './components/SequencerStatus';
import PlaceOrder from './components/PlaceOrder';
import { useOrderBook } from './hooks/useOrderBook';
import { useSequencer } from './hooks/useSequencer';
import { useRealtimeUpdates } from './hooks/useRealtimeUpdates';
import { useWallet } from './hooks/useWallet';
import { CONFIG } from './config';
import './App.css';

export default function App() {
  const [activeTab, setActiveTab] = useState('orderbook');
  const { account, signer, isConnected, connect, disconnect, connecting, error: walletError } = useWallet();

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
        <div className="header-left">
          <h1 className="title">OrderBook Monitor</h1>
          <p className="subtitle">{CONFIG.DEFAULT_PAIR}</p>
        </div>
        <div className="header-right">
          {isConnected ? (
            <div className="wallet-info">
              <span className="wallet-address">
                {account.substring(0, 6)}...{account.substring(38)}
              </span>
              <button className="disconnect-btn" onClick={disconnect}>
                断开
              </button>
            </div>
          ) : (
            <button className="connect-btn" onClick={connect} disabled={connecting}>
              {connecting ? '连接中...' : '连接钱包'}
            </button>
          )}
          {walletError && <div className="wallet-error">{walletError}</div>}
        </div>
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
        <button
          className={`tab ${activeTab === 'place' ? 'active' : ''}`}
          onClick={() => setActiveTab('place')}
        >
          下单
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
        ) : activeTab === 'sequencer' ? (
          <SequencerStatus
            status={status}
            requests={requests}
            loading={sequencerLoading}
            error={sequencerError}
          />
        ) : (
          <PlaceOrder signer={signer} account={account} />
        )}
      </main>

      {/* 底部信息栏 */}
      <footer className="footer">
        <div className="footer-info">
          {activeTab === 'orderbook' ? (
            <span>买单: {bidLevels.length} | 卖单: {askLevels.length}</span>
          ) : activeTab === 'sequencer' ? (
            <span>待处理: {status?.queueLength || 0} 个请求</span>
          ) : (
            <span>
              {isConnected
                ? `已连接: ${account.substring(0, 6)}...${account.substring(38)}`
                : '未连接钱包'}
            </span>
          )}
        </div>
        {activeTab !== 'place' && (
          <button className="refresh-btn" onClick={handleRefresh}>
            🔄 刷新
          </button>
        )}
        <div className="status-dot"></div>
      </footer>
    </div>
  );
}
