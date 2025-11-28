// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title TradingConstants
 * @notice 交易系统的统一常数定义
 */
library TradingConstants {
    // 数量精度常数（amount 的小数位数）
    uint256 public constant AMOUNT_DECIMALS = 10 ** 8;

    // 价格精度常数（price 的小数位数）
    uint256 public constant PRICE_DECIMALS = 10 ** 8;

    // 交易费率常数（千分之一 = 0.1%）
    uint256 public constant FEE_RATE = 1;
    uint256 public constant FEE_BASE = 1000;
}
