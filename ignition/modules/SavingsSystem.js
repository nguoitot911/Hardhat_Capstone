import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("SavingsSystem", (m) => {
  const deployer = m.getAccount(0);

  const feeReceiver = m.getParameter("feeReceiver", deployer);

  const initialFunds = m.getParameter("initialFunds", 1000000000n);

  const mockUSDC = m.contract("MockUSDC");

  const savingCore = m.contract("SavingCore", [mockUSDC, "0x0000000000000000000000000000000000000001"]);

  const vaultManager = m.contract("VaultManager", [mockUSDC, feeReceiver, savingCore]);

  m.call(mockUSDC, "mint", [deployer, initialFunds], { id: "mintInitialFunds" });

  m.call(savingCore, "setVaultManager", [vaultManager], { id: "setVaultManager" });

  return { mockUSDC, vaultManager, savingCore };
});