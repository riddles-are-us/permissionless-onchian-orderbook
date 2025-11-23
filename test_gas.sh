#!/bin/bash

echo "🔥 OrderBook Gas Consumption Tests"
echo "===================================="
echo ""

# 运行 gas 测试
forge test --match-contract GasTest -vv --gas-report

echo ""
echo "📊 Gas Report Summary"
echo "===================="
echo ""
echo "运行完成！查看上面的详细 gas 消耗数据。"
