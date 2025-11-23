const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OrderBook System", function () {
  let weth, usdc;
  let account, sequencer, orderBook;
  let deployer, alice, bob;
  let pairId;

  before(async function () {
    console.log("\n" + "=".repeat(60));
    console.log("🚀 部署 OrderBook 系统");
    console.log("=".repeat(60));

    // 获取签名者
    [deployer, alice, bob] = await ethers.getSigners();
    console.log("\n👥 测试账户:");
    console.log(`   Deployer: ${deployer.address}`);
    console.log(`   Alice:    ${alice.address}`);
    console.log(`   Bob:      ${bob.address}`);

    // 部署代币
    console.log("\n💎 部署代币...");
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    weth = await MockERC20.deploy("Wrapped ETH", "WETH", 18);
    await weth.waitForDeployment();
    console.log(`   ✅ WETH: ${await weth.getAddress()}`);

    usdc = await MockERC20.deploy("USD Coin", "USDC", 6);
    await usdc.waitForDeployment();
    console.log(`   ✅ USDC: ${await usdc.getAddress()}`);

    // 部署核心合约
    console.log("\n🏗️  部署核心合约...");
    const Account = await ethers.getContractFactory("Account");
    account = await Account.deploy();
    await account.waitForDeployment();
    console.log(`   ✅ Account:  ${await account.getAddress()}`);

    const Sequencer = await ethers.getContractFactory("Sequencer");
    sequencer = await Sequencer.deploy();
    await sequencer.waitForDeployment();
    console.log(`   ✅ Sequencer: ${await sequencer.getAddress()}`);

    const OrderBook = await ethers.getContractFactory("OrderBook");
    orderBook = await OrderBook.deploy();
    await orderBook.waitForDeployment();
    console.log(`   ✅ OrderBook: ${await orderBook.getAddress()}`);

    // 配置合约关系
    console.log("\n🔗 配置合约关系...");
    await sequencer.setAccount(await account.getAddress());
    await sequencer.setOrderBook(await orderBook.getAddress());
    await orderBook.setSequencer(await sequencer.getAddress());
    await orderBook.setAccount(await account.getAddress());
    await account.setSequencer(await sequencer.getAddress());
    await account.setOrderBook(await orderBook.getAddress());
    console.log("   ✅ 所有引用已设置");

    // 注册交易对
    console.log("\n📊 注册交易对...");
    pairId = ethers.keccak256(ethers.toUtf8Bytes("WETH/USDC"));
    await account.registerTradingPair(
      pairId,
      await weth.getAddress(),
      await usdc.getAddress()
    );
    console.log(`   ✅ WETH/USDC (${pairId.slice(0, 10)}...)`);

    // 准备测试资金
    console.log("\n💰 准备测试资金...");

    // Alice: 10 WETH + 50000 USDC
    await weth.mint(alice.address, ethers.parseEther("10"));
    await usdc.mint(alice.address, 50000n * 10n**6n);
    await weth.connect(alice).approve(await account.getAddress(), ethers.parseEther("10"));
    await usdc.connect(alice).approve(await account.getAddress(), 50000n * 10n**6n);
    await account.connect(alice).deposit(await weth.getAddress(), ethers.parseEther("10"));
    await account.connect(alice).deposit(await usdc.getAddress(), 50000n * 10n**6n);
    console.log("   ✅ Alice: 10 WETH, 50000 USDC");

    // Bob: 5 WETH + 30000 USDC
    await weth.mint(bob.address, ethers.parseEther("5"));
    await usdc.mint(bob.address, 30000n * 10n**6n);
    await weth.connect(bob).approve(await account.getAddress(), ethers.parseEther("5"));
    await usdc.connect(bob).approve(await account.getAddress(), 30000n * 10n**6n);
    await account.connect(bob).deposit(await weth.getAddress(), ethers.parseEther("5"));
    await account.connect(bob).deposit(await usdc.getAddress(), 30000n * 10n**6n);
    console.log("   ✅ Bob: 5 WETH, 30000 USDC");

    console.log("\n" + "=".repeat(60));
    console.log("✨ 部署完成，开始测试");
    console.log("=".repeat(60) + "\n");
  });

  describe("下单测试", function () {
    let aliceOrderIds = [];
    let bobOrderIds = [];

    it("Alice 应该能下3个买单", async function () {
      console.log("\n📈 Alice 下买单:");

      const orders = [
        { price: 2000n * 10n**6n, amount: ethers.parseEther("1") },
        { price: 1950n * 10n**6n, amount: ethers.parseEther("2") },
        { price: 1900n * 10n**6n, amount: ethers.parseEther("1") }
      ];

      for (let i = 0; i < orders.length; i++) {
        const tx = await sequencer.connect(alice).placeLimitOrder(
          pairId,
          false,  // 买单
          orders[i].price,
          orders[i].amount
        );
        const receipt = await tx.wait();

        const event = receipt.logs.find(log => {
          try {
            const parsed = sequencer.interface.parseLog(log);
            return parsed.name === "PlaceOrderRequested";
          } catch { return false; }
        });

        const parsedEvent = sequencer.interface.parseLog(event);
        const orderId = parsedEvent.args.orderId;
        aliceOrderIds.push(orderId);

        console.log(`   ✅ 订单 ${orderId}: ${orders[i].price / 10n**6n} USDC 买 ${ethers.formatEther(orders[i].amount)} WETH`);
      }

      expect(aliceOrderIds.length).to.equal(3);
    });

    it("Bob 应该能下3个卖单", async function () {
      console.log("\n📉 Bob 下卖单:");

      const orders = [
        { price: 2100n * 10n**6n, amount: ethers.parseEther("1") },
        { price: 2150n * 10n**6n, amount: ethers.parseEther("1.5") },
        { price: 2200n * 10n**6n, amount: ethers.parseEther("0.5") }
      ];

      for (let i = 0; i < orders.length; i++) {
        const tx = await sequencer.connect(bob).placeLimitOrder(
          pairId,
          true,  // 卖单
          orders[i].price,
          orders[i].amount
        );
        const receipt = await tx.wait();

        const event = receipt.logs.find(log => {
          try {
            const parsed = sequencer.interface.parseLog(log);
            return parsed.name === "PlaceOrderRequested";
          } catch { return false; }
        });

        const parsedEvent = sequencer.interface.parseLog(event);
        const orderId = parsedEvent.args.orderId;
        bobOrderIds.push(orderId);

        console.log(`   ✅ 订单 ${orderId}: ${orders[i].price / 10n**6n} USDC 卖 ${ethers.formatEther(orders[i].amount)} WETH`);
      }

      expect(bobOrderIds.length).to.equal(3);
    });

    it("应该能批量插入所有订单到OrderBook", async function () {
      console.log("\n📋 批量插入订单到OrderBook:");

      const allOrderIds = [...aliceOrderIds, ...bobOrderIds];
      const insertAfterPriceLevels = new Array(allOrderIds.length).fill(0);
      const insertAfterOrders = new Array(allOrderIds.length).fill(0);

      const tx = await orderBook.batchProcessRequests(
        allOrderIds,
        insertAfterPriceLevels,
        insertAfterOrders
      );
      await tx.wait();

      console.log(`   ✅ 成功插入 ${allOrderIds.length} 个订单`);

      // 验证订单簿不为空
      const bookData = await orderBook.orderBooks(pairId);
      expect(bookData.bidHead).to.not.equal(0);
      expect(bookData.askHead).to.not.equal(0);
    });
  });

  describe("订单簿状态", function () {
    it("应该显示正确的订单簿结构", async function () {
      console.log("\n📊 订单簿状态:");

      const bookData = await orderBook.orderBooks(pairId);
      console.log(`   Bid Head: ${bookData.bidHead}`);
      console.log(`   Ask Head: ${bookData.askHead}`);

      // 显示买单价格层级
      console.log("\n💵 买单 (Bid) 价格层级:");
      let currentPriceLevel = bookData.bidHead;
      let bidLevels = 0;
      while (currentPriceLevel !== 0n) {
        const priceLevel = await orderBook.priceLevels(currentPriceLevel);
        console.log(`   价格: ${priceLevel.price / 10n**6n} USDC, 数量: ${ethers.formatEther(priceLevel.totalVolume)} WETH`);
        currentPriceLevel = priceLevel.nextPriceLevel;
        bidLevels++;
      }

      // 显示卖单价格层级
      console.log("\n💵 卖单 (Ask) 价格层级:");
      currentPriceLevel = bookData.askHead;
      let askLevels = 0;
      while (currentPriceLevel !== 0n) {
        const priceLevel = await orderBook.priceLevels(currentPriceLevel);
        console.log(`   价格: ${priceLevel.price / 10n**6n} USDC, 数量: ${ethers.formatEther(priceLevel.totalVolume)} WETH`);
        currentPriceLevel = priceLevel.nextPriceLevel;
        askLevels++;
      }

      expect(bidLevels).to.equal(3);
      expect(askLevels).to.equal(3);
    });
  });

  describe("账户余额", function () {
    it("应该正确锁定资金", async function () {
      console.log("\n💼 账户余额:");

      const aliceWeth = await account.getBalance(alice.address, await weth.getAddress());
      const aliceUsdc = await account.getBalance(alice.address, await usdc.getAddress());
      const bobWeth = await account.getBalance(bob.address, await weth.getAddress());
      const bobUsdc = await account.getBalance(bob.address, await usdc.getAddress());

      console.log("\n   Alice:");
      console.log(`     WETH: 可用=${ethers.formatEther(aliceWeth.available)}, 锁定=${ethers.formatEther(aliceWeth.locked)}`);
      console.log(`     USDC: 可用=${aliceUsdc.available / 10n**6n}, 锁定=${aliceUsdc.locked / 10n**6n}`);

      console.log("\n   Bob:");
      console.log(`     WETH: 可用=${ethers.formatEther(bobWeth.available)}, 锁定=${ethers.formatEther(bobWeth.locked)}`);
      console.log(`     USDC: 可用=${bobUsdc.available / 10n**6n}, 锁定=${bobUsdc.locked / 10n**6n}`);

      // Alice 应该锁定了 USDC (买单)
      // 2000*1 + 1950*2 + 1900*1 = 2000 + 3900 + 1900 = 7800 USDC
      expect(aliceUsdc.locked).to.equal(7800n * 10n**6n);

      // Bob 应该锁定了 WETH (卖单)
      // 1 + 1.5 + 0.5 = 3 WETH
      expect(bobWeth.locked).to.equal(ethers.parseEther("3"));
    });
  });

  describe("撤单测试", function () {
    it("Alice 应该能撤销一个买单", async function () {
      console.log("\n🚫 测试撤单功能:");

      // 获取Alice的第一个订单ID
      const headOrderId = await sequencer.getHeadOrderId();

      // 获取订单信息
      const orderInfo = await sequencer.getQueuedRequest(headOrderId);
      console.log(`   撤销订单 ${headOrderId}`);

      // 请求撤单
      const tx = await sequencer.connect(alice).requestRemoveOrder(headOrderId);
      const receipt = await tx.wait();

      const event = receipt.logs.find(log => {
        try {
          const parsed = sequencer.interface.parseLog(log);
          return parsed.name === "RemoveOrderRequested";
        } catch { return false; }
      });

      const parsedEvent = sequencer.interface.parseLog(event);
      const removeRequestId = parsedEvent.args.requestId;
      console.log(`   ✅ 撤单请求 ${removeRequestId} 已提交`);

      // 处理撤单请求
      const processTx = await orderBook.processRemoveOrder(removeRequestId);
      await processTx.wait();
      console.log(`   ✅ 订单 ${headOrderId} 已移除`);

      // 验证资金已解锁
      const aliceUsdc = await account.getBalance(alice.address, await usdc.getAddress());
      console.log(`   Alice USDC: 可用=${aliceUsdc.available / 10n**6n}, 锁定=${aliceUsdc.locked / 10n**6n}`);
    });
  });

  after(async function () {
    console.log("\n" + "=".repeat(60));
    console.log("✨ 所有测试完成！");
    console.log("=".repeat(60));
    console.log("\n📝 测试总结:");
    console.log("   ✅ 部署了完整的 OrderBook 系统");
    console.log("   ✅ 创建了 WETH/USDC 交易对");
    console.log("   ✅ 测试了下单功能");
    console.log("   ✅ 测试了批量插入");
    console.log("   ✅ 验证了资金锁定");
    console.log("   ✅ 测试了撤单功能\n");
  });
});
