import { CONFIG } from '../../config';

/**
 * 将链上价格转换为人类可读格式
 * @param {string|BigInt} price - 链上价格 (uint256)
 * @returns {string} 格式化后的价格
 */
export function formatPrice(price) {
  if (!price || price === '0') return '0.00';

  const priceNum = BigInt(price);
  const decimals = BigInt(10 ** CONFIG.PRICE_DECIMALS);

  const integerPart = priceNum / decimals;
  const fractionalPart = priceNum % decimals;

  // 保留 2 位小数
  const fractionalStr = fractionalPart.toString().padStart(CONFIG.PRICE_DECIMALS, '0');
  const fraction = fractionalStr.substring(0, 2);

  return `${integerPart}.${fraction}`;
}

/**
 * 将链上数量转换为人类可读格式
 * @param {string|BigInt} amount - 链上数量 (uint256)
 * @returns {string} 格式化后的数量
 */
export function formatAmount(amount) {
  if (!amount || amount === '0') return '0.0000';

  const amountNum = BigInt(amount);
  const decimals = BigInt(10 ** CONFIG.AMOUNT_DECIMALS);

  const integerPart = amountNum / decimals;
  const fractionalPart = amountNum % decimals;

  // 保留 4 位小数
  const fractionalStr = fractionalPart.toString().padStart(CONFIG.AMOUNT_DECIMALS, '0');
  const fraction = fractionalStr.substring(0, 4);

  return `${integerPart}.${fraction}`;
}

/**
 * 计算交易对 ID
 * @param {string} pairName - 交易对名称，如 "WETH/USDC"
 * @returns {string} Keccak256 哈希值
 */
export function getPairId(pairName) {
  // 这个函数需要在实际使用时通过 ethers.js 计算
  // 这里返回占位符，实际实现在 ContractService 中
  return pairName;
}

/**
 * 格式化时间戳
 * @param {number} timestamp - Unix 时间戳（秒）
 * @returns {string} 格式化的时间
 */
export function formatTimestamp(timestamp) {
  const date = new Date(timestamp * 1000);
  const hours = date.getHours().toString().padStart(2, '0');
  const minutes = date.getMinutes().toString().padStart(2, '0');
  const seconds = date.getSeconds().toString().padStart(2, '0');
  return `${hours}:${minutes}:${seconds}`;
}

/**
 * 缩短地址显示
 * @param {string} address - 完整地址
 * @returns {string} 缩短后的地址
 */
export function shortenAddress(address) {
  if (!address) return '';
  return `${address.substring(0, 6)}...${address.substring(address.length - 4)}`;
}
