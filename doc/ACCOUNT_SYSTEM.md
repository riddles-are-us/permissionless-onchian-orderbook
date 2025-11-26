# 账户系统使用指南

## 系统概述

账户系统管理用户的资金存取和订单锁定，确保用户在下单时有足够的资金，并在成交时自动完成资金转移。

## 核心概念

### 1. 账户余额结构

每个用户对每种代币有两种余额：
- **可用余额 (available)**: 可以提取或用于下单
- **锁定余额 (locked)**: 已下单但未成交的资金

```
总余额 = 可用余额 + 锁定余额
```

### 2. 资金流转

```
存款 → 可用余额
下单 → 可用余额 - X, 锁定余额 + X
成交 → 买方锁定余额 - Y, 卖方锁定余额 - Z
       买方可用余额 + Z, 卖方可用余额 + Y
撤单 → 锁定余额 - X, 可用余额 + X
提款 ← 可用余额
```

### 3. 交易对配置

每个交易对包含：
- **baseToken**: 基础代币（如 ETH）
- **quoteToken**: 计价代币（如 USDC）

例如 ETH/USDC:
- 卖单锁定 ETH（baseToken）
- 买单锁定 USDC（quoteToken）

## 合约部署和初始化

### 步骤1: 部署所有合约

```solidity
// 1. 部署代币合约（示例）
ERC20 baseToken = new MockERC20("Wrapped ETH", "WETH", 18);
ERC20 quoteToken = new MockERC20("USD Coin", "USDC", 6);

// 2. 部署核心合约
Account account = new Account();
Sequencer sequencer = new Sequencer();
OrderBook orderBook = new OrderBook();
```

### 步骤2: 配置合约关系

```solidity
// 设置合约之间的引用
sequencer.setAccount(address(account));
sequencer.setOrderBook(address(orderBook));

orderBook.setSequencer(address(sequencer));
orderBook.setAccount(address(account));

account.setSequencer(address(sequencer));
account.setOrderBook(address(orderBook));
```

### 步骤3: 注册交易对

```solidity
bytes32 pairId = keccak256("ETH/USDC");

account.registerTradingPair(
    pairId,
    address(baseToken),   // ETH
    address(quoteToken)   // USDC
);
```

## 用户操作流程

### 1. 存款

用户必须先存入代币才能交易。

```solidity
// Alice存入1000 USDC
uint256 amount = 1000 * 10**6;  // USDC has 6 decimals

// 第一步：授权
quoteToken.approve(address(account), amount);

// 第二步：存款
account.deposit(address(quoteToken), amount);

// 查询余额
(uint256 available, uint256 locked, uint256 total) =
    account.getBalance(alice, address(quoteToken));
// available = 1000 USDC
// locked = 0
// total = 1000 USDC
```

### 2. 下单（自动锁定资金）

#### 限价买单

```solidity
// Alice想用价格2000买入1个ETH
bytes32 pairId = keccak256("ETH/USDC");

// 需要锁定: 2000 USDC (price * amount)
// 检查: Alice有1000 USDC可用，不够！需要先存入更多

// 假设Alice又存入了1500 USDC，现在有2500 USDC可用
uint256 orderId = sequencer.placeLimitOrder(
    pairId,
    false,  // 买单
    2000,   // 价格
    1       // 数量
);

// 资金自动锁定
// 可用余额: 2500 - 2000 = 500 USDC
// 锁定余额: 2000 USDC
```

#### 限价卖单

```solidity
// Bob想以价格2100卖出0.5个ETH
// 需要锁定: 0.5 ETH

baseToken.approve(address(account), 0.5 ether);
account.deposit(address(baseToken), 0.5 ether);

uint256 orderId = sequencer.placeLimitOrder(
    pairId,
    true,   // 卖单
    2100,   // 价格
    0.5 ether  // 数量
);

// 锁定了0.5 ETH
```

#### 市价卖单（仅支持卖单）

