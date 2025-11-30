
# **Whitepaper: A Permissionless, Gas-Efficient On-Chain Order Book**

## **Abstract**

This paper outlines the architecture of a novel permissionless on-chain order book exchange that addresses two of the most significant challenges in decentralized finance (DeFi): high gas costs and miner extractable value (MEV) through front-running. Our system employs a hybrid on-chain/off-chain design that leverages the security of the Ethereum blockchain for settlement while offloading computationally intensive tasks to a decentralized network of off-chain agents. By combining a fair-ordering sequencer, an internal fund management ledger, and a permissionless, incentivized network of "Matchers," the system provides a trading experience that is fair, resilient, and cost-effective, making on-chain order book trading viable at scale.

---

## **1. Introduction**

On-chain order books are a fundamental building block for a transparent and non-custodial financial system. However, their implementation on blockchains like Ethereum has been historically plagued by two major issues:

1.  **Prohibitive Gas Costs:** Every interaction with the order book—placing, canceling, and matching orders—requires a state change, incurring significant gas fees. Maintaining a sorted data structure on-chain is computationally expensive.
2.  **Front-Running and MEV:** In a public mempool, sophisticated actors can observe pending order transactions and place their own transactions ahead of them to profit from the price impact. This undermines market fairness and results in poor execution for regular users.

This paper presents a solution that revives the on-chain order book model by systematically solving its core inefficiencies through a decentralized, hybrid architecture.

---

## **2. System Architecture**

Our exchange is a hybrid system composed of three core on-chain smart contracts and a decentralized network of off-chain agents, known as **Matchers**.

```text
                               +--------------------------+
                               |                          |
                           +-->+   Matcher Network        +<--+
                           |   | (Permissionless, Off-Chain)|   |
                           |   +--------------------------+   |
                           |              ^  |                 |
(4) Read Events &         (5) Submit      |  | (6) Read State   |
    Calculate Positions      Batch Tx     |  |     via REST API |
                           |              |  v                 |
+----------------------+   |   +--------------------------+   |   +----------------------+
|                      |   |   |                          |   |   |                      |
| User / Trader        +<----->+    Ethereum Blockchain     +------>+ Frontend Application |
|                      |       |                          |       | (React DApp)         |
+----------------------+       | [Sequencer.sol]          |       +----------------------+
  ^  |                         | [OrderBook.sol]          |                 ^  |
  |  | (1) Sign Tx             | [Account.sol]            |                 |  | (2) Submit Tx
  +--+-------------------------+--------------------------+-----------------+--+
     (3) Tx Confirmation
```

### **2.1 On-Chain Components**

The on-chain logic is modularized into three primary contracts:

#### **2.1.1 `Account.sol`: The Internal Ledger**

To circumvent the high cost of ERC20 token transfers for each trade, all user funds are held within the central `Account.sol` contract. This contract maintains an internal ledger of each user's `available` and `locked` balances. When a trade settles, the contract simply updates the internal balances of the buyer and seller. This crucial design means that on-chain token transfers only occur during initial deposits and final withdrawals, not during active trading.

#### **2.1.2 `Sequencer.sol`: The Fair-Ordering Gateway**

The `Sequencer.sol` contract is the exclusive entry point for all user-initiated actions. Its primary role is to establish a fair and definitive sequence of events. When a user submits a request (e.g., `placeLimitOrder`), the contract appends it to a public queue and emits an event. This creates a canonical, first-in-first-out (FIFO) ordering of operations, making it impossible for miners or other agents to reorder transactions for their benefit.

#### **2.1.3 `OrderBook.sol`: The Verification and Matching Engine**

This is the core contract that manages the state of the order book, which is implemented as a 2D sorted linked list. Crucially, `OrderBook.sol` does **not** perform the computationally expensive task of finding an order's correct insertion point. Instead, it exposes a `batchProcessRequests` function that can be called by any address.

This function accepts a batch of orders from the sequencer's queue along with their pre-calculated insertion points. For each order, the contract performs a single, inexpensive on-chain check: it verifies that the new order's price is correctly positioned between its preceding and succeeding neighbors in the linked list. If the verification passes, the order is inserted. Immediately after insertion, the contract attempts to execute trades against resting orders, calling the `Account.sol` contract to settle the funds atomically.

### **2.2 Off-Chain Agents: The Matcher Network**

Instead of a single, trusted agent, our system is designed to be serviced by a permissionless network of Matchers. A Matcher is a Rust-based off-chain application that performs the system's heavy lifting. The existence of a competitive network of matchers ensures liveness and censorship resistance. Their role is detailed in Section 4.4.

---

## **3. The Order Lifecycle**

