// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./IAccount.sol";

/**
 * @title IOrderBook
 * @notice Minimal interface for OrderBook to access orderTradingPairs
 */
interface IOrderBook {
    function orderTradingPairs(uint256 orderId) external view returns (bytes32);
    function isOrderCancellable(uint256 orderId) external view returns (bool);
    function getOrderTrader(uint256 orderId) external view returns (address);
}

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
    // 优化后使用 packed storage，从12个字段减少到8个字段
    struct QueuedRequest {
        bytes32 tradingPair;      // Slot 0: 32 bytes

        // Slot 1: Packed storage (23 bytes used, 9 bytes free)
        address trader;           // 20 bytes
        uint8 requestType;        // 1 byte (0=PlaceOrder, 1=RemoveOrder)
        uint8 orderType;          // 1 byte (0=LimitOrder, 1=MarketOrder)
        bool isAsk;              // 1 byte

        // Slot 2-6
        uint256 price;           // 32 bytes - 限价单使用；撤单请求时存储orderIdToRemove
        uint256 amount;          // 32 bytes
        uint256 uncancellableDuration; // 32 bytes - 订单不可撤销时长（秒），0表示可立即撤销
        uint256 nextRequestId;   // 32 bytes - 队列中的下一个请求
        uint256 prevRequestId;   // 32 bytes - 队列中的上一个请求
    }

    // 注意：
    // 1. requestId 被移除，使用 mapping key 代替
    // 2. timestamp 被移除，使用事件中的 block.timestamp
    // 3. orderIdToRemove 被移除，撤单请求复用 price 字段

    // 存储
    mapping(uint256 => QueuedRequest) public queuedRequests;

    uint256 public queueHead;  // 队列头部（最早的请求）
    uint256 public queueTail;  // 队列尾部（最新的请求）
    uint256 public nextRequestId = 1;

    // 订单是否在OrderBook中的状态追踪
    // - 当订单被处理并插入OrderBook时设为 true
    // - 当订单被撤销或完全成交后设为 false
    // 用途：验证撤单请求时检查订单是否存在于OrderBook中
    mapping(uint256 => bool) public ordersInBook;

    // 待处理的撤单请求追踪
    // - 当撤单请求被提交时设为 true
    // - 当撤单请求被处理后设为 false
    // 用途：防止重复提交撤单请求
    mapping(uint256 => bool) public pendingRemoveRequests;

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
        uint256 uncancellableDuration,
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
    event PendingRemoveCleared(uint256 indexed orderId);

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
     * @param uncancellableDuration 订单不可撤销时长（秒），0表示可立即撤销
     * @return requestId 请求ID
     * @return orderId 订单ID
     */
    function placeLimitOrder(
        bytes32 tradingPair,
        bool isAsk,
        uint256 price,
        uint256 amount,
        uint256 uncancellableDuration
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
            0,  // orderIdToRemove不使用
            uncancellableDuration
        );

        // 锁定用户资金
        account.lockFunds(msg.sender, tradingPair, isAsk, price, amount, orderId);

        emit PlaceOrderRequested(requestId, orderId, tradingPair, msg.sender, OrderType.LimitOrder, isAsk, price, amount, uncancellableDuration, block.timestamp);

        return (requestId, orderId);
    }

    /**
     * @notice 提交市价单到Sequencer
     * @param tradingPair 交易对标识符
     * @param isAsk true表示市价卖单，false表示市价买单
     * @param amount 市价卖单：要卖出的基础代币数量；市价买单：要花费的计价代币数量
     * @return requestId 请求ID
     * @return orderId 订单ID
     */
    function placeMarketOrder(
        bytes32 tradingPair,
        bool isAsk,
        uint256 amount
    ) external returns (uint256 requestId, uint256 orderId) {
        require(amount > 0, "Amount must be greater than 0");

        // 检查用户余额
        // 市价卖单：需要基础代币（amount = 基础代币数量）
        // 市价买单：需要计价代币（amount = 计价代币数量）
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
            0,  // orderIdToRemove不使用
            0   // 市价单不需要uncancellableDuration
        );

        // 锁定用户资金
        // 市价卖单：锁定基础代币
        // 市价买单：锁定计价代币（amount + 手续费）
        account.lockFunds(msg.sender, tradingPair, isAsk, 0, amount, orderId);

        emit PlaceOrderRequested(requestId, orderId, tradingPair, msg.sender, OrderType.MarketOrder, isAsk, 0, amount, 0, block.timestamp);

        return (requestId, orderId);
    }

    /**
     * @notice 请求撤销订单
     * @param orderIdToRemove 要撤销的订单ID（必须已经在OrderBook中）
     * @return requestId 请求ID
     */
    function requestRemoveOrder(uint256 orderIdToRemove) external returns (uint256 requestId) {
        // 检查是否已有待处理的撤单请求
        require(!pendingRemoveRequests[orderIdToRemove], "Remove request already pending");

        // 验证订单存在且在OrderBook中
        require(ordersInBook[orderIdToRemove], "Order not in book");

        // 验证订单所有权
        require(
            IOrderBook(orderBook).getOrderTrader(orderIdToRemove) == msg.sender,
            "Not order owner"
        );

        // 从OrderBook获取订单的tradingPair
        bytes32 tradingPair = IOrderBook(orderBook).orderTradingPairs(orderIdToRemove);
        require(tradingPair != bytes32(0), "Order trading pair not found");

        // 验证订单是否已过不可撤销期
        require(
            IOrderBook(orderBook).isOrderCancellable(orderIdToRemove),
            "Order is still in uncancellable period"
        );

        // 标记为待处理
        pendingRemoveRequests[orderIdToRemove] = true;

        // 创建撤单请求
        requestId = _createRequest(
            RequestType.RemoveOrder,
            tradingPair,
            msg.sender,
            OrderType.LimitOrder,  // 这里不重要
            false,       // 这里不重要
            0,           // price不使用
            0,           // amount不使用
            orderIdToRemove,
            0            // uncancellableDuration不使用
        );

        emit RemoveOrderRequested(requestId, orderIdToRemove, tradingPair, msg.sender, block.timestamp);

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
        uint256 orderIdToRemove,
        uint256 uncancellableDuration
    ) internal returns (uint256 requestId) {
        requestId = nextRequestId++;

        QueuedRequest storage request = queuedRequests[requestId];
        // 优化：不再存储 requestId (使用 mapping key)
        // 优化：不再存储 timestamp (使用事件)
        request.tradingPair = tradingPair;
        request.trader = trader;
        request.requestType = uint8(requestType);  // 转换为 uint8 以支持 packed storage
        request.orderType = uint8(orderType);      // 转换为 uint8 以支持 packed storage
        request.isAsk = isAsk;

        // 优化：撤单请求复用 price 字段存储 orderIdToRemove
        if (requestType == RequestType.RemoveOrder) {
            request.price = orderIdToRemove;  // 存储要删除的订单ID
            request.amount = 0;
            request.uncancellableDuration = 0;  // 撤单请求不需要此字段
        } else {
            request.price = price;
            request.amount = amount;
            request.uncancellableDuration = uncancellableDuration;
        }

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

        // 更新 ordersInBook 状态追踪
        // 注意：requestType 现在是 uint8，需要转换比较
        if (request.requestType == uint8(RequestType.PlaceOrder)) {
            // 下单请求：订单已被插入OrderBook，标记为 true
            ordersInBook[requestId] = true;
            emit OrderInsertedToBook(requestId);
        } else if (request.requestType == uint8(RequestType.RemoveOrder)) {
            // 撤单请求：订单已从OrderBook移除，标记为 false
            // 注意：撤单请求复用 price 字段存储 orderIdToRemove
            uint256 orderIdToRemove = request.price;
            ordersInBook[orderIdToRemove] = false;
            // 清除 pending 状态
            pendingRemoveRequests[orderIdToRemove] = false;
            emit PendingRemoveCleared(orderIdToRemove);
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

        // 优化：requestType 是 uint8，需要转换为 RequestType
        emit RequestProcessed(requestId, RequestType(request.requestType));

        // 删除请求数据
        delete queuedRequests[requestId];
    }

    /**
     * @notice 清除订单的 pending remove 状态（当订单被完全成交时由 OrderBook 调用）
     * @param orderId 订单ID
     */
    function clearPendingRemove(uint256 orderId) external onlyOrderBook {
        if (pendingRemoveRequests[orderId]) {
            pendingRemoveRequests[orderId] = false;
            emit PendingRemoveCleared(orderId);
        }
    }

    /**
     * @notice 标记订单已从 OrderBook 移除（当订单被完全成交时由 OrderBook 调用）
     * @param orderId 订单ID
     */
    function markOrderRemovedFromBook(uint256 orderId) external onlyOrderBook {
        ordersInBook[orderId] = false;
        if (pendingRemoveRequests[orderId]) {
            pendingRemoveRequests[orderId] = false;
            emit PendingRemoveCleared(orderId);
        }
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
     * @return price 价格（撤单请求时为 orderIdToRemove）
     * @return amount 数量
     * @return uncancellableDuration 订单不可撤销时长（秒）
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
            uint256 uncancellableDuration
        )
    {
        QueuedRequest storage request = queuedRequests[requestId];
        // 优化：检查 tradingPair 或 trader 来验证请求存在（而不是 requestId）
        require(request.trader != address(0), "Request does not exist");

        return (
            RequestType(request.requestType),
            request.tradingPair,
            request.trader,
            OrderType(request.orderType),
            request.isAsk,
            request.price,  // 注意：对于 RemoveOrder，这里存储的是 orderIdToRemove
            request.amount,
            request.uncancellableDuration
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
            uint256 uncancellableDuration
        )
    {
        QueuedRequest storage request = queuedRequests[orderId];
        // 优化：检查 trader 来验证订单存在（而不是 requestId）
        require(request.trader != address(0), "Order does not exist");
        require(request.requestType == uint8(RequestType.PlaceOrder), "Not a place order request");

        return (
            request.tradingPair,
            request.trader,
            request.orderType,  // 已经是 uint8
            request.isAsk,
            request.price,
            request.amount,
            request.uncancellableDuration
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
            // 优化：使用 mapping key 作为 requestId
            orderIds[count] = currentOrderId;
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
