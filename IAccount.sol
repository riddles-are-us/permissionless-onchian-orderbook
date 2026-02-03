// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IAccount
 * @notice Account合约接口
 */
interface IAccount {
    function lockFunds(
        address user,
        bytes32 tradingPair,
        bool isAsk,
        uint256 price,
        uint256 amount,
        uint256 orderId
    ) external;

    function unlockFunds(
        address user,
        bytes32 tradingPair,
        bool isAsk,
        uint256 price,
        uint256 amount,
        uint256 orderId
    ) external;

    function transferFunds(
        bytes32 tradingPair,
        address buyer,
        address seller,
        uint256 price,
        uint256 amount,
        bool isBidMarketOrder
    ) external;

    function hasSufficientBalance(
        address user,
        bytes32 tradingPair,
        bool isAsk,
        uint256 price,
        uint256 amount
    ) external view returns (bool);

    function getTradingPair(bytes32 tradingPair) external view returns (address baseToken, address quoteToken, bool exists);

    function startBatch(address submitter) external;

    function endBatch(address quoteToken) external returns (uint256 submitterReward);

    /**
     * @notice 收集灰尘资金到协议
     * @param user 用户地址
     * @param tradingPair 交易对
     * @param isAsk 是否为卖单
     * @param price 价格（市价单为0）
     * @param amount 剩余数量
     * @param orderId 订单ID
     */
    function collectDustToProtocol(
        address user,
        bytes32 tradingPair,
        bool isAsk,
        uint256 price,
        uint256 amount,
        uint256 orderId
    ) external;

    /**
     * @notice 提取协议费用
     * @param token 代币地址
     * @param recipient 接收地址
     * @param amount 数量
     */
    function withdrawProtocolFees(
        address token,
        address recipient,
        uint256 amount
    ) external;
}