```solidity
// Bob想市价卖出0.3个ETH
uint256 orderId = sequencer.placeMarketOrder(
    pairId,
    true,   // 只支持市价卖单
    0.3 ether  // 数量
);

// 锁定了0.3 ETH
```

### 3. 插入订单到订单簿

```solidity
// 任何人都可以将Sequencer队列头部的订单插入到OrderBook
uint256 headOrderId = sequencer.getHeadOrderId();

orderBook.insertOrder(
    headOrderId,
    0,  // insertAfterPriceLevel
    0   // insertAfterOrder
);

// 订单现在在OrderBook中，资金仍然锁定
```

### 4. 撮合（自动转移资金）

```solidity
// 假设订单簿状态:
// Bid: 2000 (1 ETH)  - Alice
// Ask: 2100 (0.5 ETH) - Bob

// 执行撮合
orderBook.matchOrders(pairId, 100);

// 没有成交（买价2000 < 卖价2100）

// 现在Charlie下了一个2100的买单
sequencer.placeLimitOrder(pairId, false, 2100, 0.5 ether);
orderBook.insertOrder(charlieOrderId, 0, 0);

// 再次撮合
orderBook.matchOrders(pairId, 100);

// 成交！
// 成交价: 2100 (卖单价格)
// 成交量: 0.5 ETH
//
// Bob (卖方):
//   - 锁定余额 -0.5 ETH
//   - 可用余额 +1050 USDC (0.5 * 2100)
//
// Charlie (买方):
//   - 锁定余额 -1050 USDC
//   - 可用余额 +0.5 ETH
```

### 5. 撤单（解锁资金）

```solidity
// Alice想撤销她的买单
orderBook.removeOrder(pairId, aliceOrderId, false);

// 资金自动解锁
// Alice:
//   - 锁定余额 -2000 USDC
//   - 可用余额 +2000 USDC
```

### 6. 提款

```solidity
// Bob想提取他卖出ETH后得到的USDC
account.withdraw(address(quoteToken), 1050 * 10**6);

// USDC转到Bob的钱包地址
```

## 完整示例：从头到尾的交易流程

```solidity
// ========== 初始化 ==========
bytes32 pair = keccak256("ETH/USDC");

// ========== Alice: 买家 ==========
// 1. Alice存入3000 USDC
quoteToken.approve(address(account), 3000 * 10**6);
account.deposit(address(quoteToken), 3000 * 10**6);

// 2. Alice下限价买单: 2000 USDC买1 ETH
uint256 aliceOrderId = sequencer.placeLimitOrder(pair, false, 2000, 1 ether);
// 锁定: 2000 USDC
// 可用余额: 1000 USDC

// 3. 插入到订单簿
orderBook.insertOrder(aliceOrderId, 0, 0);

// ========== Bob: 卖家 ==========
// 1. Bob存入2 ETH
baseToken.approve(address(account), 2 ether);
account.deposit(address(baseToken), 2 ether);

// 2. Bob下限价卖单: 1900 USDC卖1 ETH
uint256 bobOrderId = sequencer.placeLimitOrder(pair, true, 1900, 1 ether);
// 锁定: 1 ETH
// 可用余额: 1 ETH

// 3. 插入到订单簿
orderBook.insertOrder(bobOrderId, 0, 0);

// ========== 撮合 ==========
orderBook.matchOrders(pair, 100);

// 成交结果:
// - 成交价: 1900 USDC (卖单价格)
// - 成交量: 1 ETH
//
// Alice账户变化:
//   USDC: 锁定 -2000, 可用 +100 (多付的2000-1900)
//   ETH:  可用 +1
//   最终: 1100 USDC可用, 1 ETH可用
//
// Bob账户变化:
//   ETH:  锁定 -1
//   USDC: 可用 +1900
//   最终: 1 ETH可用, 1900 USDC可用

// ========== 提款 ==========
// Alice提取她的ETH
account.withdraw(address(baseToken), 1 ether);

// Bob提取他的USDC
account.withdraw(address(quoteToken), 1900 * 10**6);
```

