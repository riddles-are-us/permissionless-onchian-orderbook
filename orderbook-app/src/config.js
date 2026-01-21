// 配置文件 - Sepolia 测试网
export const CONFIG = {
  // Sepolia WebSocket RPC 节点地址
  RPC_URL: 'wss://eth-sepolia.g.alchemy.com/v2/P2hms_foHU-rHhmt8hcpU',

  // Sepolia 链 ID
  CHAIN_ID: 11155111,

  // 合约地址 - Sepolia 部署
  CONTRACTS: {
    ACCOUNT: '0xC4025c4cbBA6B099f20c654a93aFB7A4a0dB8863',
    ORDERBOOK: '0x4D005133f815Db9B873990e4bEdF142ddBd7D7fF',
    SEQUENCER: '0xFa9750163629b5fBF531f2f847E795001aE3a7a6',
    WETH: '0x3A9d42dCe7d8302c9a2B2aDccC10C0d98F476aAd',
    USDC: '0x5ca03eDdad30D06B098608b6a14dC2cac1fb6263',
  },

  // 交易对 ID
  PAIR_ID: '0xe3fd74b5016b57bf4180a8d977a55d749f0f8f76be8d457de0768c85a6acc816',

  // 代币地址（兼容）
  TOKENS: {
    WETH: '0x3A9d42dCe7d8302c9a2B2aDccC10C0d98F476aAd',
    USDC: '0x5ca03eDdad30D06B098608b6a14dC2cac1fb6263',
  },

  // 交易对
  DEFAULT_PAIR: 'WETH/USDC',

  // 精度
  PRICE_DECIMALS: 8,
  AMOUNT_DECIMALS: 8,

  // 刷新间隔（毫秒）- Sepolia 区块时间较长，可以适当增加
  REFRESH_INTERVAL: 5000,

  // 订单簿深度显示层级数
  DEPTH_LEVELS: 10,
};
