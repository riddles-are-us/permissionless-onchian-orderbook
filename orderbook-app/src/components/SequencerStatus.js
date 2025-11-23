import React from 'react';
import { View, Text, StyleSheet, FlatList, ActivityIndicator } from 'react-native';
import { formatPrice, formatAmount, formatTimestamp, shortenAddress } from '../utils/format';

/**
 * Sequencer 队列状态组件
 */
export default function SequencerStatus({ status, requests, loading, error }) {
  if (loading) {
    return (
      <View style={styles.container}>
        <ActivityIndicator size="large" color="#3b82f6" />
        <Text style={styles.loadingText}>加载队列状态...</Text>
      </View>
    );
  }

  if (error) {
    return (
      <View style={styles.container}>
        <Text style={styles.errorText}>错误: {error}</Text>
      </View>
    );
  }

  // 请求类型映射
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

  // 订单类型映射
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

  // 渲染单个请求
  const renderRequest = ({ item, index }) => (
    <View style={[styles.requestCard, index === 0 && styles.firstRequest]}>
      <View style={styles.requestHeader}>
        <Text style={styles.requestId}>#{item.requestId}</Text>
        <View style={styles.requestTypeBadge}>
          <Text style={styles.requestTypeText}>{getRequestType(item.requestType)}</Text>
        </View>
      </View>

      {item.requestType === 0 && (
        <>
          <View style={styles.requestRow}>
            <Text style={styles.requestLabel}>类型:</Text>
            <Text style={styles.requestValue}>{getOrderType(item.orderType)}</Text>
          </View>
          <View style={styles.requestRow}>
            <Text style={styles.requestLabel}>方向:</Text>
            <Text
              style={[
                styles.requestValue,
                item.isAsk ? styles.askText : styles.bidText,
              ]}
            >
              {item.isAsk ? '卖出' : '买入'}
            </Text>
          </View>
          <View style={styles.requestRow}>
            <Text style={styles.requestLabel}>价格:</Text>
            <Text style={styles.requestValue}>{formatPrice(item.price)} USDC</Text>
          </View>
          <View style={styles.requestRow}>
            <Text style={styles.requestLabel}>数量:</Text>
            <Text style={styles.requestValue}>{formatAmount(item.amount)} WETH</Text>
          </View>
        </>
      )}

      {item.requestType === 1 && (
        <View style={styles.requestRow}>
          <Text style={styles.requestLabel}>订单 ID:</Text>
          <Text style={styles.requestValue}>#{item.orderIdToRemove}</Text>
        </View>
      )}

      <View style={styles.requestRow}>
        <Text style={styles.requestLabel}>用户:</Text>
        <Text style={[styles.requestValue, styles.addressText]}>
          {shortenAddress(item.trader)}
        </Text>
      </View>
      <View style={styles.requestRow}>
        <Text style={styles.requestLabel}>时间:</Text>
        <Text style={styles.requestValue}>{formatTimestamp(item.timestamp)}</Text>
      </View>
    </View>
  );

  return (
    <View style={styles.container}>
      {/* 队列统计 */}
      <View style={styles.statsContainer}>
        <View style={styles.statCard}>
          <Text style={styles.statLabel}>队列长度</Text>
          <Text style={styles.statValue}>{status?.queueLength || 0}</Text>
        </View>
        <View style={styles.statCard}>
          <Text style={styles.statLabel}>队列头部 ID</Text>
          <Text style={styles.statValue}>{status?.queueHead || '0'}</Text>
        </View>
        <View style={styles.statCard}>
          <Text style={styles.statLabel}>队列尾部 ID</Text>
          <Text style={styles.statValue}>{status?.queueTail || '0'}</Text>
        </View>
      </View>

      {/* 请求列表 */}
      <View style={styles.listContainer}>
        <Text style={styles.listTitle}>待处理请求</Text>
        {requests.length === 0 ? (
          <View style={styles.emptyState}>
            <Text style={styles.emptyText}>队列为空</Text>
          </View>
        ) : (
          <FlatList
            data={requests}
            renderItem={renderRequest}
            keyExtractor={(item) => item.requestId}
            contentContainerStyle={styles.listContent}
          />
        )}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#1a1a1a',
  },
  statsContainer: {
    flexDirection: 'row',
    padding: 12,
    gap: 8,
  },
  statCard: {
    flex: 1,
    backgroundColor: '#2a2a2a',
    padding: 12,
    borderRadius: 8,
    alignItems: 'center',
  },
  statLabel: {
    fontSize: 12,
    color: '#888',
    marginBottom: 4,
  },
  statValue: {
    fontSize: 18,
    fontWeight: 'bold',
    color: '#fff',
    fontFamily: 'monospace',
  },
  listContainer: {
    flex: 1,
    marginTop: 8,
  },
  listTitle: {
    fontSize: 16,
    fontWeight: 'bold',
    color: '#fff',
    paddingHorizontal: 12,
    paddingVertical: 8,
    backgroundColor: '#2a2a2a',
  },
  listContent: {
    padding: 12,
  },
  requestCard: {
    backgroundColor: '#2a2a2a',
    borderRadius: 8,
    padding: 12,
    marginBottom: 12,
    borderLeftWidth: 3,
    borderLeftColor: '#3b82f6',
  },
  firstRequest: {
    borderLeftColor: '#22c55e',
  },
  requestHeader: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginBottom: 8,
  },
  requestId: {
    fontSize: 16,
    fontWeight: 'bold',
    color: '#fff',
    fontFamily: 'monospace',
  },
  requestTypeBadge: {
    backgroundColor: '#3b82f6',
    paddingHorizontal: 8,
    paddingVertical: 4,
    borderRadius: 4,
  },
  requestTypeText: {
    fontSize: 12,
    color: '#fff',
    fontWeight: '600',
  },
  requestRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    marginVertical: 4,
  },
  requestLabel: {
    fontSize: 14,
    color: '#888',
  },
  requestValue: {
    fontSize: 14,
    color: '#ddd',
    fontFamily: 'monospace',
  },
  bidText: {
    color: '#22c55e',
    fontWeight: '600',
  },
  askText: {
    color: '#ef4444',
    fontWeight: '600',
  },
  addressText: {
    fontSize: 12,
  },
  emptyState: {
    padding: 40,
    alignItems: 'center',
  },
  emptyText: {
    fontSize: 14,
    color: '#666',
  },
  loadingText: {
    marginTop: 12,
    fontSize: 14,
    color: '#888',
  },
  errorText: {
    fontSize: 14,
    color: '#ef4444',
    textAlign: 'center',
    padding: 20,
  },
});
