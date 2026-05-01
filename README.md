# Saving System - DeFi Savings with NFT Certificates

## 1. TỔNG QUAN

Hệ thống gồm 2 contract chính:
- **VaultManager** - Quản lý thanh khoản (tiền gốc + quỹ lãi)
- **SavingCore** - Xử lý deposit/withdraw và NFT certificate

---

## 2. VAULTMANAGER

### State:
```solidity
token              → IERC20 (USDC)
feeReceiver        → address (nhận phí phạt)
savingCore         → address (địa chỉ SavingCore - đã có từ đầu)
totalDeposits      → uint256 (tổng tiền gốc trong vault)
interestFunds     → uint256 (quỹ lãi suất)
```

### Functions:

| Hàm | Người gọi | Mô tả |
|-----|-----------|-------|
| `setFeeReceiver(address)` | Admin | Cập nhật địa chỉ nhận phí phạt |
| `setSavingCore(address)` | Admin | Cập nhật địa chỉ SavingCore (đã có từ đầu) |
| `depositFunds(amount)` | Admin | Nạp tiền vào quỹ lãi |
| `withdrawFunds(amount)` | Admin | Rút tiền từ quỹ lãi |
| `receiveDeposit(amount)` | SavingCore | Nhận tiền gốc từ user |
| `withdrawToUser(user, principal, interest)` | SavingCore | Trả gốc + lãi cho user |
| `transferPenalty(amount)` | SavingCore | Chuyển phí phạt cho feeReceiver |
| `payRenewBonus(user, amount)` | SavingCore | Trả bonus cho manual renew (MỚI) |

---

## 3. SAVINGCORE

### State:
```solidity
token              → IERC20 (USDC)
vaultManager       → address (địa chỉ VaultManager)
nextPlanId         → uint256 (ID gói tiết kiệm tiếp theo)
nextTokenId        → uint256 (ID NFT tiếp theo)
autoRenewEnabled   → bool (bật/tắt auto renew)

plans[planId]      → SavingsPlan
positions[tokenId] → DepositPosition
```

### Struct SavingsPlan:
```solidity
struct SavingsPlan {
    uint256 tenorDays;                 // Kỳ hạn (ngày)
    uint256 aprBps;                    // Lãi suất năm (bps)
    uint256 minDeposit;                // Tiền tối thiểu
    uint256 maxDeposit;                // Tiền tối đa (0 = unlimited)
    uint256 earlyWithdrawPenaltyBps; // Phí phạt rút sớm (bps)
    bool enabled;                     // Đang hoạt động
}
```

### Struct DepositPosition:
```solidity
struct DepositPosition {
    address owner;          // Chủ sở hữu NFT
    uint256 principal;      // Tiền gốc
    uint256 planId;        // ID gói đã chọn
    uint256 startTime;      // Thời điểm bắt đầu kỳ hiện tại
    uint256 maturityAt;     // Thời điểm đáo hạn của kỳ hiện tại
    uint256 aprSnapshot;   // Lãi suất đã snapshot (bps)
    uint256 aprFloor;      // Sàn lãi suất (50% APR gốc, bảo vệ sau auto-renew)
    uint256 penaltySnapshot; // Phí phạt đã snapshot tại thời điểm gửi
    uint256 renewCount;    // Số lần auto-renew đã thực hiện
    bool active;          // Đang hoạt động (chưa rút)
}
```

---

## 4. CHỨC NĂNG ADMIN

### Quản lý Plans:

| Hàm | Mô tả |
|-----|-------|
| `createPlan(tenorDays, aprBps, minDeposit, maxDeposit, penaltyBps)` | Tạo gói tiết kiệm mới |
| `updatePlan(planId, newAprBps)` | Cập nhật APR (chỉ ảnh hưởng deposit mới) |
| `enablePlan(planId)` | Bật gói tiết kiệm |
| `disablePlan(planId)` | Tắt gói tiết kiệm |

### Quản lý khác:

