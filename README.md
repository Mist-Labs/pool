# Shadow Swap Protocol

A privacy-preserving Atomic Bridge between Zcash and Starknet featuring shielded pools with HTLC support and a privacy-focused ERC20 token.

---

## 🔒 Deployed Contracts

| Contract | Address |
|----------|---------|
| **FastPool** | `0x01749627bb08da4f8c3df6c55045ac429abdceada025262d4c51430d643db84e` |
| **StandardPool** | `0x05cf3a281b3932cb4fec5648558c05fe796bd2d1b6e75554e3306c4849b82ed8` |
| **VeilToken** | `0x02e90f89aecddf3f6b15bd52286a33c743b684fa8c17ed1d7ae57713a81459e1` |

---

## 📋 Contract Overview

### VeilToken

A privacy-enhanced ERC20 token that emits commitment-based events instead of exposing actual addresses.

**Features:**
- Fixed supply: **21,000,000 VEIL**
- 18 decimals
- Poseidon hash-based commitments for transfer/approval events
- Standard ERC20 interface

**Key Functions:**
- `transfer()` / `transfer_from()` - Transfer tokens with privacy commitments
- `approve()` - Approve spending with commitment tracking
- `balance_of()` / `total_supply()` - Standard ERC20 queries

---

### FastPool

A shielded pool optimized for fast withdrawals with **$10K deposit limit** per transaction.

**Features:**
- ✅ Merkle tree-based privacy (100 root history)
- ✅ Virtual HTLCs for atomic swaps
- ✅ Multi-token support
- ✅ Deposit limit: **10,000 tokens max**
- ✅ Timelock range: 1 hour - 7 days
- ✅ Reentrancy protection

**Key Functions:**
- `deposit()` - Deposit tokens with commitment
- `create_htlc()` - Create hash time-locked contract
- `withdraw()` - Withdraw with secret or after timelock
- `update_merkle_root()` - Update privacy set (owner only)

---

### StandardPool

Full-featured shielded pool with **unlimited deposits** for maximum privacy and flexibility.

**Features:**
- ✅ Merkle tree-based privacy (100 root history)
- ✅ Virtual HTLCs for atomic swaps
- ✅ Multi-token support
- ✅ **No deposit limits**
- ✅ Timelock range: 1 hour - 7 days
- ✅ Reentrancy protection

**Key Functions:**
- `deposit()` - Deposit tokens with commitment (unlimited)
- `create_htlc()` - Create hash time-locked contract
- `withdraw()` - Withdraw with secret or after timelock
- `update_merkle_root()` - Update privacy set (owner only)

---

## 🔐 Privacy Model

**Deposits:**
- Users deposit tokens with a Poseidon hash commitment
- Commitments are added to a Merkle tree
- No link between depositor and withdrawal address

**Withdrawals:**
- Prove Merkle inclusion without revealing which leaf
- Nullifiers prevent double-spending
- HTLCs enable cross-chain atomic swaps

**HTLCs:**
- Hash-locked: Requires secret preimage to claim
- Time-locked: Refundable after expiration
- Virtual: No on-chain token lock (managed by owner)

---

## 🚀 Usage

### Deposit Flow
```
1. Approve token to pool contract
2. Generate commitment: Poseidon(secret, nullifier)
3. Call deposit(token, commitment, amount)
4. Wait for Merkle root update
```

### Withdrawal Flow
```
1. Owner creates HTLC with nullifier proof
2. Recipient provides secret to withdraw
3. Or original user reclaims after timelock
```

---

## ⚠️ Security Notes

- **Owner-controlled**: HTLCs and root updates require owner signature
- **Emergency functions**: Owner can withdraw funds if needed
- **Nullifier protection**: Each nullifier can only be spent once
- **Timelock bounds**: HTLCs must expire between 1 hour and 7 days
- **FastPool limit**: Max 10,000 tokens per deposit

---

## 📜 License

MIT

---

## 🛠️ Built With

- **Cairo** - Smart contract language
- **OpenZeppelin** - Security components
- **Poseidon** - Zero-knowledge friendly hashing
- **Starknet** - Ethereum L2 scaling solution
