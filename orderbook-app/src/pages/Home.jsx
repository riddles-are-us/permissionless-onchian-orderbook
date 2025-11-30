import React from 'react';
import { Link } from 'react-router-dom';
import './Home.css';

export default function Home() {
  return (
    <div className="home-container">
      <div className="hero-section">
        <h1 className="home-title">A Permissionless, Gas-Efficient On-Chain Order Book that is run by the <span className="highlight-public">Public</span></h1>
        <p className="home-subtitle">
          Experience fair, transparent, and low-cost trading, powered by a decentralized hybrid architecture.
        </p>
        <div className="action-buttons">
          <button className="launch-button" disabled>
            Start Trading
          </button>
          <Link to="/matcher-guide" className="launch-button">
            Run Matching Node
          </Link>
          <button className="launch-button" disabled>
            Stake & Earn
          </button>
        </div>
      </div>

      <div className="features-section">
        <h2 className="features-title">Key Innovations</h2>
        <div className="features-grid">
          <div className="feature-card">
            <h3>Fair Ordering & MEV Resistance</h3>
            <p>
              Our on-chain Sequencer establishes a first-in-first-out queue for all transactions, providing strong protection against front-running and miner extractable value (MEV).
            </p>
          </div>
          <div className="feature-card">
            <h3>Drastically Lower Gas Fees</h3>
            <p>
              By delegating heavy computation to an off-chain network and using an on-chain contract for cheap verification, we reduce transaction costs to a fraction of typical on-chain exchanges.
            </p>
          </div>
          <div className="feature-card">
            <h3>Truly Decentralized & Composable</h3>
            <p>
              Powered by a permissionless network of matchers and built upon a public on-chain order book, our system is both censorship-resistant and fully integrable with the entire DeFi ecosystem.
            </p>
          </div>
        </div>
      </div>

      <footer className="home-footer">
        <p>Built on a hybrid architecture to deliver the best of on-chain security and off-chain performance.</p>
        <div className="footer-links">
          <a href="https://github.com/riddles-are-us/permissionless-onchian-orderbook" target="_blank" rel="noopener noreferrer">GitHub</a>
          <span>|</span>
          <a href="https://github.com/riddles-are-us/permissionless-onchian-orderbook/blob/main/whitepaper.md" target="_blank" rel="noopener noreferrer">Whitepaper</a>
        </div>
      </footer>
    </div>
  );
}
