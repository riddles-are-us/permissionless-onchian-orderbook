# Matching Engine 测试脚本

本目录包含用于测试 Matching Engine 正确性的自动化脚本。

## 前置条件

1. **启动 Anvil**
   ```bash
   anvil
   ```

2. **部署合约**
   ```bash
   ./test_matcher.sh
   ```

3. **启动 Matcher**
   ```bash
   cd matcher && cargo run -- --log-level debug
   ```

## 测试脚本

### 1. run_matching_tests.sh - 主测试运行器

运行基于 Forge 脚本的集成测试。

```bash
# 运行所有基础测试 (phase1, phase2, phase3)
./test-scripts/run_matching_tests.sh all

# 运行单个测试
./test-scripts/run_matching_tests.sh phase1      # 限价单测试
./test-scripts/run_matching_tests.sh phase2      # 市价单撮合测试
./test-scripts/run_matching_tests.sh phase3      # 撤单测试
./test-scripts/run_matching_tests.sh fifo        # FIFO 顺序测试
./test-scripts/run_matching_tests.sh match_all   # 批量撮合测试
./test-scripts/run_matching_tests.sh price_level # PriceLevel 删除测试
./test-scripts/run_matching_tests.sh market_buy  # 市价买单测试
```

### 2. verify_matcher_api.sh - API 验证工具

通过 Matcher REST API 检查状态。

```bash
# 系统概览
./test-scripts/verify_matcher_api.sh overview

# 获取订单簿
./test-scripts/verify_matcher_api.sh orderbook 10

# 查询订单
./test-scripts/verify_matcher_api.sh order <order_id>

# 用户订单列表
./test-scripts/verify_matcher_api.sh orders <trader_address>

# 最近成交
./test-scripts/verify_matcher_api.sh trades 10

# 验证 Phase 1
./test-scripts/verify_matcher_api.sh verify-phase1
```

### 3. test_matching_correctness.sh - 正确性测试

直接使用 cast 命令测试核心匹配逻辑。

```bash
./test-scripts/test_matching_correctness.sh
```

测试内容：
- 基础限价单撮合
- 价格优先原则
- 市价单撮合

## 测试用例说明

| 测试 | 说明 | 验证点 |
|------|------|--------|
| phase1 | 限价单插入 | 3 个 Bid 层级, 2 个 Ask 层级 |
| phase2 | 市价单撮合 | Match ID > 0, 订单部分成交 |
| phase3 | 撤单功能 | 订单从订单簿移除, 资金解锁 |
| fifo | 先到先得 | 先下单的订单先成交 |
| match_all | 批量撮合 | 超过 maxIterations 后 matchAll 继续撮合 |
| price_level | 层级清理 | 成交后空层级被删除 |
| market_buy | 市价买单 | filled_amount 正确计算 |

## 环境变量

```bash
export ANVIL_RPC="http://127.0.0.1:8545"    # Anvil RPC 地址
export MATCHER_API="http://127.0.0.1:3000"  # Matcher API 地址
```

## 相关 Forge 脚本

测试脚本调用 `script/` 目录下的 Solidity 脚本：

- `TestPhase1_LimitOrders.s.sol` - 限价单测试
- `TestPhase2_MarketOrders.s.sol` - 市价单测试
- `TestPhase3_RemoveOrders.s.sol` - 撤单测试
- `TestFIFO.s.sol` - FIFO 测试
- `TestMatchAll.s.sol` - 批量撮合测试
- `TestPriceLevelRemoval.s.sol` - 层级清理测试
- `VerifyResults.s.sol` - 结果验证
