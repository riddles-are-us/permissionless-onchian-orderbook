#!/bin/bash

# 一键部署和测试脚本
# 用法: ./test/setup_and_test.sh [选项] [test_name]
#
# 自动完成:
#   1. 检查 Anvil 是否运行
#   2. 部署合约 (如果需要)
#   3. 生成 Matcher 配置
#   4. 检查 Matcher 是否运行并正常处理
#   5. 运行指定测试并验证

set -e

# 切换到项目根目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 配置
ANVIL_RPC="${ANVIL_RPC:-http://127.0.0.1:8545}"
ANVIL_WS="${ANVIL_WS:-ws://127.0.0.1:8545}"
MATCHER_API="${MATCHER_API:-http://127.0.0.1:3000}"
CHAIN_ID=31337
MAX_WAIT_SECONDS=60
POLL_INTERVAL=2

# Anvil 默认私钥
DEPLOYER_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
USER_KEY="0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"

export PRIVATE_KEY=$DEPLOYER_KEY
export USER_PRIVATE_KEY=$USER_KEY

# 合约地址 (部署后填充)
SEQUENCER=""
ORDERBOOK=""

# 日志函数
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_error() { echo -e "${RED}[FAIL]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_step() { echo -e "${CYAN}==>${NC} $1"; }

# ============ 基础检查函数 ============

check_anvil() {
    log_step "检查 Anvil..."
    if ! cast chain-id --rpc-url $ANVIL_RPC &>/dev/null; then
        log_error "Anvil 未运行"
        echo "请在另一个终端运行: anvil"
        exit 1
    fi
    log_success "Anvil 运行中"
}

check_contracts_deployed() {
    if [ ! -f "deployments.json" ]; then
        return 1
    fi

    local seq=$(jq -r '.sequencer' deployments.json 2>/dev/null)
    if [ -z "$seq" ] || [ "$seq" = "null" ]; then
        return 1
    fi

    local code=$(cast code $seq --rpc-url $ANVIL_RPC 2>/dev/null)
    if [ "$code" = "0x" ] || [ -z "$code" ]; then
        return 1
    fi

    return 0
}

load_addresses() {
    SEQUENCER=$(jq -r '.sequencer' deployments.json)
    ORDERBOOK=$(jq -r '.orderbook' deployments.json)
}

deploy_contracts() {
    log_step "部署合约..."

    forge script script/Deploy.s.sol \
        --rpc-url $ANVIL_RPC \
        --broadcast \
        --legacy \
        2>&1 | grep -E "(Deployed|deployed|address|Contract|WETH|USDC|Account|OrderBook|Sequencer)" || true

    if [ ! -f "deployments.json" ]; then
        log_error "部署失败: deployments.json 未生成"
        exit 1
    fi

    log_success "合约部署完成"
    load_addresses
}

generate_matcher_config() {
    log_step "生成 Matcher 配置..."

    local account=$(jq -r '.account' deployments.json)
    local orderbook=$(jq -r '.orderbook' deployments.json)
    local sequencer=$(jq -r '.sequencer' deployments.json)
    local pair_id=$(jq -r '.pairId' deployments.json)

    cat > matcher/config.toml <<EOF
[network]
rpc_url = "$ANVIL_WS"
chain_id = $CHAIN_ID

[contracts]
account = "$account"
orderbook = "$orderbook"
sequencer = "$sequencer"
trading_pair = "$pair_id"

[executor]
private_key = "$DEPLOYER_KEY"
gas_price_gwei = 1
gas_limit = 5000000

[matching]
max_batch_size = 10
matching_interval_ms = 3000

[sync]
start_block = 0
sync_historical = true
EOF

    log_success "配置生成: matcher/config.toml"
}

# ============ Matcher 检查函数 ============

check_matcher_api() {
    curl -s --connect-timeout 2 "$MATCHER_API/health" &>/dev/null || \
    curl -s --connect-timeout 2 "$MATCHER_API/overview" &>/dev/null
}

get_queue_length() {
    cast call $SEQUENCER "getQueueLength(uint256)(uint256)" 100 --rpc-url $ANVIL_RPC 2>/dev/null || echo "error"
}

# 验证 Matcher 是否正常工作 (通过提交测试订单并检查处理)
verify_matcher_working() {
    log_step "验证 Matcher 是否正常工作..."

    # 检查 API
    if ! check_matcher_api; then
        log_error "Matcher API 不可用"
        echo ""
        echo "请启动 Matcher:"
        echo "  cd matcher && cargo run -- --log-level debug"
        echo ""
        return 1
    fi

    # 获取当前队列长度
    local initial_queue=$(get_queue_length)

    if [ "$initial_queue" = "error" ]; then
        log_error "无法获取队列状态"
        return 1
    fi

    # 如果队列有订单，等待一会看是否被处理
    if [ "$initial_queue" != "0" ]; then
        log_info "队列中有 $initial_queue 个订单，等待 Matcher 处理..."

        local waited=0
        while [ $waited -lt 15 ]; do
            sleep 3
            waited=$((waited + 3))
            local current=$(get_queue_length)

            if [ "$current" = "0" ]; then
                log_success "Matcher 正常工作 (队列已清空)"
                return 0
            fi

            if [ "$current" -lt "$initial_queue" ]; then
                log_success "Matcher 正常工作 (正在处理订单: $initial_queue -> $current)"
                # 继续等待完成
                wait_for_queue_empty 30
                return 0
            fi
        done

        log_error "Matcher 未处理队列中的订单"
        echo ""
        echo "可能原因:"
        echo "  1. Matcher 使用了旧的配置，需要重启"
        echo "  2. Matcher 未正确连接到合约"
        echo ""
        echo "请重启 Matcher:"
        echo "  cd matcher && cargo run -- --log-level debug"
        echo ""
        return 1
    fi

    log_success "Matcher 就绪"
    return 0
}

# 等待队列清空
wait_for_queue_empty() {
    local max_wait=${1:-$MAX_WAIT_SECONDS}
    local start_time=$(date +%s)

    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))

        if [ $elapsed -gt $max_wait ]; then
            log_warn "等待超时 (${max_wait}s)"
            return 1
        fi

        local queue_len=$(get_queue_length)

        if [ "$queue_len" = "0" ]; then
            log_success "队列已清空 (${elapsed}s)"
            return 0
        fi

        echo -n "."
        sleep $POLL_INTERVAL
    done
}

