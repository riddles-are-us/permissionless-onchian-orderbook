#!/bin/bash

# Matcher API 验证脚本
# 通过 Matcher 的 REST API 检查订单簿状态和订单结果
# 用法: ./test-scripts/verify_matcher_api.sh <command> [args]

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
CYAN='\033[0;36m'
NC='\033[0m'

MATCHER_API="${MATCHER_API:-http://127.0.0.1:3000}"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# 检查 API 是否可用
check_api() {
    if ! curl -s "$MATCHER_API/health" &>/dev/null && ! curl -s "$MATCHER_API/overview" &>/dev/null; then
        log_error "Matcher API 不可用: $MATCHER_API"
        echo "请确保 Matcher 正在运行并且 API 已启动"
        exit 1
    fi
    log_success "Matcher API 可用"
}

# 获取系统概览
get_overview() {
    echo ""
    echo "========================================"
    echo "  系统概览"
    echo "========================================"

    local response=$(curl -s "$MATCHER_API/overview" 2>/dev/null)

    if [ -z "$response" ]; then
        log_warn "无法获取系统概览"
        return
    fi

    echo "$response" | jq '.' 2>/dev/null || echo "$response"
}

# 获取订单簿
get_orderbook() {
    local depth=${1:-10}

    echo ""
    echo "========================================"
    echo "  订单簿 (深度: $depth)"
    echo "========================================"

    local response=$(curl -s "$MATCHER_API/orderbook?depth=$depth" 2>/dev/null)

    if [ -z "$response" ]; then
        log_warn "无法获取订单簿"
        return
    fi

    echo -e "${CYAN}Asks (卖单):${NC}"
    echo "$response" | jq -r '.asks[] | "  \(.price) | \(.amount) | \(.filled_amount) | \(.order_id)"' 2>/dev/null || echo "  (empty)"

    echo ""
    echo -e "${CYAN}Bids (买单):${NC}"
    echo "$response" | jq -r '.bids[] | "  \(.price) | \(.amount) | \(.filled_amount) | \(.order_id)"' 2>/dev/null || echo "  (empty)"
}

# 查询订单状态
get_order() {
    local order_id=$1

    if [ -z "$order_id" ]; then
        log_error "请提供订单 ID"
        return 1
    fi

    echo ""
    echo "========================================"
    echo "  订单 #$order_id"
    echo "========================================"

    local response=$(curl -s "$MATCHER_API/orders/$order_id" 2>/dev/null)

    if [ -z "$response" ] || echo "$response" | grep -q "not found"; then
        log_warn "订单 $order_id 不存在"
        return 1
    fi

    echo "$response" | jq '.' 2>/dev/null || echo "$response"

    # 检查订单状态
    local status=$(echo "$response" | jq -r '.status' 2>/dev/null)
    local filled=$(echo "$response" | jq -r '.filled_amount' 2>/dev/null)
    local amount=$(echo "$response" | jq -r '.amount' 2>/dev/null)

    echo ""
    if [ "$status" = "filled" ] || [ "$status" = "Filled" ]; then
        log_success "订单已完全成交"
    elif [ "$status" = "partial" ] || [ "$status" = "Partial" ]; then
        log_info "订单部分成交: $filled / $amount"
    elif [ "$status" = "open" ] || [ "$status" = "Open" ]; then
        log_info "订单未成交"
    elif [ "$status" = "cancelled" ] || [ "$status" = "Cancelled" ]; then
        log_info "订单已撤销"
    fi
}

# 获取用户订单列表
get_user_orders() {
    local trader=$1
    local status=${2:-""}

    if [ -z "$trader" ]; then
        log_error "请提供用户地址"
        return 1
    fi

    echo ""
    echo "========================================"
    echo "  用户订单: $trader"
    echo "========================================"

    local url="$MATCHER_API/orders?trader=$trader"
    [ -n "$status" ] && url="$url&status=$status"

    local response=$(curl -s "$url" 2>/dev/null)

    if [ -z "$response" ]; then
        log_warn "无法获取用户订单"
        return
    fi

    echo "$response" | jq '.[] | {order_id, status, price, amount, filled_amount}' 2>/dev/null || echo "$response"
}

# 获取最近成交
get_trades() {
    local limit=${1:-10}

    echo ""
    echo "========================================"
    echo "  最近成交 (最多 $limit 笔)"
    echo "========================================"

    local response=$(curl -s "$MATCHER_API/trades?limit=$limit" 2>/dev/null)

    if [ -z "$response" ]; then
        log_warn "无法获取成交记录"
        return
    fi

    echo "$response" | jq '.[] | {match_id, price, amount, maker_order_id, taker_order_id}' 2>/dev/null || echo "$response"
}

# 验证 Phase 1 结果
verify_phase1() {
    echo ""
    echo "========================================"
    echo "  验证 Phase 1: 限价单"
    echo "========================================"

    local response=$(curl -s "$MATCHER_API/orderbook?depth=10" 2>/dev/null)

    if [ -z "$response" ]; then
        log_error "无法获取订单簿"
        return 1
    fi

    local bid_count=$(echo "$response" | jq '.bids | length' 2>/dev/null || echo "0")
    local ask_count=$(echo "$response" | jq '.asks | length' 2>/dev/null || echo "0")

    echo "Bid 数量: $bid_count (预期: 3)"
    echo "Ask 数量: $ask_count (预期: 2)"

    if [ "$bid_count" -eq 3 ] && [ "$ask_count" -eq 2 ]; then
        log_success "Phase 1 验证通过"
        return 0
    else
        log_error "Phase 1 验证失败"
        return 1
    fi
}

# 验证订单是否成交
verify_order_filled() {
    local order_id=$1
    local expected_status=${2:-"filled"}

    local response=$(curl -s "$MATCHER_API/orders/$order_id" 2>/dev/null)
    local status=$(echo "$response" | jq -r '.status' 2>/dev/null | tr '[:upper:]' '[:lower:]')

    if [ "$status" = "$expected_status" ]; then
        log_success "订单 $order_id 状态正确: $status"
        return 0
    else
        log_error "订单 $order_id 状态错误: $status (预期: $expected_status)"
        return 1
    fi
}

# 主程序
main() {
    local cmd=${1:-"overview"}

    check_api

    case $cmd in
        overview)
            get_overview
            ;;
        orderbook)
            get_orderbook ${2:-10}
            ;;
        order)
            get_order "$2"
            ;;
        orders)
            get_user_orders "$2" "$3"
            ;;
        trades)
            get_trades ${2:-10}
            ;;
        verify-phase1)
            verify_phase1
            ;;
        verify-order)
            verify_order_filled "$2" "$3"
            ;;
        all)
            get_overview
            get_orderbook 5
            get_trades 5
            ;;
        *)
            echo "Matcher API 验证工具"
            echo ""
            echo "用法: $0 <command> [args]"
            echo ""
            echo "命令:"
            echo "  overview              - 系统概览"
            echo "  orderbook [depth]     - 获取订单簿"
            echo "  order <id>            - 查询订单"
            echo "  orders <trader> [status] - 用户订单列表"
            echo "  trades [limit]        - 最近成交"
            echo "  verify-phase1         - 验证 Phase 1"
            echo "  verify-order <id> [status] - 验证订单状态"
            echo "  all                   - 显示所有信息"
            ;;
    esac
}

main "$@"
