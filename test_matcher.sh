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

# 步骤 2: 生成 Matcher 配置文件
echo "⚙️  步骤 2: 生成 Matcher 配置文件"
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

# 显示测试说明
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "  分阶段测试流程"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "🚀 首先启动 Matcher (在新终端):"
echo ""
echo "   cd matcher && cargo run -- --log-level debug"
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "📋 Phase 1: 限价单测试"
echo "----------------------------------------"
echo "  1. 运行测试脚本:"
echo "     export PRIVATE_KEY=$DEPLOYER_KEY"
echo "     export USER_PRIVATE_KEY=$USER_KEY"
echo "     forge script script/TestPhase1_LimitOrders.s.sol --rpc-url $ANVIL_RPC --broadcast --legacy"
echo ""
echo "  2. 等待 Matcher 处理 (观察日志)"
echo ""
echo "  3. 验证结果:"
echo "     forge script script/VerifyResults.s.sol --sig 'verifyPhase1()' --rpc-url $ANVIL_RPC"
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "📋 Phase 2: 市价单测试"
echo "----------------------------------------"
echo "  1. 运行测试脚本:"
echo "     forge script script/TestPhase2_MarketOrders.s.sol --rpc-url $ANVIL_RPC --broadcast --legacy"
echo ""
echo "  2. 等待 Matcher 处理"
echo ""
echo "  3. 验证结果:"
echo "     forge script script/VerifyResults.s.sol --sig 'verifyPhase2()' --rpc-url $ANVIL_RPC"
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "📋 Phase 3: 撤单测试"
echo "----------------------------------------"
echo "  1. 下单 (准备撤销):"
echo "     forge script script/TestPhase3_RemoveOrders.s.sol --rpc-url $ANVIL_RPC --broadcast --legacy"
echo ""
echo "  2. 等待 Matcher 处理下单请求"
echo ""
echo "  3. 提交撤单请求:"
echo "     forge script script/TestPhase3_RemoveOrders.s.sol:TestPhase3_RemoveOrders_Part2 --rpc-url $ANVIL_RPC --broadcast --legacy"
echo ""
echo "  4. 等待 Matcher 处理撤单请求"
echo ""
echo "  5. 验证结果:"
echo "     forge script script/VerifyResults.s.sol --sig 'verifyPhase3()' --rpc-url $ANVIL_RPC"
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "💡 通用验证命令:"
echo "   forge script script/VerifyResults.s.sol --rpc-url $ANVIL_RPC"
echo "   forge script script/VerifyResults.s.sol --sig 'runDetailed()' --rpc-url $ANVIL_RPC"
echo ""
echo "✨ 准备完成! 按照上述步骤进行测试"
echo ""