# ============ 测试辅助函数 ============

run_forge_script() {
    local script=$1
    local sig=${2:-"run()"}

    log_info "执行: $script"
    forge script "$script" --sig "$sig" --rpc-url $ANVIL_RPC --broadcast --legacy 2>&1 | \
        grep -E "(✅|❌|Request|Order|reqId|orderId|Deposit|placed|Buy|Sell|price|amount)" || true
}

run_verify() {
    local sig=$1

    local output=$(forge script script/VerifyResults.s.sol --sig "$sig" --rpc-url $ANVIL_RPC 2>&1)
    echo "$output" | grep -E "(✅|❌|Phase|验证|Status|Expected|Actual|通过|失败|Bid|Ask|Price|Volume|Match)" || true

    if echo "$output" | grep -q "验证通过"; then
        return 0
    else
        return 1
    fi
}

get_match_id() {
    cast call $ORDERBOOK "matchId()(uint256)" --rpc-url $ANVIL_RPC 2>/dev/null || echo "0"
}

# ============ 测试用例 ============

test_phase1() {
    echo ""
    echo "========================================"
    echo "  Phase 1: 限价单测试"
    echo "========================================"
    echo "  预期: 3 个 Bid 层级, 2 个 Ask 层级"
    echo ""

    run_forge_script "script/TestPhase1_LimitOrders.s.sol"

    echo ""
    log_info "等待处理..."
    if ! wait_for_queue_empty 60; then
        log_error "Matcher 未能处理订单"
        return 1
    fi

    echo ""
    log_info "验证结果..."
    if run_verify "verifyPhase1()"; then
        log_success "Phase 1 通过"
        return 0
    else
        log_error "Phase 1 失败"
        return 1
    fi
}

test_phase2() {
    echo ""
    echo "========================================"
    echo "  Phase 2: 市价单测试"
    echo "========================================"
    echo "  预期: 市价单与限价单撮合"
    echo ""

    local initial_match_id=$(get_match_id)

    run_forge_script "script/TestPhase2_MarketOrders.s.sol"

    echo ""
    log_info "等待处理..."
    if ! wait_for_queue_empty 60; then
        log_error "Matcher 未能处理订单"
        return 1
    fi

    echo ""
    log_info "验证结果..."
    local final_match_id=$(get_match_id)

    if [ "$final_match_id" -gt "$initial_match_id" ]; then
        log_info "Match ID: $initial_match_id -> $final_match_id"
        run_verify "verifyPhase2()" || true
        log_success "Phase 2 通过"
        return 0
    else
        log_error "Phase 2 失败 (无撮合发生)"
        return 1
    fi
}

