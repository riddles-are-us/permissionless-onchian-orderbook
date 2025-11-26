# 🚀 从这里开始

## 最快开始方式（3 个命令）

```bash
# 1. 安装依赖
forge install foundry-rs/forge-std

# 2. 编译合约
forge build

# 3. 运行测试
forge test -vvv
```

## 或者使用一键脚本

```bash
./setup_foundry.sh
```

## 或者使用 Makefile

```bash
make quickstart
```

## 测试成功的标志

你应该看到类似的输出：

```
Running 7 tests for test/OrderBook.t.sol:OrderBookTest

[PASS] testPlaceOrders() (gas: ...)
[PASS] testBatchInsertOrders() (gas: ...)
[PASS] testOrderBookStructure() (gas: ...)
[PASS] testAccountBalances() (gas: ...)
[PASS] testRemoveOrder() (gas: ...)
[PASS] testMarketOrder() (gas: ...)
[PASS] testCompleteFlow() (gas: ...)

Test result: ok. 7 passed; 0 failed
```

## 下一步

查看详细文档：
- **FOUNDRY_QUICKSTART.md** - 快速入门和常用命令
- **README_FOUNDRY.md** - 完整系统文档

## 常用命令速查

```bash
# 测试
forge test -vvv              # 详细输出
make test-v                  # 使用 Makefile

# Gas 报告
forge test --gas-report
make gas

# 只运行特定测试
forge test --match-test testPlaceOrders -vvv
make test-place

# 清理重新编译
forge clean && forge build
```

## 需要帮助？

- 查看 `FOUNDRY_QUICKSTART.md` 中的故障排查部分
- 运行 `forge --help` 查看所有可用命令
- 运行 `make help` 查看 Makefile 命令

祝测试愉快！🎉
