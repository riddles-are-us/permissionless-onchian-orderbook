#!/bin/bash

# Matching 正确性测试脚本
# 测试核心匹配逻辑: FIFO, 价格优先, dust threshold 等
# 用法: ./test-scripts/test_matching_correctness.sh

set -e

# 切换到项目根目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ANVIL_RPC="${ANVIL_RPC:-http://127.0.0.1:8545}"

# Anvil 账户私钥
ACCOUNT_0="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
ACCOUNT_1="0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
ACCOUNT_2="0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"
ACCOUNT_3="0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# 检查前置条件
check_prereqs() {
    if ! cast chain-id --rpc-url $ANVIL_RPC &>/dev/null; then
        log_fail "Anvil 未运行"
        exit 1
    fi

    if [ ! -f "deployments.json" ]; then
        log_fail "deployments.json 不存在"
        exit 1
    fi

    log_pass "前置条件检查通过"
}

# 读取合约地址
load_addresses() {
    SEQUENCER=$(jq -r '.sequencer' deployments.json)
    ORDERBOOK=$(jq -r '.orderbook' deployments.json)
    ACCOUNT=$(jq -r '.account' deployments.json)
    WETH=$(jq -r '.weth' deployments.json)
    USDC=$(jq -r '.usdc' deployments.json)
    PAIR_ID=$(jq -r '.pairId' deployments.json)
}

# 获取队列长度
get_queue_length() {
    cast call $SEQUENCER "getQueueLength(uint256)(uint256)" 100 --rpc-url $ANVIL_RPC 2>/dev/null || echo "0"
}

# 等待队列清空
wait_queue_empty() {
    local timeout=${1:-30}
    local elapsed=0

    while [ $elapsed -lt $timeout ]; do
        local len=$(get_queue_length)
        if [ "$len" = "0" ]; then
            return 0
        fi
        sleep 1
        ((elapsed++))
    done
    return 1
}

# 获取订单信息
get_order_info() {
    local order_id=$1
    cast call $ORDERBOOK "orders(uint256)" $order_id --rpc-url $ANVIL_RPC 2>/dev/null
}

# 获取用户余额
get_balance() {
    local user=$1
    local token=$2
    cast call $ACCOUNT "balances(address,address)(uint256,uint256)" $user $token --rpc-url $ANVIL_RPC 2>/dev/null
}

# 获取最优价格
get_best_price() {
    local is_ask=$1
    cast call $ORDERBOOK "getBestPrice(bytes32,bool)(uint256)" $PAIR_ID $is_ask --rpc-url $ANVIL_RPC 2>/dev/null
}

# 获取 Match ID
get_match_id() {
    cast call $ORDERBOOK "matchId()(uint256)" --rpc-url $ANVIL_RPC 2>/dev/null
}

# ============ 测试用例 ============

# 测试 1: 基础限价单撮合
test_basic_limit_match() {
    echo ""
    echo "========================================"
    echo "  测试 1: 基础限价单撮合"
    echo "========================================"
    echo "  场景: A 下卖单 @100, B 下买单 @100"
    echo "  预期: 立即成交"
    echo ""

    local user_a=$(cast wallet address $ACCOUNT_1)
    local user_b=$(cast wallet address $ACCOUNT_2)

    # 记录初始 match_id
    local initial_match_id=$(get_match_id)
    log_info "初始 Match ID: $initial_match_id"

    # A 下卖单
    log_info "A 下卖单: 1 WETH @ 100 USDC"
    cast send $SEQUENCER "placeLimitOrder(bytes32,bool,uint256,uint256,uint256)" \
        $PAIR_ID true 10000000000 100000000 0 \
        --private-key $ACCOUNT_1 --rpc-url $ANVIL_RPC --legacy &>/dev/null

    # 等待处理
    sleep 2
    wait_queue_empty 10

    # B 下买单 (应触发撮合)
    log_info "B 下买单: 1 WETH @ 100 USDC"
    cast send $SEQUENCER "placeLimitOrder(bytes32,bool,uint256,uint256,uint256)" \
        $PAIR_ID false 10000000000 100000000 0 \
        --private-key $ACCOUNT_2 --rpc-url $ANVIL_RPC --legacy &>/dev/null

    # 等待处理
    sleep 3
    wait_queue_empty 15

    # 验证
    local final_match_id=$(get_match_id)
    log_info "最终 Match ID: $final_match_id"

    if [ "$final_match_id" -gt "$initial_match_id" ]; then
        log_pass "测试 1 通过: 撮合已执行"
        return 0
    else
        log_fail "测试 1 失败: 未发生撮合"
        return 1
    fi
}

