#!/bin/bash

# 配置
SEQUENCER=0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9
ACCOUNT=0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0
WETH=0x5FbDB2315678afecb367f032d93F642f64180aa3
USDC=0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
RPC=http://127.0.0.1:8545
PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
PAIR_ID=0xe3fd74b5016b57bf4180a8d977a55d749f0f8f76be8d457de0768c85a6acc816

echo "=== Minting and Depositing Tokens ==="

# Mint WETH
cast send $WETH "mint(address,uint256)" 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 1000000000000000000000 --rpc-url $RPC --private-key $PK

# Mint USDC  
cast send $USDC "mint(address,uint256)" 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 1000000000000 --rpc-url $RPC --private-key $PK

# Approve WETH
cast send $WETH "approve(address,uint256)" $ACCOUNT 115792089237316195423570985008687907853269984665640564039457584007913129639935 --rpc-url $RPC --private-key $PK

# Approve USDC
cast send $USDC "approve(address,uint256)" $ACCOUNT 115792089237316195423570985008687907853269984665640564039457584007913129639935 --rpc-url $RPC --private-key $PK

# Deposit WETH
cast send $ACCOUNT "deposit(address,uint256)" $WETH 100000000000000000000 --rpc-url $RPC --private-key $PK

# Deposit USDC
cast send $ACCOUNT "deposit(address,uint256)" $USDC 100000000000 --rpc-url $RPC --private-key $PK

echo ""
echo "=== Placing Buy Orders ==="

# 买单: 价格递减 2000, 1990, 1980, 1970, 1960
for i in {0..4}; do
  price=$((2000 - i * 10))
  price_scaled=$((price * 100000000))  # * 10^8
  amount=$((10000000 + i * 20000000))  # 0.1, 0.3, 0.5, 0.7, 0.9 WETH
  echo "Placing buy order: price=$price USDC, amount=0.$((amount / 10000000)) WETH"
  cast send $SEQUENCER "placeLimitOrder(bytes32,bool,uint256,uint256)" $PAIR_ID false $price_scaled $amount --rpc-url $RPC --private-key $PK
done

echo ""
echo "=== Placing Sell Orders ==="

# 卖单: 价格递增 2010, 2020, 2030, 2040, 2050
for i in {0..4}; do
  price=$((2010 + i * 10))
  price_scaled=$((price * 100000000))  # * 10^8
  amount=$((10000000 + i * 20000000))  # 0.1, 0.3, 0.5, 0.7, 0.9 WETH
  echo "Placing sell order: price=$price USDC, amount=0.$((amount / 10000000)) WETH"
  cast send $SEQUENCER "placeLimitOrder(bytes32,bool,uint256,uint256)" $PAIR_ID true $price_scaled $amount --rpc-url $RPC --private-key $PK
done

echo ""
echo "=== Done! ==="
echo "10 orders placed (5 buy + 5 sell)"
echo "Check your anvil window for transaction logs"
echo "Orders are in Sequencer queue - matcher will process them"