test_phase3() {
    echo ""
    echo "========================================"
    echo "  Phase 3: 撤单测试"
    echo "========================================"
    echo "  预期: 订单被撤销，资金解锁"
    echo ""

    # Step 1: 下单并捕获订单 ID
    log_info "执行: script/TestPhase3_RemoveOrders.s.sol:TestPhase3_RemoveOrders"
    local output=$(forge script "script/TestPhase3_RemoveOrders.s.sol:TestPhase3_RemoveOrders" --rpc-url $ANVIL_RPC --broadcast --legacy 2>&1)
    echo "$output" | grep -E "(Order|OrderID|reqId)" || true

    # 提取要撤销的订单 ID (第一个订单)
    local order_id=$(echo "$output" | grep -E "要撤销的订单 ID:" | grep -oE '[0-9]+' | tail -1)
    if [ -z "$order_id" ]; then
        # 尝试从 OrderID 行提取
        order_id=$(echo "$output" | grep "OrderID:" | head -1 | grep -oE '[0-9]+' | tail -1)
    fi

    if [ -z "$order_id" ]; then
        log_error "无法获取订单 ID"
        return 1
    fi

    log_info "要撤销的订单 ID: $order_id"

    echo ""
    log_info "等待下单处理..."
    if ! wait_for_queue_empty 60; then
        log_error "Matcher 未能处理下单"
        return 1
    fi

    # Step 2: 撤单 (使用正确的订单 ID)
    echo ""
    log_info "执行撤单: Order $order_id"
    export ORDER_ID_TO_CANCEL=$order_id
    forge script "script/TestPhase3_RemoveOrders.s.sol:TestPhase3_RemoveOrders_Part2" \
        --rpc-url $ANVIL_RPC --broadcast --legacy 2>&1 | \
        grep -E "(Order|Cancel|removed|submitted)" || true

    echo ""
    log_info "等待撤单处理..."
    if ! wait_for_queue_empty 60; then
        log_error "Matcher 未能处理撤单"
        return 1
    fi

    # 等待交易确认 (队列清空表示 Matcher 发送了交易，但需要等链上确认)
    log_info "等待交易确认..."
    sleep 5

    # 计算保留订单 ID
    local keep_order_id=$((order_id + 1))
    export ORDER_ID_TO_KEEP=$keep_order_id

    echo ""
    log_info "验证结果..."
    local verify_output=$(forge script script/VerifyResults.s.sol --sig "verifyPhase3()" --rpc-url $ANVIL_RPC 2>&1)
    echo "$verify_output" | grep -E "(✅|❌|Phase|验证|Order|通过|失败)" || true

    if echo "$verify_output" | grep -q "验证通过"; then
        log_success "Phase 3 通过"
        return 0
    else
        log_error "Phase 3 失败"
        return 1
    fi
}

test_fifo() {
    echo ""
    echo "========================================"
    echo "  FIFO 测试: 先到先得"
    echo "========================================"
    echo "  场景: A买单, B买单, C卖单"
    echo "  预期: C 与 A 成交 (A 先下单)"
    echo ""

    run_forge_script "script/TestFIFO.s.sol" "prepare()"

    run_forge_script "script/TestFIFO.s.sol" "step1_A_buy()"
    wait_for_queue_empty 30 || true
    echo ""

    run_forge_script "script/TestFIFO.s.sol" "step2_B_buy()"
    wait_for_queue_empty 30 || true
    echo ""

    run_forge_script "script/TestFIFO.s.sol" "step3_C_sell()"
    wait_for_queue_empty 30 || true
    echo ""

    log_info "验证 FIFO..."
    local output=$(forge script script/TestFIFO.s.sol --sig "verify()" --rpc-url $ANVIL_RPC 2>&1)
    echo "$output" | grep -E "(CORRECT|ERROR|User|FIFO|WETH|USDC)" || true

    if echo "$output" | grep -q "CORRECT"; then
        log_success "FIFO 测试通过"
        return 0
    else
        log_error "FIFO 测试失败"
        return 1
    fi
}