| Hàm | Mô tả |
|-----|-------|
| `setFeeReceiver(address)` | Cập nhật địa chỉ nhận phí phạt |
| `setAutoRenew(bool enabled)` | Bật/tắt tính năng auto renew |
| `pause()` | Dừng hệ thống (block withdraw) |
| `unpause()` | Mở lại hệ thống |

---

## 5. CHỨC NĂNG USER

### openDeposit(planId, amount):
```
1. Kiểm tra plan tồn tại & enabled
2. Kiểm tra amount trong hạn mức (min/max)
3. Transfer USDC từ user → VaultManager
4. Snapshot APR và penalty vào position
5. Tính aprFloor = aprBps * 50 / 10000 (50% APR gốc)
6. Set renewCount = 0
7. Tính maturityAt = now + tenorDays * 86400
8. Mint NFT (tokenId) cho user
9. Emit event DepositOpened
```

### withdrawAtMaturity(tokenId):
```
1. Kiểm tra: owner, active, đã matured
2. Tính interest = (principal * apr * tenorSeconds) / (365 days * 10000)
3. Gọi VaultManager.withdrawToUser(principal + interest)
4. Burn NFT
5. Emit event WithdrawAtMaturity
```

### earlyWithdraw(tokenId):
```
1. Kiểm tra: owner, active, chưa matured
2. Tính penalty = (principal * penaltyBps) / 10000
3. userReceives = principal - penalty
4. Gọi VaultManager.transferPenalty(penalty)
5. Gọi VaultManager.withdrawToUser(userReceives, 0)
6. Burn NFT
7. Emit event EarlyWithdraw
```

### transferFrom(to, tokenId):
```
1. Kiểm tra: active position, owner = msg.sender
2. Tính phí = (principal * 5%) / 10000
3. newPrincipal = principal - phí
4. Gọi VaultManager.transferPenalty(phí)
5. Update position: owner = to, principal = newPrincipal
6. ERC721 transfer bình thường
```

### autoRenew(tokenId):
```
1. Kiểm tra: autoRenewEnabled == true
2. Kiểm tra: position.active == true
3. Kiểm tra: block.timestamp >= maturityAt + 3 days (grace period)
4. Tính newApr = aprSnapshot * 90 / 100 (giảm 10%)
5. Nếu newApr < aprFloor → newApr = aprFloor (sàn)
6. Cập nhật aprSnapshot = newApr
7. Cập nhật maturityAt += tenorDays * 86400 (tính từ maturityAt cũ)
8. Cập nhật startTime = block.timestamp
9. Tăng renewCount += 1
10. Emit event AutoRenewed
```

### manualRenew(tokenId, newPlanId):
```
1. Kiểm tra: position.owner == msg.sender
2. Kiểm tra: position.active == true
3. Kiểm tra: block.timestamp >= maturityAt (đã đáo hạn)
4. Kiểm tra: plans[newPlanId].enabled == true
5. Tính bonus = principal * 50 / 10000 (0.5% principal)
6. Gọi VaultManager.payRenewBonus(user, bonus)
7. Lấy newPlan từ plans[newPlanId]
8. Cập nhật: aprSnapshot, maturityAt, startTime, planId
9. Reset aprFloor = newPlan.aprBps * 50 / 10000
10. Reset renewCount = 0
11. Emit event ManualRenewed
```

---

## 6. CÁC HẰNG SỐ

```solidity
SECONDS_PER_YEAR = 365 days = 31,536,000 giây
BPS_DIVISOR = 10,000 (chuyển bps → decimal)
TRANSFER_FEE_BPS = 500 (5% phí chuyển NFT)
```

### Công thức tính lãi:
```
interest = (principal * aprBps * tenorSeconds) / (365 * 86400 * 10000)

Ví dụ: 1000 USDC, 90 ngày, 250 bps (2.5%)
tenorSeconds = 90 * 86400 = 7,776,000
interest = (1000000000 * 250 * 7776000) / (31536000000)
          ≈ 6,164,383 ≈ 6.16 USDC
```

### Công thức phí phạt rút sớm:
```
penalty = (principal * penaltyBps) / 10000

Ví dụ: 1000 USDC, 500 bps (5%)
penalty = 50 USDC
user nhận = 1000 - 50 = 950 USDC
```

