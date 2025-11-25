#!/bin/bash

# 读取 OrderBook 地址
ORDERBOOK=$(cat deployments.json | jq -r '.orderbook')
RPC_URL=http://127.0.0.1:8545

echo "📡 监听 OrderBook 事件..."
echo "OrderBook 地址: $ORDERBOOK"
echo ""
echo "使用以下命令查看最近的事件："
echo ""
echo "# Trade 事件"
echo "cast logs --from-block 0 --address $ORDERBOOK 'Trade(bytes32,uint256,uint256,address,address,uint256,uint256)' --rpc-url $RPC_URL"
echo ""
echo "# OrderFilled 事件"  
echo "cast logs --from-block 0 --address $ORDERBOOK 'OrderFilled(bytes32,uint256,uint256,bool)' --rpc-url $RPC_URL"
echo ""
echo "# 执行查询..."
echo ""
echo "=== Trade 事件 ==="
cast logs --from-block 0 --address $ORDERBOOK 'Trade(bytes32,uint256,uint256,address,address,uint256,uint256)' --rpc-url $RPC_URL | tail -20

echo ""
echo "=== OrderFilled 事件 ==="
cast logs --from-block 0 --address $ORDERBOOK 'OrderFilled(bytes32,uint256,uint256,bool)' --rpc-url $RPC_URL | tail -20
