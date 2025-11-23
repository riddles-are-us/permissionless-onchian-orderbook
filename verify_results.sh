#!/bin/bash

SEQUENCER=$(jq -r '.sequencer' deployments.json)
ORDERBOOK=$(jq -r '.orderbook' deployments.json)
PAIR_ID=$(cast keccak "WETH/USDC")
RPC="http://127.0.0.1:8545"

echo "🔍 验证 Matcher 执行结果"
echo "========================"
echo ""

echo "📦 队列状态:"
QUEUE_LEN=$(cast call $SEQUENCER "getQueueLength(uint256)" 100 --rpc-url $RPC)
echo "  待处理订单: $QUEUE_LEN"

if [ "$QUEUE_LEN" = "0" ]; then
    echo "  ✅ 队列已清空"
else
    echo "  ⚠️  还有订单待处理"
fi
echo ""

echo "📊 订单簿状态:"
BOOK_DATA=$(cast call $ORDERBOOK "getTradingPairData(bytes32)" $PAIR_ID --rpc-url $RPC)
BID_HEAD=$(echo $BOOK_DATA | awk '{print $1}')
ASK_HEAD=$(echo $BOOK_DATA | awk '{print $2}')

echo "  Bid 头部层级 ID: $BID_HEAD"
echo "  Ask 头部层级 ID: $ASK_HEAD"

if [ "$BID_HEAD" != "0" ]; then
    echo ""
    echo "💰 Bid 价格层级:"

    LEVEL=$BID_HEAD
    for i in {1..5}; do
        if [ "$LEVEL" = "0" ]; then
            break
        fi

        LEVEL_DATA=$(cast call $ORDERBOOK "priceLevels(uint256)" $LEVEL --rpc-url $RPC)
        PRICE=$(echo $LEVEL_DATA | awk '{print $1}')
        VOLUME=$(echo $LEVEL_DATA | awk '{print $2}')
        NEXT=$(echo $LEVEL_DATA | awk '{print $5}')

        PRICE_DISP=$(awk "BEGIN {printf \"%.2f\", $PRICE / 1e8}")
        VOLUME_DISP=$(awk "BEGIN {printf \"%.4f\", $VOLUME / 1e8}")

        echo "  Level $i: $PRICE_DISP USDC x $VOLUME_DISP WETH"

        LEVEL=$NEXT
    done
fi

if [ "$ASK_HEAD" != "0" ]; then
    echo ""
    echo "💵 Ask 价格层级:"
    echo "  (当前无卖单)"
fi

echo ""
if [ "$QUEUE_LEN" = "0" ] && [ "$BID_HEAD" != "0" ]; then
    echo "✅ 测试成功! Matcher 已正确处理订单"
else
    echo "⚠️  请检查 Matcher 日志"
fi
