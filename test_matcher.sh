#!/bin/bash

set -e

echo "🧪 OrderBook Matcher 测试流程"
echo "=============================="
echo ""

# 配置
ANVIL_RPC="http://127.0.0.1:8545"
ANVIL_WS="ws://127.0.0.1:8545"
CHAIN_ID=31337

# Anvil 默认账户
DEPLOYER_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
USER_KEY="0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"

echo "📝 配置信息:"
echo "  RPC URL: $ANVIL_RPC"
echo "  WS URL:  $ANVIL_WS"
echo "  Chain ID: $CHAIN_ID"
echo ""

# 检查 Anvil 是否运行
echo "🔍 检查 Anvil..."
if ! cast chain-id --rpc-url $ANVIL_RPC &>/dev/null; then
    echo "❌ Anvil 未运行"
    echo ""
    echo "请在另一个终端运行:"
    echo "  anvil"
    echo ""
    exit 1
fi
echo "✅ Anvil 正在运行"
echo ""

# 步骤 1: 部署合约
echo "📦 步骤 1: 部署合约"
echo "----------------------------------------"

export PRIVATE_KEY=$DEPLOYER_KEY

forge script script/Deploy.s.sol \
    --rpc-url $ANVIL_RPC \
    --broadcast \
    --legacy

echo "✅ 合约部署完成"
echo ""

# 检查部署文件
if [ ! -f "deployments.json" ]; then
    echo "❌ deployments.json 未生成"
    exit 1
fi

# 读取部署地址
ACCOUNT=$(jq -r '.account' deployments.json)
ORDERBOOK=$(jq -r '.orderbook' deployments.json)
SEQUENCER=$(jq -r '.sequencer' deployments.json)
WETH=$(jq -r '.weth' deployments.json)
USDC=$(jq -r '.usdc' deployments.json)
PAIR_ID=$(jq -r '.pairId' deployments.json)

echo "📋 已部署合约:"
echo "  WETH:      $WETH"
echo "  USDC:      $USDC"
echo "  Account:   $ACCOUNT"
echo "  OrderBook: $ORDERBOOK"
echo "  Sequencer: $SEQUENCER"
echo ""

# 步骤 2: 准备测试数据
echo "💰 步骤 2: 准备测试数据"
echo "----------------------------------------"

export USER_PRIVATE_KEY=$USER_KEY

forge script script/PrepareTest.s.sol \
    --rpc-url $ANVIL_RPC \
    --broadcast \
    --legacy

echo "✅ 测试数据准备完成"
echo ""

# 步骤 3: 生成 Matcher 配置文件
echo "⚙️  步骤 3: 生成 Matcher 配置文件"
echo "----------------------------------------"

cat > matcher/config.toml <<EOF
[network]
rpc_url = "$ANVIL_WS"
chain_id = $CHAIN_ID

[contracts]
account = "$ACCOUNT"
orderbook = "$ORDERBOOK"
sequencer = "$SEQUENCER"
trading_pair = "$PAIR_ID"

[executor]
private_key = "$DEPLOYER_KEY"
gas_price_gwei = 1
gas_limit = 5000000

[matching]
max_batch_size = 10
matching_interval_ms = 3000

[sync]
start_block = 0
sync_historical = true
EOF

echo "✅ 配置文件已生成: matcher/config.toml"
echo ""

# 显示队列状态
echo "📊 当前队列状态:"
QUEUE_LEN=$(cast call $SEQUENCER "getQueueLength(uint256)" 100 --rpc-url $ANVIL_RPC)
echo "  待处理订单数: $QUEUE_LEN"
echo ""

# 步骤 4: 说明如何运行 Matcher
echo "🚀 步骤 4: 运行 Matcher"
echo "----------------------------------------"
echo ""
echo "在新终端中运行以下命令启动 Matcher:"
echo ""
echo "  cd matcher"
echo "  cargo run -- --log-level debug"
echo ""
echo "或者使用已编译的二进制:"
echo ""
echo "  cd matcher"
echo "  ./target/debug/matcher --log-level debug"
echo ""
echo "Matcher 启动后会自动:"
echo "  1. 同步当前区块链状态"
echo "  2. 加载 Sequencer 队列中的请求"
echo "  3. 计算订单插入位置"
echo "  4. 批量提交到 OrderBook"
echo ""

# 创建验证脚本
cat > verify_results.sh <<'EOF'
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
EOF

chmod +x verify_results.sh

echo "💡 提示:"
echo "  - Matcher 运行后，在另一个终端运行 ./verify_results.sh 查看结果"
echo "  - 使用 Ctrl+C 停止 Matcher"
echo ""
echo "✨ 准备完成! 现在可以启动 Matcher 进行测试"
echo ""
