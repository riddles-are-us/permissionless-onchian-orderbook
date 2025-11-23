import React from 'react';
import { formatPrice, formatAmount } from '../utils/format';
import './OrderBookDepth.css';

export default function OrderBookDepth({ bidLevels, askLevels, loading, error }) {
  if (loading) {
    return (
      <div className="orderbook-container">
        <div className="loading">
          <div className="spinner"></div>
          <p>加载订单簿...</p>
        </div>
      </div>
    );
  }

  if (error) {
    return (
      <div className="orderbook-container">
        <div className="error">错误: {error}</div>
      </div>
    );
  }

  const renderLevel = (item, index, isBid) => {
    const barWidth = Math.min((parseInt(item.volume) / 1e8) * 10, 100);

    return (
      <div key={item.levelId} className={`level-row ${index === 0 ? 'first-level' : ''}`}>
        <div className="level-info">
          <span className={`price ${isBid ? 'bid-price' : 'ask-price'}`}>
            {formatPrice(item.price)}
          </span>
          <span className="volume">{formatAmount(item.volume)}</span>
        </div>
        <div
          className={`volume-bar ${isBid ? 'bid-bar' : 'ask-bar'}`}
          style={{ width: `${barWidth}%` }}
        />
      </div>
    );
  };

  return (
    <div className="orderbook-container">
      {/* 卖单区域 */}
      <div className="section">
        <div className="header">
          <h3 className="header-title">卖单 (Ask)</h3>
          <div className="header-labels">
            <span>价格 (USDC)</span>
            <span>数量 (WETH)</span>
          </div>
        </div>
        {askLevels.length === 0 ? (
          <div className="empty-state">
            <p>暂无卖单</p>
          </div>
        ) : (
          <div className="levels-list">
            {[...askLevels].reverse().map((level, index) => renderLevel(level, index, false))}
          </div>
        )}
      </div>

      {/* 最新成交价 */}
      <div className="last-price-container">
        <span className="last-price-label">最新价</span>
        <span className="last-price">--</span>
      </div>

      {/* 买单区域 */}
      <div className="section">
        <div className="header">
          <h3 className="header-title">买单 (Bid)</h3>
          <div className="header-labels">
            <span>价格 (USDC)</span>
            <span>数量 (WETH)</span>
          </div>
        </div>
        {bidLevels.length === 0 ? (
          <div className="empty-state">
            <p>暂无买单</p>
          </div>
        ) : (
          <div className="levels-list">
            {bidLevels.map((level, index) => renderLevel(level, index, true))}
          </div>
        )}
      </div>
    </div>
  );
}
