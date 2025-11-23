import { CONFIG } from '../config';

/**
 * 将链上价格转换为人类可读格式
 */
export function formatPrice(price) {
  if (!price || price === '0') return '0.00';

  const priceNum = BigInt(price);
  const decimals = BigInt(10 ** CONFIG.PRICE_DECIMALS);

  const integerPart = priceNum / decimals;
  const fractionalPart = priceNum % decimals;

  const fractionalStr = fractionalPart.toString().padStart(CONFIG.PRICE_DECIMALS, '0');
  const fraction = fractionalStr.substring(0, 2);

  return `${integerPart}.${fraction}`;
}

/**
 * 将链上数量转换为人类可读格式
 */
export function formatAmount(amount) {
  if (!amount || amount === '0') return '0.0000';

  const amountNum = BigInt(amount);
  const decimals = BigInt(10 ** CONFIG.AMOUNT_DECIMALS);

  const integerPart = amountNum / decimals;
  const fractionalPart = amountNum % decimals;

  const fractionalStr = fractionalPart.toString().padStart(CONFIG.AMOUNT_DECIMALS, '0');
  const fraction = fractionalStr.substring(0, 4);

  return `${integerPart}.${fraction}`;
}

/**
 * 格式化时间戳
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
 */
export function shortenAddress(address) {
  if (!address) return '';
  return `${address.substring(0, 6)}...${address.substring(address.length - 4)}`;
}
