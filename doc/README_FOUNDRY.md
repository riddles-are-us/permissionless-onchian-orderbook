# OrderBook 系统 - Foundry 测试版

## 🎯 快速开始（3步）

```bash
# 1. 运行安装脚本（自动安装 Foundry 和依赖）
./setup_foundry.sh

# 2. 运行测试
forge test -vvv

# 3. 查看结果
```

就这么简单！🎉

## 📋 系统概述

这是一个完整的链上去中心化交易所（DEX）订单簿系统，包含：

- **Account.sol** - 账户管理（存款、提款、资金锁定）
- **Sequencer.sol** - FIFO 队列（确保公平性，防止抢跑）
- **OrderBook.sol** - 订单簿（双向链表，价格-时间优先）
- **MockERC20.sol** - 测试用 ERC20 代币

## 🔧 手动安装

### 前置要求

- Git
- Rust (Foundry 使用 Rust 编写)

### 1. 安装 Foundry

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

验证安装：
```bash
forge --version
anvil --version
cast --version
```

### 2. 安装依赖

```bash
forge install foundry-rs/forge-std
```

### 3. 编译合约

```bash
forge build
```

## 🧪 运行测试

### 基础测试

```bash
# 运行所有测试
forge test

# 详细输出（推荐）
forge test -vvv

# 超详细输出（包括所有调用栈）
forge test -vvvv
```

### 运行特定测试

```bash
# 只测试下单功能
forge test --match-test testPlaceOrders -vvv

# 只测试批量插入
forge test --match-test testBatchInsertOrders -vvv

# 只测试撤单
forge test --match-test testRemoveOrder -vvv
```

### Gas 报告

```bash
forge test --gas-report
```

### 代码覆盖率

```bash
forge coverage
```

## 📊 测试内容

### 1. 部署阶段 (`setUp`)

自动执行：
- ✅ 部署 WETH 和 USDC 代币
- ✅ 部署 Account、Sequencer、OrderBook
- ✅ 配置合约间引用
- ✅ 注册 WETH/USDC 交易对
- ✅ 为 Alice 和 Bob 准备资金

### 2. 测试场景

#### `testPlaceOrders` - 下单测试
- Alice 下 3 个买单（2000, 1950, 1900 USDC）
- Bob 下 3 个卖单（2100, 2150, 2200 USDC）

#### `testBatchInsertOrders` - 批量插入测试
- 批量插入 6 个订单到 OrderBook
- 验证处理数量

#### `testOrderBookStructure` - 订单簿结构测试
- 遍历买单价格层级
- 遍历卖单价格层级
- 验证层级数量

#### `testAccountBalances` - 账户余额测试
- 验证 Alice 锁定 7800 USDC
- 验证 Bob 锁定 3 WETH

#### `testRemoveOrder` - 撤单测试
- Alice 撤销一个买单
- 验证资金解锁

#### `testMarketOrder` - 市价单测试
- Bob 下市价卖单
- 验证插入成功

#### `testCompleteFlow` - 完整流程测试
- 运行所有测试场景

## 📈 预期输出示例

```
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

...

[PASS] testPlaceOrders() (gas: 1234567)
[PASS] testBatchInsertOrders() (gas: 2345678)
[PASS] testOrderBookStructure() (gas: 987654)
[PASS] testAccountBalances() (gas: 456789)
[PASS] testRemoveOrder() (gas: 567890)
[PASS] testMarketOrder() (gas: 345678)
[PASS] testCompleteFlow() (gas: 5678901)

Test result: ok. 7 passed; 0 failed; finished in 12.34s
```

## 🛠️ 常用命令

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

# 格式化
forge fmt

# 更新依赖
forge update
```

## 🌐 使用 Anvil 本地节点

```bash
# 终端1: 启动本地节点
anvil

# 终端2: Fork 本地节点测试
forge test --fork-url http://127.0.0.1:8545 -vvv
```

## 🔍 高级功能

### Fuzz 测试

Foundry 内置 Fuzz 测试支持：

```solidity
function testFuzz_PlaceOrder(uint256 price, uint256 amount) public {
    // Foundry 会自动生成随机输入
    vm.assume(price > 0 && price < 10000 * 10**6);
    vm.assume(amount > 0 && amount < 100 ether);

    vm.prank(alice);
    sequencer.placeLimitOrder(pairId, false, price, amount);
}
```

### 不变量测试

测试系统不变量：

```solidity
contract InvariantTest is Test {
    function invariant_TotalBalancesShouldMatch() public {
        // 总锁定 + 总可用 = 总存入
        // 这个条件应该始终成立
    }
}
```

### Gas 快照

```bash
# 创建快照
forge snapshot

# 比较 Gas 变化
forge snapshot --diff
```

## 📂 项目结构

```
orderbook/
├── foundry.toml              # Foundry 配置
├── setup_foundry.sh          # 自动安装脚本
├── Account.sol               # 账户合约
├── Sequencer.sol             # 排队器合约
├── OrderBook.sol             # 订单簿合约
├── MockERC20.sol             # 测试代币
├── test/
│   └── OrderBook.t.sol       # Foundry 测试
├── lib/
│   └── forge-std/            # Forge 标准库
└── out/                      # 编译输出
```

## 🐛 故障排查

### 问题1: `forge: command not found`

```bash
# 重新安装 Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### 问题2: 编译错误

```bash
forge clean
forge build
```

### 问题3: 找不到 `forge-std`

```bash
forge install foundry-rs/forge-std
```

### 问题4: Gas 不足

增加 Gas Limit：

```solidity
vm.txGasPrice(1 gwei);
```

## 🆚 Foundry vs Hardhat

| 特性 | Foundry (Forge) | Hardhat |
|------|-----------------|---------|
| **测试语言** | Solidity | JavaScript/TypeScript |
| **速度** | 🚀 极快 (~10倍) | 🐢 较慢 |
| **Gas 报告** | ✅ 内置 | ⚠️ 需插件 |
| **Fuzz 测试** | ✅ 内置 | ❌ 需额外工具 |
| **不变量测试** | ✅ 内置 | ❌ 无 |
| **快照测试** | ✅ 内置 | ❌ 无 |
| **学习曲线** | Solidity 开发者友好 | JS 开发者友好 |
| **生态系统** | 新兴但增长快 | 成熟 |

## 🎓 学习资源

- [Foundry Book](https://book.getfoundry.sh/)
- [Foundry GitHub](https://github.com/foundry-rs/foundry)
- [Forge Std Docs](https://book.getfoundry.sh/reference/forge-std/)

## 📝 下一步

- [ ] 添加撮合测试
- [ ] 添加 Fuzz 测试
- [ ] 添加不变量测试
- [ ] Gas 优化分析
- [ ] 部署脚本

## 📄 许可证

MIT

---

**Happy Testing with Foundry! 🚀**
