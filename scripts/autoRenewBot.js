import hre from "hardhat";
const { ethers } = hre;

async function main() {
    const [deployer, user1, user2] = await ethers.getSigners();
    
    const SAVING_CORE_ADDRESS = "0x5f3f1dBD7B74C6B46e8c44f98792A1dAf8d69154";
    const VAULT_MANAGER_ADDRESS = "0xCD8a1C3ba11CF5ECfa6267617243239504a98d90";
    const MOCK_USDC_ADDRESS = "0x1291Be112d480055DaFd8a610b7d1e203891C274";

    const savingCore = await ethers.getContractAt("SavingCore", SAVING_CORE_ADDRESS);
    const vaultManager = await ethers.getContractAt("VaultManager", VAULT_MANAGER_ADDRESS);
    const mockUSDC = await ethers.getContractAt("MockUSDC", MOCK_USDC_ADDRESS);

    console.log("\n=== Auto Renew Bot ===\n");
    console.log("SavingCore:", SAVING_CORE_ADDRESS);
    console.log("VaultManager:", VAULT_MANAGER_ADDRESS);
    const block = await ethers.provider.getBlock();
    console.log("Current block timestamp:", Number(block.timestamp));

    const nextTokenId = Number(await savingCore.nextTokenId());
    console.log("\nTotal NFTs minted:", nextTokenId - 1);

    const expiredTokens = [];
    const currentBlock = await ethers.provider.getBlock();
    const currentTime = Number(currentBlock.timestamp);

    console.log("\n--- Scanning for expired positions ---\n");
    for (let tokenId = 1; tokenId < nextTokenId; tokenId++) {
        try {
            const position = await savingCore.getPosition(tokenId);
            const owner = await savingCore.ownerOf(tokenId);
            
            if (!position.active) {
                console.log(`Token #${tokenId}: Already withdrawn (inactive)`);
                continue;
            }

            const maturityAt = Number(position.maturityAt);
            const gracePeriodEnd = maturityAt + (3 * 24 * 60 * 60);
            
            console.log(`Token #${tokenId}:`);
            console.log(`  Owner: ${owner}`);
            console.log(`  Principal: ${ethers.formatUnits(position.principal, 6)} USDC`);
            console.log(`  Maturity: ${maturityAt} (${new Date(maturityAt * 1000).toLocaleString()})`);
            console.log(`  Grace period ends: ${gracePeriodEnd} (${new Date(gracePeriodEnd * 1000).toLocaleString()})`);
            console.log(`  Current time: ${currentTime} (${new Date(currentTime * 1000).toLocaleString()})`);

            if (currentTime >= gracePeriodEnd) {
                expiredTokens.push({ tokenId, owner, maturityAt, gracePeriodEnd });
                console.log(`  ⚠️  EXPIRED - Can be auto renewed!`);
            } else if (currentTime >= maturityAt) {
                console.log(`  ⏳ Matured, waiting for 3-day grace period`);
            } else {
                console.log(`  ✓ Not yet matured`);
            }
            console.log("");

        } catch (e) {
            console.log(`Token #${tokenId}: Does not exist or error - ${e.message.slice(0, 50)}`);
        }
    }

    console.log("\n--- Auto Renew Execution ---\n");
    
    if (expiredTokens.length === 0) {
        console.log("No tokens to auto renew.");
    } else {
        const autoRenewEnabled = await savingCore.autoRenewEnabled();
        console.log("Auto renew enabled:", autoRenewEnabled);

        if (!autoRenewEnabled) {
            console.log("⚠️  Auto renew is disabled. Enabling...");
            const tx = await savingCore.setAutoRenew(true);
            await tx.wait();
            console.log("Enabled auto renew.\n");
        }

        for (const token of expiredTokens) {
            console.log(`Auto renewing token #${token.tokenId} for ${token.owner}...`);
            try {
                const tx = await savingCore.autoRenew(token.tokenId);
                const receipt = await tx.wait();
                console.log(`✓ Success! Gas used: ${receipt.gasUsed}`);
                
                const position = await savingCore.getPosition(token.tokenId);
                console.log(`  New maturity: ${position.maturityAt}`);
                console.log(`  New APR: ${position.aprSnapshot} bps`);
                console.log(`  Renew count: ${position.renewCount}`);
            } catch (e) {
                console.log(`✗ Failed: ${e.message}`);
            }
            console.log("");
        }
    }

    console.log("\n=== Bot Finished ===\n");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });