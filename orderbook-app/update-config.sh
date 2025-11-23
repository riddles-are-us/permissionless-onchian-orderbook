#!/bin/bash

# 从 deployments.json 自动更新 config.js 中的合约地址

DEPLOYMENTS_FILE="../deployments.json"
CONFIG_FILE="./config.js"

if [ ! -f "$DEPLOYMENTS_FILE" ]; then
    echo "❌ 错误: 找不到 deployments.json 文件"
    echo "   请先运行 test_matcher.sh 部署合约"
    exit 1
fi

echo "📖 读取部署信息..."

ACCOUNT=$(jq -r '.account' "$DEPLOYMENTS_FILE")
ORDERBOOK=$(jq -r '.orderbook' "$DEPLOYMENTS_FILE")
SEQUENCER=$(jq -r '.sequencer' "$DEPLOYMENTS_FILE")
WETH=$(jq -r '.weth' "$DEPLOYMENTS_FILE")
USDC=$(jq -r '.usdc' "$DEPLOYMENTS_FILE")

echo "✅ 合约地址:"
echo "   Account:   $ACCOUNT"
echo "   OrderBook: $ORDERBOOK"
echo "   Sequencer: $SEQUENCER"
echo "   WETH:      $WETH"
echo "   USDC:      $USDC"

# 备份原配置
if [ -f "$CONFIG_FILE" ]; then
    cp "$CONFIG_FILE" "${CONFIG_FILE}.backup"
    echo "💾 已备份原配置到 config.js.backup"
fi

# 生成新配置
cat > "$CONFIG_FILE" <<EOF
// 配置文件 - 自动生成，请勿手动编辑
// 最后更新: $(date)

export const CONFIG = {
  // RPC 节点地址
  RPC_URL: 'ws://127.0.0.1:8545', // Anvil 本地节点
  // RPC_URL: 'wss://mainnet.infura.io/ws/v3/YOUR_KEY', // 主网示例

  CHAIN_ID: 31337, // Anvil 链 ID

  // 合约地址 - 从 deployments.json 自动更新
  CONTRACTS: {
    ACCOUNT: '$ACCOUNT',
    ORDERBOOK: '$ORDERBOOK',
    SEQUENCER: '$SEQUENCER',
  },

  // 代币地址
  TOKENS: {
    WETH: '$WETH',
    USDC: '$USDC',
  },

  // 交易对
  DEFAULT_PAIR: 'WETH/USDC',

  // 精度
  PRICE_DECIMALS: 8,
  AMOUNT_DECIMALS: 8,

  // 刷新间隔（毫秒）
  REFRESH_INTERVAL: 3000,

  // 订单簿深度显示层级数
  DEPTH_LEVELS: 10,
};
EOF

echo "✅ 配置文件已更新: $CONFIG_FILE"
echo ""
echo "🚀 现在可以运行应用:"
echo "   npm start"
