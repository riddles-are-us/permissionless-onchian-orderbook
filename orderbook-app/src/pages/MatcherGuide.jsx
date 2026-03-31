import React from 'react';
import { Link } from 'react-router-dom';
import './MatcherGuide.css';

const configExample = `
[network]
# WebSocket RPC endpoint URL for your Ethereum node
rpc_url = "ws://localhost:8545"
chain_id = 31337

[contracts]
# Deployed contract addresses
account = "0x..."
orderbook = "0x..."
sequencer = "0x..."

[executor]
# Private key of the account that will submit matching transactions
# IMPORTANT: Use a dedicated, funded account. DO NOT use your personal wallet.
private_key = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
gas_price_gwei = 1
gas_limit = 15000000

[matching]
max_batch_size = 10
matching_interval_ms = 3000
`.trim();

export default function MatcherGuide() {
  return (
    <div className="guide-container">
      <div className="guide-header">
        <h1>Running a Permissionless Matcher Node</h1>
        <p>Help decentralize the network and earn rewards by running a matcher node.</p>
        <Link to="/" className="back-button">
          &larr; Back to Home
        </Link>
      </div>

      <div className="guide-content">
        <div className="guide-step">
          <h2>Prerequisites</h2>
          <ul>
            <li>Familiarity with the command line.</li>
            <li>Git installed on your system.</li>
            <li>Rust toolchain installed (you can get it from <a href="https://rustup.rs/" target="_blank" rel="noopener noreferrer">rustup.rs</a>).</li>
            <li>An Ethereum account with funds to pay for gas fees.</li>
            <li>Access to an Ethereum node with a WebSocket (WSS) endpoint.</li>
          </ul>
        </div>

        <div className="guide-step">
          <h2>Step 1: Get the Code</h2>
          <p>Clone the official repository from GitHub to get the matcher source code.</p>
          <pre><code>git clone https://github.com/riddles-are-us/permissionless-onchian-orderbook.git</code></pre>
        </div>

        <div className="guide-step">
          <h2>Step 2: Navigate to the Matcher Directory</h2>
          <p>All commands from here on should be run from within the <code>matcher</code> directory.</p>
          <pre><code>cd permissionless-onchian-orderbook/matcher</code></pre>
          <p>The project uses a specific Rust toolchain version defined in <code>rust-toolchain.toml</code>. If you use <code>rustup</code>, it will automatically download and use this correct version for you.</p>
        </div>

        <div className="guide-step">
          <h2>Step 3: Configure Your Node</h2>
          <p>Create a configuration file named <code>config.toml</code> by copying the example file.</p>
          <pre><code>cp config.toml.example config.toml</code></pre>
          <p>Now, open <code>config.toml</code> in a text editor and update the following critical fields:</p>
          <pre><code>{configExample}</code></pre>
          <ul>
            <li><code>rpc_url</code>: Your WebSocket RPC endpoint.</li>
            <li><code>private_key</code>: The private key of the account you will use to send transactions. <strong>NEVER expose this key or commit it to version control.</strong></li>
            <li><code>account</code>, <code>orderbook</code>, <code>sequencer</code>: The deployed addresses of the on-chain contracts.</li>
          </ul>
        </div>

        <div className="guide-step">
          <h2>Step 4: Build the Matcher</h2>
          <p>Compile the application in release mode for optimal performance. This may take a few minutes the first time.</p>
          <pre><code>cargo build --release</code></pre>
        </div>

        <div className="guide-step">
          <h2>Step 5: Run the Matcher!</h2>
          <p>Once the build is complete, you can start your matcher node. It will begin syncing with the blockchain and processing orders from the sequencer queue.</p>
          <pre><code>./target/release/matcher</code></pre>
          <p>You should see logs indicating that the matcher is connecting, syncing state, and watching for events. Congratulations, you are now a part of the network!</p>
        </div>

        <div className="guide-step">
          <h2>Troubleshooting</h2>
          <ul>
            <li><strong>Connection Errors:</strong> Double-check your <code>rpc_url</code>. Ensure your node is running and accessible.</li>
            <li><strong>Transaction Failures:</strong> Ensure the executor account specified by your <code>private_key</code> has enough native currency (e.g., ETH) to pay for gas.</li>
          </ul>
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
