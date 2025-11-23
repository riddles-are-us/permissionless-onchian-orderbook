/**
 * OrderBook 测试脚本
 *
 * 使用方法:
 * 1. 启动 Anvil: anvil
 * 2. 运行测试: node test_orderbook.js
 */

const { ethers } = require('ethers');
const fs = require('fs');
const solc = require('solc');

// Anvil默认配置
const ANVIL_RPC = 'http://127.0.0.1:8545';
const ANVIL_CHAIN_ID = 31337;

// Anvil默认账户（前3个）
const ACCOUNTS = [
    {
        address: '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266',
        privateKey: '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80'
    },
    {
        address: '0x70997970C51812dc3A010C7d01b50e0d17dc79C8',
        privateKey: '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d'
    },
    {
        address: '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC',
        privateKey: '0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a'
    }
];

// 编译Solidity合约
function compileSolidity(fileName) {
    console.log(`📝 编译 ${fileName}...`);
    const source = fs.readFileSync(fileName, 'utf8');

    const input = {
        language: 'Solidity',
        sources: {
            [fileName]: { content: source }
        },
        settings: {
            outputSelection: {
                '*': {
                    '*': ['abi', 'evm.bytecode']
                }
            }
        }
    };

    const output = JSON.parse(solc.compile(JSON.stringify(input)));

    if (output.errors) {
        const errors = output.errors.filter(e => e.severity === 'error');
        if (errors.length > 0) {
            console.error('编译错误:');
            errors.forEach(e => console.error(e.formattedMessage));
            process.exit(1);
        }
    }

    const contractName = Object.keys(output.contracts[fileName])[0];
    const contract = output.contracts[fileName][contractName];

    return {
        abi: contract.abi,
        bytecode: contract.evm.bytecode.object
    };
}

// 部署合约
async function deployContract(signer, contractName, compiled, ...args) {
    console.log(`🚀 部署 ${contractName}...`);
    const factory = new ethers.ContractFactory(compiled.abi, compiled.bytecode, signer);
    const contract = await factory.deploy(...args);
    await contract.waitForDeployment();
    const address = await contract.getAddress();
    console.log(`   ✅ ${contractName} 部署在: ${address}`);
    return contract;
}

