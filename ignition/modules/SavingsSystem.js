import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("SavingsSystem", (m) => {
  // Deploy MockUSDC
  const mockUSDC = m.contract("MockUSDC");

  // Initial interest rate: 5% APY = 0.05 * 1e27
  const initialInterestRate = m.getParameter("initialInterestRate", 50000000000000000000000000n); // 0.05 * 1e27

  // Deploy VaultManager
  const vaultManager = m.contract("VaultManager", [initialInterestRate]);

  // Deploy SavingCore
  const savingCore = m.contract("SavingCore", [vaultManager, mockUSDC]);

  // Fund vault with initial interest funds (for testing)
  const initialFunds = m.getParameter("initialFunds", 1000000000n); // 1000 USDC (6 decimals)
  m.call(mockUSDC, "mint", [vaultManager, initialFunds]);
  m.call(vaultManager, "depositFunds", [initialFunds]);

  // Create some interest packages
  const package1Duration = 30 * 24 * 60 * 60; // 30 days
  const package1Rate = 20000000000000000000000000n; // 2% APY
  m.call(savingCore, "createPackage", [package1Duration, package1Rate]);

  const package2Duration = 90 * 24 * 60 * 60; // 90 days
  const package2Rate = 50000000000000000000000000n; // 5% APY
  m.call(savingCore, "createPackage", [package2Duration, package2Rate]);

  const package3Duration = 365 * 24 * 60 * 60; // 1 year
  const package3Rate = 100000000000000000000000000n; // 10% APY
  m.call(savingCore, "createPackage", [package3Duration, package3Rate]);

  return { mockUSDC, vaultManager, savingCore };
});