The journey of an order from submission to settlement is a seamless interplay between the user, the on-chain contracts, and the off-chain Matcher network.

```text
   User        Sequencer.sol      Matcher (Off-chain)      OrderBook.sol        Account.sol
    |                |                   |                      |                    |
    |--placeOrder()-->|                   |                      |                    |
    |                |                   |                      |                    |
    |                |--Emit NewRequest-->|                      |                    |
    |                |                   |                      |                    |
    |                |               (Detects Event)            |                    |
    |                |                   |                      |                    |
    |                |                   |--Calculates Position--|                    |
    |                |                   |                      |                    |
    |                |                   |--batchProcessRequests()-->|                |
    |                |                   |                      |                    |
    |                |                   |                  (Verifies & Inserts)      |
    |                |                   |                      |                    |
    |                |                   |                      |--_tryMatch() & transferFunds()-->|
    |                |                   |                      |                    |
    |                |                   |                      |                (Updates Balances)
    |                |                   |                      |<------------------|
    |<--Tx Confirmed-|                   |                      |                    |
    |                |                   |                      |                    |
```

1.  **Submission:** A user signs a transaction to call `placeLimitOrder` on the `Sequencer.sol` contract, which adds the request to its queue and emits a `NewRequest` event.
2.  **Detection:** An active Matcher in the network detects the `NewRequest` event.
3.  **Calculation:** The Matcher processes the request, using its local simulation of the order book to determine the precise linked-list insertion position.
4.  **Execution:** The Matcher calls `batchProcessRequests` on `OrderBook.sol` with the order details and the calculated position. Matchers compete to process events from the Sequencer and submit valid batches to the OrderBook.
5.  **Verification & Insertion:** `OrderBook.sol` validates the position and inserts the order into its on-chain data structure.
6.  **Matching & Settlement:** Immediately following insertion, `OrderBook.sol` checks for matches. If a trade is found, it calls `transferFunds` on `Account.sol` to atomically update the balances of the buyer and seller, collecting a small trading fee in the process.

---

## **4. Key Innovations**

### **4.1 Fair Ordering via Sequencer**

The `Sequencer.sol` contract's FIFO queue provides strong pre-trade fairness guarantees, protecting users from front-running.

### **4.2 Gas Efficiency via Off-Chain Calculation**

Delegating the expensive list traversal to an off-chain agent and reducing the on-chain work to a cheap verification dramatically lowers gas costs.

### **4.3 Internal Ledger for Fund Management**

The `Account.sol` contract's internal ledger enables high-frequency matching at a fraction of the cost of traditional on-chain settlement.

### **4.4 The Permissionless Matcher Network**

The backbone of the exchange's liveness and decentralization is its open and incentivized network of Matchers.

*   **Permissionless Operation:** Anyone can download the open-source Matcher software and run a a node. These nodes monitor the `Sequencer.sol` contract for new requests. They compete to calculate valid batches and be the first to submit them to the `OrderBook.sol` contract.

*   **Economic Incentives:** To reward this crucial work, the `Account.sol` contract collects a small trading fee on every matched trade (e.g., 0.1%). These fees are accumulated in a designated `feeCollector` address controlled by the project's governance (e.g., a DAO). The governance entity is then responsible for distributing these collected fees to reward active and honest Matcher operators, creating a sustainable economic loop that ensures the system remains operational.

```text
+----------+                             +----------+
| Trader A |                             | Trader B |
+----------+                             +----------+
     |                                        |
     +---------------+------------------------+
                     |
                     v
            +---------------+  (1) Matched Trade
            | OrderBook.sol |
            +---------------+
                     |
                     | (2) Calls transferFunds()
                     v
            +---------------+
            |  Account.sol  |
            +---------------+
         (3) Takes Fee from A & B
                     |
                     v
+----------------------------------------+
|   collectedFees[token] += tradeFee     |
+----------------------------------------+
                     |
                     | (4) Governance calls withdrawFees()
                     v
+----------------------------------------+
|      Fee Collector Address (DAO)       |
+----------------------------------------+
                     |
         (5) Distributes Rewards
                     |
+--------------------+-------------------+
|                    |                   |
v                    v                   v
+----------+     +----------+      +----------+
| Matcher 1|     | Matcher 2|      | Matcher 3|
+----------+     +----------+      +----------+
```

### **4.5 Advancing Beyond Traditional Off-Chain Models**

It is crucial to understand that this architecture is not a traditional "off-chain matching" or "relayer" model. It represents a significant evolution by carefully delegating responsibilities, achieving the best of both on-chain and off-chain worlds.

