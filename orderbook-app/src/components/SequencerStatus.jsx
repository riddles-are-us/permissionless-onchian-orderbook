import React from 'react';
import { formatPrice, formatAmount, formatTimestamp, shortenAddress } from '../utils/format';
import './SequencerStatus.css';

export default function SequencerStatus({ status, requests, loading, error }) {
  if (loading) {
    return (
      <div className="sequencer-container">
        <div className="loading">
          <div className="spinner"></div>
          <p>加载队列状态...</p>
        </div>
      </div>
    );
  }

  if (error) {
    return (
      <div className="sequencer-container">
        <div className="error">错误: {error}</div>
      </div>
    );
  }

  const getRequestType = (type) => {
    switch (type) {
      case 0:
        return '下单';
      case 1:
        return '撤单';
      default:
        return '未知';
    }
  };

  const getOrderType = (type) => {
    switch (type) {
      case 0:
        return '限价';
      case 1:
        return '市价';
      default:
        return '未知';
    }
  };

  const renderRequest = (item, index) => (
    <div key={item.requestId} className={`request-card ${index === 0 ? 'first-request' : ''}`}>
      <div className="request-header">
        <span className="request-id">#{item.requestId}</span>
        <span className="request-type-badge">{getRequestType(item.requestType)}</span>
      </div>

      {item.requestType === 0 && (
        <>
          <div className="request-row">
            <span className="request-label">类型:</span>
            <span className="request-value">{getOrderType(item.orderType)}</span>
          </div>
          <div className="request-row">
            <span className="request-label">方向:</span>
            <span className={`request-value ${item.isAsk ? 'ask-text' : 'bid-text'}`}>
              {item.isAsk ? '卖出' : '买入'}
            </span>
          </div>
          <div className="request-row">
            <span className="request-label">价格:</span>
            <span className="request-value">{formatPrice(item.price)} USDC</span>
          </div>
          <div className="request-row">
            <span className="request-label">数量:</span>
            <span className="request-value">{formatAmount(item.amount)} WETH</span>
          </div>
        </>
      )}

      {item.requestType === 1 && (
        <div className="request-row">
          <span className="request-label">订单 ID:</span>
          <span className="request-value">#{item.orderIdToRemove}</span>
        </div>
      )}

      <div className="request-row">
        <span className="request-label">用户:</span>
        <span className="request-value address-text">{shortenAddress(item.trader)}</span>
      </div>
      <div className="request-row">
        <span className="request-label">时间:</span>
        <span className="request-value">{formatTimestamp(item.timestamp)}</span>
      </div>
    </div>
  );

  return (
    <div className="sequencer-container">
      {/* 队列统计 */}
      <div className="stats-container">
        <div className="stat-card">
          <div className="stat-label">队列长度</div>
          <div className="stat-value">{status?.queueLength || 0}</div>
        </div>
        <div className="stat-card">
          <div className="stat-label">队列头部 ID</div>
          <div className="stat-value">{status?.queueHead || '0'}</div>
        </div>
        <div className="stat-card">
          <div className="stat-label">队列尾部 ID</div>
          <div className="stat-value">{status?.queueTail || '0'}</div>
        </div>
      </div>

      {/* 请求列表 */}
      <div className="list-container">
        <div className="list-title">待处理请求</div>
        {requests.length === 0 ? (
          <div className="empty-state">
            <p>队列为空</p>
          </div>
        ) : (
          <div className="request-list">
            {requests.map((request, index) => renderRequest(request, index))}
          </div>
        )}
      </div>
    </div>
  );
}
