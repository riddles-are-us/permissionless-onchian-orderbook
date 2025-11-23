# OrderBook Makefile - 简化常用命令

.PHONY: help install build test test-v test-vv clean fmt coverage gas snapshot anvil

# 默认目标：显示帮助
help:
	@echo "OrderBook 系统 - 可用命令:"
	@echo ""
	@echo "  make install    - 安装 Foundry 和依赖"
	@echo "  make build      - 编译所有合约"
	@echo "  make test       - 运行测试"
	@echo "  make test-v     - 运行测试（详细输出）"
	@echo "  make test-vv    - 运行测试（超详细输出）"
	@echo "  make gas        - 生成 Gas 报告"
	@echo "  make coverage   - 生成代码覆盖率报告"
	@echo "  make clean      - 清理编译产物"
	@echo "  make fmt        - 格式化代码"
	@echo "  make snapshot   - 创建 Gas 快照"
	@echo "  make anvil      - 启动本地节点"
	@echo ""

# 安装 Foundry 和依赖
install:
	@echo "安装 Foundry..."
	@curl -L https://foundry.paradigm.xyz | bash
	@foundryup
	@echo "安装 forge-std..."
	@forge install foundry-rs/forge-std
	@echo "✅ 安装完成"

# 编译合约
build:
	@echo "编译合约..."
	@forge build
	@echo "✅ 编译完成"

# 运行测试
test:
	@forge test

# 运行测试（详细输出）
test-v:
	@forge test -vvv

# 运行测试（超详细输出）
test-vv:
	@forge test -vvvv

# 运行特定测试
test-place:
	@forge test --match-test testPlaceOrders -vvv

test-batch:
	@forge test --match-test testBatchInsertOrders -vvv

test-remove:
	@forge test --match-test testRemoveOrder -vvv

test-flow:
	@forge test --match-test testCompleteFlow -vvv

# Gas 报告
gas:
	@forge test --gas-report

# 代码覆盖率
coverage:
	@forge coverage

# 清理
clean:
	@forge clean
	@echo "✅ 清理完成"

# 格式化代码
fmt:
	@forge fmt
	@echo "✅ 格式化完成"

# Gas 快照
snapshot:
	@forge snapshot

# 快照对比
snapshot-diff:
	@forge snapshot --diff

# 启动 Anvil 本地节点
anvil:
	@echo "启动 Anvil 本地节点..."
	@anvil

# 更新依赖
update:
	@forge update
	@echo "✅ 依赖已更新"

# 快速开始（安装 + 编译 + 测试）
quickstart: install build test-v
	@echo ""
	@echo "=========================================="
	@echo "✨ 快速开始完成！"
	@echo "=========================================="