A traditional **Relayer Model** works as follows: users sign orders off-chain and send them to a central relayer. The relayer maintains an off-chain order book, finds a match, and submits the two matched orders to an on-chain contract for settlement. The primary drawbacks of this model are its opacity and lack of composability; the order book state is not public, and other smart contracts cannot interact with it.

Our model provides a more decentralized and trust-minimized alternative by keeping the authoritative state and final execution logic on-chain. The Matcher's role is not to *decide* matches but to provide a computational "hint" for cheap on-chain processing. The matching itself is executed atomically by the `OrderBook.sol` contract.

The key advantages of this design are summarized below:

| Feature | Traditional Relayer Model | This Project's Architecture | Advantage |
| :--- | :--- | :--- | :--- |
| **Order Book State** | **Off-chain**, private, and opaque. | **On-chain**, public, and verifiable. | **Trust & Transparency**: Anyone can inspect the `OrderBook.sol` contract to get the true state of the market without trusting any third party. |
| **Composability** | **Very Low**: Other smart contracts cannot read the off-chain book or place orders. | **Very High**: Any smart contract can directly interact with the `Sequencer.sol` and `OrderBook.sol` contracts, enabling deep integration with the DeFi ecosystem. |
| **Censorship Resistance** | **Low**: The relayer can choose to ignore or censor specific user orders. | **High**: The on-chain `Sequencer` queue is public. If one Matcher ignores a request, another is free to process it to earn the reward. |
| **Matching Execution**| Decided and submitted by the off-chain relayer. | Executed automatically and atomically by the on-chain contract logic. | **Fairness & Predictability**: Matching is a deterministic outcome of an order being placed on-chain, not a choice made by an off-chain entity. |

In essence, this architecture unbundles the "matching" process. It offloads the expensive, non-critical computation (finding an order's position) while keeping the critical, state-defining components (the order book's state and trade execution) on-chain as a public good.

---

## **5. Security**

The security of user funds is paramount. Funds are held securely in the `Account.sol` contract and can only be moved by the `OrderBook.sol` contract during atomic settlements.

The permissionless nature of the Matcher network introduces new considerations. A malicious Matcher cannot steal funds or corrupt the order book's state, as any invalid batch submission will be rejected by the on-chain verification logic in `OrderBook.sol`. The primary risk is liveness: if all Matchers were to halt, no new orders would be processed. However, the economic incentive model is designed to ensure a robust and competitive network of operators, making this scenario highly unlikely.

---

## **6. Conclusion**

The permissionless on-chain order book presented here offers a practical and scalable solution to the challenges of DeFi trading. By intelligently partitioning responsibilities between on-chain contracts and a decentralized off-chain network, the system delivers a trading experience that is fair, secure, censorship-resistant, and highly gas-efficient. This hybrid architecture represents a significant step forward in building a truly open and performant financial infrastructure.

---
---

## **Appendix A: Smart Contract API Reference**

This section provides an overview of the key functions exposed by the core smart contracts.

### **`Account.sol`**

*   `deposit(address token, uint256 amount)`: Deposits tokens into the user's internal account.
*   `withdraw(address token, uint256 amount)`: Withdraws tokens from the user's internal account.
*   `transferFunds(...)`: (Internal, called by `OrderBook`) Settles a trade between a buyer and seller.
*   `withdrawFees(address token, uint256 amount)`: (Owner-only) Allows the `feeCollector` to withdraw accumulated fees.

### **`Sequencer.sol`**

*   `placeLimitOrder(address baseToken, address quoteToken, uint256 price, uint256 amount, uint8 side)`: Submits a request to place a new limit order.
*   `requestRemoveOrder(bytes32 orderId)`: Submits a request to cancel an existing order.

### **`OrderBook.sol`**

*   `batchProcessRequests(Request[] calldata requests, bytes32[] calldata positions)`: (Public, called by Matchers) Processes a batch of requests from the Sequencer, verifying and inserting them into the book.

---

## **Appendix B: Matcher REST API**

Each Matcher node runs a REST API server to provide off-chain, real-time data to frontends and external services, enabling a responsive user experience.

*   `GET /health`: Returns the health status of the Matcher node.
*   `GET /api/v1/orderbook/{trading_pair}`: Retrieves the current order book depth for a given pair.
    *   Query Params: `depth` (integer)
*   `GET /api/v1/orders/{order_id}`: Fetches the details of a specific order by its ID.
*   `GET /api/v1/users/{trader}/orders`: Gets a list of all orders for a given user address.
    *   Query Params: `status`, `limit`, `offset`
*   `GET /api/v1/users/{trader}/orders/active`: Gets all active (open or partially filled) orders for a user.
*   `GET /api/v1/users/{trader}/trades`: Gets the trading history for a user.
    *   Query Params: `limit`, `offset`
