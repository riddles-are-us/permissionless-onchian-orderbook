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
gas_limit = 15000000

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
- `PlaceOrderRequested`: Add to local request queue (includes `uncancellableDuration`)
- `RemoveOrderRequested`: Add to local request queue

**From OrderBook:**
- `OrderInserted`: Add order to local simulator (includes `createdAt`, `uncancellableDuration`)
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

**Uncancellable Duration**: Limit orders can specify an `uncancellableDuration` parameter (in seconds) that prevents the order from being cancelled during this period:
- `uncancellableDuration = 0`: Order can be cancelled immediately
- `uncancellableDuration > 0`: Order cannot be cancelled until `createdAt + uncancellableDuration` has passed

This feature is useful for market makers who want to guarantee order availability for a certain period.

### RemoveOrder

Simulates order removal to ensure subsequent insertions calculate correct positions.

**Cancellation Restriction**: Before a remove request enters the Sequencer queue, the system checks if the order is still within its uncancellable period. If `block.timestamp < order.createdAt + order.uncancellableDuration`, the cancellation request is rejected.

## REST API

The matcher provides a REST API for querying orderbook state and market data. By default, the API server runs on `http://127.0.0.1:8080`.

### API Configuration

Add API settings to `config.toml`:

```toml
[api]
host = "127.0.0.1"
port = 8080
```

### Endpoints

#### Health Check

```
GET /health
```

Returns service health status.

#### Get Orders

```
GET /api/v1/orders/{trading_pair}
```

Query parameters:
- `status`: Filter by order status (`open`, `partial`, `filled`, `cancelled`)
- `side`: Filter by side (`ask`, `bid`)
- `limit`: Maximum number of orders to return (default: 100)

#### Get Trades

```
GET /api/v1/trades/{trading_pair}
```

Query parameters:
- `start_time`: Start timestamp in milliseconds
- `end_time`: End timestamp in milliseconds
- `limit`: Maximum number of trades to return (default: 100)

#### Get K-line (Candlestick) Data

```
GET /api/v1/klines/{trading_pair}
```

Query parameters:
- `interval` (required): K-line interval
  - `1m` - 1 minute
  - `5m` - 5 minutes
  - `15m` - 15 minutes
  - `1h` - 1 hour
  - `1d` - 1 day (24 hours)
  - `1M` - 1 month
  - `1y` - 1 year
- `start_time`: Start timestamp in milliseconds (optional)
- `end_time`: End timestamp in milliseconds (optional)
- `limit`: Maximum number of K-lines to return (default: 100, max: 500)

**Response:**

```json
{
  "success": true,
  "data": [
    {
      "open_time": 1704067200000,
      "close_time": 1704067259999,
      "open": "1000000000",
      "high": "1050000000",
      "low": "990000000",
      "close": "1020000000",
      "volume": "5000000000",
      "quote_volume": "5100000000000000000",
      "trade_count": 42
    }
  ]
}
```

**Field descriptions:**
- `open_time`: K-line opening timestamp (milliseconds)
- `close_time`: K-line closing timestamp (milliseconds)
- `open`: Opening price (first trade price in the interval)
- `high`: Highest price during the interval
- `low`: Lowest price during the interval
- `close`: Closing price (last trade price in the interval)
- `volume`: Total base asset volume traded
- `quote_volume`: Total quote asset volume traded (price × amount)
- `trade_count`: Number of trades in the interval

**Example:**

```bash
# Get 1-hour K-lines for the past day
curl "http://127.0.0.1:8080/api/v1/klines/0xe3fd74b5016b57bf4180a8d977a55d749f0f8f76be8d457de0768c85a6acc816?interval=1h&limit=24"

# Get 1-minute K-lines with time range
curl "http://127.0.0.1:8080/api/v1/klines/0xe3fd74b5016b57bf4180a8d977a55d749f0f8f76be8d457de0768c85a6acc816?interval=1m&start_time=1704067200000&end_time=1704153600000"
```

### K-line Data Generation

K-line data is automatically generated in monitor mode when trades occur. The matcher:

1. Listens for `Trade` events from the OrderBook contract
2. Updates all supported timeframe K-lines (1m, 5m, 15m, 1h, 1d, 1M, 1y)
3. Uses U256 arithmetic for precise calculations without floating-point errors
4. Stores data in MongoDB for persistence

K-lines are updated in real-time as trades execute, providing accurate OHLCV data for charting and analysis.

## Future Enhancements

- [ ] Market order support
- [ ] Multi-trading pair support
- [ ] WebSocket reconnection handling
- [ ] Metrics and monitoring dashboard
- [ ] Automatic gas price estimation
- [ ] MEV protection strategies
