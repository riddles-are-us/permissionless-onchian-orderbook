// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./ISequencer.sol";
import "./IAccount.sol";

contract OrderBook {

    // 订单结构
    struct Order {
        uint256 id;
        address trader;
        uint256 amount;
        uint256 filledAmount;
        bool isMarketOrder;  // true表示市价单，false表示限价单
        uint256 priceLevel;  // 该订单所属的价格（限价单使用，直接存储price值）
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
    mapping(uint256 => PriceLevel) public priceLevels;  // (price | side_flag) => PriceLevel
    // 使用复合key: Ask订单使用price本身, Bid订单使用 price | (1 << 255)
    mapping(uint256 => Order) public orders;

    // Sequencer合约引用
    ISequencer public sequencer;

    // Account合约引用
    IAccount public account;

    // 常量表示空节点
    uint256 constant EMPTY = 0;

    // 存储交易对对应的订单簿ID（用于资金转移）
    mapping(uint256 => bytes32) public orderTradingPairs;

    // 事件
    event OrderInserted(bytes32 indexed tradingPair, uint256 indexed orderId, bool isAsk, uint256 price, uint256 amount);
    event OrderRemoved(bytes32 indexed tradingPair, uint256 indexed orderId);
    event MarketOrderInserted(bytes32 indexed tradingPair, uint256 indexed orderId, bool isAsk, uint256 amount);
    event MarketOrderRemoved(bytes32 indexed tradingPair, uint256 indexed orderId);
    event PriceLevelCreated(bytes32 indexed tradingPair, uint256 indexed price, bool isAsk);
    event PriceLevelRemoved(bytes32 indexed tradingPair, uint256 indexed price);
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
    event OrderFilled(bytes32 indexed tradingPair, uint256 indexed orderId, uint256 filledAmount, bool isFullyFilled);

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
     * @dev 生成价格层级的composite key (编码价格和side)
     * Ask订单使用价格本身, Bid订单使用price | (1 << 255)
     */
    function _getPriceLevelKey(uint256 price, bool isAsk) internal pure returns (uint256) {
        if (isAsk) {
            return price;
        } else {
            return price | (uint256(1) << 255);  // Set the highest bit for bid orders
        }
    }

    /**
     * @notice 获取价格层级信息（public接口，自动处理composite key）
     * @param price 纯价格值
     * @param isAsk 是否为ask侧
     * @return PriceLevel结构
     */
    function getPriceLevel(uint256 price, bool isAsk) public view returns (PriceLevel memory) {
        uint256 key = _getPriceLevelKey(price, isAsk);
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
            uint256 amount
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
        order.priceLevel = priceLevelId;

        // 记录订单对应的交易对（用于撤单和撮合时的资金处理）
        orderTradingPairs[sequencerOrderId] = tradingPair;

        // 将订单插入到价格层级的订单列表中
        _insertOrderIntoPriceLevel(priceLevelId, sequencerOrderId, insertAfterOrder, isAsk);

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
            uint256 _unusedAmount
        ) = sequencer.getQueuedRequest(requestId);

        // 验证是撤单请求
        require(uint8(requestType) == 1, "Not a remove order request");

        // 对于撤单请求，price 字段存储的是 orderIdToRemove
        uint256 orderIdToRemove = priceOrOrderId;
        Order storage order = orders[orderIdToRemove];
        require(order.id != 0, "Order does not exist");
        require(order.trader == trader, "Not order owner");

        // 获取tradingPair（从存储中）
        tradingPair = orderTradingPairs[orderIdToRemove];
        bool isAsk = !order.isMarketOrder ? true : true; // 从订单判断

        // 处理限价单或市价单的删除
        if (order.isMarketOrder) {
            // 市价单
            uint256 remainingAmount = order.amount - order.filledAmount;
            if (remainingAmount > 0) {
                // 市价卖单才锁定了资金
                account.unlockFunds(
                    order.trader,
                    tradingPair,
                    true,  // 市价卖单
                    0,
                    remainingAmount,
                    orderIdToRemove
                );
            }
            // 需要确定isAsk，从orderBook结构推断
            _removeMarketOrderFromList(tradingPair, orderIdToRemove, true);
        } else {
            // 限价单
            uint256 priceLevelId = order.priceLevel;

            // 判断是ask还是bid
            OrderBookData storage book = orderBooks[tradingPair];
            isAsk = _isAskOrder(book, priceLevelId);

            // 使用composite key访问priceLevel
            uint256 levelKey = _getPriceLevelKey(priceLevelId, isAsk);
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

            _removeOrderFromPriceLevel(priceLevelId, orderIdToRemove, isAsk);

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
                // amount
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
            uint256 amount
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
            order.priceLevel = priceLevelId;

            orderTradingPairs[requestId] = tradingPair;
            _insertOrderIntoPriceLevel(priceLevelId, requestId, insertAfterOrder, isAsk);

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
            order.priceLevel = EMPTY;

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
            uint256 _unusedAmount
        ) = sequencer.getQueuedRequest(requestId);

        // 对于撤单请求，price 字段存储的是 orderIdToRemove
        uint256 orderIdToRemove = priceOrOrderId;
        Order storage order = orders[orderIdToRemove];
        require(order.id != 0, "Order does not exist");
        require(order.trader == trader, "Not order owner");

        tradingPair = orderTradingPairs[orderIdToRemove];

        if (order.isMarketOrder) {
            uint256 remainingAmount = order.amount - order.filledAmount;
            if (remainingAmount > 0) {
                account.unlockFunds(
                    order.trader,
                    tradingPair,
                    true,
                    0,
                    remainingAmount,
                    orderIdToRemove
                );
            }
            _removeMarketOrderFromList(tradingPair, orderIdToRemove, true);
        } else {
            uint256 priceLevelId = order.priceLevel;

            OrderBookData storage book = orderBooks[tradingPair];
            bool isAsk = _isAskOrder(book, priceLevelId);

            // 使用composite key访问priceLevel
            uint256 levelKey = _getPriceLevelKey(priceLevelId, isAsk);
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

            _removeOrderFromPriceLevel(priceLevelId, orderIdToRemove, isAsk);

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
    function _isAskOrder(OrderBookData storage book, uint256 priceLevelId) internal view returns (bool) {
        // 遍历ask列表
        uint256 currentLevel = book.askHead;
        while (currentLevel != EMPTY) {
            if (currentLevel == priceLevelId) {
                return true;
            }
            // 使用ask侧的composite key访问priceLevels
            uint256 levelKey = _getPriceLevelKey(currentLevel, true);
            currentLevel = priceLevels[levelKey].nextPrice;
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
        uint256 levelKey = _getPriceLevelKey(price, isAsk);

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
        uint256 levelKey = _getPriceLevelKey(price, isAsk);
        PriceLevel storage newPriceLevel = priceLevels[levelKey];

        if (insertAfterPrice == EMPTY) {
            // 插入到头部
            uint256 oldHead = isAsk ? book.askHead : book.bidHead;

            if (oldHead != EMPTY) {
                uint256 oldHeadKey = _getPriceLevelKey(oldHead, isAsk);

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
            // 使用composite key检查insertAfterPrice是否存在
            uint256 insertAfterKey = _getPriceLevelKey(insertAfterPrice, isAsk);
            require(priceLevels[insertAfterKey].price != 0, "Previous price level does not exist");

            PriceLevel storage prevPriceLevel = priceLevels[insertAfterKey];
            uint256 nextPrice = prevPriceLevel.nextPrice;

            // 验证排序
            if (isAsk) {
                // Ask: 价格递增
                require(newPriceLevel.price >= prevPriceLevel.price, "Invalid insertion position: price lower than previous");
                if (nextPrice != EMPTY) {
                    uint256 nextPriceKey = _getPriceLevelKey(nextPrice, isAsk);
                    require(newPriceLevel.price <= priceLevels[nextPriceKey].price, "Invalid insertion position: price higher than next");
                }
            } else {
                // Bid: 价格递减
                require(newPriceLevel.price <= prevPriceLevel.price, "Invalid insertion position: price higher than previous");
                if (nextPrice != EMPTY) {
                    uint256 nextPriceKey = _getPriceLevelKey(nextPrice, isAsk);
                    require(newPriceLevel.price >= priceLevels[nextPriceKey].price, "Invalid insertion position: price lower than next");
                }
            }

            // 插入节点
            newPriceLevel.prevPrice = insertAfterPrice;
            newPriceLevel.nextPrice = nextPrice;
            prevPriceLevel.nextPrice = price;

            if (nextPrice != EMPTY) {
                uint256 nextPriceKey = _getPriceLevelKey(nextPrice, isAsk);
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
     */
    function _insertOrderIntoPriceLevel(
        uint256 priceLevelId,
        uint256 orderId,
        uint256 insertAfterOrder,
        bool isAsk
    ) internal {
        uint256 levelKey = _getPriceLevelKey(priceLevelId, isAsk);
        PriceLevel storage priceLevel = priceLevels[levelKey];
        Order storage order = orders[orderId];

        if (insertAfterOrder == EMPTY) {
            // 插入到头部
            uint256 oldHead = priceLevel.headOrderId;

            if (oldHead != EMPTY) {
                orders[oldHead].prevOrderId = orderId;
                order.nextOrderId = oldHead;
            } else {
                // 列表为空
                priceLevel.tailOrderId = orderId;
            }

            priceLevel.headOrderId = orderId;
        } else {
            // 插入到指定订单后面
            Order storage prevOrder = orders[insertAfterOrder];
            require(prevOrder.id != 0, "Previous order does not exist");
            require(prevOrder.priceLevel == priceLevelId, "Previous order not in same price level");

            uint256 nextOrderId = prevOrder.nextOrderId;

            order.prevOrderId = insertAfterOrder;
            order.nextOrderId = nextOrderId;
            prevOrder.nextOrderId = orderId;

            if (nextOrderId != EMPTY) {
                orders[nextOrderId].prevOrderId = orderId;
            } else {
                // 插入到尾部
                priceLevel.tailOrderId = orderId;
            }
        }

        // 更新价格层级的总挂单量
        priceLevel.totalVolume += order.amount;
    }

    /**
     * @dev 从价格层级的订单列表中移除订单
     */
    function _removeOrderFromPriceLevel(
        uint256 priceLevelId,
        uint256 orderId,
        bool isAsk
    ) internal {
        uint256 levelKey = _getPriceLevelKey(priceLevelId, isAsk);
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
        uint256 levelKey = _getPriceLevelKey(priceLevelId, isAsk);
        PriceLevel storage priceLevel = priceLevels[levelKey];

        uint256 prevPriceLevelId = priceLevel.prevPrice;
        uint256 nextPriceLevelId = priceLevel.nextPrice;

        if (prevPriceLevelId != EMPTY) {
            uint256 prevKey = _getPriceLevelKey(prevPriceLevelId, isAsk);
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
            uint256 nextKey = _getPriceLevelKey(nextPriceLevelId, isAsk);
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

        emit PriceLevelRemoved(tradingPair, priceLevelId);
    }

    // ============ 查询函数 ============

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
            uint256 levelKey = _getPriceLevelKey(currentPriceLevelId, isAsk);
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

        uint256 levelKey = _getPriceLevelKey(headPriceLevelId, isAsk);
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
            uint256 amount
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
        order.priceLevel = EMPTY;  // 市价单不需要价格层级

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
        // 尝试匹配最多 10 次（防止 gas 耗尽）
        // 这个数字可以根据实际情况调整
        uint256 maxIterations = 10;

        // 匹配限价单
        _matchOrdersInternal(tradingPair, maxIterations);

        // 匹配市价单
        _matchMarketOrdersInternal(tradingPair, maxIterations);
    }

    /**
     * @notice 撮合订单（外部调用接口，保留用于手动触发）
     * @dev 撮合bid和ask订单，确保撮合后bid最高价 < ask最低价
     * @param tradingPair 交易对标识符
     * @param maxIterations 最大撮合次数（防止gas耗尽）
     * @return totalTrades 成交的交易数量
     */
    function matchOrders(bytes32 tradingPair, uint256 maxIterations) external returns (uint256 totalTrades) {
        return _matchOrdersInternal(tradingPair, maxIterations);
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

            uint256 bidLevelKey = _getPriceLevelKey(bidPriceLevelId, false);
            uint256 askLevelKey = _getPriceLevelKey(askPriceLevelId, true);
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

        // 计算可成交数量
        uint256 bidRemaining = bidOrder.amount - bidOrder.filledAmount;
        uint256 askRemaining = askOrder.amount - askOrder.filledAmount;
        uint256 tradeAmount = bidRemaining < askRemaining ? bidRemaining : askRemaining;

        if (tradeAmount == 0) {
            return false;
        }

        // 成交价格：取卖单价格（价格优先原则）
        uint256 tradePrice = askPrice;

        // 更新订单已成交数量
        bidOrder.filledAmount += tradeAmount;
        askOrder.filledAmount += tradeAmount;

        // 更新价格层级的总挂单量
        if (!bidOrder.isMarketOrder) {
            uint256 bidLevelKey = _getPriceLevelKey(bidOrder.priceLevel, false);
            PriceLevel storage bidPriceLevel = priceLevels[bidLevelKey];
            bidPriceLevel.totalVolume -= tradeAmount;
        }
        if (!askOrder.isMarketOrder) {
            uint256 askLevelKey = _getPriceLevelKey(askOrder.priceLevel, true);
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

        // 检查买单是否完全成交
        bool bidFullyFilled = (bidOrder.filledAmount == bidOrder.amount);
        if (bidFullyFilled) {
            _removeFilledOrder(tradingPair, bidOrderId, false);
        }
        emit OrderFilled(tradingPair, bidOrderId, tradeAmount, bidFullyFilled);

        // 检查卖单是否完全成交
        bool askFullyFilled = (askOrder.filledAmount == askOrder.amount);
        if (askFullyFilled) {
            _removeFilledOrder(tradingPair, askOrderId, true);
        }
        emit OrderFilled(tradingPair, askOrderId, tradeAmount, askFullyFilled);

        return true;
    }

    /**
     * @dev 移除已完全成交的订单
     * @param tradingPair 交易对
     * @param orderId 订单ID
     * @param isAsk 是否为卖单
     */
    function _removeFilledOrder(bytes32 tradingPair, uint256 orderId, bool isAsk) internal {
        Order storage order = orders[orderId];

        if (order.isMarketOrder) {
            // 市价单：从市价单列表中移除
            _removeMarketOrderFromList(tradingPair, orderId, isAsk);
        } else {
            // 限价单：从价格层级中移除
            uint256 priceLevelId = order.priceLevel;
            _removeOrderFromPriceLevel(priceLevelId, orderId, isAsk);

            // 如果价格层级没有订单了，删除该价格层级
            uint256 levelKey = _getPriceLevelKey(priceLevelId, isAsk);
            PriceLevel storage priceLevel = priceLevels[levelKey];
            if (priceLevel.headOrderId == EMPTY) {
                _removePriceLevel(tradingPair, priceLevelId, isAsk);
            }
        }

        // 删除订单交易对记录
        delete orderTradingPairs[orderId];

        // 删除订单数据
        delete orders[orderId];
    }

    /**
     * @notice 撮合市价单（外部调用接口，保留用于手动触发）
     * @dev 市价买单与最优卖价撮合，市价卖单与最优买价撮合
     * @param tradingPair 交易对标识符
     * @param maxIterations 最大撮合次数
     * @return totalTrades 成交的交易数量
     */
    function matchMarketOrders(bytes32 tradingPair, uint256 maxIterations) external returns (uint256 totalTrades) {
        return _matchMarketOrdersInternal(tradingPair, maxIterations);
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
                uint256 askLevelKey = _getPriceLevelKey(book.askHead, true);
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
                uint256 bidLevelKey = _getPriceLevelKey(book.bidHead, false);
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

}
