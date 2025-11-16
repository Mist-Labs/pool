use starknet::ContractAddress;

#[starknet::interface]
pub trait IBridgePool<TContractState> {
    fn lock_for_htlc(ref self: TContractState, htlc_address: ContractAddress, amount: u256);
    fn get_balance(self: @TContractState) -> u256;
    fn set_max_lock(ref self: TContractState, new_max: u256);
    fn withdraw(ref self: TContractState, to: ContractAddress, amount: u256);
    fn get_max_lock(self: @TContractState) -> u256;
}