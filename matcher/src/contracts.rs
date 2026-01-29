use ethers::prelude::abigen;

// 生成合约绑定
abigen!(
    Sequencer,
    "./abi/Sequencer.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    OrderBook,
    "./abi/OrderBook.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

abigen!(
    Account,
    "./abi/Account.json",
    event_derives(serde::Deserialize, serde::Serialize)
);

// ERC20 合约绑定（用于读取代币 symbol 和 decimals）
abigen!(
    ERC20,
    r#"[
        function symbol() external view returns (string)
        function decimals() external view returns (uint8)
        function name() external view returns (string)
    ]"#
);
