// 配置文件 - Sepolia 测试网
export const CONFIG = {
  // Sepolia WebSocket RPC 节点地址
  RPC_URL: 'wss://eth-sepolia.g.alchemy.com/v2/P2hms_foHU-rHhmt8hcpU',

  // Sepolia 链 ID
  CHAIN_ID: 11155111,

  // 合约地址 - Sepolia 部署
  CONTRACTS: {
    ACCOUNT: '0x989762108c68E9A6B0701826Af9B7Da6Ca05a88f',
    ORDERBOOK: '0xa0E3100DaB93E5cCdD57b0f143F1378598799E1C',
    SEQUENCER: '0x2B5c82A7569E5Ad08aED541Ef2d8508F75033cD8',
    WETH: '0xd33b979B2B670981a41Cc7F884fe4C546F8f086F',
    USDC: '0xFD7ca13A85BbA1e9C465c8Cc80D9e02A6C773442',
  },

  // 交易对 ID
  PAIR_ID: '0xe3fd74b5016b57bf4180a8d977a55d749f0f8f76be8d457de0768c85a6acc816',

  // 代币地址（兼容）
  TOKENS: {
    WETH: '0xd33b979B2B670981a41Cc7F884fe4C546F8f086F',
    USDC: '0xFD7ca13A85BbA1e9C465c8Cc80D9e02A6C773442',
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
