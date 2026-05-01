import hre from "hardhat";
const { ethers } = hre;

async function main() {
    const [deployer, user1, user2, user3] = await ethers.getSigners();
    
    const SAVING_CORE_ADDRESS = "0x5f3f1dBD7B74C6B46e8c44f98792A1dAf8d69154";
    const VAULT_MANAGER_ADDRESS = "0xCD8a1C3ba11CF5ECfa6267617243239504a98d90";
    const MOCK_USDC_ADDRESS = "0x1291Be112d480055DaFd8a610b7d1e203891C274";

    const savingCore = await ethers.getContractAt("SavingCore", SAVING_CORE_ADDRESS);
    const vaultManager = await ethers.getContractAt("VaultManager", VAULT_MANAGER_ADDRESS);
    const mockUSDC = await ethers.getContractAt("MockUSDC", MOCK_USDC_ADDRESS);

    console.log("\n=== Setup Test Data ===\n");

    const userAmount = ethers.parseUnits("5000", 6);
    console.log("Minting USDC for test users...");
    await mockUSDC.mint(user1.address, userAmount);
    await mockUSDC.mint(user2.address, userAmount);
    await mockUSDC.mint(user3.address, userAmount);
    console.log("Minted 5000 USDC for each user\n");

    const INITIAL_FUNDS = ethers.parseUnits("50000", 6);
    console.log("Depositing interest funds to vault...");
    await mockUSDC.approve(vaultManager, INITIAL_FUNDS);
    await vaultManager.depositFunds(INITIAL_FUNDS);
    console.log("Deposited:", ethers.formatUnits(INITIAL_FUNDS, 6), "USDC\n");

    console.log("Existing plans:");
    const nextPlanId = await savingCore.nextPlanId();
    for (let i = 1; i < nextPlanId; i++) {
        const plan = await savingCore.getPlan(i);
        console.log(`  Plan ${i}: ${plan.tenorDays}d, APR ${plan.aprBps}bps, min ${plan.minDeposit}, max ${plan.maxDeposit}`);
    }
    console.log("");

    console.log("Creating test plans with higher limits...");
    await savingCore.createPlan(2, 100, 10, 100000000000, 200);
    await savingCore.createPlan(7, 150, 10, 100000000000, 300);
    await savingCore.createPlan(30, 250, 10, 100000000000, 500);
    console.log("Created new plans with high max limits (100B USDC)\n");

    const depositAmount = ethers.parseUnits("100", 6);
    console.log("Setting up deposits...\n");

    console.log("=== User1: Deposit for 2-day plan (will be ready for auto-renew soon) ===");
    await mockUSDC.connect(user1).approve(savingCore, depositAmount);
    const tx1 = await savingCore.connect(user1).openDeposit(1, depositAmount);
    const receipt1 = await tx1.wait();
    const tokenId1 = receipt1.logs.find(l => l.fragment?.name === "DepositOpened")?.args[1] || 1;
    console.log("Deposited 100 USDC, Token ID:", tokenId1);

    const position1 = await savingCore.getPosition(tokenId1);
    console.log(`  Maturity: ${position1.maturityAt} (${new Date(Number(position1.maturityAt) * 1000).toLocaleString()})`);
    console.log("");

    console.log("=== User2: Deposit for 30-day plan ===");
    await mockUSDC.connect(user2).approve(savingCore, depositAmount);
    const tx2 = await savingCore.connect(user2).openDeposit(3, depositAmount);
    const receipt2 = await tx2.wait();
    const tokenId2 = receipt2.logs.find(l => l.fragment?.name === "DepositOpened")?.args[1] || 2;
    console.log("Deposited 100 USDC, Token ID:", tokenId2);

    const position2 = await savingCore.getPosition(tokenId2);
    console.log(`  Maturity: ${position2.maturityAt} (${new Date(Number(position2.maturityAt) * 1000).toLocaleString()})`);
    console.log("");

    console.log("=== User3: Deposit for 7-day plan ===");
    await mockUSDC.connect(user3).approve(savingCore, depositAmount);
    const tx3 = await savingCore.connect(user3).openDeposit(2, depositAmount);
    const receipt3 = await tx3.wait();
    const tokenId3 = receipt3.logs.find(l => l.fragment?.name === "DepositOpened")?.args[1] || 3;
    console.log("Deposited 100 USDC, Token ID:", tokenId3);

    const position3 = await savingCore.getPosition(tokenId3);
    console.log(`  Maturity: ${position3.maturityAt} (${new Date(Number(position3.maturityAt) * 1000).toLocaleString()})`);
    console.log("");

    console.log("=== Current Block Timestamp ===");
    const currentBlock = await ethers.provider.getBlock();
    console.log(`Timestamp: ${currentBlock.timestamp} (${new Date(currentBlock.timestamp * 1000).toLocaleString()})`);
    console.log("");

    console.log("=== Summary ===");
    console.log(`- Token #${tokenId1} (user1): 100 USDC, maturity ${new Date(Number(position1.maturityAt) * 1000).toLocaleString()}`);
    console.log(`- Token #${tokenId2} (user2): 100 USDC, maturity ${new Date(Number(position2.maturityAt) * 1000).toLocaleString()}`);
    console.log(`- Token #${tokenId3} (user3): 100 USDC, maturity ${new Date(Number(position3.maturityAt) * 1000).toLocaleString()}`);
    console.log("\nTo test auto-renew, advance time past maturity + 3 days");
    console.log("Run: npx hardhat node with --timestamp option or use evm_increaseTime\n");

    console.log("=== Setup Complete ===");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });