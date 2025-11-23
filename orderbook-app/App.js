import React, { useState } from 'react';
import {
  StyleSheet,
  Text,
  View,
  SafeAreaView,
  TouchableOpacity,
  RefreshControl,
  ScrollView,
} from 'react-native';
import { StatusBar } from 'expo-status-bar';
import OrderBookDepth from './src/components/OrderBookDepth';
import SequencerStatus from './src/components/SequencerStatus';
import { useOrderBook } from './src/hooks/useOrderBook';
import { useSequencer } from './src/hooks/useSequencer';
import { useRealtimeUpdates } from './src/hooks/useRealtimeUpdates';
import { CONFIG } from './config';

export default function App() {
  const [activeTab, setActiveTab] = useState('orderbook'); // 'orderbook' or 'sequencer'

  // 使用自定义 Hooks
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

  // 实时更新处理
  useRealtimeUpdates({
    onOrderPlaced: (data) => {
      console.log('📌 Order placed:', data);
      // 自动刷新订单簿
      setTimeout(() => {
        refreshOrderbook();
      }, 1000);
    },
    onOrderRemoved: (data) => {
      console.log('🗑️ Order removed:', data);
      // 自动刷新订单簿
      setTimeout(() => {
        refreshOrderbook();
      }, 1000);
    },
    onOrderRequested: (data) => {
      console.log('📝 Order requested:', data);
      // 自动刷新 Sequencer
      setTimeout(() => {
        refreshSequencer();
      }, 1000);
    },
  });

  // 刷新当前标签页数据
  const handleRefresh = () => {
    if (activeTab === 'orderbook') {
      refreshOrderbook();
    } else {
      refreshSequencer();
    }
  };

  const isLoading = activeTab === 'orderbook' ? orderbookLoading : sequencerLoading;

  return (
    <SafeAreaView style={styles.container}>
      <StatusBar style="light" />

      {/* 头部 */}
      <View style={styles.header}>
        <Text style={styles.title}>OrderBook Monitor</Text>
        <Text style={styles.subtitle}>{CONFIG.DEFAULT_PAIR}</Text>
      </View>

      {/* 标签页切换 */}
      <View style={styles.tabBar}>
        <TouchableOpacity
          style={[styles.tab, activeTab === 'orderbook' && styles.activeTab]}
          onPress={() => setActiveTab('orderbook')}
        >
          <Text style={[styles.tabText, activeTab === 'orderbook' && styles.activeTabText]}>
            订单簿
          </Text>
        </TouchableOpacity>
        <TouchableOpacity
          style={[styles.tab, activeTab === 'sequencer' && styles.activeTab]}
          onPress={() => setActiveTab('sequencer')}
        >
          <Text style={[styles.tabText, activeTab === 'sequencer' && styles.activeTabText]}>
            队列状态
          </Text>
        </TouchableOpacity>
      </View>

      {/* 内容区域 */}
      <ScrollView
        style={styles.content}
        refreshControl={
          <RefreshControl refreshing={isLoading} onRefresh={handleRefresh} tintColor="#3b82f6" />
        }
      >
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
      </ScrollView>

      {/* 底部信息栏 */}
      <View style={styles.footer}>
        <Text style={styles.footerText}>
          {activeTab === 'orderbook'
            ? `买单: ${bidLevels.length} | 卖单: ${askLevels.length}`
            : `待处理: ${status?.queueLength || 0} 个请求`}
        </Text>
        <View style={styles.statusDot} />
      </View>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#1a1a1a',
  },
  header: {
    padding: 16,
    backgroundColor: '#2a2a2a',
    borderBottomWidth: 1,
    borderBottomColor: '#3a3a3a',
  },
  title: {
    fontSize: 24,
    fontWeight: 'bold',
    color: '#fff',
  },
  subtitle: {
    fontSize: 14,
    color: '#888',
    marginTop: 4,
  },
  tabBar: {
    flexDirection: 'row',
    backgroundColor: '#2a2a2a',
    borderBottomWidth: 1,
    borderBottomColor: '#3a3a3a',
  },
  tab: {
    flex: 1,
    paddingVertical: 12,
    alignItems: 'center',
    borderBottomWidth: 2,
    borderBottomColor: 'transparent',
  },
  activeTab: {
    borderBottomColor: '#3b82f6',
  },
  tabText: {
    fontSize: 16,
    color: '#888',
    fontWeight: '600',
  },
  activeTabText: {
    color: '#3b82f6',
  },
  content: {
    flex: 1,
  },
  footer: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    padding: 12,
    backgroundColor: '#2a2a2a',
    borderTopWidth: 1,
    borderTopColor: '#3a3a3a',
  },
  footerText: {
    fontSize: 12,
    color: '#888',
  },
  statusDot: {
    width: 8,
    height: 8,
    borderRadius: 4,
    backgroundColor: '#22c55e',
  },
});