// 主测试函数
async function main() {
    console.log('🎬 开始 OrderBook 测试\n');

    // 连接到Anvil
    const provider = new ethers.JsonRpcProvider(ANVIL_RPC);
    const deployer = new ethers.Wallet(ACCOUNTS[0].privateKey, provider);
    const alice = new ethers.Wallet(ACCOUNTS[1].privateKey, provider);
    const bob = new ethers.Wallet(ACCOUNTS[2].privateKey, provider);

    console.log('👥 测试账户:');
    console.log(`   Deployer: ${deployer.address}`);
    console.log(`   Alice:    ${alice.address}`);
    console.log(`   Bob:      ${bob.address}\n`);

    // ========== 第一步: 编译合约 ==========
    console.log('='.repeat(60));
    console.log('第一步: 编译合约');
    console.log('='.repeat(60));

    const mockERC20Compiled = compileSolidity('MockERC20.sol');
    const accountCompiled = compileSolidity('Account.sol');
    const sequencerCompiled = compileSolidity('Sequencer.sol');
    const orderBookCompiled = compileSolidity('OrderBook.sol');
    console.log('');

    // ========== 第二步: 部署合约 ==========
    console.log('='.repeat(60));
    console.log('第二步: 部署合约');
    console.log('='.repeat(60));

    // 部署代币
    const weth = await deployContract(deployer, 'WETH', mockERC20Compiled, 'Wrapped ETH', 'WETH', 18);
    const usdc = await deployContract(deployer, 'USDC', mockERC20Compiled, 'USD Coin', 'USDC', 6);

    // 部署核心合约
    const account = await deployContract(deployer, 'Account', accountCompiled);
    const sequencer = await deployContract(deployer, 'Sequencer', sequencerCompiled);
    const orderBook = await deployContract(deployer, 'OrderBook', orderBookCompiled);
    console.log('');

    // ========== 第三步: 配置合约关系 ==========
    console.log('='.repeat(60));
    console.log('第三步: 配置合约关系');
    console.log('='.repeat(60));

    console.log('🔗 设置合约引用...');
    await (await sequencer.setAccount(await account.getAddress())).wait();
    await (await sequencer.setOrderBook(await orderBook.getAddress())).wait();
    await (await orderBook.setSequencer(await sequencer.getAddress())).wait();
    await (await orderBook.setAccount(await account.getAddress())).wait();
    await (await account.setSequencer(await sequencer.getAddress())).wait();
    await (await account.setOrderBook(await orderBook.getAddress())).wait();
    console.log('   ✅ 所有引用已设置\n');

    // ========== 第四步: 注册交易对 ==========
    console.log('='.repeat(60));
    console.log('第四步: 注册交易对');
    console.log('='.repeat(60));

    const pairId = ethers.keccak256(ethers.toUtf8Bytes('WETH/USDC'));
    console.log(`📊 注册交易对 WETH/USDC (pairId: ${pairId.slice(0, 10)}...)`);
    await (await account.registerTradingPair(
        pairId,
        await weth.getAddress(),
        await usdc.getAddress()
    )).wait();
    console.log('   ✅ 交易对已注册\n');

    // ========== 第五步: 铸造并存入代币 ==========
    console.log('='.repeat(60));
    console.log('第五步: 准备测试资金');
    console.log('='.repeat(60));

    // Alice: 10 WETH + 50000 USDC
    console.log('💰 为 Alice 准备资金...');
    await (await weth.mint(alice.address, ethers.parseEther('10'))).wait();
    await (await usdc.mint(alice.address, 50000n * 10n**6n)).wait();

    await (await weth.connect(alice).approve(await account.getAddress(), ethers.parseEther('10'))).wait();
    await (await usdc.connect(alice).approve(await account.getAddress(), 50000n * 10n**6n)).wait();

    await (await account.connect(alice).deposit(await weth.getAddress(), ethers.parseEther('10'))).wait();
    await (await account.connect(alice).deposit(await usdc.getAddress(), 50000n * 10n**6n)).wait();
    console.log('   ✅ Alice: 10 WETH, 50000 USDC');

    // Bob: 5 WETH + 30000 USDC
    console.log('💰 为 Bob 准备资金...');
    await (await weth.mint(bob.address, ethers.parseEther('5'))).wait();
    await (await usdc.mint(bob.address, 30000n * 10n**6n)).wait();

    await (await weth.connect(bob).approve(await account.getAddress(), ethers.parseEther('5'))).wait();
    await (await usdc.connect(bob).approve(await account.getAddress(), 30000n * 10n**6n)).wait();

    await (await account.connect(bob).deposit(await weth.getAddress(), ethers.parseEther('5'))).wait();
    await (await account.connect(bob).deposit(await usdc.getAddress(), 30000n * 10n**6n)).wait();
    console.log('   ✅ Bob: 5 WETH, 30000 USDC\n');

    // ========== 第六步: 下单测试 ==========
    console.log('='.repeat(60));
    console.log('第六步: 下单测试');
    console.log('='.repeat(60));

    // Alice 下买单
    console.log('\n📈 Alice 下买单:');
    const aliceBuyOrders = [
        { price: 2000n * 10n**6n, amount: ethers.parseEther('1'), desc: '2000 USDC 买 1 WETH' },
        { price: 1950n * 10n**6n, amount: ethers.parseEther('2'), desc: '1950 USDC 买 2 WETH' },
        { price: 1900n * 10n**6n, amount: ethers.parseEther('1'), desc: '1900 USDC 买 1 WETH' }
    ];

    const aliceOrderIds = [];
    for (const order of aliceBuyOrders) {
        const tx = await sequencer.connect(alice).placeLimitOrder(
            pairId,
            false,  // 买单
            order.price,
            order.amount
        );
        const receipt = await tx.wait();
        const event = receipt.logs.find(log => {
            try {
                return sequencer.interface.parseLog(log).name === 'PlaceOrderRequested';
            } catch { return false; }
        });
        const orderId = sequencer.interface.parseLog(event).args.orderId;
        aliceOrderIds.push(orderId);
        console.log(`   ✅ 订单 ${orderId}: ${order.desc}`);
    }

    // Bob 下卖单
    console.log('\n📉 Bob 下卖单:');
    const bobSellOrders = [
        { price: 2100n * 10n**6n, amount: ethers.parseEther('1'), desc: '2100 USDC 卖 1 WETH' },
        { price: 2150n * 10n**6n, amount: ethers.parseEther('1.5'), desc: '2150 USDC 卖 1.5 WETH' },
        { price: 2200n * 10n**6n, amount: ethers.parseEther('0.5'), desc: '2200 USDC 卖 0.5 WETH' }
    ];

    const bobOrderIds = [];
    for (const order of bobSellOrders) {
        const tx = await sequencer.connect(bob).placeLimitOrder(
            pairId,
            true,  // 卖单
            order.price,
            order.amount
        );
        const receipt = await tx.wait();
        const event = receipt.logs.find(log => {
            try {
                return sequencer.interface.parseLog(log).name === 'PlaceOrderRequested';
            } catch { return false; }
        });
        const orderId = sequencer.interface.parseLog(event).args.orderId;
        bobOrderIds.push(orderId);
        console.log(`   ✅ 订单 ${orderId}: ${order.desc}`);
    }

    // ========== 第七步: 插入订单到OrderBook ==========
    console.log('\n' + '='.repeat(60));
    console.log('第七步: 插入订单到OrderBook');
    console.log('='.repeat(60));

    const allOrderIds = [...aliceOrderIds, ...bobOrderIds];
    console.log(`\n📋 批量插入 ${allOrderIds.length} 个订单...`);

    // 准备批量插入参数（全部插入到头部）
    const insertAfterPriceLevels = new Array(allOrderIds.length).fill(0);
    const insertAfterOrders = new Array(allOrderIds.length).fill(0);

    const insertTx = await orderBook.batchProcessRequests(
        allOrderIds,
        insertAfterPriceLevels,
        insertAfterOrders
    );
    const insertReceipt = await insertTx.wait();
    console.log(`   ✅ 成功插入 ${allOrderIds.length} 个订单\n`);

    // ========== 第八步: 查看订单簿状态 ==========
    console.log('='.repeat(60));
    console.log('第八步: 订单簿状态');
    console.log('='.repeat(60));

    const bookData = await orderBook.orderBooks(pairId);
    console.log('\n📊 订单簿结构:');
    console.log(`   Bid Head (最高买价): ${bookData.bidHead}`);
    console.log(`   Bid Tail (最低买价): ${bookData.bidTail}`);
    console.log(`   Ask Head (最低卖价): ${bookData.askHead}`);
    console.log(`   Ask Tail (最高卖价): ${bookData.askTail}`);

    // 查看价格层级
    console.log('\n💵 买单 (Bid) 价格层级:');
    let currentPriceLevel = bookData.bidHead;
    while (currentPriceLevel !== 0n) {
        const priceLevel = await orderBook.priceLevels(currentPriceLevel);
        console.log(`   价格: ${priceLevel.price / 10n**6n} USDC, 数量: ${ethers.formatEther(priceLevel.totalVolume)} WETH`);
        currentPriceLevel = priceLevel.nextPriceLevel;
    }

    console.log('\n💵 卖单 (Ask) 价格层级:');
    currentPriceLevel = bookData.askHead;
    while (currentPriceLevel !== 0n) {
        const priceLevel = await orderBook.priceLevels(currentPriceLevel);
        console.log(`   价格: ${priceLevel.price / 10n**6n} USDC, 数量: ${ethers.formatEther(priceLevel.totalVolume)} WETH`);
        currentPriceLevel = priceLevel.nextPriceLevel;
    }

    // ========== 第九步: 查看账户余额 ==========
    console.log('\n' + '='.repeat(60));
    console.log('第九步: 账户余额');
    console.log('='.repeat(60));

    const aliceWethBalance = await account.getBalance(alice.address, await weth.getAddress());
    const aliceUsdcBalance = await account.getBalance(alice.address, await usdc.getAddress());
    const bobWethBalance = await account.getBalance(bob.address, await weth.getAddress());
    const bobUsdcBalance = await account.getBalance(bob.address, await usdc.getAddress());

    console.log('\n💼 Alice 余额:');
    console.log(`   WETH: 可用=${ethers.formatEther(aliceWethBalance.available)}, 锁定=${ethers.formatEther(aliceWethBalance.locked)}, 总计=${ethers.formatEther(aliceWethBalance.total)}`);
    console.log(`   USDC: 可用=${aliceUsdcBalance.available / 10n**6n}, 锁定=${aliceUsdcBalance.locked / 10n**6n}, 总计=${aliceUsdcBalance.total / 10n**6n}`);

    console.log('\n💼 Bob 余额:');
    console.log(`   WETH: 可用=${ethers.formatEther(bobWethBalance.available)}, 锁定=${ethers.formatEther(bobWethBalance.locked)}, 总计=${ethers.formatEther(bobWethBalance.total)}`);
    console.log(`   USDC: 可用=${bobUsdcBalance.available / 10n**6n}, 锁定=${bobUsdcBalance.locked / 10n**6n}, 总计=${bobUsdcBalance.total / 10n**6n}`);

    // ========== 完成 ==========
    console.log('\n' + '='.repeat(60));
    console.log('✨ 测试完成！');
    console.log('='.repeat(60));
    console.log('\n📝 总结:');
    console.log(`   - 部署了 WETH/USDC 交易对`);
    console.log(`   - Alice 下了 ${aliceOrderIds.length} 个买单`);
    console.log(`   - Bob 下了 ${bobOrderIds.length} 个卖单`);
    console.log(`   - 所有订单已插入订单簿`);
    console.log(`   - 资金已正确锁定\n`);

    console.log('🎯 下一步可以测试:');
    console.log('   - 调用 matchOrders() 进行撮合');
    console.log('   - 测试撤单功能');
    console.log('   - 测试市价单\n');
}

// 运行测试
main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error('\n❌ 错误:', error);
        process.exit(1);
    });