### Auto Renew:
```
newApr = aprSnapshot * 90 / 100 (giảm 10% mỗi kỳ)
aprFloor = aprBps * 50 / 10000 (sàn 50% APR gốc)
```

### Manual Renew Bonus:
```
bonus = principal * 50 / 10000 (0.5% tiền gốc)
```

---

## 7. DEPLOYMENT

### Ignition Module
File: `ignition/modules/SavingsSystem.js`

Sử dụng Hardhat Ignition để deploy contracts một cách deterministic và có thể reproducible.

```javascript
import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("SavingsSystem", (m) => {
  const deployer = m.getAccount(0);
  const feeReceiver = m.getParameter("feeReceiver", deployer);
  const initialFunds = m.getParameter("initialFunds", 1000000000n);

  // 1. Deploy MockUSDC (ERC20 token cho testing)
  const mockUSDC = m.contract("MockUSDC");

  // 2. Deploy SavingCore trước (vaultManager set tạm = address(0))
  const savingCore = m.contract("SavingCore", [mockUSDC, "0x0000000000000000000000000000000000000001"]);

  // 3. Deploy VaultManager với savingCore address thực
  const vaultManager = m.contract("VaultManager", [mockUSDC, feeReceiver, savingCore]);

  // 4. Mint initial USDC cho deployer (dùng trong testing)
  m.call(mockUSDC, "mint", [deployer, initialFunds], { id: "mintInitialFunds" });

  // 5. Set vaultManager address chính xác cho SavingCore
  m.call(savingCore, "setVaultManager", [vaultManager], { id: "setVaultManager" });

  // 6. Export contracts
  return { mockUSDC, vaultManager, savingCore };
});
```

### Các tham số có thể tùy chỉnh

| Parameter | Type | Default | Mô tả |
|-----------|------|---------|-------|
| `feeReceiver` | address | deployer | Địa chỉ nhận phí phạt |
| `initialFunds` | uint256 | 1,000,000,000 (1B) | Số USDC mint cho deployer |

### Deploy

```bash
# Deploy to local node
npx hardhat ignition deploy ignition/modules/SavingsSystem.js --network localhost

# Deploy với custom deployment ID
npx hardhat ignition deploy ignition/modules/SavingsSystem.js --network localhost --deploymentId my-deployment

# Deploy với custom parameters (nếu hardhat.config.js có cấu hình)
npx hardhat ignition deploy ignition/modules/SavingsSystem.js --network sepolia
```

### Deployment Flow

```
1. Batch 1: Deploy MockUSDC
   └─ Tạo token ERC20 với 6 decimals

2. Batch 2: 
   ├─ Mint initial USDC cho deployer (1B USDC)
   └─ Deploy SavingCore (vaultManager tạm = address(0))

3. Batch 3: Deploy VaultManager
   └─ Kết nối với SavingCore đã deploy

4. Batch 4: Set vaultManager
   └─ Cập nhật vaultManager address trong SavingCore
```

### Sau khi deploy (addresses sẽ khác nhau mỗi lần deploy)

```
MockUSDC     → 0x1291Be112d480055DaFd8a610b7d1e203891C274
SavingCore   → 0x5f3f1dBD7B74C6B46e8c44f98792A1dAf8d69154
VaultManager → 0xCD8a1C3ba11CF5ECfa6267617243239504a98d90
```

### Redeploy

```bash
# Deploy lại (giữ nguyên addresses nếu không có thay đổi)
npx hardhat ignition deploy ignition/modules/SavingsSystem.js --network localhost

# Deploy lại với reset (xóa cache cũ)
npx hardhat ignition deploy ignition/modules/SavingsSystem.js --network localhost --reset
```

### Kiểm tra deployment status

```bash
# Xem các deployment hiện có
npx hardhat ignition status

# Xem chi tiết deployment
npx hardhat ignition status SavingsSystem
```

### Lưu ý quan trọng

