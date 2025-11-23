# Matcher Engine - Usage Guide

## Overview

The Matcher Engine is a Rust-based off-chain matching engine for the OrderBook protocol. It synchronizes state from the blockchain, calculates optimal insertion positions for orders, and submits batch transactions to minimize gas costs.

## Features

- **State Synchronization**: Syncs historical state from a specific block height
- **Event Monitoring**: Watches blockchain events to maintain incremental state
- **Batch Processing**: Groups multiple order requests into single transactions
- **Off-chain Matching**: Calculates insertion positions off-chain to save gas
- **Price Level Caching**: Maintains local cache of price levels for fast lookups

## Prerequisites

- Rust toolchain (stable, see `rust-toolchain.toml`)
- Access to an Ethereum-compatible RPC endpoint (WebSocket)
- Private key for the executor account
- Deployed contracts (Account, OrderBook, Sequencer)

## Configuration

Create a `config.toml` file in the matcher directory:

```toml
[network]
rpc_url = "ws://localhost:8545"
chain_id = 31337

[contracts]
account = "0x5FbDB2315678afecb367f032d93F642f64180aa3"
orderbook = "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512"
sequencer = "0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0"

[executor]
private_key = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
gas_price_gwei = 20
gas_limit = 5000000

[matching]
max_batch_size = 10
matching_interval_ms = 1000

[sync]
start_block = 0
sync_historical = true
```

### Configuration Parameters

#### Network
- `rpc_url`: WebSocket RPC endpoint URL
- `chain_id`: Chain ID of the network

#### Contracts
- `account`: Deployed Account contract address
- `orderbook`: Deployed OrderBook contract address
- `sequencer`: Deployed Sequencer contract address

#### Executor
- `private_key`: Private key of the account that will submit transactions
- `gas_price_gwei`: Gas price in Gwei
- `gas_limit`: Maximum gas limit for transactions

#### Matching
- `max_batch_size`: Maximum number of orders to process in one batch
- `matching_interval_ms`: Interval between batch processing (milliseconds)

#### Sync
- `start_block`: Block number to start syncing from (0 = current block)
- `sync_historical`: Whether to sync historical state on startup

## Building

```bash
cd matcher
cargo build --release
```

The optimized binary will be at `target/release/matcher`.

## Running

### Basic Usage

```bash
./target/release/matcher
```

This will use the default `config.toml` in the current directory.

### Custom Configuration

```bash
./target/release/matcher --config /path/to/config.toml
```

### Override Start Block

```bash
./target/release/matcher --start-block 12345
```

### Adjust Log Level

```bash
./target/release/matcher --log-level debug
```

Available log levels: `error`, `warn`, `info`, `debug`, `trace`

## How It Works

### 1. Initialization

The matcher connects to the blockchain via WebSocket and loads contract ABIs.

### 2. State Synchronization

- Reads the current queue head from the Sequencer contract
- Traverses the request queue to load pending requests
- Builds local cache of price levels and orders

### 3. Matching Loop

Every `matching_interval_ms`:

1. **Fetch Requests**: Get up to `max_batch_size` requests from the queue
2. **Calculate Positions**: For each request, determine the correct insertion position
   - For ask orders: price ascending (low to high)
   - For bid orders: price descending (high to low)
3. **Build Transaction**: Create a batch transaction with all insertions
4. **Submit**: Send transaction to the blockchain
5. **Wait**: Confirm transaction and update local state

### 4. Price Level Cache

The matcher maintains a local cache of price levels to avoid unnecessary RPC calls:

- **Key**: Trading pair + price
- **Value**: Price level ID, volume, head/tail order IDs
- **Update**: Refreshed when orders are processed or events are received

## Architecture

```
matcher/
├── src/
│   ├── main.rs          # CLI entry point
│   ├── config.rs        # Configuration management
│   ├── contracts.rs     # Contract bindings (generated)
│   ├── types.rs         # Data structures
│   ├── state.rs         # Global state management
│   ├── sync.rs          # State synchronization
│   └── matcher.rs       # Matching engine
├── abi/                 # Contract ABIs (JSON)
├── config.toml          # Configuration file
└── Cargo.toml          # Rust dependencies
```

## Monitoring

The matcher outputs structured logs:

```
[INFO] 🔄 Starting state synchronizer
[INFO] 📚 Syncing historical state from block 0
[DEBUG]   Queue head: 1
[DEBUG]   Loaded 3 requests from queue
[INFO] ✅ Historical state synced to block 0
[INFO] 🎯 Starting matching engine
[INFO]   Batch size: 10
[INFO]   Interval: 1000ms
[INFO] 📤 Executing batch with 3 orders
[INFO] 📝 Transaction sent: 0x1234...
[INFO] ✅ Transaction confirmed in block: Some(123)
[INFO]   3 events emitted
[INFO] ✨ Processed 3 requests
```

## Troubleshooting

### Connection Issues

If you see WebSocket connection errors:
- Verify `rpc_url` is correct and accessible
- Check if the node supports WebSocket connections
- Ensure firewall allows outbound WebSocket connections

### Transaction Failures

If transactions revert:
- Check executor account has sufficient ETH for gas
- Verify contract addresses in config are correct
- Ensure executor is authorized to call `batchProcessRequests`
- Review gas price and limit settings

### State Sync Issues

If state sync fails:
- Verify contract addresses are deployed at the configured addresses
- Check if `start_block` is valid
- Ensure the contracts are on the correct chain

### Performance Tuning

To optimize performance:
- **Increase `max_batch_size`**: Process more orders per transaction (higher gas)
- **Decrease `matching_interval_ms`**: Process batches more frequently
- **Adjust `gas_price_gwei`**: Higher price = faster confirmation
- **Enable historical sync**: Set `sync_historical = true` for complete state

## Security Considerations

- **Private Key**: Store private key securely, never commit to version control
- **RPC Endpoint**: Use trusted RPC providers
- **Gas Limits**: Set reasonable limits to prevent excessive spending
- **Monitoring**: Monitor executor account balance and transaction status

## Future Enhancements

- [ ] Event stream processing for real-time state updates
- [ ] Multi-threaded batch processing
- [ ] Advanced order matching algorithms
- [ ] MEV protection strategies
- [ ] Metrics and monitoring dashboard
- [ ] Automatic gas price estimation
- [ ] Transaction retry logic with backoff
- [ ] Support for multiple trading pairs
