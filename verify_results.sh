#!/bin/bash

SEQUENCER=$(jq -r '.sequencer' deployments.json)
ORDERBOOK=$(jq -r '.orderbook' deployments.json)
PAIR_ID=$(jq -r '.pairId' deployments.json)
RPC="http://127.0.0.1:8545"

echo "🔍 验证 Matcher 执行结果"
echo "========================"
echo ""

echo "📦 队列状态:"
QUEUE_LEN_RAW=$(cast call $SEQUENCER "getQueueLength(uint256)" 100 --rpc-url $RPC)
QUEUE_LEN=$(cast --to-dec $QUEUE_LEN_RAW 2>/dev/null || echo "0")
echo "  待处理订单: $QUEUE_LEN"

if [ "$QUEUE_LEN" = "0" ]; then
    echo "  ✅ 队列已清空"
else
    echo "  ⚠️  还有 $QUEUE_LEN 订单待处理"
fi
echo ""

echo "📊 订单簿状态:"

# 获取 matchId
MATCH_ID_RAW=$(cast call $ORDERBOOK "matchId()" --rpc-url $RPC)
MATCH_ID=$(cast --to-dec $MATCH_ID_RAW 2>/dev/null || echo "0")
echo "  matchId: $MATCH_ID"

# 获取订单数量
echo ""
echo "📦 订单状态:"
for i in 1 2 3; do
    # 使用 abi-decode 正确解析返回值
    ORDER_DATA=$(cast call $ORDERBOOK "orders(uint256)(uint256,uint256,address,bool,uint256,uint256)" $i --rpc-url $RPC 2>/dev/null)
    if [ -n "$ORDER_DATA" ]; then
        # 解析订单数据 - 每行一个值, 移除科学计数法注释
        PRICE=$(echo "$ORDER_DATA" | sed -n '1p' | sed 's/ \[.*\]//')
        AMOUNT=$(echo "$ORDER_DATA" | sed -n '2p' | sed 's/ \[.*\]//')
        if [ -n "$PRICE" ] && [ "$PRICE" != "0" ]; then
            # 使用 bc 处理大数
            PRICE_DISP=$(echo "scale=2; $PRICE / 100000000" | bc 2>/dev/null || echo "N/A")
            AMOUNT_DISP=$(echo "scale=4; $AMOUNT / 100000000" | bc 2>/dev/null || echo "N/A")
            echo "  Order $i: $PRICE_DISP USDC, $AMOUNT_DISP WETH"
        else
            echo "  Order $i: (empty or removed)"
        fi
    fi
done

echo ""
if [ "$QUEUE_LEN" = "0" ] && [ "$MATCH_ID" != "0" ]; then
    echo "✅ 测试成功! Matcher 已正确处理订单"
    echo "   - 队列已清空"
    echo "   - matchId 已更新为 $MATCH_ID"
else
    echo "⚠️  请检查 Matcher 日志"
fi
