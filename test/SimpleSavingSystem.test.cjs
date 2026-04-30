const { ethers } = require("hardhat");
const { expect } = require("chai");

describe("SimpleSavingSystem", function () {
  let savingSystem, mockUSDC, owner, user1, user2;

  beforeEach(async function () {
    [owner, user1, user2] = await ethers.getSigners();

    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    mockUSDC = await MockUSDC.deploy();
    await mockUSDC.waitForDeployment();

    const SimpleSavingSystem = await ethers.getContractFactory("SimpleSavingSystem");
    savingSystem = await SimpleSavingSystem.deploy(await mockUSDC.getAddress());
    await savingSystem.waitForDeployment();

    // Mint some USDC for testing
    await mockUSDC.mint(owner.address, ethers.parseEther("10000"));
    await mockUSDC.mint(user1.address, ethers.parseEther("10000"));
    await mockUSDC.mint(user2.address, ethers.parseEther("10000"));
  });

  describe("Deposit", function () {
    it("Should allow deposit and mint NFT", async function () {
      await mockUSDC.connect(user1).approve(await savingSystem.getAddress(), ethers.parseEther("1000"));
      
      const tx = await savingSystem.connect(user1).deposit(ethers.parseEther("1000"), 30 * 24 * 60 * 60);
      await tx.wait();
      
      const tokenId = 1;
      
      expect(await savingSystem.ownerOf(tokenId)).to.equal(user1.address);
      expect((await savingSystem.positions(tokenId)).principal).to.equal(ethers.parseEther("1000"));
    });
  });

  describe("Withdraw", function () {
    beforeEach(async function () {
      // Add interest funds first
      await mockUSDC.connect(owner).approve(await savingSystem.getAddress(), ethers.parseEther("1000"));
      await savingSystem.connect(owner).addInterestFunds(ethers.parseEther("1000"));
      
      // User deposits
      await mockUSDC.connect(user1).approve(await savingSystem.getAddress(), ethers.parseEther("1000"));
      await savingSystem.connect(user1).deposit(ethers.parseEther("1000"), 30 * 24 * 60 * 60);
    });

    it("Should allow withdraw after lock period", async function () {
      // Skip time forward 31 days
      await ethers.provider.send("evm_increaseTime", [31 * 24 * 60 * 60]);
      await ethers.provider.send("evm_mine");

      const tokenId = 1;
      const balanceBefore = await mockUSDC.balanceOf(user1.address);
      
      await savingSystem.connect(user1).withdraw(tokenId);
      
      const balanceAfter = await mockUSDC.balanceOf(user1.address);
      expect(balanceAfter - balanceBefore).to.be.gt(ethers.parseEther("1000"));
    });
  });
});