1. **Thứ tự deploy**: SavingCore phải deploy trước VaultManager vì VaultManager cần SavingCore address
2. **setVaultManager**: Phải gọi sau khi VaultManager deployed để link 2 contracts
3. **Initial Funds**: Chỉ dùng cho testing, mainnet cần thay thế bằng real USDC
4. **Fee Receiver**: Mặc định là deployer, có thể thay đổi sau khi deploy

---

## 8. FLOW HOẠT ĐỘNG

```
1. Admin tạo Plan (createPlan)
2. Admin nạp quỹ lãi (VaultManager.depositFunds)
3. User approve USDC cho SavingCore
4. User gọi openDeposit → nhận NFT
   ↓
5a. User đợi maturity → withdrawAtMaturity → nhận gốc + lãi
   HOẶC
5b. User rút sớm → earlyWithdraw → nhận gốc - phí phạt
   HOẶC
5c. User chuyển NFT → transferFrom → phí 5% trừ kh��i principal
   HOẶC
5d. Sau maturity + 3 ngày → bot autoRenew → APR giảm 10%, extend kỳ
   HOẶC
5e. User manualRenew đổi plan → nhận bonus 0.5%, reset renewCount
```

---

## 9. CHẠY PROJECT

```bash
# Compile
npx hardhat compile

# Deploy
npx hardhat ignition deploy ignition/modules/SavingsSystem.js

# Test
npx hardhat test
```

---

## 10. AUTO RENEW BOT

### Mô tả
Bot tự động quét tất cả NFT positions, tìm các token đã hết grace period (maturity + 3 ngày) và gọi hàm `autoRenew()` để gia hạn kỳ tiết kiệm tự động.

### Các tính năng:
- Scan tất cả NFT tokens trong hệ thống
- Kiểm tra trạng thái position (active/inactive)
- Tính toán maturityAt và grace period
- Gọi autoRenew() cho các token đã hết hạn
- Hiển thị chi tiết: owner, principal, maturity date, APR mới, renew count

### Scripts có sẵn:

| Script | Mô tả |
|--------|-------|
| `scripts/autoRenewBot.js` | Bot chính - quét và gọi autoRenew |
| `scripts/setupTestData.js` | Tạo test data mẫu (plans, deposits) |
| `scripts/advanceTime.js` | Advance blockchain time để test |
| `scripts/fixVaultManager.js` | Fix địa chỉ vaultManager |

### Cách sử dụng:

#### Bước 1: Khởi động Hardhat Node
```bash
# Terminal 1: Chạy hardhat node
npx hardhat node
```

#### Bước 2: Deploy contracts (Terminal khác)
```bash
npx hardhat ignition deploy ignition/modules/SavingsSystem.js --network localhost
```

#### Bước 3: Tạo test data
```bash
npx hardhat run scripts/setupTestData.js --network localhost
```
Script này sẽ:
- Mint USDC cho các test users
- Nạp interest funds vào vault
- Tạo các plans (2-day, 7-day, 30-day)
- Tạo deposits mẫu cho 3 users

#### Bước 4: Advance time (để test auto-renew)
```bash
# Advance 5 ngày để token 1 (2-day plan) hết grace period
npx hardhat run scripts/advanceTime.js --network localhost
```
**Lưu ý:** Script advance 5 ngày mặc định. Có thể chỉnh sửa `scripts/advanceTime.js` để thay đổi số ngày.

#### Bước 5: Chạy Auto Renew Bot
```bash
npx hardhat run scripts/autoRenewBot.js --network localhost
```

### Output mẫu của Bot:
```
=== Auto Renew Bot ===

SavingCore: 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
VaultManager: 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9
Current block timestamp: 1778086609

Total NFTs minted: 3

--- Scanning for expired positions ---

Token #1:
  Owner: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8
  Principal: 100.0 USDC
  Maturity: 1777827382 (23:56:22 3/5/2026)
  Grace period ends: 1778086582 (23:56:22 6/5/2026)
  Current time: 1778086609 (23:56:49 6/5/2026)
  ⚠️  EXPIRED - Can be auto renewed!

Token #2:
  Owner: 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
  Principal: 100.0 USDC
  Maturity: 1780246584 (23:56:24 31/5/2026)
  Grace period ends: 1780505784 (23:56:24 3/6/2026)
  Current time: 1778086609 (23:56:49 6/5/2026)
  ✓ Not yet matured

Token #3:
  Owner: 0x90F79bf6EB2c4f870365E785982E1f101E93b906
  Principal: 100.0 USDC
  Maturity: 1778259386 (23:56:26 8/5/2026)
  Grace period ends: 1778518586 (23:56:26 11/5/2026)
  Current time: 1778086609 (23:56:49 6/5/2026)
  ✓ Not yet matured


--- Auto Renew Execution ---

Auto renew enabled: true
Auto renewing token #1 for 0x70997970C51812dc3A010C7d01b50e0d17dc79C8...
✓ Success! Gas used: 76603
  New maturity: 1778259447
  New APR: 90 bps
  Renew count: 1


=== Bot Finished ===
```

### Các địa chỉ cứng (hardcoded):
Bot sử dụng các địa chỉ sau (thay đổi nếu redeploy):
```javascript
const SAVING_CORE_ADDRESS = "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512";
const VAULT_MANAGER_ADDRESS = "0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9";
const MOCK_USDC_ADDRESS = "0x5FbDB2315678afecb367f032d93F642f64180aa3";
```

### Chạy bot trong production:
Để chạy bot trong production (mainnet/testnet), cần:
1. Cập nhật địa chỉ contracts trong script
2. Thay `localhost` bằng network thực (ví dụ: `sepolia`)
3. Cấu hình private key cho bot wallet
4. Set up cron job hoặc trigger interval để chạy định kỳ

```bash
# Ví dụ chạy trên Sepolia
npx hardhat run scripts/autoRenewBot.js --network sepolia
```

---

## 11. TESTING

### Tổng quan
Dự án sử dụng Hardhat test framework với Chai assertions. Test coverage đạt **98.46%** (>90% yêu cầu).

### Các file test

| File | Mô tả | Số test cases |
|------|-------|---------------|
| `test/SavingCore.cjs` | Test contract SavingCore | ~90 |
| `test/VaultManager.cjs` | Test contract VaultManager | ~50 |

### Coverage

```
File               |  % Stmts | % Branch |  % Funcs |  % Lines
-------------------|----------|----------|----------|----------
VaultManager.sol   |   100.00 |   68.29 |   100.00 |   100.00
SavingCore.sol     |    98.86 |   88.52 |   100.00 |   98.23
MockUSDC.sol       |    66.67 |   100.00 |    66.67 |    66.67
-------------------|----------|----------|----------|----------
Overall            |    98.46 |   80.39 |    97.14 |   98.21
```

### Test Cases đã bao gồm

#### SavingCore (90+ test cases)

**Constructor**
- ✅ Deploy với token và vaultManager đúng
- ✅ Deployer có admin role
- ✅ autoRenewEnabled = true mặc định
- ✅ nextPlanId = 1, nextTokenId = 1
- ✅ Revert với địa chỉ invalid

**Plan Management**
- ✅ createPlan - tạo plan mới
- ✅ createPlan - emit event
- ✅ createPlan - increment nextPlanId
- ✅ createPlan - revert với tenor=0, apr=0, min>max
- ✅ updatePlan - cập nhật APR
- ✅ updatePlan - revert khi plan không tồn tại
- ✅ enablePlan - bật plan
- ✅ enablePlan - revert khi đã enabled
- ✅ disablePlan - tắt plan
- ✅ disablePlan - revert khi đã disabled

**Admin Functions**
- ✅ setFeeReceiver
- ✅ setVaultManager
- ✅ setAutoRenew
- ✅ pause/unpause

**User Functions - openDeposit**
- ✅ Tạo deposit thành công
- ✅ Mint NFT cho user
- ✅ Tạo position với data đúng
- ✅ emit DepositOpened event
- ✅ Revert khi paused, amount=0, plan không tồn tại
- ✅ Revert khi amount < min hoặc > max