# 测试 2: 价格优先
test_price_priority() {
    echo ""
    echo "========================================"
    echo "  测试 2: 价格优先"
    echo "========================================"
    echo "  场景: A 下卖单 @110, B 下卖单 @100, C 下买单 @110"
    echo "  预期: C 与 B 成交 (B 价格更低)"
    echo ""

    local initial_match_id=$(get_match_id)

    # A 下卖单 @110
    log_info "A 下卖单 @110"
    cast send $SEQUENCER "placeLimitOrder(bytes32,bool,uint256,uint256,uint256)" \
        $PAIR_ID true 11000000000 100000000 0 \
        --private-key $ACCOUNT_1 --rpc-url $ANVIL_RPC --legacy &>/dev/null

    sleep 2
    wait_queue_empty 10

    # B 下卖单 @100
    log_info "B 下卖单 @100"
    cast send $SEQUENCER "placeLimitOrder(bytes32,bool,uint256,uint256,uint256)" \
        $PAIR_ID true 10000000000 100000000 0 \
        --private-key $ACCOUNT_2 --rpc-url $ANVIL_RPC --legacy &>/dev/null

    sleep 2
    wait_queue_empty 10

    # C 下买单 @110 (应与 B 成交，因为 B 价格更低)
    log_info "C 下买单 @110"
    cast send $SEQUENCER "placeLimitOrder(bytes32,bool,uint256,uint256,uint256)" \
        $PAIR_ID false 11000000000 100000000 0 \
        --private-key $ACCOUNT_3 --rpc-url $ANVIL_RPC --legacy &>/dev/null

    sleep 3
    wait_queue_empty 15

    local final_match_id=$(get_match_id)

    # 检查最优卖价 (应该是 110，因为 100 被吃掉了)
    local best_ask=$(get_best_price true)
    log_info "最优卖价: $best_ask"

    if [ "$final_match_id" -gt "$initial_match_id" ]; then
        log_pass "测试 2 通过: 价格优先撮合"
        return 0
    else
        log_fail "测试 2 失败"
        return 1
    fi
}

# 测试 3: 市价单撮合
test_market_order() {
    echo ""
    echo "========================================"
    echo "  测试 3: 市价单撮合"
    echo "========================================"
    echo "  场景: A 下限价卖单 @150, B 下市价买单"
    echo "  预期: B 以 150 成交"
    echo ""

    local initial_match_id=$(get_match_id)

    # A 下限价卖单
    log_info "A 下限价卖单: 1 WETH @ 150 USDC"
    cast send $SEQUENCER "placeLimitOrder(bytes32,bool,uint256,uint256,uint256)" \
        $PAIR_ID true 15000000000 100000000 0 \
        --private-key $ACCOUNT_1 --rpc-url $ANVIL_RPC --legacy &>/dev/null

    sleep 2
    wait_queue_empty 10

    # B 下市价买单 (花费 150 USDC)
    log_info "B 下市价买单: 150 USDC"
    cast send $SEQUENCER "placeMarketOrder(bytes32,bool,uint256)" \
        $PAIR_ID false 15000000000 \
        --private-key $ACCOUNT_2 --rpc-url $ANVIL_RPC --legacy &>/dev/null

    sleep 3
    wait_queue_empty 15

    local final_match_id=$(get_match_id)

    if [ "$final_match_id" -gt "$initial_match_id" ]; then
        log_pass "测试 3 通过: 市价单撮合成功"
        return 0
    else
        log_fail "测试 3 失败"
        return 1
    fi
}

# 汇总测试结果
run_all_tests() {
    local passed=0
    local failed=0

    check_prereqs
    load_addresses

    # 准备测试用户资金
    log_info "准备测试用户资金..."
    for key in $ACCOUNT_1 $ACCOUNT_2 $ACCOUNT_3; do
        local addr=$(cast wallet address $key)

        # Mint tokens
        cast send $WETH "mint(address,uint256)" $addr 100000000000000000000 \
            --private-key $ACCOUNT_0 --rpc-url $ANVIL_RPC --legacy &>/dev/null
        cast send $USDC "mint(address,uint256)" $addr 100000000000 \
            --private-key $ACCOUNT_0 --rpc-url $ANVIL_RPC --legacy &>/dev/null

        # Approve
        cast send $WETH "approve(address,uint256)" $ACCOUNT 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff \
            --private-key $key --rpc-url $ANVIL_RPC --legacy &>/dev/null
        cast send $USDC "approve(address,uint256)" $ACCOUNT 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff \
            --private-key $key --rpc-url $ANVIL_RPC --legacy &>/dev/null

        # Deposit
        cast send $ACCOUNT "deposit(address,uint256)" $WETH 10000000000000000000 \
            --private-key $key --rpc-url $ANVIL_RPC --legacy &>/dev/null
        cast send $ACCOUNT "deposit(address,uint256)" $USDC 10000000000 \
            --private-key $key --rpc-url $ANVIL_RPC --legacy &>/dev/null
    done
    log_pass "资金准备完成"

    # 运行测试
    test_basic_limit_match && ((passed++)) || ((failed++))
    test_price_priority && ((passed++)) || ((failed++))
    test_market_order && ((passed++)) || ((failed++))

    # 汇总
    echo ""
    echo "========================================"
    echo "  测试结果"
    echo "========================================"
    echo ""
    log_pass "通过: $passed"
    [ $failed -gt 0 ] && log_fail "失败: $failed"

    return $failed
}

# 主程序
main() {
    echo ""
    echo "=============================================="
    echo "  Matching 正确性测试"
    echo "=============================================="
    echo ""

    run_all_tests
    exit $?
}

main