## 资金安全保证

### 1. 下单前验证

```solidity
// Sequencer在placeLimitOrder时会检查:
require(
    account.hasSufficientBalance(msg.sender, tradingPair, isAsk, price, amount),
    "Insufficient balance"
);
```

如果余额不足，交易会revert。

### 2. 原子操作

下单和锁定资金在同一笔交易中完成：
```solidity
// placeLimitOrder内部:
_placeOrder(...);              // 创建订单
account.lockFunds(...);        // 锁定资金（原子操作）
```

### 3. 撮合时的资金转移

```solidity
// _executeTrade内部:
// 1. 更新filledAmount
// 2. 调用account.transferFunds()
//    - 扣除买方锁定的USDC
//    - 扣除卖方锁定的ETH
//    - 增加买方可用的ETH
//    - 增加卖方可用的USDC
// 3. emit Trade事件
```

所有操作都是原子的，要么全部成功，要么全部失败。

## 余额查询

```solidity
// 查询用户的代币余额
(uint256 available, uint256 locked, uint256 total) =
    account.getBalance(userAddress, tokenAddress);

console.log("可用余额:", available);
console.log("锁定余额:", locked);
console.log("总余额:", total);
```

## 事件监听

### 存款事件
```solidity
event Deposit(address indexed user, address indexed token, uint256 amount);
```

### 提款事件
```solidity
event Withdraw(address indexed user, address indexed token, uint256 amount);
```

### 资金锁定事件
```solidity
event FundsLocked(address indexed user, address indexed token, uint256 amount, uint256 orderId);
```

### 资金解锁事件
```solidity
event FundsUnlocked(address indexed user, address indexed token, uint256 amount, uint256 orderId);
```

### 资金转移事件
```solidity
event FundsTransferred(address indexed from, address indexed to, address indexed token, uint256 amount);
```

## 限制和注意事项

### 1. 市价买单不支持

市价买单需要预先不知道确切的成交价格，无法提前锁定精确金额，因此当前版本不支持。

```solidity
// ❌ 这会失败
sequencer.placeMarketOrder(pair, false, amount);  // 市价买单
// Error: "Only market sell orders supported"

// ✅ 只支持市价卖单
sequencer.placeMarketOrder(pair, true, amount);   // 市价卖单
```

### 2. 部分成交的资金处理

订单可以部分成交，每次成交都会转移相应的资金：

```solidity
// Alice下单: 买10个 @ 2000
// 锁定: 20000 USDC

// 第1次成交: 3个 @ 2000
// 转移: 锁定 -6000 USDC, 可用 +3 ETH
// 剩余锁定: 14000 USDC

// 第2次成交: 7个 @ 2000
// 转移: 锁定 -14000 USDC, 可用 +7 ETH
// 订单完全成交，从订单簿移除
```

### 3. 提款限制

只能提取可用余额，不能提取锁定余额：

```solidity
// 可用余额: 100 USDC
// 锁定余额: 900 USDC

account.withdraw(tokenAddress, 100);  // ✓ 成功
account.withdraw(tokenAddress, 101);  // ✗ 失败 "Insufficient available balance"
```

如果想提取锁定资金，必须先撤单。

## 总结

账户系统的核心特点：
1. ✅ **存款前置**: 用户必须先存款才能交易
2. ✅ **余额验证**: 下单时自动检查余额
3. ✅ **资金锁定**: 下单时自动锁定所需资金
4. ✅ **原子转移**: 撮合时原子性地转移资金
5. ✅ **部分成交**: 支持订单部分成交的资金处理
6. ✅ **撤单解锁**: 撤单时自动解锁资金
7. ✅ **安全提款**: 只能提取可用余额

完整的资金安全保障让用户可以放心交易！
