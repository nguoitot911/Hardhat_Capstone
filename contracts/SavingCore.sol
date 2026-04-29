// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/types/Time.sol";
import "./interfaces/IVaultManager.sol";

/**
 * @title SavingCore
 * @dev Core contract for time-locked savings with NFT certificates
 */
contract SavingCore is ERC721, ERC721URIStorage, AccessControl, ReentrancyGuard, Pausable {
    using SafeCast for uint256;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    IVaultManager public vaultManager;
    IERC20 public token; // MockUSDC

    uint256 public nextTokenId = 1;
    uint256 public constant MIN_LOCK_DURATION = 30 days; // Minimum 30 days

    struct DepositPosition {
        address depositor;
        uint256 principal;
        uint256 scaledPrincipal; // For interest calculation
        uint48 startTime;
        uint48 unlockTime;
        uint256 interestRate; // Snapshot at deposit time
        bool withdrawn;
    }

    mapping(uint256 => DepositPosition) public positions;

    // Interest packages (duration => rate in RAY)
    mapping(uint256 => uint256) public interestPackages;

    event Deposited(
        address indexed depositor,
        uint256 tokenId,
        uint256 amount,
        uint256 lockDuration,
        uint256 interestRate
    );

    event Withdrawn(
        address indexed depositor,
        uint256 tokenId,
        uint256 principal,
        uint256 interest
    );

    event PackageCreated(uint256 duration, uint256 interestRate);

    constructor(
        address _vaultManager,
        address _token
    ) ERC721("Savings Certificate", "SAVING") {
        vaultManager = IVaultManager(_vaultManager);
        token = IERC20(_token);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    /**
     * @dev Create interest package (admin only)
     */
    function createPackage(uint256 duration, uint256 interestRate) external onlyRole(ADMIN_ROLE) {
        require(duration >= MIN_LOCK_DURATION, "Duration too short");
        interestPackages[duration] = interestRate;
        emit PackageCreated(duration, interestRate);
    }

    /**
     * @dev Deposit tokens and mint NFT certificate
     */
    function deposit(uint256 amount, uint256 lockDuration)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 tokenId)
    {
        require(amount > 0, "Amount must be > 0");
        require(interestPackages[lockDuration] > 0, "Invalid package");

        require(token.transferFrom(msg.sender, address(vaultManager), amount), "Transfer to vault failed");

        vaultManager.receiveDeposit(amount);

        vaultManager.updateReserveIndex();
        uint256 currentIndex = vaultManager.reserveIndex();
        uint256 scaledPrincipal = amount * vaultManager.RAY() / currentIndex;

        tokenId = nextTokenId++;
        positions[tokenId] = DepositPosition({
            depositor: msg.sender,
            principal: amount,
            scaledPrincipal: scaledPrincipal,
            startTime: Time.timestamp(),
            unlockTime: uint48(Time.timestamp() + lockDuration),
            interestRate: interestPackages[lockDuration],
            withdrawn: false
        });

        _mint(msg.sender, tokenId);

        string memory metadata = generateMetadata(tokenId);
        _setTokenURI(tokenId, metadata);

        emit Deposited(msg.sender, tokenId, amount, lockDuration, interestPackages[lockDuration]);
    }

    /**
     * @dev Withdraw principal and interest after lock period
     */
    function withdraw(uint256 tokenId)
        external
        whenNotPaused
        nonReentrant
    {
        DepositPosition storage position = positions[tokenId];
        require(position.depositor == msg.sender, "Not owner");
        require(!position.withdrawn, "Already withdrawn");
        require(Time.timestamp() >= position.unlockTime, "Still locked");

        position.withdrawn = true;

        uint256 currentBalance = vaultManager.getBalanceWithInterest(position.scaledPrincipal);
        uint256 interest = currentBalance - position.principal;

        _burn(tokenId);

        vaultManager.withdrawToUser(msg.sender, position.principal, interest);

        emit Withdrawn(msg.sender, tokenId, position.principal, interest);
    }

    /**
     * @dev Early withdrawal with penalty (50% interest loss)
     */
    function earlyWithdraw(uint256 tokenId)
        external
        whenNotPaused
        nonReentrant
    {
        DepositPosition storage position = positions[tokenId];
        require(position.depositor == msg.sender, "Not owner");
        require(!position.withdrawn, "Already withdrawn");
        require(Time.timestamp() < position.unlockTime, "Use regular withdraw");

        position.withdrawn = true;

        uint256 currentBalance = vaultManager.getBalanceWithInterest(position.scaledPrincipal);
        uint256 fullInterest = currentBalance - position.principal;
        uint256 penaltyInterest = fullInterest / 2;

        _burn(tokenId);

        vaultManager.withdrawToUser(msg.sender, position.principal, penaltyInterest);

        emit Withdrawn(msg.sender, tokenId, position.principal, penaltyInterest);
    }

    /**
     * @dev Generate metadata URI for NFT
     */
    function generateMetadata(uint256 tokenId) internal view returns (string memory) {
        DepositPosition memory position = positions[tokenId];
        // Simple JSON metadata (in production, use IPFS or similar)
        return string(abi.encodePacked(
            '{"name": "Savings Certificate #',
            Strings.toString(tokenId),
            '", "description": "Time-locked savings certificate", "attributes": [',
            '{"trait_type": "Principal", "value": "',
            Strings.toString(position.principal),
            '"}, {"trait_type": "Lock Duration", "value": "',
            Strings.toString(position.unlockTime - position.startTime),
            '"}]}'
        ));
    }

    /**
     * @dev Get position details
     */
    function getPosition(uint256 tokenId) external view returns (DepositPosition memory) {
        return positions[tokenId];
    }

    /**
     * @dev Get current balance with interest for a position
     */
    function getCurrentBalance(uint256 tokenId) external returns (uint256) {
        DepositPosition memory position = positions[tokenId];
        return vaultManager.getBalanceWithInterest(position.scaledPrincipal);
    }

    /**
     * @dev Pause/unpause contract (admin only)
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // ERC721 overrides
    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721URIStorage, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    }