**User Functions - withdrawAtMaturity**
- ✅ Rút tiền sau maturity
- ✅ Burn NFT
- ✅ Tính interest đúng
- ✅ Revert khi chưa matured, không phải owner, position inactive

**User Functions - earlyWithdraw**
- ✅ Rút tiền trước maturity
- ✅ Trừ penalty (5%)
- ✅ Burn NFT
- ✅ Revert khi đã matured (dùng withdrawAtMaturity)

**User Functions - autoRenew**
- ✅ Renew sau grace period (3 ngày)
- ✅ Giảm APR 10%
- ✅ Không giảm dưới aprFloor
- ✅ Extend maturity
- ✅ Tăng renewCount
- ✅ Revert khi auto-renew disabled, quá sớm, position inactive

**User Functions - manualRenew**
- ✅ Renew với plan mới
- ✅ Trả bonus 0.5%
- ✅ Reset renewCount
- ✅ Update aprFloor theo plan mới
- ✅ Revert khi chưa matured, plan không tồn tại

**User Functions - transferFrom**
- ✅ Transfer NFT thành công
- ✅ Trừ 5% phí từ principal
- ✅ Chuyển phí cho feeReceiver
- ✅ Revert khi gửi đến address(0), token không tồn tại

**View Functions**
- ✅ getPosition
- ✅ getPlan
- ✅ getNextPlanId
- ✅ nextTokenId
- ✅ supportsInterface (IERC721, IERC165)

**calculateInterest**
- ✅ Tính lãi đúng cho 30 ngày
- ✅ Tính lãi đúng cho 90 ngày
- ✅ Return 0 với principal=0, apr=0, tenure=0

---

#### VaultManager (50+ test cases)

**Constructor**
- ✅ Deploy với token, feeReceiver, savingCore đúng
- ✅ Deployer có admin role
- ✅ Revert với địa chỉ invalid

**Admin Functions**
- ✅ setSavingCore
- ✅ setFeeReceiver
- ✅ depositFunds
- ✅ withdrawFunds

**SavingCore Functions**
- ✅ receiveDeposit
- ✅ withdrawToUser (principal + interest)
- ✅ withdrawToUser (chỉ principal)
- ✅ withdrawToUser (chỉ interest)
- ✅ transferPenalty
- ✅ payRenewBonus

**Edge Cases**
- ✅ Revert khi caller không phải SavingCore
- ✅ Revert khi amount = 0
- ✅ Revert khi insufficient funds
- ✅ Revert khi user address = 0
- ✅ Reentrancy protection

### Chạy test

```bash
# Chạy tất cả test
npx hardhat test

# Chạy test với coverage
npx hardhat coverage

# Chạy test cụ thể
npx hardhat test test/SavingCore.cjs
npx hardhat test test/VaultManager.cjs
```

### Các tham số test

```javascript
BASE_UNIT = 1e6       // USDC decimals
ONE_DAY = 86400       // Seconds per day
TRANSFER_FEE_BPS = 500 // 5%
RENEW_BONUS_BPS = 50   // 0.5%
APR_FLOOR = 50%       // 50% of original APR
AUTO_RENEW_REDUCTION = 10% // APR giảm 10% mỗi kỳ
GRACE_PERIOD = 3 days // Sau maturity + 3 ngày
```

### Lưu ý khi viết test

1. **MockUSDC**: Dùng cho test, có 6 decimals
2. **beforeEach**: Mỗi test case deploy contract mới
3. **EVM Time**: Dùng `evm_increaseTime` để test time-dependent functions
4. **Revert Messages**: OpenZeppelin v5+ dùng custom errors, test cần handle đúng

### Test Patterns

```javascript
// Test access control
await expect(contract.connect(user).function())
  .to.be.revertedWith(/AccessControl: account .* is missing role/);

// Test time-dependent
await ethers.provider.send("evm_increaseTime", [days * ONE_DAY]);
await ethers.provider.send("evm_mine");

// Test events
await expect(contract.function())
  .to.emit(contract, "EventName")
  .withArgs(args);
```