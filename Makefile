# OrderBook Makefile - 简化常用命令

.PHONY: help install build test test-v test-vv clean fmt coverage gas snapshot anvil deploy update-config place-orders full-setup

# Anvil 默认私钥和 RPC
PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
RPC_URL=http://127.0.0.1:8545

# 默认目标：显示帮助
help:
	@echo "OrderBook 系统 - 可用命令:"
	@echo ""
	@echo "开发和测试:"
	@echo "  make install       - 安装 Foundry 和依赖"
	@echo "  make build         - 编译所有合约"
	@echo "  make test          - 运行测试"
	@echo "  make test-v        - 运行测试（详细输出）"
	@echo "  make test-vv       - 运行测试（超详细输出）"
	@echo "  make gas           - 生成 Gas 报告"
	@echo "  make coverage      - 生成代码覆盖率报告"
	@echo "  make clean         - 清理编译产物"
	@echo "  make fmt           - 格式化代码"
	@echo ""
	@echo "部署和配置:"
	@echo "  make deploy        - 部署合约到本地节点"
	@echo "  make update-config - 从 deployments.json 更新所有配置"
	@echo "  make full-setup    - 部署 + 更新配置 + 下测试订单"
	@echo "  make place-orders  - 下测试订单"
	@echo "  make show-config   - 显示当前部署信息"
	@echo ""
	@echo "节点:"
	@echo "  make anvil         - 启动本地节点"
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

# ============ 部署和配置 ============

# 部署合约
deploy:
	@echo "📦 部署合约..."
	@PRIVATE_KEY=$(PRIVATE_KEY) forge script script/Deploy.s.sol --rpc-url $(RPC_URL) --broadcast
	@echo "✅ 合约部署完成"

# 更新配置文件
update-config:
	@echo "🔧 更新配置文件..."
	@node update_config.js

# 下测试订单
place-orders:
	@echo "📝 下测试订单..."
	@PRIVATE_KEY=$(PRIVATE_KEY) forge script script/PlaceTestOrders.s.sol --rpc-url $(RPC_URL) --broadcast
	@echo "✅ 测试订单已下"

# 完整设置（部署 + 更新配置 + 下订单）
full-setup: deploy update-config place-orders
	@echo ""
	@echo "=========================================="
	@echo "🎉 完整设置完成！"
	@echo "=========================================="
	@make show-config

# 显示当前配置
show-config:
	@echo ""
	@echo "📋 当前部署信息:"
	@cat deployments.json | grep -v "^{" | grep -v "^}"
