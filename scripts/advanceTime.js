import hre from "hardhat";
const { ethers, network } = hre;

async function main() {
    const SECONDS_PER_DAY = 24 * 60 * 60;
    
    console.log("Advancing time by 5 days (past maturity + 3 days grace period for token 1)...");
    
    await network.provider.send("evm_increaseTime", [5 * SECONDS_PER_DAY]);
    await network.provider.send("evm_mine");
    
    const block = await ethers.provider.getBlock();
    console.log(`New timestamp: ${block.timestamp} (${new Date(block.timestamp * 1000).toLocaleString()})`);
}

main().catch(console.error);