import { useState } from 'react';
import { Contract, parseUnits, formatUnits } from 'ethers';
import { CONFIG } from '../config';

// ERC20 ABI（只需要我们用到的函数）
const ERC20_ABI = [
  'function approve(address spender, uint256 amount) returns (bool)',
  'function allowance(address owner, address spender) view returns (uint256)',
  'function balanceOf(address account) view returns (uint256)',
  'function decimals() view returns (uint8)',
];

// Sequencer ABI
const SEQUENCER_ABI = [
  'function placeLimitOrder(bytes32 pairId, bool isAsk, uint256 price, uint256 amount) returns (uint256 requestId, uint256 orderId)',
];

// Account ABI
const ACCOUNT_ABI = [
  'function deposit(address token, uint256 amount)',
  'function balances(address user, address token) view returns (uint256)',
];

export function usePlaceOrder(signer) {
  const [placing, setPlacing] = useState(false);
  const [approving, setApproving] = useState(false);
  const [depositing, setDepositing] = useState(false);
  const [error, setError] = useState(null);

  // 检查并授权代币
  const approveToken = async (tokenAddress, amount, decimals = 18) => {
    if (!signer) throw new Error('Wallet not connected');

    setApproving(true);
    setError(null);

    try {
      const token = new Contract(tokenAddress, ERC20_ABI, signer);
      const accountAddress = CONFIG.CONTRACTS.ACCOUNT;
      const userAddress = await signer.getAddress();

      // 检查当前授权额度
      const currentAllowance = await token.allowance(userAddress, accountAddress);
      const amountWei = parseUnits(amount.toString(), decimals);

      if (currentAllowance >= amountWei) {
        console.log('Already approved');
        return true;
      }

      // 授权最大额度以减少后续交易
      const maxApproval = parseUnits('1000000', decimals);
      const tx = await token.approve(accountAddress, maxApproval);
      console.log('Approval tx sent:', tx.hash);

      await tx.wait();
      console.log('Approval confirmed');
      return true;
    } catch (err) {
      console.error('Approval failed:', err);
      setError(err.message || '授权失败');
      return false;
    } finally {
      setApproving(false);
    }
  };

  // 充值到 Account 合约
  const depositToAccount = async (tokenAddress, amount, decimals = 18) => {
    if (!signer) throw new Error('Wallet not connected');

    setDepositing(true);
    setError(null);

    try {
      const account = new Contract(CONFIG.CONTRACTS.ACCOUNT, ACCOUNT_ABI, signer);
      const amountWei = parseUnits(amount.toString(), decimals);

      const tx = await account.deposit(tokenAddress, amountWei);
      console.log('Deposit tx sent:', tx.hash);

      await tx.wait();
      console.log('Deposit confirmed');
      return true;
    } catch (err) {
      console.error('Deposit failed:', err);
      setError(err.message || '充值失败');
      return false;
    } finally {
      setDepositing(false);
    }
  };

  // 下限价单
  const placeLimitOrder = async ({ isAsk, price, amount }) => {
    if (!signer) {
      setError('请先连接钱包');
      return null;
    }

    setPlacing(true);
    setError(null);

    try {
      const sequencer = new Contract(CONFIG.CONTRACTS.SEQUENCER, SEQUENCER_ABI, signer);

      // 将价格和数量转换为合约要求的格式
      // 价格单位：USDC，8位小数
      // 数量单位：WETH，8位小数（注意这里不是18位）
      const priceScaled = parseUnits(price.toString(), 8);
      const amountScaled = parseUnits(amount.toString(), 8);

      console.log('Placing order:', {
        isAsk,
        price: price.toString(),
        amount: amount.toString(),
        priceScaled: priceScaled.toString(),
        amountScaled: amountScaled.toString(),
      });

      const tx = await sequencer.placeLimitOrder(
        CONFIG.PAIR_ID,
        isAsk,
        priceScaled,
        amountScaled
      );

      console.log('Order tx sent:', tx.hash);
      const receipt = await tx.wait();
      console.log('Order confirmed in block:', receipt.blockNumber);

      return {
        txHash: tx.hash,
        blockNumber: receipt.blockNumber,
      };
    } catch (err) {
      console.error('Place order failed:', err);
      setError(err.message || '下单失败');
      return null;
    } finally {
      setPlacing(false);
    }
  };

  // 获取账户余额
  const getAccountBalance = async (tokenAddress) => {
    if (!signer) return '0';

    try {
      const account = new Contract(CONFIG.CONTRACTS.ACCOUNT, ACCOUNT_ABI, signer);
      const userAddress = await signer.getAddress();
      const balance = await account.balances(userAddress, tokenAddress);

      // 根据代币类型返回不同精度
      const isWETH = tokenAddress.toLowerCase() === CONFIG.CONTRACTS.WETH.toLowerCase();
      const decimals = isWETH ? 18 : 6;

      return formatUnits(balance, decimals);
    } catch (err) {
      console.error('Failed to get account balance:', err);
      return '0';
    }
  };

  // 获取钱包余额
  const getWalletBalance = async (tokenAddress) => {
    if (!signer) return '0';

    try {
      const token = new Contract(tokenAddress, ERC20_ABI, signer);
      const userAddress = await signer.getAddress();
      const balance = await token.balanceOf(userAddress);
      const decimals = await token.decimals();

      return formatUnits(balance, decimals);
    } catch (err) {
      console.error('Failed to get wallet balance:', err);
      return '0';
    }
  };

  return {
    placing,
    approving,
    depositing,
    error,
    approveToken,
    depositToAccount,
    placeLimitOrder,
    getAccountBalance,
    getWalletBalance,
  };
}
