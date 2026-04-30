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
totalDeposits      → uint256 (tổng tiền gốc trong vault)
interestFunds     → uint256 (quỹ lãi suất)
```

### Functions:

| Hàm | Người gọi | Mô tả |
|-----|-----------|-------|
| `setFeeReceiver(address)` | Admin | Cập nhật địa chỉ nhận phí phạt |
| `depositFunds(amount)` | Admin | Nạp tiền vào quỹ lãi |
| `withdrawFunds(amount)` | Admin | Rút tiền từ quỹ lãi |
| `receiveDeposit(amount)` | SavingCore | Nhận tiền gốc từ user |
| `withdrawToUser(user, principal, interest)` | SavingCore | Trả gốc + lãi cho user |
| `transferPenalty(amount)` | SavingCore | Chuyển phí phạt cho feeReceiver |

---

## 3. SAVINGCORE

### State:
```solidity
token              → IERC20 (USDC)
vaultManager       → address (địa chỉ VaultManager)
nextPlanId         → uint256 (ID gói tiết kiệm tiếp theo)
nextTokenId        → uint256 (ID NFT tiếp theo)

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
    uint256 earlyWithdrawPenaltyBps;   // Phí phạt rút sớm (bps)
    bool enabled;                      // Đang hoạt động
}
```

### Struct DepositPosition:
```solidity
struct DepositPosition {
    address owner;          // Chủ sở hữu NFT
    uint256 principal;     // Tiền gốc
    uint256 planId;        // ID gói đã chọn
    uint256 startTime;     // Thời điểm gửi
    uint256 maturityAt;    // Thời điểm đáo hạn
    uint256 unlockTime;    // Thời điểm có thể rút
    uint256 aprSnapshot;   // Lãi suất đã snapshot tại thời điểm gửi
    uint256 penaltySnapshot; // Phí phạt đã snapshot tại thời điểm gửi
    bool active;           // Đang hoạt động (chưa rút)
    bool withdrawn;        // Đã rút tiền
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
5. Tính maturityAt = now + tenorDays * 86400
6. Mint NFT (tokenId) cho user
7. Emit event DepositOpened
```

### withdrawAtMaturity(tokenId):
```
1. Kiểm tra: owner, active, not withdrawn, đã matured
2. Tính interest = (principal * apr * tenorSeconds) / (365 days * 10000)
3. Gọi VaultManager.withdrawToUser(principal + interest)
4. Burn NFT
5. Emit event WithdrawAtMaturity
```

### earlyWithdraw(tokenId):
```
1. Kiểm tra: owner, active, not withdrawn, chưa matured
2. Tính penalty = (principal * penaltyBps) / 10000
3. userReceives = principal - penalty
4. Gọi VaultManager.transferPenalty(penalty)
5. Gọi VaultManager.withdrawToUser(userReceives, 0)
6. Burn NFT
7. Emit event EarlyWithdraw
```

### transferFrom(from, to, tokenId):
```
1. Kiểm tra: active position
2. Tính phí = (principal * 5%) / 10000
3. newPrincipal = principal - phí
4. Gọi VaultManager.transferPenalty(phí)
5. Update position: owner = to, principal = newPrincipal
6. ERC721 transfer bình thường
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

---

## 7. DEPLOYMENT

```
MockUSDC     → 0x5FbDB2315678afecb367f032d93F642f64180aa3
VaultManager → 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
SavingCore   → 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9
```

### Deploy lại:
```bash
npx hardhat ignition deploy ignition/modules/SavingsSystem.js
```

---

## 8. FLOW HOẠT ĐỘNG

```
1. Admin tạo Plan (createPlan)
2. Admin nạp quỹ lãi (VaultManager.depositFunds)
3. User approve USDC cho SavingCore
4. User gọi openDeposit → nhận NFT
5. User đợi maturity → gọi withdrawAtMaturity → nhận gốc + lãi
   HOẶC User gọi earlyWithdraw → nhận gốc - phí phạt
   HOẶC User transfer NFT → phí 5% trừ khỏi principal
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