# Matcher Engine - Usage Guide

## Overview

The Matcher Engine is a Rust-based off-chain matching engine for the OrderBook protocol. It uses event-driven state synchronization to maintain a local replica of the on-chain orderbook, calculates optimal insertion positions using a local simulator, and submits batch transactions to minimize gas costs.

## Features

- **Event-Driven Sync**: Real-time state updates through blockchain events
- **Local Simulator**: `OrderBookSimulator` mirrors on-chain orderbook structure exactly
- **Deep Copy Isolation**: Simulation calculations use deep copies, ensuring state consistency
- **Batch Processing**: Groups multiple order requests into single transactions
- **Auto-Retry**: Failed transactions keep requests in queue for retry

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
account = "0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0"
orderbook = "0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9"
sequencer = "0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9"

[executor]
private_key = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
gas_price_gwei = 1
gas_limit = 5000000

[matching]
max_batch_size = 10
matching_interval_ms = 3000
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

### Adjust Log Level

```bash
./target/release/matcher --log-level debug
```

Available log levels: `error`, `warn`, `info`, `debug`, `trace`

## How It Works

### 1. Initialization

The matcher connects to the blockchain via WebSocket and loads contract ABIs.

### 2. Historical State Sync

On startup, the matcher syncs the current state:

1. **Sequencer Queue**: Reads `queueHead` and traverses the request queue
2. **OrderBook State**:
   - Reads `askHead`, `bidHead` from OrderBookData
   - Traverses price level linked lists
   - Loads orders for each price level

### 3. Event Watching

After initial sync, the matcher subscribes to events:

**From Sequencer:**
- `PlaceOrderRequested`: Add to local request queue
- `RemoveOrderRequested`: Add to local request queue

**From OrderBook:**
- `OrderInserted`: Add order to local simulator
- `PriceLevelCreated`: Add price level to local simulator
- `PriceLevelRemoved`: Remove price level from simulator
- `OrderFilled`: Update order's filled amount
- `OrderRemoved`: Remove order from simulator
- `Trade`: Log trade execution

### 4. Matching Loop

Every `matching_interval_ms`:

1. **Fetch Requests**: Get up to `max_batch_size` requests from queue
2. **Clone Orderbook**: Create deep copy of current simulator state
3. **Calculate Positions**: For each request, simulate on the clone:
   - `PlaceOrder`: Calculate `insertAfterPrice`
   - `RemoveOrder`: Simulate removal for correct subsequent calculations
4. **Build Transaction**: Create batch with all insertions
5. **Submit**: Send `batchProcessRequests` transaction
6. **Wait**: Confirm transaction
7. **Cleanup**: Remove processed requests from queue (only on success)

### 5. State Consistency

The key design ensures state consistency:

- **Event-Driven Updates**: `GlobalState.orderbook` only updates via chain events
- **Deep Copy Isolation**: Simulations use cloned state, original unaffected
- **Failure Handling**: Failed tx = no events = no state change = auto retry

## Architecture

```
matcher/
├── src/
│   ├── main.rs               # CLI entry point
│   ├── config.rs             # Configuration management
│   ├── contracts.rs          # Contract bindings (generated)
│   ├── types.rs              # Data structures
│   ├── state.rs              # GlobalState management
│   ├── sync.rs               # State synchronization + event watching
│   ├── matcher.rs            # Matching engine
│   └── orderbook_simulator.rs # Orderbook simulator (mirrors chain)
├── abi/                      # Contract ABIs (JSON)
├── config.toml               # Configuration file
└── Cargo.toml               # Rust dependencies
```

## Monitoring

The matcher outputs structured logs:

```
🚀 Starting OrderBook Matcher
📋 Configuration loaded
🔄 Starting state synchronizer
📚 Syncing historical state at block 100
📊 Trading pair: askHead=201, bidHead=200
✅ Historical state synced at block 100
👀 Watching for OrderBook and Sequencer events from block 100
📡 Starting OrderBook event listener from block 100
📡 Starting Sequencer event listener from block 100
🎯 Starting matching engine
📥 PlaceOrderRequested: requestId=11, price=199500000000, isAsk=false
📊 Simulator state: ask_head=201, bid_head=200, 10 price_levels, 10 orders
PlaceOrder 11 (price=199500000000, is_ask=false): insertAfterPrice=200000000000
📤 Executing batch with 1 orders
📝 Transaction sent: 0xabc...
📦 OrderInserted: orderId=11, price=199500000000, amount=20000000, isAsk=false
📊 PriceLevelCreated: price=199500000000, isAsk=false
✅ Transaction confirmed, 4 events emitted
✨ Processed 1 requests
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
- Check the contracts are on the correct chain
- Review logs for specific error messages

### Simulator Mismatch

If `insertAfterPrice` calculations are wrong:
- Ensure all OrderBook events are being processed
- Check that price level composite keys match chain logic
- Verify ask/bid sorting direction

## Performance Tuning

- **Increase `max_batch_size`**: Process more orders per transaction (higher gas)
- **Decrease `matching_interval_ms`**: Process batches more frequently
- **Adjust `gas_price_gwei`**: Higher price = faster confirmation

## Security Considerations

- **Private Key**: Store private key securely, never commit to version control
- **RPC Endpoint**: Use trusted RPC providers
- **Gas Limits**: Set reasonable limits to prevent excessive spending
- **Monitoring**: Monitor executor account balance and transaction status

## Testing

### Unit Tests

```bash
cd matcher
cargo test
```

The `orderbook_simulator.rs` includes comprehensive tests:
- Single order insertion
- Multiple orders same side
- Ask order sorting
- Cross-price matching
- Full match removes price level
- Batch orders with matching

### Integration Test

```bash
# Terminal 1: Start Anvil
anvil --block-time 1

# Terminal 2: Deploy contracts
forge script script/Deploy.s.sol --broadcast --rpc-url http://127.0.0.1:8545

# Terminal 3: Place test orders
forge script script/PlaceTestOrders.s.sol --broadcast --rpc-url http://127.0.0.1:8545

# Terminal 4: Run matcher
cd matcher
cargo run -- -l debug
```

## Supported Request Types

### PlaceOrder (Limit)

Calculates `insertAfterPrice` for correct linked list insertion:
- Ask orders: sorted by price ascending (low to high)
- Bid orders: sorted by price descending (high to low)

### RemoveOrder

Simulates order removal to ensure subsequent insertions calculate correct positions.

## Future Enhancements

- [ ] Market order support
- [ ] Multi-trading pair support
- [ ] WebSocket reconnection handling
- [ ] Metrics and monitoring dashboard
- [ ] Automatic gas price estimation
- [ ] MEV protection strategies
