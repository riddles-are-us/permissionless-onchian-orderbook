#!/bin/bash

echo "=========================================="
echo "Setting up Foundry for OrderBook"
echo "=========================================="
echo ""

# 检查是否安装了 Foundry
if ! command -v forge &> /dev/null
then
    echo "❌ Foundry not found. Installing..."
    curl -L https://foundry.paradigm.xyz | bash
    source ~/.bashrc
    foundryup
else
    echo "✅ Foundry already installed"
    forge --version
fi

echo ""
echo "Installing forge-std library..."
forge install foundry-rs/forge-std

echo ""
echo "Compiling contracts..."
forge build

echo ""
echo "=========================================="
echo "✨ Setup Complete!"
echo "=========================================="
echo ""
echo "Run tests with:"
echo "  forge test -vvv"
echo ""
