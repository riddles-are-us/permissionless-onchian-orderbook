# OrderBook 测试指南

## 环境准备

### 1. 安装依赖

```bash
npm install
```

这会安装：
- hardhat
- @nomicfoundation/hardhat-toolbox (包含 ethers, chai 等)

### 2. 启动本地节点

在一个终端窗口中启动 Hardhat 本地节点（类似 Anvil）：

```bash
npx hardhat node
```

这会启动一个本地 EVM 节点，监听在 `http://127.0.0.1:8545`

## 运行测试

### 方法1: 使用 Hardhat 内置网络（推荐）

```bash
npx hardhat test
```

这会：
1. 自动启动临时测试网络
2. 编译所有合约
3. 运行测试
4. 测试完成后自动清理

### 方法2: 使用独立的本地节点

如果你想在独立的节点上测试（比如 Anvil）：

```bash
# 终端1: 启动 Anvil
anvil

# 终端2: 运行测试
npx hardhat test --network localhost
```

## 测试内容

测试脚本会执行以下操作：

### 1. 部署阶段
- ✅ 部署 WETH 和 USDC 代币
- ✅ 部署 Account、Sequencer、OrderBook 合约
- ✅ 配置合约之间的引用关系
- ✅ 注册 WETH/USDC 交易对

### 2. 资金准备
- ✅ Alice: 10 WETH + 50000 USDC
- ✅ Bob: 5 WETH + 30000 USDC
- ✅ 存入到 Account 合约

### 3. 下单测试
**Alice 买单** (锁定 USDC):
- 2000 USDC 买 1 WETH
- 1950 USDC 买 2 WETH
- 1900 USDC 买 1 WETH

**Bob 卖单** (锁定 WETH):
- 2100 USDC 卖 1 WETH
- 2150 USDC 卖 1.5 WETH
- 2200 USDC 卖 0.5 WETH

### 4. 批量插入
- ✅ 使用 `batchProcessRequests()` 批量插入 6 个订单

### 5. 验证
- ✅ 订单簿结构正确
- ✅ 价格层级排序正确
- ✅ 资金锁定正确
- ✅ Alice 锁定 7800 USDC
- ✅ Bob 锁定 3 WETH

### 6. 撤单测试
- ✅ 请求撤单
- ✅ 处理撤单请求
- ✅ 验证资金解锁

## 预期输出

```
OrderBook System
🚀 部署 OrderBook 系统
============================================================

👥 测试账户:
   Deployer: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
   Alice:    0x70997970C51812dc3A010C7d01b50e0d17dc79C8
   Bob:      0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC

💎 部署代币...
   ✅ WETH: 0x5FbDB2315678afecb367f032d93F642f64180aa3
   ✅ USDC: 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512

🏗️  部署核心合约...
   ✅ Account:  0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0
   ✅ Sequencer: 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9
   ✅ OrderBook: 0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9

🔗 配置合约关系...
   ✅ 所有引用已设置

📊 注册交易对...
   ✅ WETH/USDC (0x1234567890...)

💰 准备测试资金...
   ✅ Alice: 10 WETH, 50000 USDC
   ✅ Bob: 5 WETH, 30000 USDC

============================================================
✨ 部署完成，开始测试
============================================================

  下单测试
    📈 Alice 下买单:
       ✅ 订单 1: 2000 USDC 买 1.0 WETH
       ✅ 订单 2: 1950 USDC 买 2.0 WETH
       ✅ 订单 3: 1900 USDC 买 1.0 WETH
    ✔ Alice 应该能下3个买单

    📉 Bob 下卖单:
       ✅ 订单 4: 2100 USDC 卖 1.0 WETH
       ✅ 订单 5: 2150 USDC 卖 1.5 WETH
       ✅ 订单 6: 2200 USDC 卖 0.5 WETH
    ✔ Bob 应该能下3个卖单

    📋 批量插入订单到OrderBook:
       ✅ 成功插入 6 个订单
    ✔ 应该能批量插入所有订单到OrderBook

  订单簿状态
    📊 订单簿状态:
       Bid Head: 1
       Ask Head: 4

    💵 买单 (Bid) 价格层级:
       价格: 2000 USDC, 数量: 1.0 WETH
       价格: 1950 USDC, 数量: 2.0 WETH
       价格: 1900 USDC, 数量: 1.0 WETH

    💵 卖单 (Ask) 价格层级:
       价格: 2100 USDC, 数量: 1.0 WETH
       价格: 2150 USDC, 数量: 1.5 WETH
       价格: 2200 USDC, 数量: 0.5 WETH
    ✔ 应该显示正确的订单簿结构

  账户余额
    💼 账户余额:

       Alice:
         WETH: 可用=10.0, 锁定=0.0
         USDC: 可用=42200, 锁定=7800

       Bob:
         WETH: 可用=2.0, 锁定=3.0
         USDC: 可用=30000, 锁定=0
    ✔ 应该正确锁定资金

  撤单测试
    🚫 测试撤单功能:
       撤销订单 1
       ✅ 撤单请求 7 已提交
       ✅ 订单 1 已移除
       Alice USDC: 可用=44200, 锁定=5800
    ✔ Alice 应该能撤销一个买单

============================================================
✨ 所有测试完成！
============================================================

📝 测试总结:
   ✅ 部署了完整的 OrderBook 系统
   ✅ 创建了 WETH/USDC 交易对
   ✅ 测试了下单功能
   ✅ 测试了批量插入
   ✅ 验证了资金锁定
   ✅ 测试了撤单功能

  5 passing (2s)
```

## 合约文件结构

```
orderbook/
├── Account.sol          # 账户管理合约
├── Sequencer.sol        # 排队器合约
├── OrderBook.sol        # 订单簿合约
├── MockERC20.sol        # 测试用 ERC20 代币
├── hardhat.config.js    # Hardhat 配置
├── package.json         # 依赖配置
└── test/
    └── OrderBook.test.js # 测试脚本
```

## 自定义测试

你可以修改 `test/OrderBook.test.js` 来添加更多测试场景：

### 测试撮合功能

```javascript
it("应该能撮合订单", async function () {
  // Alice 下买单: 2100 USDC 买 0.5 WETH (匹配 Bob 的卖单)
  const tx = await sequencer.connect(alice).placeLimitOrder(
    pairId,
    false,
    2100n * 10n**6n,
    ethers.parseEther("0.5")
  );
  // ... 插入订单

  // 执行撮合
  await orderBook.matchOrders(pairId, 10);

  // 验证成交
  // ...
});
```

### 测试市价单

```javascript
it("应该能下市价卖单", async function () {
  const tx = await sequencer.connect(bob).placeMarketOrder(
    pairId,
    true,  // 市价卖单
    ethers.parseEther("0.3")
  );
  // ...
});
```

## 故障排查

### 问题1: 编译错误

```bash
# 清理并重新编译
npx hardhat clean
npx hardhat compile
```

### 问题2: 测试失败

检查 Solidity 版本是否匹配：
- `hardhat.config.js` 中设置为 `0.8.20`
- 合约文件头部应为 `pragma solidity ^0.8.0;`

### 问题3: Gas 不足

如果批量插入太多订单导致 Gas 不足，减少订单数量或增加 Gas Limit：

```javascript
const tx = await orderBook.batchProcessRequests(
  orderIds,
  insertAfterPriceLevels,
  insertAfterOrders,
  { gasLimit: 10000000 }
);
```

## 下一步

- 添加撮合测试
- 添加更复杂的订单场景
- 测试边界情况（空订单簿、单边市场等）
- 性能测试（批量处理大量订单）
- Gas 优化分析
