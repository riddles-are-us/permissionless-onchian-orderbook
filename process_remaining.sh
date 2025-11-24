#!/bin/bash

ORDERBOOK=0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9
RPC=http://127.0.0.1:8545
PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

echo "=== 批量处理剩余请求 ==="

# 处理请求 6-13 (第一批的剩余买单)
for i in $(seq 6 13); do
  prev=$((i-1))
  echo "处理请求 $i..."
  cast send $ORDERBOOK "batchProcessRequests(uint256[],uint256[],uint256[])" "[$i]" "[$prev]" "[0]" \
    --private-key $PK --rpc-url $RPC --gas-limit 5000000 > /dev/null 2>&1
  if [ $? -eq 0 ]; then
    echo "  ✓ 成功"
  else
    echo "  ✗ 失败"
  fi
done

# 处理请求 14-23 (第二批的买单和卖单)
for i in $(seq 14 23); do
  prev=$((i-1))
  echo "处理请求 $i..."
  cast send $ORDERBOOK "batchProcessRequests(uint256[],uint256[],uint256[])" "[$i]" "[$prev]" "[0]" \
    --private-key $PK --rpc-url $RPC --gas-limit 5000000 > /dev/null 2>&1
  if [ $? -eq 0 ]; then
    echo "  ✓ 成功"
  else
    echo "  ✗ 失败"
  fi
done

# 处理新的卖单 24-26
# 这些是卖单，需要插入到ask侧，insertAfterPriceLevel需要根据已有的ask侧价格层级来设置
# 先简单地用0试试（插入到头部）
echo "处理卖单 24..."
cast send $ORDERBOOK "batchProcessRequests(uint256[],uint256[],uint256[])" "[24]" "[0]" "[0]" \
  --private-key $PK --rpc-url $RPC --gas-limit 5000000 > /dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "  ✓ 成功"
else
  echo "  ✗ 失败"
fi

echo "处理卖单 25..."
cast send $ORDERBOOK "batchProcessRequests(uint256[],uint256[],uint256[])" "[25]" "[14]" "[0]" \
  --private-key $PK --rpc-url $RPC --gas-limit 5000000 > /dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "  ✓ 成功"
else
  echo "  ✗ 失败"
fi

echo "处理卖单 26..."
cast send $ORDERBOOK "batchProcessRequests(uint256[],uint256[],uint256[])" "[26]" "[15]" "[0]" \
  --private-key $PK --rpc-url $RPC --gas-limit 5000000 > /dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "  ✓ 成功"
else
  echo "  ✗ 失败"
fi

echo "=== 完成 ==="
