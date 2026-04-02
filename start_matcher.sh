#!/bin/bash
# Matcher 启动脚本

set -e

echo "========================================="
echo "🚀 启动 OrderBook Matcher"
echo "========================================="

# 检查是否已经有 matcher 会话在运行
if tmux has-session -t matcher 2>/dev/null; then
    echo "⚠️  检测到 matcher 会话已经存在"
    echo ""
    echo "选项："
    echo "  1. 查看现有会话: tmux attach -t matcher"
    echo "  2. 关闭旧会话: tmux kill-session -t matcher"
    echo ""
    read -p "是否关闭旧会话并重新启动？(y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "🔄 关闭旧会话..."
        tmux kill-session -t matcher
    else
        echo "❌ 取消启动，进入现有会话..."
        tmux attach -t matcher
        exit 0
    fi
fi

# 检查 MongoDB
echo ""
echo "📦 检查 MongoDB 状态..."
if ! docker-compose ps | grep -q "orderbook-mongodb.*Up"; then
    echo "⚠️  MongoDB 未运行，正在启动..."
    docker-compose up -d
    sleep 3
fi
echo "✅ MongoDB 运行中"

# 检查 Cloudflare Tunnel
echo ""
echo "🌐 检查 Cloudflare Tunnel 状态..."
if ! systemctl is-active --quiet cloudflare-tunnel; then
    echo "⚠️  Cloudflare Tunnel 未运行，正在启动..."
    sudo systemctl start cloudflare-tunnel
    sleep 2
fi
TUNNEL_URL=$(sudo journalctl -u cloudflare-tunnel -n 100 --no-pager | grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1)
echo "✅ Cloudflare Tunnel 运行中"
if [ -n "$TUNNEL_URL" ]; then
    echo "   API 地址: $TUNNEL_URL"
fi

# 启动 Matcher
echo ""
echo "🎯 启动 Matcher..."
cd /root/test/permissionless-onchian-orderbook/matcher

# 创建 tmux 会话
tmux new-session -s matcher -d

# 在会话中运行 matcher
tmux send-keys -t matcher "cd /root/test/permissionless-onchian-orderbook/matcher" C-m
tmux send-keys -t matcher "echo '🚀 启动 Matcher...'" C-m
tmux send-keys -t matcher "cargo run --release -- -l info" C-m

echo ""
echo "========================================="
echo "✅ Matcher 已在 tmux 会话中启动！"
echo "========================================="
echo ""
echo "📋 常用命令："
echo "  查看日志: tmux attach -t matcher"
echo "  分离会话: Ctrl+B, 然后按 D"
echo "  停止服务: tmux kill-session -t matcher"
echo ""
echo "🌐 API 地址："
if [ -n "$TUNNEL_URL" ]; then
    echo "  外部访问: $TUNNEL_URL"
else
    echo "  外部访问: (查看日志获取 URL)"
fi
echo "  本地测试: http://localhost:8080"
echo ""
echo "等待 3 秒后自动进入会话..."
sleep 3
tmux attach -t matcher
