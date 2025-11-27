// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

/**
 * @title Account
 * @notice 管理用户的资金账户和订单锁定
 * @dev 用户需要先存入资金，下单时会锁定相应金额
 */
contract Account {

    // 数量精度常数（amount 的小数位数）
    uint256 public constant AMOUNT_DECIMALS = 10 ** 8;
    // 价格精度常数（price 的小数位数）
    uint256 public constant PRICE_DECIMALS = 10 ** 8;

    // 交易费率常数（千分之一 = 0.1%）
    uint256 public constant FEE_RATE = 1;
    uint256 public constant FEE_BASE = 1000;

    // 交易对信息
    struct TradingPair {
        address baseToken;   // 基础代币（如 ETH）
        address quoteToken;  // 计价代币（如 USDC）
        bool exists;
    }

    // 用户账户余额
    struct Balance {
        uint256 available;  // 可用余额
        uint256 locked;     // 锁定余额（订单中）
    }

    // 存储
    mapping(bytes32 => TradingPair) public tradingPairs;  // 交易对信息
    mapping(address => mapping(address => Balance)) public balances;  // user => token => balance

    // 授权的Sequencer合约
    address public sequencer;

    // 授权的OrderBook合约
    address public orderBook;

    // 费用收集地址
    address public feeCollector;

    // 已收取的费用（token => amount）
    mapping(address => uint256) public collectedFees;

    // 事件
    event TradingPairRegistered(bytes32 indexed tradingPair, address indexed baseToken, address indexed quoteToken);
    event Deposit(address indexed user, address indexed token, uint256 amount);
    event Withdraw(address indexed user, address indexed token, uint256 amount);
    event FundsLocked(address indexed user, address indexed token, uint256 amount, uint256 orderId);
    event FundsUnlocked(address indexed user, address indexed token, uint256 amount, uint256 orderId);
    event FundsTransferred(address indexed from, address indexed to, address indexed token, uint256 amount);
    event SequencerSet(address indexed sequencer);
    event OrderBookSet(address indexed orderBook);
    event FeeCollectorSet(address indexed feeCollector);
    event FeeCollected(address indexed token, uint256 amount, address indexed payer);
    event FeeWithdrawn(address indexed token, uint256 amount, address indexed recipient);

    // 修饰器
    modifier onlySequencer() {
        require(msg.sender == sequencer, "Only sequencer can call");
        _;
    }

    modifier onlyOrderBook() {
        require(msg.sender == orderBook, "Only orderbook can call");
        _;
    }

    /**
     * @notice 设置Sequencer合约地址
     */
    function setSequencer(address _sequencer) external {
        require(sequencer == address(0), "Sequencer already set");
        require(_sequencer != address(0), "Invalid address");
        sequencer = _sequencer;
        emit SequencerSet(_sequencer);
    }

    /**
     * @notice 设置OrderBook合约地址
     */
    function setOrderBook(address _orderBook) external {
        require(orderBook == address(0), "OrderBook already set");
        require(_orderBook != address(0), "Invalid address");
        orderBook = _orderBook;
        emit OrderBookSet(_orderBook);
    }

    /**
     * @notice 设置费用收集地址
     */
    function setFeeCollector(address _feeCollector) external {
        require(feeCollector == address(0), "FeeCollector already set");
        require(_feeCollector != address(0), "Invalid address");
        feeCollector = _feeCollector;
        emit FeeCollectorSet(_feeCollector);
    }

    /**
     * @notice 注册交易对
     * @param tradingPair 交易对标识符
     * @param baseToken 基础代币地址
     * @param quoteToken 计价代币地址
     */
    function registerTradingPair(
        bytes32 tradingPair,
        address baseToken,
        address quoteToken
    ) external {
        require(!tradingPairs[tradingPair].exists, "Trading pair already exists");
        require(baseToken != address(0) && quoteToken != address(0), "Invalid token address");
        require(baseToken != quoteToken, "Base and quote must be different");

        tradingPairs[tradingPair] = TradingPair({
            baseToken: baseToken,
            quoteToken: quoteToken,
            exists: true
        });

        emit TradingPairRegistered(tradingPair, baseToken, quoteToken);
    }

    /**
     * @notice 存入代币
     * @param token 代币地址
     * @param amount 存入数量
     */
    function deposit(address token, uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");

        // 从用户转入代币到合约
        IERC20(token).transferFrom(msg.sender, address(this), amount);

        // 更新用户可用余额
        balances[msg.sender][token].available += amount;

        emit Deposit(msg.sender, token, amount);
    }

    /**
     * @notice 提取代币
     * @param token 代币地址
     * @param amount 提取数量
     */
    function withdraw(address token, uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");
        require(balances[msg.sender][token].available >= amount, "Insufficient available balance");

        // 更新用户可用余额
        balances[msg.sender][token].available -= amount;

        // 转账给用户
        IERC20(token).transfer(msg.sender, amount);

        emit Withdraw(msg.sender, token, amount);
    }

    /**
     * @notice 锁定资金（下单时调用，只能由Sequencer调用）
     * @param user 用户地址
     * @param tradingPair 交易对
     * @param isAsk 是否为卖单
     * @param price 价格（市价单为0）
     * @param amount 数量
     * @param orderId 订单ID
     */
    function lockFunds(
        address user,
        bytes32 tradingPair,
        bool isAsk,
        uint256 price,
        uint256 amount,
        uint256 orderId
    ) external onlySequencer {
        require(amount > 0, "Amount must be greater than 0");

        TradingPair storage pair = tradingPairs[tradingPair];
        require(pair.exists, "Trading pair not registered");

        address tokenToLock;
        uint256 amountToLock;

        if (isAsk) {
            // 卖单：锁定基础代币
            tokenToLock = pair.baseToken;
            // amount 包含精度，真实数量 = amount / AMOUNT_DECIMALS
            // 需要锁定的代币数量（最小单位）= 真实数量 * 10^baseDecimals
            uint8 baseDecimals = IERC20(pair.baseToken).decimals();
            amountToLock = (amount * (10 ** baseDecimals)) / AMOUNT_DECIMALS;
        } else {
            // 买单：锁定计价代币（包含交易费用）
            tokenToLock = pair.quoteToken;
            if (price == 0) {
                // 市价买单：不预先锁定，在执行时从可用余额扣除
                // 只需检查用户有可用余额即可（粗略检查）
                emit FundsLocked(user, tokenToLock, 0, orderId);
                return;
            }
            // 限价买单计算：
            // 真实价格 = price / PRICE_DECIMALS
            // 真实数量 = amount / AMOUNT_DECIMALS
            // 需要的计价代币（完整单位）= 真实价格 × 真实数量 = (price × amount) / (PRICE_DECIMALS × AMOUNT_DECIMALS)
            // 需要的计价代币（最小单位）= 上述结果 × 10^quoteDecimals
            uint8 quoteDecimals = IERC20(pair.quoteToken).decimals();
            uint256 baseQuoteAmount = (price * amount * (10 ** quoteDecimals)) / (PRICE_DECIMALS * AMOUNT_DECIMALS);
            // 买单需要额外锁定 0.1% 的交易费用
            amountToLock = (baseQuoteAmount * (FEE_BASE + FEE_RATE)) / FEE_BASE;
        }

        // 检查可用余额
        require(
            balances[user][tokenToLock].available >= amountToLock,
            "Insufficient available balance"
        );

        // 锁定资金
        balances[user][tokenToLock].available -= amountToLock;
        balances[user][tokenToLock].locked += amountToLock;

        emit FundsLocked(user, tokenToLock, amountToLock, orderId);
    }

    /**
     * @notice 解锁资金（取消订单时调用，只能由OrderBook调用）
     * @param user 用户地址
     * @param tradingPair 交易对
     * @param isAsk 是否为卖单
     * @param price 价格
     * @param amount 要解锁的数量
     * @param orderId 订单ID
     */
    function unlockFunds(
        address user,
        bytes32 tradingPair,
        bool isAsk,
        uint256 price,
        uint256 amount,
        uint256 orderId
    ) external onlyOrderBook {
        require(amount > 0, "Amount must be greater than 0");

        TradingPair storage pair = tradingPairs[tradingPair];
        require(pair.exists, "Trading pair not registered");

        address tokenToUnlock;
        uint256 amountToUnlock;

        if (isAsk) {
            // 卖单：解锁基础代币
            tokenToUnlock = pair.baseToken;
            uint8 baseDecimals = IERC20(pair.baseToken).decimals();
            amountToUnlock = (amount * (10 ** baseDecimals)) / AMOUNT_DECIMALS;
        } else {
            // 买单：解锁计价代币（包含预锁定的交易费用）
            tokenToUnlock = pair.quoteToken;
            if (price == 0) {
                // 市价买单：没有预先锁定，无需解锁
                emit FundsUnlocked(user, tokenToUnlock, 0, orderId);
                return;
            }
            uint8 quoteDecimals = IERC20(pair.quoteToken).decimals();
            uint256 baseQuoteAmount = (price * amount * (10 ** quoteDecimals)) / (PRICE_DECIMALS * AMOUNT_DECIMALS);
            // 解锁时也需要包含预锁定的交易费用
            amountToUnlock = (baseQuoteAmount * (FEE_BASE + FEE_RATE)) / FEE_BASE;
        }

        // 检查锁定余额
        require(
            balances[user][tokenToUnlock].locked >= amountToUnlock,
            "Insufficient locked balance"
        );

        // 解锁资金
        balances[user][tokenToUnlock].locked -= amountToUnlock;
        balances[user][tokenToUnlock].available += amountToUnlock;

        emit FundsUnlocked(user, tokenToUnlock, amountToUnlock, orderId);
    }

    /**
     * @notice 转移资金（成交时调用，只能由OrderBook调用）
     * @dev 同时收取买卖双方的交易费用（各0.1%）
     *      如果余额不足以支付全部费用，则尽可能收取（不revert）
     * @param tradingPair 交易对
     * @param buyer 买方地址
     * @param seller 卖方地址
     * @param price 成交价格
     * @param amount 成交数量
     * @param isBidMarketOrder 是否为市价买单
     */
    function transferFunds(
        bytes32 tradingPair,
        address buyer,
        address seller,
        uint256 price,
        uint256 amount,
        bool isBidMarketOrder
    ) external onlyOrderBook {
        require(amount > 0, "Amount must be greater than 0");
        require(price > 0, "Price must be greater than 0");

        TradingPair storage pair = tradingPairs[tradingPair];
        require(pair.exists, "Trading pair not registered");

        uint8 baseDecimals = IERC20(pair.baseToken).decimals();
        uint8 quoteDecimals = IERC20(pair.quoteToken).decimals();

        // 计算实际的代币数量（最小单位）
        uint256 baseAmount = (amount * (10 ** baseDecimals)) / AMOUNT_DECIMALS;
        uint256 quoteAmount = (price * amount * (10 ** quoteDecimals)) / (PRICE_DECIMALS * AMOUNT_DECIMALS);

        // 计算理想的费用（各0.1%）
        uint256 idealBuyerFee = (quoteAmount * FEE_RATE) / FEE_BASE;
        uint256 idealSellerFee = (quoteAmount * FEE_RATE) / FEE_BASE;

        // 实际收取的费用（可能因余额不足而减少）
        uint256 actualBuyerFee;
        uint256 actualSellerFee;

        // 买方：扣除计价代币，增加基础代币
        if (isBidMarketOrder) {
            // 市价买单：从可用余额扣除（未预先锁定）
            uint256 buyerAvailable = balances[buyer][pair.quoteToken].available;

            // 首先确保买方有足够的 quoteAmount（这是必须的）
            require(buyerAvailable >= quoteAmount, "Buyer insufficient available quote token");

            // 计算买方可以支付的费用（余额 - quoteAmount，但不超过理想费用）
            uint256 buyerRemainingForFee = buyerAvailable - quoteAmount;
            actualBuyerFee = buyerRemainingForFee >= idealBuyerFee ? idealBuyerFee : buyerRemainingForFee;

            // 扣除买方的 quoteAmount + 实际费用
            balances[buyer][pair.quoteToken].available -= (quoteAmount + actualBuyerFee);
        } else {
            // 限价买单：从锁定余额扣除（已预先锁定，包含费用）
            uint256 buyerTotalPay = quoteAmount + idealBuyerFee;
            require(
                balances[buyer][pair.quoteToken].locked >= buyerTotalPay,
                "Buyer insufficient locked quote token"
            );
            balances[buyer][pair.quoteToken].locked -= buyerTotalPay;
            actualBuyerFee = idealBuyerFee;
        }
        balances[buyer][pair.baseToken].available += baseAmount;

        // 卖方：扣除锁定的基础代币，增加计价代币（扣除费用后）
        require(
            balances[seller][pair.baseToken].locked >= baseAmount,
            "Seller insufficient locked base token"
        );
        balances[seller][pair.baseToken].locked -= baseAmount;

        // 卖方费用总是从 quoteAmount 中扣除，所以总能收取
        actualSellerFee = idealSellerFee;
        uint256 sellerReceives = quoteAmount - actualSellerFee;
        balances[seller][pair.quoteToken].available += sellerReceives;

        // 收取费用
        uint256 totalFee = actualBuyerFee + actualSellerFee;
        collectedFees[pair.quoteToken] += totalFee;

        emit FundsTransferred(buyer, seller, pair.baseToken, amount);
        emit FundsTransferred(buyer, seller, pair.quoteToken, sellerReceives);
        if (actualBuyerFee > 0) {
            emit FeeCollected(pair.quoteToken, actualBuyerFee, buyer);
        }
        if (actualSellerFee > 0) {
            emit FeeCollected(pair.quoteToken, actualSellerFee, seller);
        }
    }

    /**
     * @notice 获取用户余额
     * @param user 用户地址
     * @param token 代币地址
     * @return available 可用余额
     * @return locked 锁定余额
     * @return total 总余额
     */
    function getBalance(address user, address token)
        external
        view
        returns (uint256 available, uint256 locked, uint256 total)
    {
        Balance storage balance = balances[user][token];
        available = balance.available;
        locked = balance.locked;
        total = available + locked;
        return (available, locked, total);
    }

    /**
     * @notice 获取交易对信息
     * @param tradingPair 交易对标识符
     * @return baseToken 基础代币地址
     * @return quoteToken 计价代币地址
     * @return exists 是否存在
     */
    function getTradingPair(bytes32 tradingPair)
        external
        view
        returns (address baseToken, address quoteToken, bool exists)
    {
        TradingPair storage pair = tradingPairs[tradingPair];
        return (pair.baseToken, pair.quoteToken, pair.exists);
    }

    /**
     * @notice 检查用户是否有足够余额下单
     * @param user 用户地址
     * @param tradingPair 交易对
     * @param isAsk 是否为卖单
     * @param price 价格
     * @param amount 数量
     * @return 是否有足够余额
     */
    function hasSufficientBalance(
        address user,
        bytes32 tradingPair,
        bool isAsk,
        uint256 price,
        uint256 amount
    ) external view returns (bool) {
        TradingPair storage pair = tradingPairs[tradingPair];
        if (!pair.exists) {
            return false;
        }

        if (isAsk) {
            // 卖单：需要基础代币
            uint8 baseDecimals = IERC20(pair.baseToken).decimals();
            uint256 requiredBase = (amount * (10 ** baseDecimals)) / AMOUNT_DECIMALS;
            return balances[user][pair.baseToken].available >= requiredBase;
        } else {
            // 买单：需要计价代币（包含0.1%交易费用）
            if (price == 0) {
                // 市价买单：无法预先计算所需金额，只检查用户是否有可用余额
                return balances[user][pair.quoteToken].available > 0;
            }
            uint8 quoteDecimals = IERC20(pair.quoteToken).decimals();
            uint256 baseQuote = (price * amount * (10 ** quoteDecimals)) / (PRICE_DECIMALS * AMOUNT_DECIMALS);
            // 包含交易费用
            uint256 requiredQuote = (baseQuote * (FEE_BASE + FEE_RATE)) / FEE_BASE;
            return balances[user][pair.quoteToken].available >= requiredQuote;
        }
    }

    /**
     * @notice 提取收集的交易费用（只能由feeCollector调用）
     * @param token 代币地址
     * @param amount 提取数量
     */
    function withdrawFees(address token, uint256 amount) external {
        require(msg.sender == feeCollector, "Only feeCollector can withdraw");
        require(amount > 0, "Amount must be greater than 0");
        require(collectedFees[token] >= amount, "Insufficient collected fees");

        collectedFees[token] -= amount;

        // 转账给feeCollector
        IERC20(token).transfer(feeCollector, amount);

        emit FeeWithdrawn(token, amount, feeCollector);
    }

    /**
     * @notice 获取已收集的费用
     * @param token 代币地址
     * @return 已收集的费用数量
     */
    function getCollectedFees(address token) external view returns (uint256) {
        return collectedFees[token];
    }
}
