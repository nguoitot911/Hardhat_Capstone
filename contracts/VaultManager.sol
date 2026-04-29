// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/types/Time.sol";

/**
 * @title VaultManager
 * @dev Manages interest funds and calculates compounded interest using reserve index pattern
 * Inspired by Aave Protocol's interest rate calculations
 */
contract VaultManager is AccessControl, ReentrancyGuard {
    using Math for uint256;
    using SafeCast for uint256;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant SAVING_CORE_ROLE = keccak256("SAVING_CORE_ROLE");

    IERC20 public immutable token;

    // RAY = 1e27 for fixed-point arithmetic
    uint256 public constant RAY = 1e27;
    uint256 private constant SECONDS_PER_YEAR = 365 days;

    // Reserve index for interest accumulation
    uint256 public reserveIndex = RAY;
    uint48 public lastUpdateTime;

    // Interest rate in RAY (e.g., 5% APY = 0.05 * RAY)
    uint256 public interestRate;

    // Total interest funds available
    uint256 public totalInterestFunds;

    // Total deposits (principal)
    uint256 public totalDeposits;

    event InterestRateUpdated(uint256 oldRate, uint256 newRate);
    event FundsDeposited(address indexed depositor, uint256 amount);
    event FundsWithdrawn(address indexed withdrawer, uint256 amount);
    event DepositReceived(address indexed user, uint256 amount);
    event WithdrawalProcessed(address indexed user, uint256 principal, uint256 interest);

    constructor(address _token, uint256 _initialInterestRate) {
        require(_token != address(0), "Invalid token");
        token = IERC20(_token);
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        interestRate = _initialInterestRate;
        lastUpdateTime = Time.timestamp();
    }

    function updateReserveIndex() public {
        uint48 currentTime = uint48(Time.timestamp());
        if (currentTime <= lastUpdateTime) return;

        uint256 compoundedInterest = calculateCompoundedInterest(
            interestRate,
            lastUpdateTime,
            currentTime
        );

        reserveIndex = (reserveIndex * compoundedInterest) / RAY;
        lastUpdateTime = currentTime;
    }

    function calculateCompoundedInterest(
        uint256 rate,
        uint48 lastTime,
        uint48 currentTime
    ) public pure returns (uint256) {
        uint256 exp = uint256(currentTime - lastTime);

        if (exp == 0) return RAY;

        uint256 expMinusOne = exp - 1;
        uint256 expMinusTwo = exp > 2 ? exp - 2 : 0;

        uint256 ratePerSecond = rate / SECONDS_PER_YEAR;

        uint256 firstTerm = ratePerSecond * exp;

        uint256 secondTerm = 0;
        if (expMinusOne > 0) {
            uint256 basePowerTwo = ratePerSecond.mulDiv(ratePerSecond, RAY);
            secondTerm = exp.mulDiv(expMinusOne, 2).mulDiv(basePowerTwo, RAY);
        }

        uint256 thirdTerm = 0;
        if (expMinusTwo > 0) {
            uint256 basePowerThree = ratePerSecond.mulDiv(
                ratePerSecond.mulDiv(ratePerSecond, RAY),
                RAY
            );
            thirdTerm = exp.mulDiv(expMinusOne, 1).mulDiv(expMinusTwo, 6).mulDiv(basePowerThree, RAY);
        }

        return RAY + firstTerm + secondTerm + thirdTerm;
    }

/**
     * @dev Receive deposit notification from SavingCore (tokens already transferred)
     */
    function receiveDeposit(uint256 amount) external nonReentrant {
        totalDeposits += amount;
        emit DepositReceived(msg.sender, amount);
    }

    /**
     * @dev Withdraw funds (principal + interest) to user
     */
    function withdrawToUser(address user, uint256 principal, uint256 interest) 
        external 
        onlyRole(SAVING_CORE_ROLE) 
        nonReentrant 
    {
        require(totalDeposits >= principal, "Insufficient deposits");
        
        uint256 totalAmount = principal + interest;
        require(totalInterestFunds >= interest, "Insufficient interest funds");
        require(token.balanceOf(address(this)) >= totalAmount, "Insufficient token balance");

        totalDeposits -= principal;
        totalInterestFunds -= interest;

        require(token.transfer(user, totalAmount), "Transfer failed");
        emit WithdrawalProcessed(user, principal, interest);
    }

    function depositFunds(uint256 amount) external onlyRole(ADMIN_ROLE) {
        require(token.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        totalInterestFunds += amount;
        emit FundsDeposited(msg.sender, amount);
    }

    function withdrawFunds(uint256 amount) external onlyRole(ADMIN_ROLE) {
        require(amount <= totalInterestFunds, "Insufficient funds");
        totalInterestFunds -= amount;
        require(token.transfer(msg.sender, amount), "Transfer failed");
        emit FundsWithdrawn(msg.sender, amount);
    }

    function setInterestRate(uint256 newRate) external onlyRole(ADMIN_ROLE) {
        updateReserveIndex();
        uint256 oldRate = interestRate;
        interestRate = newRate;
        emit InterestRateUpdated(oldRate, newRate);
    }

    function getBalanceWithInterest(uint256 scaledAmount) external view returns (uint256) {
        uint48 currentTime = uint48(Time.timestamp());
        uint256 currentIndex = reserveIndex;
        
        if (currentTime > lastUpdateTime) {
            uint256 compoundedInterest = calculateCompoundedInterest(
                interestRate,
                lastUpdateTime,
                currentTime
            );
            currentIndex = (reserveIndex * compoundedInterest) / RAY;
        }
        
        return scaledAmount.mulDiv(currentIndex, RAY);
    }

    function grantSavingCoreRole(address savingCore) external onlyRole(ADMIN_ROLE) {
        _grantRole(SAVING_CORE_ROLE, savingCore);
    }
}