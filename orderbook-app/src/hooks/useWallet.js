import { useState, useEffect } from 'react';
import { BrowserProvider } from 'ethers';

export function useWallet() {
  const [account, setAccount] = useState(null);
  const [provider, setProvider] = useState(null);
  const [signer, setSigner] = useState(null);
  const [chainId, setChainId] = useState(null);
  const [connecting, setConnecting] = useState(false);
  const [error, setError] = useState(null);

  // 检查是否安装了 MetaMask
  const isMetaMaskInstalled = typeof window !== 'undefined' && typeof window.ethereum !== 'undefined';

  // 连接钱包
  const connect = async () => {
    if (!isMetaMaskInstalled) {
      setError('请安装 MetaMask 钱包');
      return;
    }

    setConnecting(true);
    setError(null);

    try {
      const browserProvider = new BrowserProvider(window.ethereum);
      const accounts = await browserProvider.send('eth_requestAccounts', []);
      const signer = await browserProvider.getSigner();
      const network = await browserProvider.getNetwork();

      setProvider(browserProvider);
      setSigner(signer);
      setAccount(accounts[0]);
      setChainId(Number(network.chainId));
    } catch (err) {
      console.error('Failed to connect wallet:', err);
      setError(err.message || '连接钱包失败');
    } finally {
      setConnecting(false);
    }
  };

  // 断开连接
  const disconnect = () => {
    setAccount(null);
    setProvider(null);
    setSigner(null);
    setChainId(null);
  };

  // 监听账户变化
  useEffect(() => {
    if (!isMetaMaskInstalled) return;

    const handleAccountsChanged = (accounts) => {
      if (accounts.length === 0) {
        disconnect();
      } else if (accounts[0] !== account) {
        setAccount(accounts[0]);
      }
    };

    const handleChainChanged = (chainId) => {
      setChainId(parseInt(chainId, 16));
      // 刷新页面以重新初始化
      window.location.reload();
    };

    window.ethereum.on('accountsChanged', handleAccountsChanged);
    window.ethereum.on('chainChanged', handleChainChanged);

    return () => {
      window.ethereum.removeListener('accountsChanged', handleAccountsChanged);
      window.ethereum.removeListener('chainChanged', handleChainChanged);
    };
  }, [account, isMetaMaskInstalled]);

  // 自动连接（如果之前连接过）
  useEffect(() => {
    if (!isMetaMaskInstalled) return;

    const checkConnection = async () => {
      try {
        const browserProvider = new BrowserProvider(window.ethereum);
        const accounts = await browserProvider.send('eth_accounts', []);

        if (accounts.length > 0) {
          const signer = await browserProvider.getSigner();
          const network = await browserProvider.getNetwork();

          setProvider(browserProvider);
          setSigner(signer);
          setAccount(accounts[0]);
          setChainId(Number(network.chainId));
        }
      } catch (err) {
        console.error('Failed to check connection:', err);
      }
    };

    checkConnection();
  }, [isMetaMaskInstalled]);

  return {
    account,
    provider,
    signer,
    chainId,
    isConnected: !!account,
    isMetaMaskInstalled,
    connecting,
    error,
    connect,
    disconnect,
  };
}
