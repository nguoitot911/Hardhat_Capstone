// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract VaultManager is AccessControl, ReentrancyGuard {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    IERC20 public immutable token;
    address public feeReceiver;
    address public savingCore;
    uint256 public totalDeposits;
    uint256 public interestFunds;

    modifier onlySavingCore() {
        require(msg.sender == savingCore, "Caller is not SavingCore");
        _;
    }

    event FeeReceiverSet(address indexed newFeeReceiver);
    event FundsDeposited(address indexed depositor, uint256 amount);
    event FundsWithdrawn(address indexed withdrawer, uint256 amount);
    event DepositReceived(address indexed from, uint256 amount);
    event WithdrawalProcessed(address indexed user, uint256 principal, uint256 interest);
    event PenaltyTransferred(address indexed feeReceiver, uint256 amount);
    event RenewalBonusPaid(address indexed user, uint256 amount);

    constructor(address _token, address _feeReceiver, address _savingCore) {
        require(_token != address(0), "Invalid token address");
        require(_feeReceiver != address(0), "Invalid feeReceiver address");
        require(_savingCore != address(0), "Invalid savingCore address");

        token = IERC20(_token);
        feeReceiver = _feeReceiver;
        savingCore = _savingCore;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    function setSavingCore(address _savingCore) external onlyRole(ADMIN_ROLE) {
        require(_savingCore != address(0), "Invalid savingCore address");
        savingCore = _savingCore;
    }

    function setFeeReceiver(address _feeReceiver) external onlyRole(ADMIN_ROLE) {
        require(_feeReceiver != address(0), "Invalid feeReceiver address");
        feeReceiver = _feeReceiver;
        emit FeeReceiverSet(_feeReceiver);
    }

    function depositFunds(uint256 amount) external onlyRole(ADMIN_ROLE) {
        require(amount > 0, "Amount must be > 0");
        require(token.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        interestFunds = interestFunds + amount;
        emit FundsDeposited(msg.sender, amount);
    }

    function withdrawFunds(uint256 amount) external onlyRole(ADMIN_ROLE) nonReentrant {
        require(amount <= interestFunds, "Insufficient interest funds");
        require(token.transfer(msg.sender, amount), "Transfer failed");
        interestFunds -= amount;
        emit FundsWithdrawn(msg.sender, amount);
    }

    function receiveDeposit(uint256 amount) external onlySavingCore {
        require(amount > 0, "Amount must be > 0");
        totalDeposits = totalDeposits + amount;
        emit DepositReceived(msg.sender, amount);
    }

    function withdrawToUser(address user, uint256 principal, uint256 interest) external onlySavingCore nonReentrant{
        require(user != address(0), "Invalid user address");
        require(principal > 0 || interest > 0, "Amount must be > 0");

        uint256 totalAmount = principal + interest;
        require(token.balanceOf(address(this)) >= totalAmount, "Insufficient vault funds");

        if (principal > 0) {
            require(totalDeposits >= principal, "Insufficient deposits");
        }

        if (interest > 0) {
            require(interestFunds >= interest, "Insufficient interest funds");
        }

        require(token.transfer(user, totalAmount), "Transfer failed");

        if (principal > 0) {
            totalDeposits -= principal;
        }

        if (interest > 0) {
            interestFunds -= interest;
        }

        emit WithdrawalProcessed(user, principal, interest);
    }

    function transferPenalty(uint256 amount) external onlySavingCore nonReentrant {
        require(amount > 0, "Amount must be > 0");
        require(totalDeposits >= amount, "Insufficient deposits");

        require(token.transfer(feeReceiver, amount), "Transfer failed");
        totalDeposits -= amount;
        emit PenaltyTransferred(feeReceiver, amount);
    }

    function payRenewBonus(address user, uint256 amount) external onlySavingCore nonReentrant {
        require(user != address(0), "Invalid user address");
        require(amount > 0, "Amount must be > 0");
        require(interestFunds >= amount, "Insufficient interest funds");

        require(token.transfer(user, amount), "Transfer failed");
        interestFunds -= amount;
        emit RenewalBonusPaid(user, amount);
    }

    function getAvailableFunds() external view returns (uint256) {
        return token.balanceOf(address(this));
    }
}