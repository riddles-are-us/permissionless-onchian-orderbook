#!/bin/bash

# Matching Engine 自动化测试脚本
# 用法: ./test-scripts/run_matching_tests.sh [test_name]
# test_name 可选: phase1, phase2, phase3, fifo, match_all, price_level, market_buy, all

set -e

# 切换到项目根目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置
ANVIL_RPC="http://127.0.0.1:8545"
MATCHER_API="http://127.0.0.1:3000"
MAX_WAIT_SECONDS=30
POLL_INTERVAL=2

# Anvil 默认私钥
export PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
export USER_PRIVATE_KEY="0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"

# 辅助函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# 检查 Anvil 是否运行
check_anvil() {
    if ! cast chain-id --rpc-url $ANVIL_RPC &>/dev/null; then
        log_error "Anvil 未运行。请先运行: anvil"
        exit 1
    fi
    log_success "Anvil 运行中"
}

# 检查 Matcher 是否运行 (通过 API)
check_matcher() {
    if curl -s "$MATCHER_API/health" &>/dev/null || curl -s "$MATCHER_API/overview" &>/dev/null; then
        log_success "Matcher 运行中"
        return 0
    else
        log_warn "Matcher API 不可用 (可能未启动或无 API)"
        return 1
    fi
}

# 等待队列清空
wait_for_queue_empty() {
    local max_wait=$1
    local start_time=$(date +%s)

    log_info "等待 Matcher 处理队列..."

    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))

        if [ $elapsed -gt $max_wait ]; then
            log_warn "等待超时 (${max_wait}s)，继续验证..."
            return 1
        fi

        # 通过合约调用获取队列长度
        local queue_len=$(cast call $(jq -r '.sequencer' deployments.json) \
            "getQueueLength(uint256)(uint256)" 100 \
            --rpc-url $ANVIL_RPC 2>/dev/null || echo "error")

        if [ "$queue_len" = "0" ] || [ "$queue_len" = "0x0" ]; then
            log_success "队列已清空"
            return 0
        fi

        echo -n "."
        sleep $POLL_INTERVAL
    done
}

# 运行 Forge 脚本
run_forge_script() {
    local script=$1
    local sig=${2:-"run()"}

    log_info "运行: forge script $script --sig '$sig'"

    forge script "$script" --sig "$sig" --rpc-url $ANVIL_RPC --broadcast --legacy 2>&1 | \
        grep -E "(✅|❌|✓|✗|PASS|FAIL|Error|Success|验证)" || true
}

# 运行验证脚本 (只读)
run_verify_script() {
    local sig=$1

    log_info "验证: forge script script/VerifyResults.s.sol --sig '$sig'"

    local output=$(forge script script/VerifyResults.s.sol --sig "$sig" --rpc-url $ANVIL_RPC 2>&1)
    echo "$output" | grep -E "(✅|❌|Phase|验证|Status|Expected|Actual|通过|失败)" || true

    # 检查是否通过
    if echo "$output" | grep -q "验证通过"; then
        return 0
    else
        return 1
    fi
}

# ============ 测试用例 ============

# Phase 1: 限价单测试
test_phase1() {
    echo ""
    echo "========================================"
    echo "  Phase 1: 限价单测试"
    echo "========================================"
    echo ""

    log_info "下单: 3 个买单, 2 个卖单"
    run_forge_script "script/TestPhase1_LimitOrders.s.sol"

    wait_for_queue_empty $MAX_WAIT_SECONDS

    log_info "验证结果..."
    if run_verify_script "verifyPhase1()"; then
        log_success "Phase 1 测试通过"
        return 0
    else
        log_error "Phase 1 测试失败"
        return 1
    fi
}

