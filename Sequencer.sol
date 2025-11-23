// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./IAccount.sol";

/**
 * @title Sequencer
 * @notice 链上订单排序器，确保订单插入的公平性和顺序性
 * @dev 所有订单必须先在Sequencer中排队，然后才能被插入到OrderBook中
 */
contract Sequencer {

    // 请求类型枚举
    enum RequestType {
        PlaceOrder,   // 下单请求
        RemoveOrder   // 撤单请求
    }

    // 订单类型枚举
    enum OrderType {
        LimitOrder,   // 限价单
        MarketOrder   // 市价单
    }

    // 排队中的请求信息
    struct QueuedRequest {
        uint256 requestId;
        RequestType requestType;  // 请求类型：下单或撤单
        bytes32 tradingPair;
        address trader;
        OrderType orderType;
        bool isAsk;
        uint256 price;      // 限价单使用，市价单为0
        uint256 amount;
        uint256 orderIdToRemove;  // 如果是撤单请求，这里存储要删除的订单ID
        uint256 timestamp;
        uint256 nextRequestId;  // 队列中的下一个请求
        uint256 prevRequestId;  // 队列中的上一个请求
    }

    // 存储
    mapping(uint256 => QueuedRequest) public queuedRequests;

    uint256 public queueHead;  // 队列头部（最早的请求）
    uint256 public queueTail;  // 队列尾部（最新的请求）
    uint256 public nextRequestId = 1;

    // 存储已经在OrderBook中的订单ID（用于验证撤单请求）
    mapping(uint256 => bool) public ordersInBook;

    // 常量表示空节点
    uint256 constant EMPTY = 0;

    // 授权的OrderBook合约地址
    address public orderBook;

    // Account合约引用
    IAccount public account;

    // 事件
    event PlaceOrderRequested(
        uint256 indexed requestId,
        uint256 indexed orderId,
        bytes32 indexed tradingPair,
        address trader,
        OrderType orderType,
        bool isAsk,
        uint256 price,
        uint256 amount,
        uint256 timestamp
    );
    event RemoveOrderRequested(
        uint256 indexed requestId,
        uint256 indexed orderIdToRemove,
        bytes32 indexed tradingPair,
        address trader,
        uint256 timestamp
    );
    event RequestProcessed(uint256 indexed requestId, RequestType requestType);
    event OrderInsertedToBook(uint256 indexed orderId);
    event OrderBookSet(address indexed orderBook);
    event AccountSet(address indexed account);

    // 修饰器
    modifier onlyOrderBook() {
        require(msg.sender == orderBook, "Only OrderBook can call this");
        _;
    }

    /**
     * @notice 设置授权的OrderBook合约地址
     * @param _orderBook OrderBook合约地址
     */
    function setOrderBook(address _orderBook) external {
        require(orderBook == address(0), "OrderBook already set");
        require(_orderBook != address(0), "Invalid address");
        orderBook = _orderBook;
        emit OrderBookSet(_orderBook);
    }

    /**
     * @notice 设置Account合约地址
     * @param _account Account合约地址
     */
    function setAccount(address _account) external {
        require(address(account) == address(0), "Account already set");
        require(_account != address(0), "Invalid address");
        account = IAccount(_account);
        emit AccountSet(_account);
    }

    /**
     * @notice 提交限价单到Sequencer
     * @param tradingPair 交易对标识符
     * @param isAsk true表示卖单，false表示买单
     * @param price 订单价格
     * @param amount 订单数量
     * @return requestId 请求ID
     * @return orderId 订单ID
     */
    function placeLimitOrder(
        bytes32 tradingPair,
        bool isAsk,
        uint256 price,
        uint256 amount
    ) external returns (uint256 requestId, uint256 orderId) {
        require(price > 0, "Price must be greater than 0");
        require(amount > 0, "Amount must be greater than 0");

        // 检查用户余额是否足够
        require(
            account.hasSufficientBalance(msg.sender, tradingPair, isAsk, price, amount),
            "Insufficient balance"
        );

        // 生成订单ID
        orderId = nextRequestId;

        // 创建下单请求
        requestId = _createRequest(
            RequestType.PlaceOrder,
            tradingPair,
            msg.sender,
            OrderType.LimitOrder,
            isAsk,
            price,
            amount,
            0  // orderIdToRemove不使用
        );

        // 锁定用户资金
        account.lockFunds(msg.sender, tradingPair, isAsk, price, amount, orderId);

        emit PlaceOrderRequested(requestId, orderId, tradingPair, msg.sender, OrderType.LimitOrder, isAsk, price, amount, block.timestamp);

        return (requestId, orderId);
    }

    /**
     * @notice 提交市价单到Sequencer
     * @param tradingPair 交易对标识符
     * @param isAsk true表示市价卖单，false表示市价买单
     * @param amount 订单数量
     * @return requestId 请求ID
     * @return orderId 订单ID
     */
    function placeMarketOrder(
        bytes32 tradingPair,
        bool isAsk,
        uint256 amount
    ) external returns (uint256 requestId, uint256 orderId) {
        require(amount > 0, "Amount must be greater than 0");

        // 市价买单暂不支持（无法预先确定锁定金额）
        require(isAsk, "Only market sell orders supported");

        // 检查用户余额（市价卖单只需要基础代币）
        require(
            account.hasSufficientBalance(msg.sender, tradingPair, isAsk, 0, amount),
            "Insufficient balance"
        );

        // 生成订单ID
        orderId = nextRequestId;

        // 创建下单请求
        requestId = _createRequest(
            RequestType.PlaceOrder,
            tradingPair,
            msg.sender,
            OrderType.MarketOrder,
            isAsk,
            0,  // 市价单价格为0
            amount,
            0   // orderIdToRemove不使用
        );

        // 锁定用户资金（市价卖单锁定基础代币）
        account.lockFunds(msg.sender, tradingPair, isAsk, 0, amount, orderId);

        emit PlaceOrderRequested(requestId, orderId, tradingPair, msg.sender, OrderType.MarketOrder, isAsk, 0, amount, block.timestamp);

        return (requestId, orderId);
    }

    /**
     * @notice 请求撤销订单
     * @param orderIdToRemove 要撤销的订单ID（必须已经在OrderBook中）
     * @return requestId 请求ID
     */
    function requestRemoveOrder(uint256 orderIdToRemove) external returns (uint256 requestId) {
        // 验证订单存在且在OrderBook中
        require(ordersInBook[orderIdToRemove], "Order not in book");

        // 验证订单所有权（通过OrderBook查询）
        // 这里简化处理，实际应该查询OrderBook验证

        // 创建撤单请求
        requestId = _createRequest(
            RequestType.RemoveOrder,
            bytes32(0),  // tradingPair从OrderBook获取
            msg.sender,
            OrderType.LimitOrder,  // 这里不重要
            false,       // 这里不重要
            0,           // price不使用
            0,           // amount不使用
            orderIdToRemove
        );

        emit RemoveOrderRequested(requestId, orderIdToRemove, bytes32(0), msg.sender, block.timestamp);

        return requestId;
    }

    /**
     * @dev 内部函数：创建请求并加入队列
     */
    function _createRequest(
        RequestType requestType,
        bytes32 tradingPair,
        address trader,
        OrderType orderType,
        bool isAsk,
        uint256 price,
        uint256 amount,
        uint256 orderIdToRemove
    ) internal returns (uint256 requestId) {
        requestId = nextRequestId++;

        QueuedRequest storage request = queuedRequests[requestId];
        request.requestId = requestId;
        request.requestType = requestType;
        request.tradingPair = tradingPair;
        request.trader = trader;
        request.orderType = orderType;
        request.isAsk = isAsk;
        request.price = price;
        request.amount = amount;
        request.orderIdToRemove = orderIdToRemove;
        request.timestamp = block.timestamp;

        // 添加到队列尾部
        if (queueTail != EMPTY) {
            queuedRequests[queueTail].nextRequestId = requestId;
            request.prevRequestId = queueTail;
        } else {
            // 队列为空，设置头部
            queueHead = requestId;
        }

        queueTail = requestId;

        return requestId;
    }

    /**
     * @notice 处理队列头部的请求（只能由OrderBook调用）
     * @param requestId 要处理的请求ID，必须是队列头部
     */
    function processRequest(uint256 requestId) external onlyOrderBook {
        require(requestId == queueHead, "Can only process the head request");
        require(queueHead != EMPTY, "Queue is empty");

        QueuedRequest storage request = queuedRequests[requestId];

        // 如果是下单请求，标记订单已在OrderBook中
        if (request.requestType == RequestType.PlaceOrder) {
            ordersInBook[requestId] = true;
            emit OrderInsertedToBook(requestId);
        }

        uint256 nextRequestId = request.nextRequestId;

        // 更新队列头部
        queueHead = nextRequestId;

        if (nextRequestId != EMPTY) {
            queuedRequests[nextRequestId].prevRequestId = EMPTY;
        } else {
            // 队列变空，重置尾部
            queueTail = EMPTY;
        }

        emit RequestProcessed(requestId, request.requestType);

        // 删除请求数据
        delete queuedRequests[requestId];
    }

    /**
     * @notice 验证请求是否在队列头部
     * @param requestId 请求ID
     * @return 是否在队列头部
     */
    function isHeadRequest(uint256 requestId) external view returns (bool) {
        return requestId == queueHead && queueHead != EMPTY;
    }

    /**
     * @notice 验证订单是否在队列头部（向后兼容）
     * @param orderId 订单ID
     * @return 是否在队列头部
     */
    function isHeadOrder(uint256 orderId) external view returns (bool) {
        return orderId == queueHead && queueHead != EMPTY;
    }

    /**
     * @notice 获取队列头部订单ID
     * @return 队列头部订单ID，如果队列为空返回0
     */
    function getHeadOrderId() external view returns (uint256) {
        return queueHead;
    }

    /**
     * @notice 获取排队中的请求信息
     * @param requestId 请求ID
     * @return requestType 请求类型
     * @return tradingPair 交易对
     * @return trader 交易者
     * @return orderType 订单类型
     * @return isAsk 是否为卖单
     * @return price 价格
     * @return amount 数量
     * @return orderIdToRemove 要删除的订单ID（撤单请求时使用）
     * @return timestamp 时间戳
     */
    function getQueuedRequest(uint256 requestId)
        external
        view
        returns (
            RequestType requestType,
            bytes32 tradingPair,
            address trader,
            OrderType orderType,
            bool isAsk,
            uint256 price,
            uint256 amount,
            uint256 orderIdToRemove,
            uint256 timestamp
        )
    {
        QueuedRequest storage request = queuedRequests[requestId];
        require(request.requestId != 0, "Request does not exist");

        return (
            request.requestType,
            request.tradingPair,
            request.trader,
            request.orderType,
            request.isAsk,
            request.price,
            request.amount,
            request.orderIdToRemove,
            request.timestamp
        );
    }

    /**
     * @notice 获取排队中的订单信息（向后兼容）
     * @param orderId 订单ID（即requestId）
     */
    function getQueuedOrder(uint256 orderId)
        external
        view
        returns (
            bytes32 tradingPair,
            address trader,
            uint8 orderType,
            bool isAsk,
            uint256 price,
            uint256 amount,
            uint256 timestamp
        )
    {
        QueuedRequest storage request = queuedRequests[orderId];
        require(request.requestId != 0, "Order does not exist");
        require(request.requestType == RequestType.PlaceOrder, "Not a place order request");

        return (
            request.tradingPair,
            request.trader,
            uint8(request.orderType),
            request.isAsk,
            request.price,
            request.amount,
            request.timestamp
        );
    }

    /**
     * @notice 获取队列快照
     * @param maxCount 最多返回的订单数量
     * @return orderIds 订单ID数组
     * @return traders 交易者地址数组
     * @return amounts 订单数量数组
     */
    function getQueueSnapshot(uint256 maxCount)
        external
        view
        returns (
            uint256[] memory orderIds,
            address[] memory traders,
            uint256[] memory amounts
        )
    {
        orderIds = new uint256[](maxCount);
        traders = new address[](maxCount);
        amounts = new uint256[](maxCount);

        uint256 currentOrderId = queueHead;
        uint256 count = 0;

        while (currentOrderId != EMPTY && count < maxCount) {
            QueuedRequest storage request = queuedRequests[currentOrderId];
            orderIds[count] = request.requestId;
            traders[count] = request.trader;
            amounts[count] = request.amount;
            currentOrderId = request.nextRequestId;
            count++;
        }

        return (orderIds, traders, amounts);
    }

    /**
     * @notice 获取队列长度（估算，最多遍历指定数量）
     * @param maxCount 最多遍历的订单数量
     * @return 队列中的订单数量
     */
    function getQueueLength(uint256 maxCount) external view returns (uint256) {
        uint256 currentOrderId = queueHead;
        uint256 count = 0;

        while (currentOrderId != EMPTY && count < maxCount) {
            currentOrderId = queuedRequests[currentOrderId].nextRequestId;
            count++;
        }

        return count;
    }
}