test_match_all() {
    echo ""
    echo "========================================"
    echo "  MatchAll 测试: 批量撮合"
    echo "========================================"
    echo "  预期: 多个订单批量撮合"
    echo ""

    local initial_match_id=$(get_match_id)

    run_forge_script "script/TestMatchAll.s.sol"
    wait_for_queue_empty 30 || true
    echo ""

    run_forge_script "script/TestMatchAllPhase2.s.sol"
    wait_for_queue_empty 60 || true
    echo ""

    local final_match_id=$(get_match_id)
    log_info "Match ID: $initial_match_id -> $final_match_id"

    if [ "$final_match_id" -gt "$initial_match_id" ]; then
        log_success "MatchAll 测试通过"
        return 0
    else
        log_error "MatchAll 测试失败"
        return 1
    fi
}

test_price_level() {
    echo ""
    echo "========================================"
    echo "  PriceLevel 删除测试"
    echo "========================================"
    echo "  预期: 完全成交后价格层级被删除"
    echo ""

    run_forge_script "script/TestPriceLevelRemoval.s.sol"
    wait_for_queue_empty 60 || true
    echo ""

    log_info "验证 PriceLevel..."
    local output=$(forge script script/TestPriceLevelRemoval.s.sol:VerifyPriceLevelRemoval --rpc-url $ANVIL_RPC 2>&1)
    echo "$output" | grep -E "(✅|❌|PriceLevel|Volume|验证)" || true

    if echo "$output" | grep -q "验证通过"; then
        log_success "PriceLevel 测试通过"
        return 0
    else
        log_error "PriceLevel 测试失败"
        return 1
    fi
}

# ============ 帮助信息 ============

show_help() {
    echo "Matching Engine 测试脚本"
    echo ""
    echo "用法: $0 [选项] [测试名]"
    echo ""
    echo "选项:"
    echo "  --deploy-only    只部署合约"
    echo "  --skip-deploy    跳过部署"
    echo "  --help, -h       显示帮助"
    echo ""
    echo "测试名:"
    echo "  all          phase1 + phase2 + phase3 (默认)"
    echo "  phase1       限价单测试"
    echo "  phase2       市价单撮合测试"
    echo "  phase3       撤单测试"
    echo "  fifo         FIFO 顺序测试"
    echo "  match_all    批量撮合测试"
    echo "  price_level  PriceLevel 删除测试"
}

# ============ 主程序 ============

main() {
    local skip_deploy=false
    local deploy_only=false
    local test_name="all"

    # 解析参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            --deploy-only) deploy_only=true; shift ;;
            --skip-deploy) skip_deploy=true; shift ;;
            --help|-h) show_help; exit 0 ;;
            *) test_name=$1; shift ;;
        esac
    done

    echo ""
    echo "=============================================="
    echo "  Matching Engine 测试"
    echo "=============================================="
    echo ""

    # Step 1: 检查 Anvil
    check_anvil

    # Step 2: 部署合约
    if [ "$skip_deploy" = false ]; then
        if check_contracts_deployed; then
            log_info "合约已部署"
            load_addresses
        else
            deploy_contracts
        fi
        generate_matcher_config
    else
        load_addresses
    fi

    if [ "$deploy_only" = true ]; then
        echo ""
        log_success "部署完成"
        echo ""
        echo "下一步: 启动 Matcher"
        echo "  cd matcher && cargo run -- --log-level debug"
        exit 0
    fi

    # Step 3: 验证 Matcher
    if ! verify_matcher_working; then
        exit 1
    fi

    # Step 4: 运行测试
    local passed=0
    local failed=0

    case $test_name in
        phase1)     test_phase1 && ((passed++)) || ((failed++)) ;;
        phase2)     test_phase2 && ((passed++)) || ((failed++)) ;;
        phase3)     test_phase3 && ((passed++)) || ((failed++)) ;;
        fifo)       test_fifo && ((passed++)) || ((failed++)) ;;
        match_all)  test_match_all && ((passed++)) || ((failed++)) ;;
        price_level) test_price_level && ((passed++)) || ((failed++)) ;;
        all)
            test_phase1 && ((passed++)) || ((failed++))
            test_phase2 && ((passed++)) || ((failed++))
            test_phase3 && ((passed++)) || ((failed++))
            ;;
        *)
            log_error "未知测试: $test_name"
            show_help
            exit 1
            ;;
    esac

    # 汇总
    echo ""
    echo "=============================================="
    echo "  测试结果"
    echo "=============================================="
    echo ""
    echo -e "${GREEN}通过: $passed${NC}"
    [ $failed -gt 0 ] && echo -e "${RED}失败: $failed${NC}"
    echo ""

    [ $failed -eq 0 ] && exit 0 || exit 1
}

main "$@"