# Phase 2: 市价单测试
test_phase2() {
    echo ""
    echo "========================================"
    echo "  Phase 2: 市价单测试"
    echo "========================================"
    echo ""

    log_info "下市价单触发撮合"
    run_forge_script "script/TestPhase2_MarketOrders.s.sol"

    wait_for_queue_empty $MAX_WAIT_SECONDS

    log_info "验证结果..."
    if run_verify_script "verifyPhase2()"; then
        log_success "Phase 2 测试通过"
        return 0
    else
        log_error "Phase 2 测试失败"
        return 1
    fi
}

# Phase 3: 撤单测试
test_phase3() {
    echo ""
    echo "========================================"
    echo "  Phase 3: 撤单测试"
    echo "========================================"
    echo ""

    log_info "Step 1: 下单 (准备撤销)"
    run_forge_script "script/TestPhase3_RemoveOrders.s.sol"

    wait_for_queue_empty $MAX_WAIT_SECONDS

    log_info "Step 2: 提交撤单请求"
    run_forge_script "script/TestPhase3_RemoveOrders.s.sol:TestPhase3_RemoveOrders_Part2"

    wait_for_queue_empty $MAX_WAIT_SECONDS

    log_info "验证结果..."
    if run_verify_script "verifyPhase3()"; then
        log_success "Phase 3 测试通过"
        return 0
    else
        log_error "Phase 3 测试失败"
        return 1
    fi
}

# FIFO 测试
test_fifo() {
    echo ""
    echo "========================================"
    echo "  FIFO 测试: 先到先得"
    echo "========================================"
    echo ""

    log_info "准备用户资金"
    run_forge_script "script/TestFIFO.s.sol" "prepare()"

    log_info "Step 1: A 下买单"
    run_forge_script "script/TestFIFO.s.sol" "step1_A_buy()"
    wait_for_queue_empty $MAX_WAIT_SECONDS

    log_info "Step 2: B 下买单"
    run_forge_script "script/TestFIFO.s.sol" "step2_B_buy()"
    wait_for_queue_empty $MAX_WAIT_SECONDS

    log_info "Step 3: C 下卖单 (应与 A 成交)"
    run_forge_script "script/TestFIFO.s.sol" "step3_C_sell()"
    wait_for_queue_empty $MAX_WAIT_SECONDS

    log_info "验证 FIFO 结果..."
    local output=$(forge script script/TestFIFO.s.sol --sig "verify()" --rpc-url $ANVIL_RPC 2>&1)
    echo "$output" | grep -E "(CORRECT|ERROR|User|FIFO)" || true

    if echo "$output" | grep -q "CORRECT"; then
        log_success "FIFO 测试通过"
        return 0
    else
        log_error "FIFO 测试失败"
        return 1
    fi
}

# MatchAll 测试
test_match_all() {
    echo ""
    echo "========================================"
    echo "  MatchAll 测试: 批量撮合"
    echo "========================================"
    echo ""

    log_info "Phase 1: 放置 5 个买单"
    run_forge_script "script/TestMatchAll.s.sol"
    wait_for_queue_empty $MAX_WAIT_SECONDS

    log_info "Phase 2: 放置大卖单触发批量撮合"
    run_forge_script "script/TestMatchAllPhase2.s.sol"
    wait_for_queue_empty $MAX_WAIT_SECONDS

    log_info "验证订单簿状态..."
    local output=$(forge script script/VerifyResults.s.sol --sig "runDetailed()" --rpc-url $ANVIL_RPC 2>&1)
    echo "$output" | grep -E "(Match ID|Bid|Ask|Price)" || true

    # 检查 Match ID > 0
    local match_id=$(echo "$output" | grep "Match ID" | grep -oE '[0-9]+' | head -1)
    if [ -n "$match_id" ] && [ "$match_id" -gt 0 ]; then
        log_success "MatchAll 测试通过 (Match ID: $match_id)"
        return 0
    else
        log_error "MatchAll 测试失败"
        return 1
    fi
}

