// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./ISequencer.sol";
import "./IAccount.sol";
import "./TradingConstants.sol";

contract OrderBook {
    using TradingConstants for *;

    // 订单结构
    struct Order {
        uint256 id;
        address trader;
        uint256 amount;
        uint256 filledAmount;
        bool isMarketOrder;  // true表示市价单，false表示限价单
        bool isAsk;  // true表示卖单，false表示买单（避免执行时遍历链表判断）
        uint256 priceLevel;  // 该订单所属的价格（限价单使用，直接存储price值）
        uint256 createdAt;  // 订单创建时的区块时间戳
        uint256 uncancellableDuration;  // 订单不可撤销时长（秒），0表示可立即撤销
        uint256 nextOrderId;  // 同一价格层级下的下一个订单或市价单列表中的下一个订单
        uint256 prevOrderId;  // 同一价格层级下的上一个订单或市价单列表中的上一个订单
    }

    // 价格层级结构 - 每个价格层级包含该价格下的所有订单
    // 注意：mapping的key就是price，所以这里的price字段是冗余的，但为了清晰保留
    struct PriceLevel {
        uint256 price;
        uint256 totalVolume;  // 该价格层级的总挂单量
        uint256 headOrderId;  // 该价格层级的第一个订单
        uint256 tailOrderId;  // 该价格层级的最后一个订单
        uint256 nextPrice;  // 下一个价格（不是ID，直接是price值）
        uint256 prevPrice;  // 上一个价格（不是ID，直接是price值）
    }

    // 交易对的订单簿结构
    struct OrderBookData {
        uint256 askHead;  // 限价Ask列表头部的价格（最低卖价）
        uint256 askTail;  // 限价Ask列表尾部的价格（最高卖价）
        uint256 bidHead;  // 限价Bid列表头部的价格（最高买价）
        uint256 bidTail;  // 限价Bid列表尾部的价格（最低买价）
        uint256 marketAskHead;  // 市价Ask列表的头部订单ID
        uint256 marketAskTail;  // 市价Ask列表的尾部订单ID
        uint256 marketBidHead;  // 市价Bid列表的头部订单ID
        uint256 marketBidTail;  // 市价Bid列表的尾部订单ID
    }

    // 存储
    mapping(bytes32 => OrderBookData) public orderBooks;  // tradingPair => OrderBookData
    mapping(bytes32 => PriceLevel) public priceLevels;  // keccak256(tradingPair, price, isAsk) => PriceLevel
    mapping(uint256 => Order) public orders;

    // Sequencer合约引用
    ISequencer public sequencer;

    // Account合约引用
    IAccount public account;

    // 常量表示空节点
    uint256 constant EMPTY = 0;

    // 存储交易对对应的订单簿ID（用于资金转移）
    mapping(uint256 => bytes32) public orderTradingPairs;

    // 匹配版本号，每次处理batch请求或主动match后递增
    // matcher可以用这个值来检测是否有未同步的事件
    uint256 public matchId;

    // 协议收益
    mapping(address => uint256) public protocolFees;  // token => accumulated fees
    address public protocolFeeRecipient;  // 协议费用接收地址
    address public owner;  // 合约所有者

    // 事件
    event OrderInserted(bytes32 indexed tradingPair, uint256 indexed orderId, bool isAsk, uint256 price, uint256 amount);
    event OrderRemoved(bytes32 indexed tradingPair, uint256 indexed orderId);
    event MarketOrderInserted(bytes32 indexed tradingPair, uint256 indexed orderId, bool isAsk, uint256 amount);
    event MarketOrderRemoved(bytes32 indexed tradingPair, uint256 indexed orderId);
    event PriceLevelCreated(bytes32 indexed tradingPair, uint256 indexed price, bool isAsk);
    event PriceLevelRemoved(bytes32 indexed tradingPair, uint256 indexed price, bool indexed isAsk);
    event SequencerSet(address indexed sequencer);
    event AccountSet(address indexed account);
    event Trade(
        bytes32 indexed tradingPair,
        uint256 indexed buyOrderId,
        uint256 indexed sellOrderId,
        address buyer,
        address seller,
        uint256 price,
        uint256 amount
    );
    event OrderFilled(bytes32 indexed tradingPair, uint256 indexed orderId, uint256 quoteAmount, uint256 baseAmount, bool isFullyFilled);
    event BatchProcessed(address indexed submitter, uint256 indexed matchId, uint256 processedCount, uint256 totalFees);
    event ProtocolFeeCollected(address indexed token, uint256 amount);
    event ProtocolFeeWithdrawn(address indexed token, address indexed recipient, uint256 amount);
    event ProtocolFeeRecipientSet(address indexed recipient);
    event OwnerSet(address indexed owner);

    // 修饰器
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this");
        _;
    }

    /**
     * @notice 设置合约所有者（只能设置一次）
     * @param _owner 所有者地址
     */
    function setOwner(address _owner) external {
        require(owner == address(0), "Owner already set");
        require(_owner != address(0), "Invalid owner address");
        owner = _owner;
        emit OwnerSet(_owner);
    }

    /**
     * @notice 设置Sequencer合约地址
     * @param _sequencer Sequencer合约地址
     */
    function setSequencer(address _sequencer) external {
        require(address(sequencer) == address(0), "Sequencer already set");
        require(_sequencer != address(0), "Invalid sequencer address");
        sequencer = ISequencer(_sequencer);
        emit SequencerSet(_sequencer);
    }

    /**
     * @notice 设置Account合约地址
     * @param _account Account合约地址
     */
    function setAccount(address _account) external {
        require(address(account) == address(0), "Account already set");
        require(_account != address(0), "Invalid account address");
        account = IAccount(_account);
        emit AccountSet(_account);
    }

    /**
     * @notice 设置协议费用接收地址
     * @param _recipient 接收地址
     */
    function setProtocolFeeRecipient(address _recipient) external onlyOwner {
        require(_recipient != address(0), "Invalid recipient address");
        protocolFeeRecipient = _recipient;
        emit ProtocolFeeRecipientSet(_recipient);
    }

    /**
     * @notice 提取协议费用
     * @param token 代币地址
     */
    function withdrawProtocolFees(address token) external onlyOwner {
        require(protocolFeeRecipient != address(0), "Protocol fee recipient not set");
        uint256 amount = protocolFees[token];
        require(amount > 0, "No fees to withdraw");

        protocolFees[token] = 0;

        // 从Account合约转移资金到协议费用接收地址
        account.withdrawProtocolFees(token, protocolFeeRecipient, amount);

        emit ProtocolFeeWithdrawn(token, protocolFeeRecipient, amount);
    }

    /**
     * @dev 生成价格层级的composite key (编码tradingPair、价格和side)
     * 使用 keccak256(tradingPair, price, isAsk) 作为唯一标识
     */
    function _getPriceLevelKey(bytes32 tradingPair, uint256 price, bool isAsk) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(tradingPair, price, isAsk));
    }

    /**
     * @notice 获取价格层级信息（public接口）
     * @param tradingPair 交易对标识符
     * @param price 纯价格值
     * @param isAsk 是否为ask侧
     * @return PriceLevel结构
     */
    function getPriceLevel(bytes32 tradingPair, uint256 price, bool isAsk) public view returns (PriceLevel memory) {
        bytes32 key = _getPriceLevelKey(tradingPair, price, isAsk);
        return priceLevels[key];
    }

    /**
     * @notice 插入限价单到订单簿
     * @param sequencerOrderId Sequencer中的订单ID
     * @param insertAfterPrice 要插入位置的前一个价格层级的价格值（0表示插入到头部）
     * @param insertAfterOrder 在该价格层级内，要插入的订单的前一个订单ID（0表示插入到该价格层级头部）
     */
    function insertOrder(
        uint256 sequencerOrderId,
        uint256 insertAfterPrice,
        uint256 insertAfterOrder
    ) external {
        // 验证该订单是Sequencer队列的头部
        require(sequencer.isHeadOrder(sequencerOrderId), "Order is not at head of sequencer queue");

        // 从Sequencer获取订单信息
        (
            bytes32 tradingPair,
            address trader,
            uint8 orderType,
            bool isAsk,
            uint256 price,
            uint256 amount,
            uint256 uncancellableDuration
        ) = sequencer.getQueuedOrder(sequencerOrderId);

        // 验证是限价单
        require(orderType == 0, "Not a limit order");
        require(price > 0, "Price must be greater than 0");
        require(amount > 0, "Amount must be greater than 0");

        // 查找或创建价格层级
        uint256 priceLevelId = _findOrCreatePriceLevel(
            tradingPair,
            isAsk,
            price,
            insertAfterPrice
        );

        // 创建新订单，使用Sequencer的订单ID
        Order storage order = orders[sequencerOrderId];
        order.id = sequencerOrderId;
        order.trader = trader;
        order.amount = amount;
        order.filledAmount = 0;
        order.isMarketOrder = false;
        order.isAsk = isAsk;
        order.priceLevel = priceLevelId;
        order.createdAt = block.timestamp;
        order.uncancellableDuration = uncancellableDuration;

        // 记录订单对应的交易对（用于撤单和撮合时的资金处理）
        orderTradingPairs[sequencerOrderId] = tradingPair;

        // 将订单插入到价格层级的订单列表中
        _insertOrderIntoPriceLevel(tradingPair, priceLevelId, sequencerOrderId, insertAfterOrder, isAsk);

        // 从Sequencer中处理该请求
        sequencer.processRequest(sequencerOrderId);

        emit OrderInserted(tradingPair, sequencerOrderId, isAsk, price, amount);

        // 自动尝试匹配（如果订单插在最优价格）
        _tryMatchAfterInsertion(tradingPair, sequencerOrderId, isAsk);
    }

    /**
     * @notice 处理删除订单请求（从Sequencer队列）
     * @param requestId Sequencer中的请求ID
     */
    function processRemoveOrder(uint256 requestId) external {
        // 验证该请求是Sequencer队列的头部
        require(sequencer.isHeadRequest(requestId), "Request is not at head of sequencer queue");

        // 从Sequencer获取请求信息
        (
            ISequencer.RequestType requestType,
            bytes32 tradingPair,
            address trader,
            ,  // orderType
            ,  // isAsk
            uint256 priceOrOrderId,  // 对于 RemoveOrder，这里是 orderIdToRemove
            ,  // amount
            // uncancellableDuration (not used for remove requests)
        ) = sequencer.getQueuedRequest(requestId);

        // 验证是撤单请求
        require(uint8(requestType) == 1, "Not a remove order request");

        // 对于撤单请求，price 字段存储的是 orderIdToRemove
        uint256 orderIdToRemove = priceOrOrderId;
        Order storage order = orders[orderIdToRemove];

        // 优雅处理：如果订单不存在，静默返回而不是 revert
        if (order.id == 0) {
            // 订单不存在（可能已被完全成交），直接处理请求并返回
            sequencer.processRequest(requestId);
            emit OrderRemoved(tradingPair, orderIdToRemove);
            return;
        }

        // 验证订单所有权
        require(order.trader == trader, "Not order owner");

        // 获取tradingPair（从存储中）
        tradingPair = orderTradingPairs[orderIdToRemove];
        bool isAsk;

        // 处理限价单或市价单的删除
        // 直接使用 order.isAsk，避免遍历链表
        isAsk = order.isAsk;

        if (order.isMarketOrder) {
            // 市价单
            uint256 remainingAmount = order.amount - order.filledAmount;
            if (remainingAmount > 0) {
                account.unlockFunds(
                    order.trader,
                    tradingPair,
                    isAsk,
                    0,
                    remainingAmount,
                    orderIdToRemove
                );
            }
            _removeMarketOrderFromList(tradingPair, orderIdToRemove, isAsk);
        } else {
            // 限价单
            uint256 priceLevelId = order.priceLevel;

            // 使用composite key访问priceLevel
            bytes32 levelKey = _getPriceLevelKey(tradingPair, priceLevelId, isAsk);
            PriceLevel storage priceLevel = priceLevels[levelKey];

            uint256 remainingAmount = order.amount - order.filledAmount;
            if (remainingAmount > 0) {
                account.unlockFunds(
                    order.trader,
                    tradingPair,
                    isAsk,
                    priceLevel.price,
                    remainingAmount,
                    orderIdToRemove
                );
            }

            _removeOrderFromPriceLevel(tradingPair, priceLevelId, orderIdToRemove, isAsk);

            if (priceLevel.headOrderId == EMPTY) {
                _removePriceLevel(tradingPair, priceLevelId, isAsk);
            }
        }

        // 删除订单交易对记录
        delete orderTradingPairs[orderIdToRemove];

        // 删除订单
        delete orders[orderIdToRemove];

        // 从Sequencer中处理该请求
        sequencer.processRequest(requestId);

        emit OrderRemoved(tradingPair, orderIdToRemove);
    }

    /**
     * @notice 批量处理Sequencer队列中的请求
     * @param requestIds 要处理的请求ID数组（必须按队列顺序）
     * @param insertAfterPrices 下单请求的价格插入位置数组（前一个价格层级的价格值，0表示头部）
     * @param insertAfterOrders 下单请求的订单插入位置数组
     * @return processedCount 实际处理的请求数量
     */
    function batchProcessRequests(
        uint256[] calldata requestIds,
        uint256[] calldata insertAfterPrices,
        uint256[] calldata insertAfterOrders
    ) external returns (uint256 processedCount) {
        require(requestIds.length > 0, "Empty request array");
        require(requestIds.length <= 100, "Batch size too large");  // Gas控制：限制批量大小
        require(
            requestIds.length == insertAfterPrices.length &&
            requestIds.length == insertAfterOrders.length,
            "Array length mismatch"
        );

        // 从第一个请求获取tradingPair和quoteToken
        (
            ,
            bytes32 tradingPair,
            ,  // trader
            ,  // orderType
            ,  // isAsk
            ,  // price
            ,  // amount
            // uncancellableDuration
        ) = sequencer.getQueuedRequest(requestIds[0]);

        (, address quoteToken, bool exists) = account.getTradingPair(tradingPair);
        require(exists, "Trading pair not registered");

        // 开始batch，记录提交者
        account.startBatch(msg.sender);

        processedCount = 0;

        for (uint256 i = 0; i < requestIds.length; i++) {
            uint256 requestId = requestIds[i];

            // 验证请求在队列头部
            if (!sequencer.isHeadRequest(requestId)) {
                break;  // 如果不是头部，停止处理
            }

            // 获取请求信息
            (
                ISequencer.RequestType requestType,
                ,  // tradingPair
                ,  // trader
                ,  // orderType
                ,  // isAsk
                ,  // price
                ,  // amount
                // uncancellableDuration
            ) = sequencer.getQueuedRequest(requestId);

            // 根据请求类型处理
            if (uint8(requestType) == 0) {
                // PlaceOrder请求
                _batchProcessPlaceOrder(requestId, insertAfterPrices[i], insertAfterOrders[i]);
            } else if (uint8(requestType) == 1) {
                // RemoveOrder请求
                _batchProcessRemoveOrder(requestId);
            } else {
                break;  // 未知类型，停止处理
            }

            processedCount++;
        }

        // 结束batch，分配费用
        uint256 submitterReward = account.endBatch(quoteToken);

        // 处理完成后递增matchId
        if (processedCount > 0) {
            matchId++;
            emit BatchProcessed(msg.sender, matchId, processedCount, submitterReward);
        }

        return processedCount;
    }

    /**
     * @dev 批量处理下单请求
     */
    function _batchProcessPlaceOrder(
        uint256 requestId,
        uint256 insertAfterPrice,
        uint256 insertAfterOrder
    ) internal {
        // 获取请求信息
        (
            ,  // requestType
            bytes32 tradingPair,
            address trader,
            ISequencer.OrderType orderType,
            bool isAsk,
            uint256 price,
            uint256 amount,
            uint256 uncancellableDuration
        ) = sequencer.getQueuedRequest(requestId);

        if (uint8(orderType) == 0) {
            // 限价单
            uint256 priceLevelId = _findOrCreatePriceLevel(
                tradingPair,
                isAsk,
                price,
                insertAfterPrice
            );

            Order storage order = orders[requestId];
            order.id = requestId;
            order.trader = trader;
            order.amount = amount;
            order.filledAmount = 0;
            order.isMarketOrder = false;
            order.isAsk = isAsk;
            order.priceLevel = priceLevelId;
            order.createdAt = block.timestamp;
            order.uncancellableDuration = uncancellableDuration;

            orderTradingPairs[requestId] = tradingPair;
            _insertOrderIntoPriceLevel(tradingPair, priceLevelId, requestId, insertAfterOrder, isAsk);

            sequencer.processRequest(requestId);
            emit OrderInserted(tradingPair, requestId, isAsk, price, amount);

            // 自动尝试匹配
            _tryMatchAfterInsertion(tradingPair, requestId, isAsk);
        } else {
            // 市价单 - 总是插入到队尾
            Order storage order = orders[requestId];
            order.id = requestId;
            order.trader = trader;
            order.amount = amount;
            order.filledAmount = 0;
            order.isMarketOrder = true;
            order.isAsk = isAsk;
            order.priceLevel = EMPTY;
            order.createdAt = block.timestamp;
            order.uncancellableDuration = 0;  // 市价单不需要不可撤销时长

            orderTradingPairs[requestId] = tradingPair;
            _insertMarketOrderAtTail(tradingPair, isAsk, requestId);

            sequencer.processRequest(requestId);
            emit MarketOrderInserted(tradingPair, requestId, isAsk, amount);

            // 自动尝试匹配
            _tryMatchAfterInsertion(tradingPair, requestId, isAsk);
        }
    }

    /**
     * @dev 批量处理撤单请求
     */
    function _batchProcessRemoveOrder(uint256 requestId) internal {
        // 获取请求信息
        (
            ,  // requestType
            bytes32 tradingPair,
            address trader,
            ,  // orderType
            ,  // isAsk
            uint256 priceOrOrderId,  // 对于 RemoveOrder，这里是 orderIdToRemove
            ,  // amount
            // uncancellableDuration (not used for remove requests)
        ) = sequencer.getQueuedRequest(requestId);

        // 对于撤单请求，price 字段存储的是 orderIdToRemove
        uint256 orderIdToRemove = priceOrOrderId;
        Order storage order = orders[orderIdToRemove];

        // 优雅处理：如果订单不存在，静默返回而不是 revert
        if (order.id == 0) {
            // 订单不存在（可能已被完全成交），直接处理请求并返回
            sequencer.processRequest(requestId);
            emit OrderRemoved(tradingPair, orderIdToRemove);
            return;
        }

        // 验证订单所有权
        require(order.trader == trader, "Not order owner");

        tradingPair = orderTradingPairs[orderIdToRemove];

        // 直接使用 order.isAsk，避免遍历链表
        bool isAsk = order.isAsk;

        if (order.isMarketOrder) {
            // 市价单
            uint256 remainingAmount = order.amount - order.filledAmount;
            if (remainingAmount > 0) {
                account.unlockFunds(
                    order.trader,
                    tradingPair,
                    isAsk,
                    0,
                    remainingAmount,
                    orderIdToRemove
                );
            }
            _removeMarketOrderFromList(tradingPair, orderIdToRemove, isAsk);
        } else {
            // 限价单
            uint256 priceLevelId = order.priceLevel;

            // 使用composite key访问priceLevel
            bytes32 levelKey = _getPriceLevelKey(tradingPair, priceLevelId, isAsk);
            PriceLevel storage priceLevel = priceLevels[levelKey];

            uint256 remainingAmount = order.amount - order.filledAmount;
            if (remainingAmount > 0) {
                account.unlockFunds(
                    order.trader,
                    tradingPair,
                    isAsk,
                    priceLevel.price,
                    remainingAmount,
                    orderIdToRemove
                );
            }

            _removeOrderFromPriceLevel(tradingPair, priceLevelId, orderIdToRemove, isAsk);

            if (priceLevel.headOrderId == EMPTY) {
                _removePriceLevel(tradingPair, priceLevelId, isAsk);
            }
        }

        delete orderTradingPairs[orderIdToRemove];
        delete orders[orderIdToRemove];

        sequencer.processRequest(requestId);
        emit OrderRemoved(tradingPair, orderIdToRemove);
    }

    /**
     * @dev 判断价格层级是否为ask
     */
    function _isAskOrder(bytes32 tradingPair, OrderBookData storage book, uint256 priceLevelId) internal view returns (bool) {
        // 遍历ask列表
        uint256 currentLevel = book.askHead;
        while (currentLevel != EMPTY) {
            if (currentLevel == priceLevelId) {
                return true;
            }
            // 使用ask侧的composite key访问priceLevels
            bytes32 levelKey = _getPriceLevelKey(tradingPair, currentLevel, true);
            currentLevel = priceLevels[levelKey].nextPrice;
        }
        return false;
    }

    /**
     * @dev 判断市价单是否为卖单（通过检查在哪个列表中）
     */
    function _isMarketAskOrder(OrderBookData storage book, uint256 orderId) internal view returns (bool) {
        // 遍历市价卖单列表
        uint256 currentOrderId = book.marketAskHead;
        while (currentOrderId != EMPTY) {
            if (currentOrderId == orderId) {
                return true;
            }
            currentOrderId = orders[currentOrderId].nextOrderId;
        }
        return false;
    }

    /**
     * @dev 查找或创建价格层级
     * @param insertAfterPrice 前一个价格层级的价格值（0表示插入到头部）
     * @return price 返回价格值（现在price本身就是key）
     */
    function _findOrCreatePriceLevel(
        bytes32 tradingPair,
        bool isAsk,
        uint256 price,
        uint256 insertAfterPrice
    ) internal returns (uint256) {
        // 生成composite key来访问priceLevels映射
        bytes32 levelKey = _getPriceLevelKey(tradingPair, price, isAsk);

        // 直接检查该price是否已存在
        if (priceLevels[levelKey].price != 0) {
            // 价格层级已存在
            return price;  // 返回纯价格(不含side标志)
        }

        // 创建新的价格层级，使用composite key存储
        PriceLevel storage newPriceLevel = priceLevels[levelKey];
        newPriceLevel.price = price;  // 存储纯价格
        newPriceLevel.totalVolume = 0;
        newPriceLevel.headOrderId = EMPTY;
        newPriceLevel.tailOrderId = EMPTY;

        // 插入价格层级到列表中
        _insertPriceLevelIntoList(tradingPair, isAsk, price, insertAfterPrice);

        emit PriceLevelCreated(tradingPair, price, isAsk);

        return price;  // 返回纯价格(不含side标志)
    }

    /**
     * @dev 将价格层级插入到列表中，并验证排序
     * @param insertAfterPrice 前一个价格层级的价格值（0表示插入到头部）
     */
    function _insertPriceLevelIntoList(
        bytes32 tradingPair,
        bool isAsk,
        uint256 price,  // 纯价格(不含side标志)
        uint256 insertAfterPrice  // 纯价格(不含side标志)
    ) internal {
        OrderBookData storage book = orderBooks[tradingPair];

        // 使用composite key访问priceLevels
        bytes32 levelKey = _getPriceLevelKey(tradingPair, price, isAsk);
        PriceLevel storage newPriceLevel = priceLevels[levelKey];

        if (insertAfterPrice == EMPTY) {
            // 插入到头部
            uint256 oldHead = isAsk ? book.askHead : book.bidHead;

            if (oldHead != EMPTY) {
                bytes32 oldHeadKey = _getPriceLevelKey(tradingPair, oldHead, isAsk);

                // 验证排序：新价格层级应该小于等于原头部（ask）或大于等于原头部（bid）
                if (isAsk) {
                    require(newPriceLevel.price <= priceLevels[oldHeadKey].price, "Invalid insertion position: price too high for ask head");
                } else {
                    require(newPriceLevel.price >= priceLevels[oldHeadKey].price, "Invalid insertion position: price too low for bid head");
                }

                priceLevels[oldHeadKey].prevPrice = price;
                newPriceLevel.nextPrice = oldHead;
            } else {
                // 列表为空，同时设置tail
                if (isAsk) {
                    book.askTail = price;
                } else {
                    book.bidTail = price;
                }
            }

            if (isAsk) {
                book.askHead = price;
            } else {
                book.bidHead = price;
            }
        } else {
            // 使用composite key检查insertAfterPrice是否存��
            bytes32 insertAfterKey = _getPriceLevelKey(tradingPair, insertAfterPrice, isAsk);
            require(priceLevels[insertAfterKey].price != 0, "Previous price level does not exist");

            PriceLevel storage prevPriceLevel = priceLevels[insertAfterKey];
            uint256 nextPrice = prevPriceLevel.nextPrice;

            // 验证排序
            if (isAsk) {
                // Ask: 价格递增
                require(newPriceLevel.price >= prevPriceLevel.price, "Invalid insertion position: price lower than previous");
                if (nextPrice != EMPTY) {
                    bytes32 nextPriceKey = _getPriceLevelKey(tradingPair, nextPrice, isAsk);
                    require(newPriceLevel.price <= priceLevels[nextPriceKey].price, "Invalid insertion position: price higher than next");
                }
            } else {
                // Bid: 价格递减
                require(newPriceLevel.price <= prevPriceLevel.price, "Invalid insertion position: price higher than previous");
                if (nextPrice != EMPTY) {
                    bytes32 nextPriceKey = _getPriceLevelKey(tradingPair, nextPrice, isAsk);
                    require(newPriceLevel.price >= priceLevels[nextPriceKey].price, "Invalid insertion position: price lower than next");
                }
            }

            // 插入节点
            newPriceLevel.prevPrice = insertAfterPrice;
            newPriceLevel.nextPrice = nextPrice;
            prevPriceLevel.nextPrice = price;

            if (nextPrice != EMPTY) {
                bytes32 nextPriceKey = _getPriceLevelKey(tradingPair, nextPrice, isAsk);
                priceLevels[nextPriceKey].prevPrice = price;
            } else {
                // 插入到尾部
                if (isAsk) {
                    book.askTail = price;
                } else {
                    book.bidTail = price;
                }
            }
        }
    }

    /**
     * @dev 将订单插入到价格层级的订单列表中
     * FIFO 强制：新订单必须插入到尾部
     * - 如果价格层级为空，insertAfterOrder 必须为 0
     * - 如果价格层级不为空，insertAfterOrder 必须等于 tailOrderId
     */
    function _insertOrderIntoPriceLevel(
        bytes32 tradingPair,
        uint256 priceLevelId,
        uint256 orderId,
        uint256 insertAfterOrder,
        bool isAsk
    ) internal {
        bytes32 levelKey = _getPriceLevelKey(tradingPair, priceLevelId, isAsk);
        PriceLevel storage priceLevel = priceLevels[levelKey];
        Order storage order = orders[orderId];

        uint256 oldTail = priceLevel.tailOrderId;

        if (oldTail == EMPTY) {
            // 价格层级为空，insertAfterOrder 必须为 0
            require(insertAfterOrder == EMPTY, "FIFO: insertAfterOrder must be 0 for empty level");
            // 新订单既是头也是尾
            priceLevel.headOrderId = orderId;
            priceLevel.tailOrderId = orderId;
        } else {
            // 价格层级不为空，insertAfterOrder 必须等于 tailOrderId（强制 FIFO）
            require(insertAfterOrder == oldTail, "FIFO: insertAfterOrder must equal tailOrderId");
            // 插入到尾部
            orders[oldTail].nextOrderId = orderId;
            order.prevOrderId = oldTail;
            priceLevel.tailOrderId = orderId;
        }

        // 更新价格层级的总挂单量
        priceLevel.totalVolume += order.amount;
    }

    /**
     * @dev 从价格层级的订单列表中移除订单
     */
    function _removeOrderFromPriceLevel(
        bytes32 tradingPair,
        uint256 priceLevelId,
        uint256 orderId,
        bool isAsk
    ) internal {
        bytes32 levelKey = _getPriceLevelKey(tradingPair, priceLevelId, isAsk);
        PriceLevel storage priceLevel = priceLevels[levelKey];
        Order storage order = orders[orderId];

        uint256 prevOrderId = order.prevOrderId;
        uint256 nextOrderId = order.nextOrderId;

        if (prevOrderId != EMPTY) {
            orders[prevOrderId].nextOrderId = nextOrderId;
        } else {
            // 这是头节点
            priceLevel.headOrderId = nextOrderId;
        }

        if (nextOrderId != EMPTY) {
            orders[nextOrderId].prevOrderId = prevOrderId;
        } else {
            // 这是尾节点
            priceLevel.tailOrderId = prevOrderId;
        }

        // 更新价格层级的总挂单量
        priceLevel.totalVolume -= (order.amount - order.filledAmount);
    }

    /**
     * @dev 从列表中移除价格层级
     */
    function _removePriceLevel(
        bytes32 tradingPair,
        uint256 priceLevelId,
        bool isAsk
    ) internal {
        OrderBookData storage book = orderBooks[tradingPair];
        bytes32 levelKey = _getPriceLevelKey(tradingPair, priceLevelId, isAsk);
        PriceLevel storage priceLevel = priceLevels[levelKey];

        uint256 prevPriceLevelId = priceLevel.prevPrice;
        uint256 nextPriceLevelId = priceLevel.nextPrice;

        if (prevPriceLevelId != EMPTY) {
            bytes32 prevKey = _getPriceLevelKey(tradingPair, prevPriceLevelId, isAsk);
            priceLevels[prevKey].nextPrice = nextPriceLevelId;
        } else {
            // 这是头节点
            if (isAsk) {
                book.askHead = nextPriceLevelId;
            } else {
                book.bidHead = nextPriceLevelId;
            }
        }

        if (nextPriceLevelId != EMPTY) {
            bytes32 nextKey = _getPriceLevelKey(tradingPair, nextPriceLevelId, isAsk);
            priceLevels[nextKey].prevPrice = prevPriceLevelId;
        } else {
            // 这是尾节点
            if (isAsk) {
                book.askTail = prevPriceLevelId;
            } else {
                book.bidTail = prevPriceLevelId;
            }
        }

        // 删除价格层级
        delete priceLevels[levelKey];

        emit PriceLevelRemoved(tradingPair, priceLevelId, isAsk);
    }

    // ============ 查询函数 ============

    /**
     * @notice 检查订单是否可以被撤销
     * @param orderId 订单ID
     * @return 如果订单已过不可撤销期则返回true，否则返回false
     */
    function isOrderCancellable(uint256 orderId) external view returns (bool) {
        Order storage order = orders[orderId];
        if (order.id == 0) {
            return false;  // 订单不存在
        }
        // 如果当前时间 >= 订单创建时间 + 不可撤销时长，则可以撤销
        return block.timestamp >= order.createdAt + order.uncancellableDuration;
    }

    /**
     * @notice 获取订单的交易者地址
     * @param orderId 订单ID
     * @return 交易者地址
     */
    function getOrderTrader(uint256 orderId) external view returns (address) {
        return orders[orderId].trader;
    }

    /**
     * @notice 获取交易对的订单簿快照
     */
    function getOrderBookSnapshot(bytes32 tradingPair, bool isAsk, uint256 depth)
        external
        view
        returns (uint256[] memory prices, uint256[] memory volumes)
    {
        prices = new uint256[](depth);
        volumes = new uint256[](depth);

        OrderBookData storage book = orderBooks[tradingPair];
        uint256 currentPriceLevelId = isAsk ? book.askHead : book.bidHead;

        for (uint256 i = 0; i < depth && currentPriceLevelId != EMPTY; i++) {
            bytes32 levelKey = _getPriceLevelKey(tradingPair, currentPriceLevelId, isAsk);
            PriceLevel storage priceLevel = priceLevels[levelKey];
            prices[i] = priceLevel.price;
            volumes[i] = priceLevel.totalVolume;
            currentPriceLevelId = priceLevel.nextPrice;
        }

        return (prices, volumes);
    }

    /**
     * @notice 获取最优价格
     */
    function getBestPrice(bytes32 tradingPair, bool isAsk) external view returns (uint256) {
        OrderBookData storage book = orderBooks[tradingPair];
        uint256 headPriceLevelId = isAsk ? book.askHead : book.bidHead;

        if (headPriceLevelId == EMPTY) {
            return 0;
        }

        bytes32 levelKey = _getPriceLevelKey(tradingPair, headPriceLevelId, isAsk);
        return priceLevels[levelKey].price;
    }

    // ============ 市价单相关函数 ============

    /**
     * @notice 插入市价单到订单簿（总是插入到队尾，保证FIFO）
     * @param sequencerOrderId Sequencer中的订单ID
     */
    function insertMarketOrder(
        uint256 sequencerOrderId
    ) external {
        // 验证该订单是Sequencer队列的头部
        require(sequencer.isHeadOrder(sequencerOrderId), "Order is not at head of sequencer queue");

        // 从Sequencer获取订单信息
        (
            bytes32 tradingPair,
            address trader,
            uint8 orderType,
            bool isAsk,
            ,  // price
            uint256 amount,
            // uncancellableDuration (市价单不需要)
        ) = sequencer.getQueuedOrder(sequencerOrderId);

        // 验证是市价单
        require(orderType == 1, "Not a market order");
        require(amount > 0, "Amount must be greater than 0");

        // 创建新的市价单，使用Sequencer的订单ID
        Order storage order = orders[sequencerOrderId];
        order.id = sequencerOrderId;
        order.trader = trader;
        order.amount = amount;
        order.filledAmount = 0;
        order.isMarketOrder = true;
        order.isAsk = isAsk;
        order.priceLevel = EMPTY;  // 市价单不需要价格层级
        order.createdAt = block.timestamp;
        order.uncancellableDuration = 0;  // 市价单不需要不可撤销时长

        // 记录订单对应的交易对
        orderTradingPairs[sequencerOrderId] = tradingPair;

        // 将订单插入到市价单队尾（FIFO）
        _insertMarketOrderAtTail(tradingPair, isAsk, sequencerOrderId);

        // 从Sequencer中处理该请求
        sequencer.processRequest(sequencerOrderId);

        emit MarketOrderInserted(tradingPair, sequencerOrderId, isAsk, amount);

        // 自动尝试匹配（市价单总是会立即匹配）
        _tryMatchAfterInsertion(tradingPair, sequencerOrderId, isAsk);
    }

    /**
     * @dev 将市价单插入到队尾（FIFO保证）
     */
    function _insertMarketOrderAtTail(
        bytes32 tradingPair,
        bool isAsk,
        uint256 orderId
    ) internal {
        OrderBookData storage book = orderBooks[tradingPair];
        Order storage order = orders[orderId];

        uint256 oldTail = isAsk ? book.marketAskTail : book.marketBidTail;

        if (oldTail == EMPTY) {
            // 列表为空，设置为head和tail
            if (isAsk) {
                book.marketAskHead = orderId;
                book.marketAskTail = orderId;
            } else {
                book.marketBidHead = orderId;
                book.marketBidTail = orderId;
            }
        } else {
            // 插入到队尾
            orders[oldTail].nextOrderId = orderId;
            order.prevOrderId = oldTail;

            if (isAsk) {
                book.marketAskTail = orderId;
            } else {
                book.marketBidTail = orderId;
            }
        }
    }

    /**
     * @dev 从市价单列表中移除订单
     */
    function _removeMarketOrderFromList(
        bytes32 tradingPair,
        uint256 orderId,
        bool isAsk
    ) internal {
        OrderBookData storage book = orderBooks[tradingPair];
        Order storage order = orders[orderId];

        uint256 prevOrderId = order.prevOrderId;
        uint256 nextOrderId = order.nextOrderId;

        if (prevOrderId != EMPTY) {
            orders[prevOrderId].nextOrderId = nextOrderId;
        } else {
            // 这是头节点
            if (isAsk) {
                book.marketAskHead = nextOrderId;
            } else {
                book.marketBidHead = nextOrderId;
            }
        }

        if (nextOrderId != EMPTY) {
            orders[nextOrderId].prevOrderId = prevOrderId;
        } else {
            // 这是尾节点
            if (isAsk) {
                book.marketAskTail = prevOrderId;
            } else {
                book.marketBidTail = prevOrderId;
            }
        }
    }

    /**
     * @notice 获取市价单列表快照
     */
    function getMarketOrderSnapshot(bytes32 tradingPair, bool isAsk, uint256 depth)
        external
        view
        returns (uint256[] memory orderIds, uint256[] memory amounts)
    {
        orderIds = new uint256[](depth);
        amounts = new uint256[](depth);

        OrderBookData storage book = orderBooks[tradingPair];
        uint256 currentOrderId = isAsk ? book.marketAskHead : book.marketBidHead;

        for (uint256 i = 0; i < depth && currentOrderId != EMPTY; i++) {
            Order storage order = orders[currentOrderId];
            orderIds[i] = order.id;
            amounts[i] = order.amount - order.filledAmount;
            currentOrderId = order.nextOrderId;
        }

        return (orderIds, amounts);
    }

    // ============ 撮合引擎 ============

    /**
     * @dev 插入订单后自动尝试匹配
     * @param tradingPair 交易对
     * @param newOrderId 新插入的订单ID
     * @param isAsk 是否是卖单
     */
    function _tryMatchAfterInsertion(
        bytes32 tradingPair,
        uint256 newOrderId,
        bool isAsk
    ) internal {
        // 尝试匹配最多 50 次
        // 每次撮合约消耗 50,000-100,000 gas
        // 50次 ≈ 2.5M-5M gas，BSC上约 $0.15-0.50
        uint256 maxIterations = 50;

        // 匹配限价单
        _matchOrdersInternal(tradingPair, maxIterations);

        // 匹配市价单
        _matchMarketOrdersInternal(tradingPair, maxIterations);
    }

    /**
     * @dev 内部撮合逻辑
     * @param tradingPair 交易对标识符
     * @param maxIterations 最大撮合次数
     * @return totalTrades 成交的交易数量
     */
    function _matchOrdersInternal(bytes32 tradingPair, uint256 maxIterations) internal returns (uint256 totalTrades) {
        OrderBookData storage book = orderBooks[tradingPair];
        totalTrades = 0;

        for (uint256 i = 0; i < maxIterations; i++) {
            // 获取最优买价和卖价
            uint256 bidPriceLevelId = book.bidHead;
            uint256 askPriceLevelId = book.askHead;

            // 如果任意一方为空，停止撮合
            if (bidPriceLevelId == EMPTY || askPriceLevelId == EMPTY) {
                break;
            }

            bytes32 bidLevelKey = _getPriceLevelKey(tradingPair, bidPriceLevelId, false);
            bytes32 askLevelKey = _getPriceLevelKey(tradingPair, askPriceLevelId, true);
            PriceLevel storage bidPriceLevel = priceLevels[bidLevelKey];
            PriceLevel storage askPriceLevel = priceLevels[askLevelKey];

            // 检查是否可以成交：买价 >= 卖价
            if (bidPriceLevel.price < askPriceLevel.price) {
                break;
            }

            // 获取该价格层级的第一个订单
            uint256 bidOrderId = bidPriceLevel.headOrderId;
            uint256 askOrderId = askPriceLevel.headOrderId;

            if (bidOrderId == EMPTY || askOrderId == EMPTY) {
                break;
            }

            // 执行撮合
            bool traded = _executeTrade(tradingPair, bidOrderId, askOrderId, bidPriceLevel.price, askPriceLevel.price);

            if (traded) {
                totalTrades++;
            } else {
                break;
            }
        }

        return totalTrades;
    }

    /**
     * @dev 执行单笔交易
     * @param tradingPair 交易对
     * @param bidOrderId 买单ID
     * @param askOrderId 卖单ID
     * @param bidPrice 买单价格
     * @param askPrice 卖单价格
     * @return 是否成功成交
     */
    function _executeTrade(
        bytes32 tradingPair,
        uint256 bidOrderId,
        uint256 askOrderId,
        uint256 bidPrice,
        uint256 askPrice
    ) internal returns (bool) {
        Order storage bidOrder = orders[bidOrderId];
        Order storage askOrder = orders[askOrderId];

        // 检查订单有效性
        if (bidOrder.id == 0 || askOrder.id == 0) {
            return false;
        }

        // 成交价格：按时间优先原则，maker（先挂单）的价格成交
        // orderId 较小的是 maker（先挂单），较大的是 taker（后挂单）
        uint256 tradePrice;
        if (bidOrderId < askOrderId) {
            // 买单先挂，按买单价格成交
            tradePrice = bidPrice;
        } else {
            // 卖单先挂，按卖单价格成交
            tradePrice = askPrice;
        }

        // 计算可成交数量
        uint256 bidRemaining;
        bool isBidMarketOrder = bidOrder.isMarketOrder;

        if (isBidMarketOrder) {
            // 市价买单：amount是quote tokens（要花费的计价代币）
            // 需要转换为可购买的base tokens数量
            uint256 quoteRemaining = bidOrder.amount - bidOrder.filledAmount;
            // bidRemaining = quoteRemaining / tradePrice (with precision handling)
            bidRemaining = (quoteRemaining * TradingConstants.PRICE_DECIMALS) / tradePrice;
        } else {
            // 限价买单：amount是base tokens
            bidRemaining = bidOrder.amount - bidOrder.filledAmount;
        }

        uint256 askRemaining = askOrder.amount - askOrder.filledAmount;
        uint256 tradeAmount = bidRemaining < askRemaining ? bidRemaining : askRemaining;

        if (tradeAmount == 0) {
            // tradeAmount == 0 可能有两种情况：
            // 1. 订单已精确成交完毕（filledAmount == amount）
            // 2. 由于精度问题，剩余数量在转换后向下取整为0（常见于市价买单）
            //
            // 对于情况2，订单可能已成交99.99%但无法继续成交，
            // 如果剩余价值低于 DUST_THRESHOLD（0.01 USDC），应视为完全成交并移除订单，
            // 避免订单一直卡在 OPEN 状态占用系统资源

            bool bidShouldClose = _isOrderFullyFilled(bidOrder, tradePrice);
            bool askShouldClose = _isOrderFullyFilled(askOrder, tradePrice);

            // 如果买单应该关闭但尚未精确成交完毕，发出事件并移除
            if (bidShouldClose && bidOrder.filledAmount < bidOrder.amount) {
                // 发出 OrderFilled 事件，本次成交量为0，标记为完全成交
                emit OrderFilled(tradingPair, bidOrderId, 0, 0, true);
                _removeFilledOrder(tradingPair, bidOrderId, false);
            }

            // 如果卖单应该关闭但尚未精确成交完毕，发出事件并移除
            if (askShouldClose && askOrder.filledAmount < askOrder.amount) {
                emit OrderFilled(tradingPair, askOrderId, 0, 0, true);
                _removeFilledOrder(tradingPair, askOrderId, true);
            }

            return false;
        }

        // 更新订单已成交数量
        uint256 bidFilledIncrement;
        if (isBidMarketOrder) {
            // 市价买单：filledAmount追踪已花费的quote tokens
            bidFilledIncrement = (tradeAmount * tradePrice) / TradingConstants.PRICE_DECIMALS;
            bidOrder.filledAmount += bidFilledIncrement;
        } else {
            bidFilledIncrement = tradeAmount;
            bidOrder.filledAmount += bidFilledIncrement;
        }
        askOrder.filledAmount += tradeAmount;

        // 更新价格层级的总挂单量
        if (!bidOrder.isMarketOrder) {
            bytes32 bidLevelKey = _getPriceLevelKey(tradingPair, bidOrder.priceLevel, false);
            PriceLevel storage bidPriceLevel = priceLevels[bidLevelKey];
            bidPriceLevel.totalVolume -= tradeAmount;
        }
        if (!askOrder.isMarketOrder) {
            bytes32 askLevelKey = _getPriceLevelKey(tradingPair, askOrder.priceLevel, true);
            PriceLevel storage askPriceLevel = priceLevels[askLevelKey];
            askPriceLevel.totalVolume -= tradeAmount;
        }

        // 执行资金转移
        account.transferFunds(
            tradingPair,
            bidOrder.trader,  // 买方
            askOrder.trader,  // 卖方
            tradePrice,
            tradeAmount,
            bidOrder.isMarketOrder  // 是否为市价买单
        );

        // 触发成交事件
        emit Trade(
            tradingPair,
            bidOrderId,
            askOrderId,
            bidOrder.trader,
            askOrder.trader,
            tradePrice,
            tradeAmount
        );

        // 计算 quote amount (用于事件)
        uint256 quoteAmount = (tradeAmount * tradePrice) / TradingConstants.PRICE_DECIMALS;

        // 检查订单是否完全成交（使用灰尘阈值判断）
        bool bidFullyFilled = _isOrderFullyFilled(bidOrder, tradePrice);
        bool askFullyFilled = _isOrderFullyFilled(askOrder, tradePrice);

        // 先触发 OrderFilled 事件，再移除订单
        // 这确保事件顺序为: OrderFilled -> PriceLevelRemoved
        // 买单: quoteAmount=花费的quote tokens, baseAmount=获得的base tokens
        emit OrderFilled(tradingPair, bidOrderId, quoteAmount, tradeAmount, bidFullyFilled);
        // 卖单: quoteAmount=获得的quote tokens, baseAmount=卖出的base tokens
        emit OrderFilled(tradingPair, askOrderId, quoteAmount, tradeAmount, askFullyFilled);

        // 移除已完全成交的订单（会触发 PriceLevelRemoved 事件）
        if (bidFullyFilled) {
            _removeFilledOrder(tradingPair, bidOrderId, false);
        }
        if (askFullyFilled) {
            _removeFilledOrder(tradingPair, askOrderId, true);
        }

        return true;
    }

    /**
     * @dev 判断订单是否完全成交（使用灰尘阈值）
     * 当剩余未成交部分的价值低于 DUST_THRESHOLD 时，视为完全成交
     * @param order 订单
     * @param tradePrice 成交价格
     * @return 是否完全成交
     */
    function _isOrderFullyFilled(Order storage order, uint256 tradePrice) internal view returns (bool) {
        // 精确相等时直接返回
        if (order.filledAmount >= order.amount) {
            return true;
        }

        // 计算剩余未成交部分的 quote value
        uint256 remainingQuoteValue;
        if (order.isMarketOrder && !order.isAsk) {
            // 市价买单：amount 和 filledAmount 都是 quote tokens
            remainingQuoteValue = order.amount - order.filledAmount;
        } else {
            // 限价买单、限价卖单、市价卖单：amount 和 filledAmount 都是 base tokens
            uint256 remainingBase = order.amount - order.filledAmount;
            remainingQuoteValue = (remainingBase * tradePrice) / TradingConstants.PRICE_DECIMALS;
        }

        // 如果剩余价值低于灰尘阈值，视为完全成交
        return remainingQuoteValue < TradingConstants.DUST_THRESHOLD;
    }

    /**
     * @dev 移除已完全成交的订单
     * @param tradingPair 交易对
     * @param orderId 订单ID
     * @param isAsk 是否为卖单
     */
    function _removeFilledOrder(bytes32 tradingPair, uint256 orderId, bool isAsk) internal {
        Order storage order = orders[orderId];

        // 计算剩余锁定资金（灰尘）并转给协议
        uint256 remainingAmount = order.amount - order.filledAmount;
        if (remainingAmount > 0) {
            // 获取交易对信息
            (address baseToken, address quoteToken, ) = account.getTradingPair(tradingPair);

            // 确定要收取的代币
            address feeToken;
            uint256 feeAmount;

            if (order.isMarketOrder && !isAsk) {
                // 市价买单：剩余的是 quote tokens
                feeToken = quoteToken;
                feeAmount = remainingAmount;
            } else if (isAsk) {
                // 卖单（限价或市价）：剩余的是 base tokens
                feeToken = baseToken;
                feeAmount = remainingAmount;
            } else {
                // 限价买单：剩余的是 base tokens（但锁定的是 quote tokens）
                // 需要计算剩余的 quote tokens
                bytes32 levelKey = _getPriceLevelKey(tradingPair, order.priceLevel, false);
                uint256 price = priceLevels[levelKey].price;
                feeToken = quoteToken;
                feeAmount = (remainingAmount * price) / TradingConstants.PRICE_DECIMALS;
            }

            if (feeAmount > 0) {
                // 解锁资金并转给协议
                account.collectDustToProtocol(
                    order.trader,
                    tradingPair,
                    isAsk,
                    order.isMarketOrder ? 0 : order.priceLevel,
                    remainingAmount,
                    orderId
                );

                // 累计协议费用
                protocolFees[feeToken] += feeAmount;
                emit ProtocolFeeCollected(feeToken, feeAmount);
            }
        }

        if (order.isMarketOrder) {
            // 市价单：从市价单列表中移除
            _removeMarketOrderFromList(tradingPair, orderId, isAsk);
        } else {
            // 限价单：从价格层级中移除
            uint256 priceLevelId = order.priceLevel;
            _removeOrderFromPriceLevel(tradingPair, priceLevelId, orderId, isAsk);

            // 如果价格层级没有订单了，删除该价格层级
            bytes32 levelKey = _getPriceLevelKey(tradingPair, priceLevelId, isAsk);
            PriceLevel storage priceLevel = priceLevels[levelKey];
            if (priceLevel.headOrderId == EMPTY) {
                _removePriceLevel(tradingPair, priceLevelId, isAsk);
            }
        }

        // 删除订单交易对记录
        delete orderTradingPairs[orderId];

        // 通知 Sequencer 订单已从 OrderBook 移除
        sequencer.markOrderRemovedFromBook(orderId);

        // 删除订单数据
        delete orders[orderId];
    }

    /**
     * @dev 内部市价单撮合逻辑
     * @param tradingPair 交易对标识符
     * @param maxIterations 最大撮合次数
     * @return totalTrades 成交的交易数量
     */
    function _matchMarketOrdersInternal(bytes32 tradingPair, uint256 maxIterations) internal returns (uint256 totalTrades) {
        OrderBookData storage book = orderBooks[tradingPair];
        totalTrades = 0;

        for (uint256 i = 0; i < maxIterations; i++) {
            bool traded = false;

            // 优先撮合市价买单（与最优卖价）
            if (book.marketBidHead != EMPTY && book.askHead != EMPTY) {
                uint256 marketBidOrderId = book.marketBidHead;
                bytes32 askLevelKey = _getPriceLevelKey(tradingPair, book.askHead, true);
                PriceLevel storage askPriceLevel = priceLevels[askLevelKey];
                uint256 askOrderId = askPriceLevel.headOrderId;

                if (askOrderId != EMPTY) {
                    traded = _executeTrade(
                        tradingPair,
                        marketBidOrderId,
                        askOrderId,
                        askPriceLevel.price,  // 市价单使用对手价
                        askPriceLevel.price
                    );
                    if (traded) {
                        totalTrades++;
                        continue;
                    }
                }
            }

            // 撮合市价卖单（与最优买价）
            if (book.marketAskHead != EMPTY && book.bidHead != EMPTY) {
                uint256 marketAskOrderId = book.marketAskHead;
                bytes32 bidLevelKey = _getPriceLevelKey(tradingPair, book.bidHead, false);
                PriceLevel storage bidPriceLevel = priceLevels[bidLevelKey];
                uint256 bidOrderId = bidPriceLevel.headOrderId;

                if (bidOrderId != EMPTY) {
                    traded = _executeTrade(
                        tradingPair,
                        bidOrderId,
                        marketAskOrderId,
                        bidPriceLevel.price,
                        bidPriceLevel.price   // 市价单使用对手价
                    );
                    if (traded) {
                        totalTrades++;
                        continue;
                    }
                }
            }

            // 如果没有成交，退出循环
            if (!traded) {
                break;
            }
        }

        return totalTrades;
    }

    /**
     * @notice 综合撮合接口，先撮合限价单再撮合市价单
     * @dev 供 matcher 使用，当 maxIteration 达到后继续撮合剩余可匹配的订单
     * @param tradingPair 交易对标识符
     * @param maxIterations 最大撮合次数（限价单和市价单各自的最大次数）
     * @return limitTrades 限价单成交数量
     * @return marketTrades 市价单成交数量
     */
    function matchAll(bytes32 tradingPair, uint256 maxIterations) external returns (uint256 limitTrades, uint256 marketTrades) {
        // 获取quoteToken用于费用分配
        (, address quoteToken, bool exists) = account.getTradingPair(tradingPair);
        require(exists, "Trading pair not registered");

        // 开始batch，记录提交者
        account.startBatch(msg.sender);

        // 先撮合限价单
        limitTrades = _matchOrdersInternal(tradingPair, maxIterations);

        // 再撮合市价单
        marketTrades = _matchMarketOrdersInternal(tradingPair, maxIterations);

        // 结束batch，分配费用
        uint256 submitterReward = account.endBatch(quoteToken);

        // 只有在有成交时才更新 matchId
        uint256 totalTrades = limitTrades + marketTrades;
        if (totalTrades > 0) {
            matchId++;
            emit BatchProcessed(msg.sender, matchId, totalTrades, submitterReward);
        }

        return (limitTrades, marketTrades);
    }

}
