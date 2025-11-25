#!/bin/bash

# 确保 anvil 在运行
PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
RPC_URL=http://127.0.0.1:8545

echo "📝 下一些可以立即匹配的订单..."

# 读取配置
SEQUENCER=$(cat deployments.json | jq -r '.sequencer')
PAIR_ID=$(cat deployments.json | jq -r '.pairId')

# 使用 cast 下订单
echo "买单: 价格 1.5 USDC, 数量 0.1 WETH"
cast send $SEQUENCER "placeOrder(bytes32,uint8,bool,uint256,uint256)" \
  $PAIR_ID 0 false 150000000 10000000 \
  --private-key $PRIVATE_KEY --rpc-url $RPC_URL

echo "卖单: 价格 1.5 USDC, 数量 0.1 WETH (应该立即匹配)"
cast send $SEQUENCER "placeOrder(bytes32,uint8,bool,uint256,uint256)" \
  $PAIR_ID 0 true 150000000 10000000 \
  --private-key $PRIVATE_KEY --rpc-url $RPC_URL

echo "✅ 订单已提交，查看 matcher 日志查看匹配事件"
