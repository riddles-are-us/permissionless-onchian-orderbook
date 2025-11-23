import React from 'react';
import { View, Text, StyleSheet, FlatList, ActivityIndicator } from 'react-native';
import { formatPrice, formatAmount } from '../utils/format';

/**
 * 订单簿深度组件
 */
export default function OrderBookDepth({ bidLevels, askLevels, loading, error }) {
  if (loading) {
    return (
      <View style={styles.container}>
        <ActivityIndicator size="large" color="#3b82f6" />
        <Text style={styles.loadingText}>加载订单簿...</Text>
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

  // 渲染单个价格层级
  const renderLevel = ({ item, index }, isBid) => (
    <View style={[styles.levelRow, index === 0 && styles.firstLevel]}>
      <View style={styles.levelInfo}>
        <Text style={[styles.price, isBid ? styles.bidPrice : styles.askPrice]}>
          {formatPrice(item.price)}
        </Text>
        <Text style={styles.volume}>{formatAmount(item.volume)}</Text>
      </View>
      <View
        style={[
          styles.volumeBar,
          { width: `${Math.min((parseInt(item.volume) / 1e8) * 10, 100)}%` },
          isBid ? styles.bidBar : styles.askBar,
        ]}
      />
    </View>
  );

  return (
    <View style={styles.container}>
      {/* 卖单区域（价格从低到高） */}
      <View style={styles.section}>
        <View style={styles.header}>
          <Text style={styles.headerTitle}>卖单 (Ask)</Text>
          <View style={styles.headerLabels}>
            <Text style={styles.headerLabel}>价格 (USDC)</Text>
            <Text style={styles.headerLabel}>数量 (WETH)</Text>
          </View>
        </View>
        {askLevels.length === 0 ? (
          <View style={styles.emptyState}>
            <Text style={styles.emptyText}>暂无卖单</Text>
          </View>
        ) : (
          <FlatList
            data={[...askLevels].reverse()} // 反转数组，价格从高到低显示
            renderItem={(props) => renderLevel(props, false)}
            keyExtractor={(item) => item.levelId}
            style={styles.list}
            scrollEnabled={false}
          />
        )}
      </View>

      {/* 最新成交价 */}
      <View style={styles.lastPriceContainer}>
        <Text style={styles.lastPriceLabel}>最新价</Text>
        <Text style={styles.lastPrice}>--</Text>
      </View>

      {/* 买单区域（价格从高到低） */}
      <View style={styles.section}>
        <View style={styles.header}>
          <Text style={styles.headerTitle}>买单 (Bid)</Text>
          <View style={styles.headerLabels}>
            <Text style={styles.headerLabel}>价格 (USDC)</Text>
            <Text style={styles.headerLabel}>数量 (WETH)</Text>
          </View>
        </View>
        {bidLevels.length === 0 ? (
          <View style={styles.emptyState}>
            <Text style={styles.emptyText}>暂无买单</Text>
          </View>
        ) : (
          <FlatList
            data={bidLevels}
            renderItem={(props) => renderLevel(props, true)}
            keyExtractor={(item) => item.levelId}
            style={styles.list}
            scrollEnabled={false}
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
  section: {
    flex: 1,
  },
  header: {
    padding: 12,
    backgroundColor: '#2a2a2a',
    borderBottomWidth: 1,
    borderBottomColor: '#3a3a3a',
  },
  headerTitle: {
    fontSize: 16,
    fontWeight: 'bold',
    color: '#fff',
    marginBottom: 8,
  },
  headerLabels: {
    flexDirection: 'row',
    justifyContent: 'space-between',
  },
  headerLabel: {
    fontSize: 12,
    color: '#888',
  },
  list: {
    flex: 1,
  },
  levelRow: {
    position: 'relative',
    paddingVertical: 6,
    paddingHorizontal: 12,
    borderBottomWidth: 1,
    borderBottomColor: '#2a2a2a',
  },
  firstLevel: {
    backgroundColor: '#2a2a2a',
  },
  levelInfo: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    zIndex: 1,
  },
  price: {
    fontSize: 14,
    fontWeight: '600',
    fontFamily: 'monospace',
  },
  bidPrice: {
    color: '#22c55e', // 绿色
  },
  askPrice: {
    color: '#ef4444', // 红色
  },
  volume: {
    fontSize: 14,
    color: '#ddd',
    fontFamily: 'monospace',
  },
  volumeBar: {
    position: 'absolute',
    top: 0,
    right: 0,
    bottom: 0,
    opacity: 0.2,
  },
  bidBar: {
    backgroundColor: '#22c55e',
  },
  askBar: {
    backgroundColor: '#ef4444',
  },
  lastPriceContainer: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    padding: 16,
    backgroundColor: '#2a2a2a',
    borderTopWidth: 2,
    borderBottomWidth: 2,
    borderColor: '#3a3a3a',
  },
  lastPriceLabel: {
    fontSize: 14,
    color: '#888',
  },
  lastPrice: {
    fontSize: 20,
    fontWeight: 'bold',
    color: '#fff',
    fontFamily: 'monospace',
  },
  emptyState: {
    padding: 20,
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
  },
});
