# Foundry 快速开始指南

## 环境要求

确保已安装 Foundry (Forge, Cast, Anvil):

```bash
# 安装 Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

验证安装:
```bash
forge --version
anvil --version
cast --version
```

## 一键运行测试

```bash
# 安装依赖（Forge标准库）
forge install foundry-rs/forge-std

# 运行所有测试
forge test -vvv
```

就这么简单！🎉

## 详细步骤

### 1. 初始化项目（如果需要）

```bash
# 如果是新项目
forge init

# 已有项目，安装依赖
forge install foundry-rs/forge-std
```

### 2. 编译合约

```bash
forge build
```

这会编译所有 `.sol` 文件，包括:
- Account.sol
- Sequencer.sol
- OrderBook.sol
- MockERC20.sol
- test/OrderBook.t.sol

### 3. 运行测试

```bash
# 基础测试
forge test

# 详细输出（推荐）
forge test -vvv

# 非常详细（包括所有traces）
forge test -vvvv

# 运行特定测试
forge test --match-test testPlaceOrders -vvv

# 运行特定合约的测试
forge test --match-contract OrderBookTest -vvv
```

### 4. Gas 报告

```bash
forge test --gas-report
```

### 5. 代码覆盖率

```bash
forge coverage
```

## 测试内容

### 测试函数列表

1. **testPlaceOrders** - 测试下单功能
   - Alice 下 3 个买单
   - Bob 下 3 个卖单

2. **testBatchInsertOrders** - 测试批量插入
   - 批量插入 6 个订单到 OrderBook

3. **testOrderBookStructure** - 测试订单簿结构
   - 验证价格层级
   - 显示买卖单列表

4. **testAccountBalances** - 测试账户余额
   - 验证资金锁定
   - Alice 锁定 7800 USDC
   - Bob 锁定 3 WETH

5. **testRemoveOrder** - 测试撤单
   - 请求撤单
   - 验证资金解锁

6. **testMarketOrder** - 测试市价单
   - Bob 下市价卖单
   - 插入到订单簿

7. **testCompleteFlow** - 完整流程测试
   - 运行所有测试场景

## 使用 Anvil 本地节点

如果想在本地节点上测试：

```bash
# 终端1: 启动 Anvil
anvil

# 终端2: 运行测试（fork本地节点）
forge test --fork-url http://127.0.0.1:8545 -vvv
```

## 预期输出

```bash
$ forge test -vvv

[⠊] Compiling...
[⠒] Compiling 5 files with 0.8.20
[⠢] Solc 0.8.20 finished in 2.34s
Compiler run successful!

Running 7 tests for test/OrderBook.t.sol:OrderBookTest

========================================
Deploying OrderBook System
========================================

Test Accounts:
  Deployer: 0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496
  Alice:    0x6813Eb9362372EEF6200f3b1dbC3f819671cBA69
  Bob:      0x1efF47bc3a10a45D4B230B5d10E37751FE6AA718

Deploying Tokens...
  WETH: 0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f
  USDC: 0x2e234DAe75C793f67A35089C9d99245E1C58470b

Deploying Core Contracts...
  Account:  0xF62849F9A0B5Bf2913b396098F7c7019b51A820a
  Sequencer: 0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9
  OrderBook: 0xc7183455a4C133Ae270771860664b6B7ec320bB1

Configuring Contract References...
  All references set

Registering Trading Pair...
  WETH/USDC registered

Preparing Test Funds...
  Alice: 10 WETH, 50000 USDC
  Bob: 5 WETH, 30000 USDC

========================================
Setup Complete - Starting Tests
========================================

[PASS] testPlaceOrders() (gas: 1234567)

--- Test: Place Orders ---

Alice placing buy orders:
  Order 1 : 2000 USDC buy 1 WETH
  Order 2 : 1950 USDC buy 2 WETH
  Order 3 : 1900 USDC buy 1 WETH

Bob placing sell orders:
  Order 4 : 2100 USDC sell 1 WETH
  Order 5 : 2150 USDC sell 1.5 WETH
  Order 6 : 2200 USDC sell 0.5 WETH

[PASS] testBatchInsertOrders() (gas: 2345678)

--- Test: Batch Insert Orders ---

Batch inserting 6 orders...
  Processed count: 6
  Bid Head: 1
  Ask Head: 4

[PASS] testOrderBookStructure() (gas: 987654)

--- Test: OrderBook Structure ---

