// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IVaultManager {
    function RAY() external pure returns (uint256);
    function reserveIndex() external view returns (uint256);
    function totalInterestFunds() external view returns (uint256);
    function totalDeposits() external view returns (uint256);
    function updateReserveIndex() external;
    function getBalanceWithInterest(uint256 scaledAmount) external returns (uint256);
    function depositFunds(uint256 amount) external;
    function withdrawFunds(uint256 amount) external;
    function receiveDeposit(uint256 amount) external;
    function withdrawToUser(address user, uint256 principal, uint256 interest) external;
    function grantSavingCoreRole(address savingCore) external;
}