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
}
