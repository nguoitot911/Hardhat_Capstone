import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("SavingsSystem", (m) => {
  const deployer = m.getAccount(0);

  const mockUSDC = m.contract("MockUSDC");

  const feeReceiver = m.getParameter("feeReceiver", deployer);

  const vaultManager = m.contract("VaultManager", [mockUSDC, feeReceiver]);

  const savingCore = m.contract("SavingCore", [mockUSDC, vaultManager]);

  const initialFunds = m.getParameter("initialFunds", 1000000000n);
  m.call(mockUSDC, "mint", [deployer, initialFunds], { id: "mintInitialFunds" });

  return { mockUSDC, vaultManager, savingCore };
});