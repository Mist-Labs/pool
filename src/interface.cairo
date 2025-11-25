use starknet::ContractAddress;

#[starknet::interface]
pub trait IShieldedPool<TContractState> {
    // ==================== DEPOSIT ====================
    /// Deposit tokens and create privacy note
    /// @param commitment: Note commitment (computed off-chain)
    /// @param amount: Amount to deposit
    fn deposit(ref self: TContractState, token: ContractAddress, commitment: felt252, amount: u256);

    // ==================== HTLC OPERATIONS ====================
    /// Create virtual HTLC (no token transfer, state only)
    /// @param nullifier: Proves note ownership
    /// @param commitment: Links to deposited note
    /// @param hash_lock: Secret hash for redemption
    /// @param timelock: Expiration timestamp
    fn create_htlc(
        ref self: TContractState,
        token: ContractAddress,
        nullifier: felt252,
        root: felt252,
        commitment: felt252,
        amount: u256,
        merkle_proof: Span<felt252>,
        path_indices: Span<u8>,
        hash_lock: felt252,
        timelock: u64,
    );

    // ==================== WITHDRAWAL ====================
    /// Unified withdrawal (redemption or refund)
    /// @param nullifier: Proves note ownership (privacy-preserving)
    /// @param secret: Some(secret) for redemption, None for refund
    /// @param recipient: Withdrawal address (can differ from depositor)
    /// @param amount: Amount to withdraw
    /// @param blinding_factor: Proves amount correctness
    fn withdraw(
        ref self: TContractState,
        token: ContractAddress,
        nullifier: felt252,
        recipient: ContractAddress,
        secret: Option<felt252>,
    );


    // ==================== ADMIN ====================
    fn update_merkle_root(ref self: TContractState, new_root: felt252);

    fn add_supported_token(ref self: TContractState, token: ContractAddress);
    fn remove_supported_token(ref self: TContractState, token: ContractAddress);
    fn is_token_supported(self: @TContractState, token: ContractAddress) -> bool;
    /// Emergency withdraw (owner only)
    fn emergency_withdraw(
        ref self: TContractState, token: ContractAddress, to: ContractAddress, amount: u256,
    );

    // ==================== VIEWS ====================
    fn get_next_leaf_index(self: @TContractState) -> u32;

    fn get_current_root(self: @TContractState) -> felt252;

    fn is_known_root(self: @TContractState, root: felt252) -> bool;
    /// Check if nullifier has been spent
    fn is_nullifier_spent(self: @TContractState, nullifier: felt252) -> bool;

    /// Get HTLC state
    fn get_htlc(
        self: @TContractState, nullifier: felt252,
    ) -> (felt252, ContractAddress, felt252, u64, u256, u8);

    /// Get pool balance for token
    fn get_balance(self: @TContractState, token: ContractAddress) -> u256;
}


#[starknet::interface]
pub trait IVeilToken<TContractState> {
    // Additional metadata views
    fn name(self: @TContractState) -> ByteArray;
    fn symbol(self: @TContractState) -> ByteArray;
    fn decimals(self: @TContractState) -> u8;
    fn max_supply(self: @TContractState) -> u256;
}
