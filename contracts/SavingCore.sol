// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

contract SavingCore is ERC721, AccessControl, Pausable {
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
        address owner;
        uint256 principal;
        uint256 planId;
        uint256 startTime;
        uint256 maturityAt;
        uint256 unlockTime;
        uint256 aprSnapshot;
        uint256 penaltySnapshot;
        bool active;
        bool withdrawn;
    }

    IERC20 public token;
    address public vaultManager;
    uint256 public nextPlanId = 1;
    uint256 public nextTokenId = 1;

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

    function openDeposit(uint256 planId, uint256 amount) external whenNotPaused returns (uint256 tokenId) {
        require(amount > 0, "Amount must be > 0");

        SavingsPlan memory plan = plans[planId];
        require(plan.enabled, "Plan not enabled");
        
        if (plan.minDeposit > 0) {
            require(amount >= plan.minDeposit, "Amount below minimum");
        }
        if (plan.maxDeposit > 0) {
            require(amount <= plan.maxDeposit, "Amount exceeds maximum");
        }

        require(token.transferFrom(msg.sender, vaultManager, amount), "Transfer to vault failed");

        tokenId = nextTokenId++;
        uint256 maturityAt = block.timestamp + plan.tenorDays * 86400;

        positions[tokenId] = DepositPosition({
            owner: msg.sender,
            principal: amount,
            planId: planId,
            startTime: block.timestamp,
            maturityAt: maturityAt,
            unlockTime: maturityAt,
            aprSnapshot: plan.aprBps,
            penaltySnapshot: plan.earlyWithdrawPenaltyBps,
            active: true,
            withdrawn: false
        });

        _mint(msg.sender, tokenId);

        emit DepositOpened(msg.sender, tokenId, amount, planId, maturityAt);
    }

    function withdrawAtMaturity(uint256 tokenId) external whenNotPaused {
        DepositPosition storage position = positions[tokenId];
        
        require(position.owner == msg.sender, "Not owner");
        require(position.active, "Position not active");
        require(!position.withdrawn, "Already withdrawn");
        require(block.timestamp >= position.maturityAt, "Not yet matured");

        position.active = false;
        position.withdrawn = true;

        uint256 interest = calculateInterest(position.principal, position.aprSnapshot, position.maturityAt - position.startTime);
        uint256 totalAmount = position.principal + interest;

        IVaultManager(vaultManager).withdrawToUser(msg.sender, position.principal, interest);

        _burn(tokenId);
        emit WithdrawAtMaturity(msg.sender, tokenId, position.principal, interest);
    }

    function earlyWithdraw(uint256 tokenId) external whenNotPaused {
        DepositPosition storage position = positions[tokenId];
        
        require(position.owner == msg.sender, "Not owner");
        require(position.active, "Position not active");
        require(!position.withdrawn, "Already withdrawn");
        require(block.timestamp < position.maturityAt, "Use withdrawAtMaturity");

        position.active = false;
        position.withdrawn = true;

        uint256 penalty = (position.principal * position.penaltySnapshot) / BPS_DIVISOR;
        uint256 userReceives = position.principal - penalty;

        IVaultManager(vaultManager).transferPenalty(penalty);
        IVaultManager(vaultManager).withdrawToUser(msg.sender, userReceives, 0);

        _burn(tokenId);
        emit EarlyWithdraw(msg.sender, tokenId, userReceives, penalty);
    }

    function transferFrom(address from, address to, uint256 tokenId) public override whenNotPaused {
        require(from != address(0) && to != address(0), "Invalid address");
        
        DepositPosition storage position = positions[tokenId];
        require(position.active, "Position not active");

        uint256 transferFee = (position.principal * TRANSFER_FEE_BPS) / BPS_DIVISOR;
        uint256 newPrincipal = position.principal - transferFee;

        position.owner = to;
        position.principal = newPrincipal;

        IVaultManager(vaultManager).transferPenalty(transferFee);

        super.transferFrom(from, to, tokenId);
    }

    function calculateInterest(uint256 principal, uint256 aprBps, uint256 tenorSeconds) public pure returns (uint256) {
        return (principal * aprBps * tenorSeconds) / (SECONDS_PER_YEAR * BPS_DIVISOR);
    }

    function getPosition(uint256 tokenId) external view returns (DepositPosition memory) {
        return positions[tokenId];
    }

    function getPlan(uint256 planId) external view returns (SavingsPlan memory) {
        return plans[planId];
    }

    function getNextPlanId() external view returns (uint256) {
        return nextPlanId;
    }
}

interface IVaultManager {
    function setFeeReceiver(address _feeReceiver) external;
    function withdrawToUser(address user, uint256 principal, uint256 interest) external;
    function transferPenalty(uint256 amount) external;
}