// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title ISequencer
 * @notice Sequencer合约接口
 */
interface ISequencer {
    enum RequestType { PlaceOrder, RemoveOrder }
    enum OrderType { LimitOrder, MarketOrder }

    function processRequest(uint256 requestId) external;

    function isHeadRequest(uint256 requestId) external view returns (bool);

    function isHeadOrder(uint256 orderId) external view returns (bool);

    function getHeadOrderId() external view returns (uint256);

    function getQueuedRequest(uint256 requestId) external view returns (
        RequestType requestType,
        bytes32 tradingPair,
        address trader,
        OrderType orderType,
        bool isAsk,
        uint256 price,  // 注意：对于 RemoveOrder，这里存储 orderIdToRemove
        uint256 amount
    );

    function getQueuedOrder(uint256 orderId) external view returns (
        bytes32 tradingPair,
        address trader,
        uint8 orderType,
        bool isAsk,
        uint256 price,
        uint256 amount
    );
}