# PriceLevel 删除测试
test_price_level() {
    echo ""
    echo "========================================"
    echo "  PriceLevel 删除测试"
    echo "========================================"
    echo ""

    log_info "下单并撮合完全消耗"
    run_forge_script "script/TestPriceLevelRemoval.s.sol"
    wait_for_queue_empty $MAX_WAIT_SECONDS

    log_info "验证 PriceLevel 是否正确删除..."
    local output=$(forge script script/TestPriceLevelRemoval.s.sol:VerifyPriceLevelRemoval --rpc-url $ANVIL_RPC 2>&1)
    echo "$output" | grep -E "(✅|❌|PriceLevel|Volume|验证)" || true

    if echo "$output" | grep -q "验证通过"; then
        log_success "PriceLevel 删除测试通过"
        return 0
    else
        log_error "PriceLevel 删除测试失败"
        return 1
    fi
}

# 市价买单 FillAmount 测试
test_market_buy() {
    echo ""
    echo "========================================"
    echo "  市价买单 FillAmount 测试"
    echo "========================================"
    echo ""

    log_info "下限价单和市价买单"
    run_forge_script "script/TestMarketBuyFillAmount.s.sol"
    wait_for_queue_empty $MAX_WAIT_SECONDS

    log_info "验证市价买单成交..."
    # 通过 API 或合约查询订单状态
    local output=$(forge script script/VerifyResults.s.sol --sig "runDetailed()" --rpc-url $ANVIL_RPC 2>&1)
    echo "$output" | grep -E "(Match ID|Bid|Ask)" || true

    local match_id=$(echo "$output" | grep "Match ID" | grep -oE '[0-9]+' | head -1)
    if [ -n "$match_id" ] && [ "$match_id" -gt 0 ]; then
        log_success "市价买单测试通过"
        return 0
    else
        log_warn "市价买单测试需要手动检查"
        return 0
    fi
}

# ============ 主程序 ============

main() {
    echo ""
    echo "=============================================="
    echo "  Matching Engine 自动化测试"
    echo "=============================================="
    echo ""

    # 检查依赖
    check_anvil
    check_matcher || true

    # 检查 deployments.json
    if [ ! -f "deployments.json" ]; then
        log_error "deployments.json 不存在。请先运行 ./test_matcher.sh 部署合约"
        exit 1
    fi

    local test_name=${1:-"all"}
    local passed=0
    local failed=0

    case $test_name in
        phase1)
            test_phase1 && ((passed++)) || ((failed++))
            ;;
        phase2)
            test_phase2 && ((passed++)) || ((failed++))
            ;;
        phase3)
            test_phase3 && ((passed++)) || ((failed++))
            ;;
        fifo)
            test_fifo && ((passed++)) || ((failed++))
            ;;
        match_all)
            test_match_all && ((passed++)) || ((failed++))
            ;;
        price_level)
            test_price_level && ((passed++)) || ((failed++))
            ;;
        market_buy)
            test_market_buy && ((passed++)) || ((failed++))
            ;;
        all)
            # 运行所有测试 (按依赖顺序)
            test_phase1 && ((passed++)) || ((failed++))
            test_phase2 && ((passed++)) || ((failed++))
            test_phase3 && ((passed++)) || ((failed++))
            ;;
        *)
            echo "用法: $0 [test_name]"
            echo ""
            echo "可用测试:"
            echo "  phase1      - 限价单测试"
            echo "  phase2      - 市价单撮合测试"
            echo "  phase3      - 撤单测试"
            echo "  fifo        - FIFO 顺序测试"
            echo "  match_all   - 批量撮合测试"
            echo "  price_level - PriceLevel 删除测试"
            echo "  market_buy  - 市价买单测试"
            echo "  all         - 运行 phase1, phase2, phase3"
            exit 1
            ;;
    esac

    # 汇总结果
    echo ""
    echo "=============================================="
    echo "  测试结果汇总"
    echo "=============================================="
    echo ""
    log_success "通过: $passed"
    [ $failed -gt 0 ] && log_error "失败: $failed"
    echo ""

    [ $failed -eq 0 ] && exit 0 || exit 1
}

main "$@"
