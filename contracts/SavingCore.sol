// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract SavingCore is ERC721, AccessControl, Pausable, ReentrancyGuard {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
    uint256 private constant SECONDS_PER_YEAR = 365 days;
    uint256 private constant BPS_DIVISOR = 10000;
    uint256 private constant TRANSFER_FEE_BPS = 500; // 5%

    struct SavingsPlan {
        uint256 tenorDays;
        uint256 aprBps;
        uint256 minDeposit;
        uint256 maxDeposit;
        uint256 earlyWithdrawPenaltyBps;
        bool enabled;
    }

    struct DepositPosition {
        uint256 principal;
        uint256 planId;
        uint256 startTime;
        uint256 maturityAt;
        uint256 aprSnapshot;
        uint256 aprFloor;
        uint256 penaltySnapshot;
        uint256 renewCount;
        bool active;
    }

    IERC20 public token;
    address public vaultManager;
    uint256 public nextPlanId = 1;
    uint256 public nextTokenId = 1;
    bool public autoRenewEnabled = true;

    mapping(uint256 => SavingsPlan) public plans;
    mapping(uint256 => DepositPosition) public positions;

    event PlanCreated(uint256 indexed planId, uint256 tenorDays, uint256 aprBps, uint256 minDeposit, uint256 maxDeposit, uint256 penaltyBps);
    event PlanUpdated(uint256 indexed planId, uint256 newAprBps);
    event PlanEnabled(uint256 indexed planId);
    event PlanDisabled(uint256 indexed planId);
    event FeeReceiverUpdated(address indexed newFeeReceiver);
    event DepositOpened(address indexed user, uint256 indexed tokenId, uint256 amount, uint256 planId, uint256 maturityAt);
    event WithdrawAtMaturity(address indexed user, uint256 indexed tokenId, uint256 principal, uint256 interest);
    event EarlyWithdraw(address indexed user, uint256 indexed tokenId, uint256 principal, uint256 penalty);
    event AutoRenewed(address indexed user, uint256 indexed tokenId, uint256 newApr, uint256 newMaturityAt, uint256 renewCount);
    event ManualRenewed(address indexed user, uint256 indexed tokenId, uint256 newPlanId, uint256 newApr, uint256 newMaturityAt, uint256 bonus);

    constructor(address _token, address _vaultManager) ERC721("SavingCertificate", "SAVC") {
        require(_token != address(0), "Invalid token address");
        require(_vaultManager != address(0), "Invalid vaultManager address");

        token = IERC20(_token);
        vaultManager = _vaultManager;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    function createPlan(
        uint256 tenorDays,
        uint256 aprBps,
        uint256 minDeposit,
        uint256 maxDeposit,
        uint256 earlyWithdrawPenaltyBps
    ) external onlyRole(ADMIN_ROLE) {
        require(tenorDays > 0, "Tenor must be > 0");
        require(aprBps > 0, "APR must be > 0");
        require(minDeposit <= maxDeposit || maxDeposit == 0, "Invalid min/max deposit");

        uint256 planId = nextPlanId++;
        plans[planId] = SavingsPlan({
            tenorDays: tenorDays,
            aprBps: aprBps,
            minDeposit: minDeposit,
            maxDeposit: maxDeposit,
            earlyWithdrawPenaltyBps: earlyWithdrawPenaltyBps,
            enabled: true
        });

        emit PlanCreated(planId, tenorDays, aprBps, minDeposit, maxDeposit, earlyWithdrawPenaltyBps);
    }

    function updatePlan(uint256 planId, uint256 newAprBps) external onlyRole(ADMIN_ROLE) {
        require(planId < nextPlanId, "Plan does not exist");
        require(newAprBps > 0, "APR must be > 0");

        plans[planId].aprBps = newAprBps;
        emit PlanUpdated(planId, newAprBps);
    }

    function enablePlan(uint256 planId) external onlyRole(ADMIN_ROLE) {
        require(planId < nextPlanId, "Plan does not exist");
        require(!plans[planId].enabled, "Plan already enabled");

        plans[planId].enabled = true;
        emit PlanEnabled(planId);
    }

    function disablePlan(uint256 planId) external onlyRole(ADMIN_ROLE) {
        require(planId < nextPlanId, "Plan does not exist");
        require(plans[planId].enabled, "Plan already disabled");

        plans[planId].enabled = false;
        emit PlanDisabled(planId);
    }

    function setFeeReceiver(address _feeReceiver) external onlyRole(ADMIN_ROLE) {
        require(_feeReceiver != address(0), "Invalid feeReceiver address");
        IVaultManager(vaultManager).setFeeReceiver(_feeReceiver);
        emit FeeReceiverUpdated(_feeReceiver);
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function setVaultManager(address _vaultManager) external onlyRole(ADMIN_ROLE) {
        require(_vaultManager != address(0), "Invalid vaultManager address");
        vaultManager = _vaultManager;
    }

    function setAutoRenew(bool enabled) external onlyRole(ADMIN_ROLE) {
        autoRenewEnabled = enabled;
    }

    function openDeposit(uint256 planId, uint256 amount) external whenNotPaused nonReentrant returns (uint256 tokenId) {
        require(amount > 0, "Amount must be > 0");
        require(planId > 0 && planId < nextPlanId, "Plan does not exist");

        SavingsPlan memory plan = plans[planId];
        require(plan.enabled, "Plan not enabled");
        
        if (plan.minDeposit > 0) {
            require(amount >= plan.minDeposit, "Amount below minimum");
        }
        if (plan.maxDeposit > 0) {
            require(amount <= plan.maxDeposit, "Amount exceeds maximum");
        }

        require(token.transferFrom(msg.sender, vaultManager, amount), "Transfer to vault failed");
        IVaultManager(vaultManager).receiveDeposit(amount);

        tokenId = nextTokenId++;
        uint256 maturityAt = block.timestamp + plan.tenorDays * 86400;
        uint256 aprFloor = plan.aprBps * 50 / 10000;

        positions[tokenId] = DepositPosition({
            principal: amount,
            planId: planId,
            startTime: block.timestamp,
            maturityAt: maturityAt,
            aprSnapshot: plan.aprBps,
            aprFloor: aprFloor,
            penaltySnapshot: plan.earlyWithdrawPenaltyBps,
            renewCount: 0,
            active: true
        });

        _mint(msg.sender, tokenId);

        emit DepositOpened(msg.sender, tokenId, amount, planId, maturityAt);
    }

    function withdrawAtMaturity(uint256 tokenId) external whenNotPaused nonReentrant {
        DepositPosition storage position = positions[tokenId];
        
        require(ownerOf(tokenId) == msg.sender, "Not owner");
        require(position.active, "Position not active");
        require(block.timestamp >= position.maturityAt, "Not yet matured");

        position.active = false;

        uint256 interest = calculateInterest(position.principal, position.aprSnapshot, position.maturityAt - position.startTime);

        IVaultManager(vaultManager).withdrawToUser(msg.sender, position.principal, interest);

        _burn(tokenId);
        emit WithdrawAtMaturity(msg.sender, tokenId, position.principal, interest);
    }

    function earlyWithdraw(uint256 tokenId) external whenNotPaused nonReentrant {
        DepositPosition storage position = positions[tokenId];
        
        require(ownerOf(tokenId) == msg.sender, "Not owner");
        require(position.active, "Position not active");
        require(block.timestamp < position.maturityAt, "Use withdrawAtMaturity");

        position.active = false;

        uint256 penalty = (position.principal * position.penaltySnapshot) / BPS_DIVISOR;
        uint256 userReceives = position.principal - penalty;

        IVaultManager(vaultManager).transferPenalty(penalty);
        IVaultManager(vaultManager).withdrawToUser(msg.sender, userReceives, 0);

        _burn(tokenId);
        emit EarlyWithdraw(msg.sender, tokenId, userReceives, penalty);
    }

    function autoRenew(uint256 tokenId) external whenNotPaused {
        require(autoRenewEnabled, "Auto renew disabled");
        
        DepositPosition storage position = positions[tokenId];
        require(position.active, "Position not active");
        require(block.timestamp >= position.maturityAt + 3 days, "Too early to auto renew");

        uint256 newApr = position.aprSnapshot * 90 / 100;
        if (newApr < position.aprFloor) {
            newApr = position.aprFloor;
        }
        position.aprSnapshot = newApr;
        position.maturityAt = block.timestamp + plans[position.planId].tenorDays * 86400;
        position.startTime = block.timestamp;
        position.renewCount += 1;

        emit AutoRenewed(ownerOf(tokenId), tokenId, newApr, position.maturityAt, position.renewCount);
    }

    function manualRenew(uint256 tokenId, uint256 newPlanId) external whenNotPaused nonReentrant {
        DepositPosition storage position = positions[tokenId];
        
        require(ownerOf(tokenId) == msg.sender, "Not owner");
        require(position.active, "Position not active");
        require(block.timestamp >= position.maturityAt, "Not yet matured");
        require(newPlanId > 0 && newPlanId < nextPlanId, "Plan does not exist");
        require(plans[newPlanId].enabled, "Plan not enabled");

        uint256 bonus = position.principal * 50 / 10000;
        IVaultManager(vaultManager).payRenewBonus(msg.sender, bonus);

        SavingsPlan memory newPlan = plans[newPlanId];
        uint256 newAprFloor = newPlan.aprBps * 50 / 10000;

        position.aprSnapshot = newPlan.aprBps;
        position.maturityAt = block.timestamp + newPlan.tenorDays * 86400;
        position.startTime = block.timestamp;
        position.planId = newPlanId;
        position.penaltySnapshot = newPlan.earlyWithdrawPenaltyBps;
        position.aprFloor = newAprFloor;
        position.renewCount = 0;

        emit ManualRenewed(msg.sender, tokenId, newPlanId, newPlan.aprBps, position.maturityAt, bonus);
    }

function transferFrom(address from, address to, uint256 tokenId) public override whenNotPaused nonReentrant {
        require(to != address(0), "Invalid address");
        require(_ownerOf(tokenId) != address(0), "Token does not exist");
        
        DepositPosition storage position = positions[tokenId];
        require(ownerOf(tokenId) == msg.sender, "Not owner");
        require(position.active, "Position not active");

        uint256 transferFee = (position.principal * TRANSFER_FEE_BPS) / BPS_DIVISOR;
        uint256 newPrincipal = position.principal - transferFee;

        position.principal = newPrincipal;

        IVaultManager(vaultManager).transferPenalty(transferFee);

        super.transferFrom(from, to, tokenId);
    }
    // Interest = Principal * (APR / 100) * (Tenor in years)
    function calculateInterest(uint256 principal, uint256 aprBps, uint256 tenorSeconds) public pure returns (uint256) {
        return (principal * aprBps * tenorSeconds) / (SECONDS_PER_YEAR * BPS_DIVISOR);
    }
    // View functions for frontend
    function getPosition(uint256 tokenId) external view returns (DepositPosition memory) {
        return positions[tokenId];
    }
    // View function to get plan details
    function getPlan(uint256 planId) external view returns (SavingsPlan memory) {
        return plans[planId];
    }
    // View function to get next token ID (for frontend tracking)
    function getNextPlanId() external view returns (uint256) {
        return nextPlanId;
    }
}

interface IVaultManager {
    function receiveDeposit(uint256 amount) external;
    function setFeeReceiver(address _feeReceiver) external;
    function withdrawToUser(address user, uint256 principal, uint256 interest) external;
    function transferPenalty(uint256 amount) external;
    function payRenewBonus(address user, uint256 amount) external;
}