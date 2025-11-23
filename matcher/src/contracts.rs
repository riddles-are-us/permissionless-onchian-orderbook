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
