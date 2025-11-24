import React, { useState, useEffect } from 'react';
import { usePlaceOrder } from '../hooks/usePlaceOrder';
import { CONFIG } from '../config';
import './PlaceOrder.css';

export default function PlaceOrder({ signer, account }) {
  const {
    placing,
    approving,
    depositing,
    error,
    approveToken,
    depositToAccount,
    placeLimitOrder,
    getAccountBalance,
    getWalletBalance,
  } = usePlaceOrder(signer);

  const [orderType, setOrderType] = useState('buy'); // 'buy' or 'sell'
  const [price, setPrice] = useState('');
  const [amount, setAmount] = useState('');
  const [success, setSuccess] = useState(null);

  // 余额
  const [wethBalance, setWethBalance] = useState('0');
  const [usdcBalance, setUsdcBalance] = useState('0');
  const [wethAccountBalance, setWethAccountBalance] = useState('0');
  const [usdcAccountBalance, setUsdcAccountBalance] = useState('0');

  // 加载余额
  useEffect(() => {
    if (!signer || !account) return;

    const loadBalances = async () => {
      try {
        const [wethWallet, usdcWallet, wethAccount, usdcAccount] = await Promise.all([
          getWalletBalance(CONFIG.CONTRACTS.WETH),
          getWalletBalance(CONFIG.CONTRACTS.USDC),
          getAccountBalance(CONFIG.CONTRACTS.WETH),
          getAccountBalance(CONFIG.CONTRACTS.USDC),
        ]);

        setWethBalance(wethWallet);
        setUsdcBalance(usdcWallet);
        setWethAccountBalance(wethAccount);
        setUsdcAccountBalance(usdcAccount);
      } catch (err) {
        console.error('Failed to load balances:', err);
      }
    };

    loadBalances();
    const interval = setInterval(loadBalances, 5000);
    return () => clearInterval(interval);
  }, [signer, account]);

  const handleSubmit = async (e) => {
    e.preventDefault();
    setSuccess(null);

    if (!price || !amount) {
      alert('请填写价格和数量');
      return;
    }

    const isAsk = orderType === 'sell';

    try {
      // 1. 检查并授权代币（买单需要USDC，卖单需要WETH）
      const tokenToApprove = isAsk ? CONFIG.CONTRACTS.WETH : CONFIG.CONTRACTS.USDC;
      const tokenDecimals = isAsk ? 18 : 6;
      const approveAmount = isAsk ? amount : parseFloat(price) * parseFloat(amount);

      console.log('Step 1: Approving token...');
      const approved = await approveToken(tokenToApprove, approveAmount, tokenDecimals);
      if (!approved) {
        throw new Error('授权失败');
      }

      // 2. 下单
      console.log('Step 2: Placing order...');
      const result = await placeLimitOrder({
        isAsk,
        price: parseFloat(price),
        amount: parseFloat(amount),
      });

      if (result) {
        setSuccess(`下单成功！交易哈希: ${result.txHash.substring(0, 10)}...`);
        setPrice('');
        setAmount('');

        // 刷新余额
        setTimeout(async () => {
          const [wethWallet, usdcWallet, wethAccount, usdcAccount] = await Promise.all([
            getWalletBalance(CONFIG.CONTRACTS.WETH),
            getWalletBalance(CONFIG.CONTRACTS.USDC),
            getAccountBalance(CONFIG.CONTRACTS.WETH),
            getAccountBalance(CONFIG.CONTRACTS.USDC),
          ]);
          setWethBalance(wethWallet);
          setUsdcBalance(usdcWallet);
          setWethAccountBalance(wethAccount);
          setUsdcAccountBalance(usdcAccount);
        }, 2000);
      }
    } catch (err) {
      console.error('Order failed:', err);
    }
  };

  const handleDeposit = async (token) => {
    const amountToDeposit = prompt(`请输入要充值的 ${token} 数量:`);
    if (!amountToDeposit) return;

    const tokenAddress = token === 'WETH' ? CONFIG.CONTRACTS.WETH : CONFIG.CONTRACTS.USDC;
    const decimals = token === 'WETH' ? 18 : 6;

    try {
      // 先授权
      const approved = await approveToken(tokenAddress, amountToDeposit, decimals);
      if (!approved) return;

      // 再充值
      const deposited = await depositToAccount(tokenAddress, amountToDeposit, decimals);
      if (deposited) {
        alert('充值成功！');
        // 刷新余额
        setTimeout(async () => {
          if (token === 'WETH') {
            setWethBalance(await getWalletBalance(CONFIG.CONTRACTS.WETH));
            setWethAccountBalance(await getAccountBalance(CONFIG.CONTRACTS.WETH));
          } else {
            setUsdcBalance(await getWalletBalance(CONFIG.CONTRACTS.USDC));
            setUsdcAccountBalance(await getAccountBalance(CONFIG.CONTRACTS.USDC));
          }
        }, 2000);
      }
    } catch (err) {
      console.error('Deposit failed:', err);
    }
  };

  if (!account) {
    return (
      <div className="place-order">
        <div className="no-wallet">
          <p>请先连接钱包</p>
        </div>
      </div>
    );
  }

  const isBusy = placing || approving || depositing;

  return (
    <div className="place-order">
      <div className="balances-section">
        <h3>余额</h3>
        <div className="balance-grid">
          <div className="balance-item">
            <div className="balance-header">
              <span className="token-name">WETH</span>
              <button
                className="deposit-btn"
                onClick={() => handleDeposit('WETH')}
                disabled={isBusy}
              >
                充值
              </button>
            </div>
            <div className="balance-row">
              <span className="label">钱包:</span>
              <span className="value">{parseFloat(wethBalance).toFixed(4)}</span>
            </div>
            <div className="balance-row">
              <span className="label">账户:</span>
              <span className="value">{parseFloat(wethAccountBalance).toFixed(4)}</span>
            </div>
          </div>

          <div className="balance-item">
            <div className="balance-header">
              <span className="token-name">USDC</span>
              <button
                className="deposit-btn"
                onClick={() => handleDeposit('USDC')}
                disabled={isBusy}
              >
                充值
              </button>
            </div>
            <div className="balance-row">
              <span className="label">钱包:</span>
              <span className="value">{parseFloat(usdcBalance).toFixed(2)}</span>
            </div>
            <div className="balance-row">
              <span className="label">账户:</span>
              <span className="value">{parseFloat(usdcAccountBalance).toFixed(2)}</span>
            </div>
          </div>
        </div>
      </div>

      <form onSubmit={handleSubmit} className="order-form">
        <h3>下限价单</h3>

        <div className="order-type-selector">
          <button
            type="button"
            className={`type-btn ${orderType === 'buy' ? 'active buy' : ''}`}
            onClick={() => setOrderType('buy')}
          >
            买入 (Bid)
          </button>
          <button
            type="button"
            className={`type-btn ${orderType === 'sell' ? 'active sell' : ''}`}
            onClick={() => setOrderType('sell')}
          >
            卖出 (Ask)
          </button>
        </div>

        <div className="form-group">
          <label>价格 (USDC)</label>
          <input
            type="number"
            step="0.01"
            value={price}
            onChange={(e) => setPrice(e.target.value)}
            placeholder="例如: 2000"
            disabled={isBusy}
          />
        </div>

        <div className="form-group">
          <label>数量 (WETH)</label>
          <input
            type="number"
            step="0.01"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            placeholder="例如: 0.1"
            disabled={isBusy}
          />
        </div>

        {price && amount && (
          <div className="order-summary">
            <div className="summary-row">
              <span>总价值:</span>
              <span className="value">
                {(parseFloat(price) * parseFloat(amount)).toFixed(2)} USDC
              </span>
            </div>
          </div>
        )}

        <button
          type="submit"
          className={`submit-btn ${orderType === 'buy' ? 'buy' : 'sell'}`}
          disabled={isBusy || !price || !amount}
        >
          {approving
            ? '授权中...'
            : depositing
            ? '充值中...'
            : placing
            ? '下单中...'
            : orderType === 'buy'
            ? '买入'
            : '卖出'}
        </button>

        {error && <div className="error-message">{error}</div>}
        {success && <div className="success-message">{success}</div>}
      </form>
    </div>
  );
}