Bid Price Levels:
  Price: 2000 USDC, Volume: 1 WETH
  Price: 1950 USDC, Volume: 2 WETH
  Price: 1900 USDC, Volume: 1 WETH

Ask Price Levels:
  Price: 2100 USDC, Volume: 1 WETH
  Price: 2150 USDC, Volume: 1 WETH
  Price: 2200 USDC, Volume: 0 WETH

[PASS] testAccountBalances() (gas: 456789)

--- Test: Account Balances ---

Alice:
  WETH: available = 10 , locked = 0
  USDC: available = 42200 , locked = 7800

Bob:
  WETH: available = 2 , locked = 3
  USDC: available = 30000 , locked = 0

[PASS] testRemoveOrder() (gas: 567890)

--- Test: Remove Order ---

Removing order: 1
  Remove request ID: 7
  Order removed

Alice USDC after removal:
  Available: 44200
  Locked: 5800

[PASS] testMarketOrder() (gas: 345678)

--- Test: Market Order ---

Bob placing market sell order:
  Market order 8 : sell 0.5 WETH
  Processed: 1
  Market ask head: 8

[PASS] testCompleteFlow() (gas: 5678901)

========================================
Complete Flow Test
========================================
... (all previous test output)
========================================
All Tests Passed!
========================================

Test result: ok. 7 passed; 0 failed; finished in 12.34s
```

## 高级用法

### 1. 测试特定场景

```bash
# 只运行下单测试
forge test --match-test testPlaceOrders -vvv

# 只运行批量插入测试
forge test --match-test testBatchInsertOrders -vvv
```

### 2. Gas 优化分析

```bash
# 生成详细的 Gas 报告
forge test --gas-report

# 查看最贵的函数
forge test --gas-report | grep "batchProcessRequests"
```

### 3. 快照测试

```bash
# 创建 Gas 快照
forge snapshot

# 比较 Gas 变化
forge snapshot --diff
```

### 4. Fuzz 测试

在测试函数中添加参数即可进行 Fuzz 测试：

```solidity
function testFuzzPlaceOrder(uint256 price, uint256 amount) public {
    vm.assume(price > 0 && price < 10000 * 10**6);
    vm.assume(amount > 0 && amount < 100 ether);

    vm.prank(alice);
    sequencer.placeLimitOrder(pairId, false, price, amount);
}
```

### 5. 调试

```bash
# 使用 Forge 调试器
forge test --debug testPlaceOrders

# 在测试中使用 console.log
# 已在测试合约中使用 import "forge-std/Test.sol"
```

## 项目结构

```
orderbook/
├── foundry.toml           # Foundry 配置
├── Account.sol            # 账户管理合约
├── Sequencer.sol          # 排队器合约
├── OrderBook.sol          # 订单簿合约
├── MockERC20.sol          # 测试用代币
├── test/
│   └── OrderBook.t.sol    # Foundry 测试合约
├── lib/
│   └── forge-std/         # Forge 标准库（自动安装）
└── out/                   # 编译输出（自动生成）
```

## 常用命令速查

```bash
# 编译
forge build

# 测试
forge test -vvv

# Gas 报告
forge test --gas-report

# 覆盖率
forge coverage

# 清理
forge clean

# 格式化代码
forge fmt

# 更新依赖
forge update

# 查看帮助
forge --help
forge test --help
```

## 故障排查

### 问题1: 找不到 forge

```bash
# 重新安装 Foundry
foundryup
```

### 问题2: 编译错误

```bash
# 清理并重新编译
forge clean
forge build
```

### 问题3: 依赖缺失

```bash
# 重新安装 forge-std
forge install foundry-rs/forge-std
```

### 问题4: Solidity 版本不匹配

检查 `foundry.toml` 中的 `solc` 版本设置：
```toml
solc = "0.8.20"
```

## 与 Hardhat 对比

| 特性 | Foundry | Hardhat |
|------|---------|---------|
| 测试语言 | Solidity | JavaScript/TypeScript |
| 速度 | 🚀 非常快 | 🐢 较慢 |
| Gas 报告 | ✅ 内置 | ⚠️ 需要插件 |
| Fuzz 测试 | ✅ 内置 | ❌ 需要额外工具 |
| 学习曲线 | Solidity 开发者友好 | JS 开发者友好 |

## 下一步

- 添加撮合测试
- 添加 Fuzz 测试
- 添加不变量测试
- 性能基准测试
- Gas 优化分析

祝测试愉快！🚀
