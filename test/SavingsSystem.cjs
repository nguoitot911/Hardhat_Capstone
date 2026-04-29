const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("SavingsSystem", function () {
  let mockUSDC, vaultManager, savingCore;
  let owner, user1, user2;
  const RAY = ethers.parseEther("1"); // 1e18, but we use 1e27 in contract

  beforeEach(async function () {
    [owner, user1, user2] = await ethers.getSigners();

    // Deploy contracts
    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    mockUSDC = await MockUSDC.deploy();

    const VaultManager = await ethers.getContractFactory("VaultManager");
    vaultManager = await VaultManager.deploy(mockUSDC.target, 50000000000000000000000000n); // 5% APY

    const SavingCore = await ethers.getContractFactory("SavingCore");
    savingCore = await SavingCore.deploy(vaultManager.target, mockUSDC.target);

    // Grant saving core role to SavingCore contract
    await vaultManager.grantSavingCoreRole(savingCore.target);

    // Create interest packages (duration in seconds => interest rate in RAY)
    await savingCore.createPackage(30 * 24 * 60 * 60, 50000000000000000000000000n); // 30 days - 5%
    await savingCore.createPackage(60 * 24 * 60 * 60, 60000000000000000000000000n); // 60 days - 6%
    await savingCore.createPackage(90 * 24 * 60 * 60, 70000000000000000000000000n); // 90 days - 7%
    await savingCore.createPackage(365 * 24 * 60 * 60, 80000000000000000000000000n); // 365 days - 8%

    // Fund users with USDC
    await mockUSDC.mint(user1.address, ethers.parseUnits("10000", 6));
    await mockUSDC.mint(user2.address, ethers.parseUnits("10000", 6));

    // Fund vault
    await mockUSDC.mint(owner.address, ethers.parseUnits("10000", 6));
    await mockUSDC.connect(owner).approve(vaultManager.target, ethers.parseUnits("10000", 6));
    await vaultManager.depositFunds(ethers.parseUnits("10000", 6));
  });

  describe("Deployment", function () {
    it("Should deploy all contracts", async function () {
      expect(mockUSDC.target).to.be.properAddress;
      expect(vaultManager.target).to.be.properAddress;
      expect(savingCore.target).to.be.properAddress;
    });

    it("Should have correct initial setup", async function () {
      expect(await mockUSDC.decimals()).to.equal(6);
      // RAY = 1e27 = 10^27
      expect(await vaultManager.reserveIndex()).to.equal(10n ** 27n);
    });
  });

  describe("Deposit", function () {
    it("Should allow deposit and mint NFT", async function () {
      const amount = ethers.parseUnits("1000", 6);
      const lockDuration = 30 * 24 * 60 * 60; // 30 days

      await mockUSDC.connect(user1).approve(savingCore.target, ethers.parseUnits("10000", 6));

      await expect(savingCore.connect(user1).deposit(amount, lockDuration))
        .to.emit(savingCore, "Deposited");

      expect(await savingCore.balanceOf(user1.address)).to.equal(1);
      expect(await savingCore.ownerOf(1)).to.equal(user1.address);
    });

    it("Should reject invalid package", async function () {
      const amount = ethers.parseUnits("1000", 6);
      const invalidDuration = 10 * 24 * 60 * 60; // 10 days

      await mockUSDC.connect(user1).approve(savingCore.target, ethers.parseUnits("10000", 6));

      await expect(
        savingCore.connect(user1).deposit(amount, invalidDuration)
      ).to.be.revertedWith("Invalid package");
    });
  });

  describe("Withdrawal", function () {
    let tokenId;

    beforeEach(async function () {
      const amount = ethers.parseUnits("1000", 6);
      const lockDuration = 30 * 24 * 60 * 60;

      await mockUSDC.connect(user1).approve(savingCore.target, ethers.parseUnits("10000", 6));
      const tx = await savingCore.connect(user1).deposit(amount, lockDuration);
      const receipt = await tx.wait();
      tokenId = 1; // First token
    });

    it("Should reject withdrawal before unlock time", async function () {
      await expect(
        savingCore.connect(user1).withdraw(tokenId)
      ).to.be.revertedWith("Still locked");
    });

    it("Should allow withdrawal after unlock time", async function () {
      // Advance time
      await time.increase(30 * 24 * 60 * 60 + 1);

      const balanceBefore = await mockUSDC.balanceOf(user1.address);

      await expect(savingCore.connect(user1).withdraw(tokenId))
        .to.emit(savingCore, "Withdrawn");

      const balanceAfter = await mockUSDC.balanceOf(user1.address);

      // Should have more than principal due to interest
      expect(balanceAfter).to.be.gt(balanceBefore);
    });

    it("Should allow early withdrawal with penalty", async function () {
      // Advance partial time
      await time.increase(15 * 24 * 60 * 60); // 15 days

      const balanceBefore = await mockUSDC.balanceOf(user1.address);

      await savingCore.connect(user1).earlyWithdraw(tokenId);

      const balanceAfter = await mockUSDC.balanceOf(user1.address);

      // Should have some interest but less than full
      expect(balanceAfter).to.be.gt(balanceBefore);
    });
  });

  describe("Interest Calculation", function () {
    it("Should calculate interest correctly", async function () {
      const amount = ethers.parseUnits("1000", 6);
      const lockDuration = 365 * 24 * 60 * 60; // 1 year

      await mockUSDC.connect(user1).approve(savingCore.target, ethers.parseUnits("10000", 6));
      await savingCore.connect(user1).deposit(amount, lockDuration);

      await time.increase(365 * 24 * 60 * 60);

      const currentBalance = await savingCore.getCurrentBalance.staticCall(1);
      
      // At 8% APY (365-day package), after 1 year should be ~1080
      expect(currentBalance).to.be.gt(amount);
      expect(currentBalance).to.be.lt(ethers.parseUnits("1100", 6));
    });
  });

  describe("Admin Functions", function () {
    it("Should allow admin to create packages", async function () {
      const duration = 60 * 24 * 60 * 60; // 60 days
      const rate = 30000000000000000000000000n; // 3%

      await expect(savingCore.createPackage(duration, rate))
        .to.emit(savingCore, "PackageCreated");

      expect(await savingCore.interestPackages(duration)).to.equal(rate);
    });

    it("Should allow admin to pause/unpause", async function () {
      await savingCore.pause();
      expect(await savingCore.paused()).to.be.true;

      await savingCore.unpause();
      expect(await savingCore.paused()).to.be.false;
    });
  });
});