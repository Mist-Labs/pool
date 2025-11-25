use starknet::SyscallResultTrait;
use core::hash::HashStateTrait;
use core::num::traits::Zero;
use core::option::OptionTrait;
use core::pedersen::PedersenTrait;
use core::poseidon::PoseidonTrait;
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use pool::interface::{IShieldedPoolDispatcher, IShieldedPoolDispatcherTrait};
use pool::fast_shielded_pool::FastPool;
use pool::fast_shielded_pool::FastPool::{
    Deposit, EmergencyWithdraw, Event, HTLCCreated, TokenAdded, TokenRemoved, Withdrawal,
};
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, EventSpy, EventSpyAssertionsTrait, EventSpyTrait,
    declare, spy_events, start_cheat_block_timestamp, start_cheat_caller_address,
    stop_cheat_block_timestamp, stop_cheat_caller_address,
};
use starknet::{ContractAddress, contract_address_const, get_block_timestamp};

fn deploy_mock_token(recipient: ContractAddress, _supply: u256) -> ContractAddress {
    let contract = declare("VeilToken").unwrap_syscall().contract_class();
    let args = array![recipient.into()]; 
    let (contract_address, _) = contract.deploy(@args).unwrap_syscall();
    contract_address
}

fn deploy_pool(owner: ContractAddress) -> IShieldedPoolDispatcher {
    let contract = declare("FastPool").unwrap_syscall().contract_class();
    let args = array![owner.into()];
    let (pool_address, _) = contract.deploy(@args).unwrap_syscall();
    IShieldedPoolDispatcher { contract_address: pool_address }
}

fn generate_commitment(amount: u256, blinding: felt252) -> felt252 {
    PedersenTrait::new(0).update(amount.low.into()).update(blinding).finalize()
}

fn generate_hash_lock(secret: felt252) -> felt252 {
    PoseidonTrait::new().update(secret).finalize()
}

#[test]
fn test_pool_deployment_success() {
    let owner = contract_address_const::<0x123>();
    let pool = deploy_pool(owner);

    assert(pool.contract_address.is_non_zero(), 'Pool not deployed');
    assert(pool.get_current_root() == 0, 'Wrong initial merkle root');
}

#[test]
fn test_add_supported_token_success() {
    let owner = contract_address_const::<0x123>();
    let pool = deploy_pool(owner);
    let token = deploy_mock_token(owner, 1000000_u256);

    let mut spy = spy_events();

    start_cheat_caller_address(pool.contract_address, owner);
    pool.add_supported_token(token);
    stop_cheat_caller_address(pool.contract_address);

    assert(pool.is_token_supported(token), 'Token not added');

    spy.assert_emitted(@array![(pool.contract_address, Event::TokenAdded(TokenAdded { token }))]);
}

#[test]
#[should_panic(expected: 'Caller is not the owner')]
fn test_add_supported_token_not_owner() {
    let owner = contract_address_const::<0x123>();
    let non_owner = contract_address_const::<0x999>();
    let pool = deploy_pool(owner);
    let token = deploy_mock_token(owner, 1000000_u256);

    start_cheat_caller_address(pool.contract_address, non_owner);
    pool.add_supported_token(token);
}

#[test]
#[should_panic(expected: 'Invalid token')]
fn test_add_supported_token_zero_address() {
    let owner = contract_address_const::<0x123>();
    let pool = deploy_pool(owner);
    let zero_token = contract_address_const::<0x0>();

    start_cheat_caller_address(pool.contract_address, owner);
    pool.add_supported_token(zero_token);
}

#[test]
#[should_panic(expected: 'Token already supported')]
fn test_add_supported_token_duplicate() {
    let owner = contract_address_const::<0x123>();
    let pool = deploy_pool(owner);
    let token = deploy_mock_token(owner, 1000000_u256);

    start_cheat_caller_address(pool.contract_address, owner);
    pool.add_supported_token(token);
    pool.add_supported_token(token);
}

#[test]
fn test_remove_supported_token_success() {
    let owner = contract_address_const::<0x123>();
    let pool = deploy_pool(owner);
    let token = deploy_mock_token(owner, 1000000_u256);

    start_cheat_caller_address(pool.contract_address, owner);
    pool.add_supported_token(token);
    assert(pool.is_token_supported(token), 'Token not added');

    let mut spy = spy_events();
    pool.remove_supported_token(token);
    stop_cheat_caller_address(pool.contract_address);

    assert(!pool.is_token_supported(token), 'Token not removed');

    spy
        .assert_emitted(
            @array![(pool.contract_address, Event::TokenRemoved(TokenRemoved { token }))],
        );
}

#[test]
#[should_panic(expected: 'Token not supported')]
fn test_remove_unsupported_token() {
    let owner = contract_address_const::<0x123>();
    let pool = deploy_pool(owner);
    let token = deploy_mock_token(owner, 1000000_u256);

    start_cheat_caller_address(pool.contract_address, owner);
    pool.remove_supported_token(token);
}

#[test]
fn test_deposit_success() {
    let owner = contract_address_const::<0x123>();
    let user = contract_address_const::<0x456>();
    let pool = deploy_pool(owner);
    let token = deploy_mock_token(user, 1000000_u256);
    let amount = 9000_u256;
    let blinding = 12345_felt252;
    let commitment = generate_commitment(amount, blinding);

    start_cheat_caller_address(pool.contract_address, owner);
    pool.add_supported_token(token);
    stop_cheat_caller_address(pool.contract_address);

    let token_dispatcher = IERC20Dispatcher { contract_address: token };
    start_cheat_caller_address(token, user);
    token_dispatcher.approve(pool.contract_address, amount);
    stop_cheat_caller_address(token);

    let mut spy = spy_events();
    let leaf_index = pool.get_next_leaf_index();

    start_cheat_caller_address(pool.contract_address, user);
    pool.deposit(token, commitment, amount);
    stop_cheat_caller_address(pool.contract_address);

    assert(pool.get_balance(token) == amount, 'Wrong pool balance');

    spy
        .assert_emitted(
            @array![
                (
                    pool.contract_address,
                    Event::Deposit(Deposit { commitment, leaf_index, timestamp: get_block_timestamp() }),
                ),
            ],
        );
}

#[test]
#[should_panic(expected: 'Amount exceeds limit')]
fn test_deposit_exceeds_max_amount() {
    let owner = contract_address_const::<0x123>();
    let user = contract_address_const::<0x456>();
    let pool = deploy_pool(owner);
    let token = deploy_mock_token(user, 20000000000000000000000_u256);
    let amount = 10000000000000000000001_u256;
    let commitment = generate_commitment(amount, 123_felt252);

    start_cheat_caller_address(pool.contract_address, owner);
    pool.add_supported_token(token);
    stop_cheat_caller_address(pool.contract_address);

    let token_dispatcher = IERC20Dispatcher { contract_address: token };
    start_cheat_caller_address(token, user);
    token_dispatcher.approve(pool.contract_address, amount);
    stop_cheat_caller_address(token);

    start_cheat_caller_address(pool.contract_address, user);
    pool.deposit(token, commitment, amount);
}

#[test]
fn test_deposit_at_max_amount() {
    let owner = contract_address_const::<0x123>();
    let user = contract_address_const::<0x456>();
    let pool = deploy_pool(owner);
    let token = deploy_mock_token(user, 20000000000000000000000_u256);
    let amount = 10000000000000000000000_u256;
    let commitment = generate_commitment(amount, 123_felt252);

    start_cheat_caller_address(pool.contract_address, owner);
    pool.add_supported_token(token);
    stop_cheat_caller_address(pool.contract_address);

    let token_dispatcher = IERC20Dispatcher { contract_address: token };
    start_cheat_caller_address(token, user);
    token_dispatcher.approve(pool.contract_address, amount);
    stop_cheat_caller_address(token);

    start_cheat_caller_address(pool.contract_address, user);
    pool.deposit(token, commitment, amount);
    stop_cheat_caller_address(pool.contract_address);

    assert(pool.get_balance(token) == amount, 'Wrong pool balance');
}

#[test]
#[should_panic(expected: 'Token not supported')]
fn test_deposit_unsupported_token() {
    let owner = contract_address_const::<0x123>();
    let user = contract_address_const::<0x456>();
    let pool = deploy_pool(owner);
    let token = deploy_mock_token(user, 1000000_u256);
    let commitment = generate_commitment(1000_u256, 123_felt252);

    start_cheat_caller_address(pool.contract_address, user);
    pool.deposit(token, commitment, 1000_u256);
}

#[test]
#[should_panic(expected: 'Zero amount')]
fn test_deposit_zero_amount() {
    let owner = contract_address_const::<0x123>();
    let user = contract_address_const::<0x456>();
    let pool = deploy_pool(owner);
    let token = deploy_mock_token(user, 1000000_u256);
    let commitment = generate_commitment(0_u256, 123_felt252);

    start_cheat_caller_address(pool.contract_address, owner);
    pool.add_supported_token(token);
    stop_cheat_caller_address(pool.contract_address);

    start_cheat_caller_address(pool.contract_address, user);
    pool.deposit(token, commitment, 0_u256);
}

#[test]
fn test_create_htlc_success() {
    let owner = contract_address_const::<0x123>();
    let user = contract_address_const::<0x456>();
    let pool = deploy_pool(owner);
    let token = deploy_mock_token(user, 1000000_u256);
    let amount = 9000_u256;
    let blinding = 12345_felt252;
    let commitment = generate_commitment(amount, blinding);
    let secret = 99999_felt252;
    let hash_lock = generate_hash_lock(secret);
    let nullifier = 55555_felt252;

    start_cheat_caller_address(pool.contract_address, owner);
    pool.add_supported_token(token);
    stop_cheat_caller_address(pool.contract_address);

    let token_dispatcher = IERC20Dispatcher { contract_address: token };
    start_cheat_caller_address(token, user);
    token_dispatcher.approve(pool.contract_address, amount);
    stop_cheat_caller_address(token);

    start_cheat_caller_address(pool.contract_address, user);
    pool.deposit(token, commitment, amount);
    stop_cheat_caller_address(pool.contract_address);

    // For single-leaf tree, root IS the commitment itself
    start_cheat_caller_address(pool.contract_address, owner);
    pool.update_merkle_root(commitment);
    stop_cheat_caller_address(pool.contract_address);

    let current_time = 1000000_u64;
    start_cheat_block_timestamp(pool.contract_address, current_time);
    let timelock = current_time + 7200;

    // Empty proof for single-leaf tree (leaf == root, no proof needed)
    let merkle_proof: Array<felt252> = array![];
    let path_indices: Array<u8> = array![];

    let mut spy = spy_events();
    start_cheat_caller_address(pool.contract_address, owner);
    pool.create_htlc(token, nullifier, commitment, commitment, amount, merkle_proof.span(), path_indices.span(), hash_lock, timelock);
    stop_cheat_caller_address(pool.contract_address);
    stop_cheat_block_timestamp(pool.contract_address);

    let (stored_root, stored_token, stored_hash, stored_timelock, stored_amount, state) = pool
        .get_htlc(nullifier);
    assert(stored_root == commitment, 'Wrong root');
    assert(stored_token == token, 'Wrong token');
    assert(stored_hash == hash_lock, 'Wrong hash lock');
    assert(stored_timelock == timelock, 'Wrong timelock');
    assert(stored_amount == amount, 'Wrong amount');
    assert(state == 0, 'Wrong initial state');

    spy
        .assert_emitted(
            @array![
                (
                    pool.contract_address,
                    Event::HTLCCreated(
                        HTLCCreated {
                            nullifier, hash_lock, timelock, timestamp: current_time,
                        },
                    ),
                ),
            ],
        );
}

#[test]
#[should_panic(expected: 'Caller is not the owner')]
fn test_create_htlc_not_owner() {
    let owner = contract_address_const::<0x123>();
    let user = contract_address_const::<0x456>();
    let pool = deploy_pool(owner);
    let token = deploy_mock_token(user, 1000000_u256);
    let amount = 5000_u256;
    let commitment = generate_commitment(amount, 123_felt252);
    let hash_lock = generate_hash_lock(999_felt252);
    let nullifier = 55555_felt252;

    start_cheat_caller_address(pool.contract_address, owner);
    pool.add_supported_token(token);
    stop_cheat_caller_address(pool.contract_address);

    let token_dispatcher = IERC20Dispatcher { contract_address: token };
    start_cheat_caller_address(token, user);
    token_dispatcher.approve(pool.contract_address, amount);
    stop_cheat_caller_address(token);

    start_cheat_caller_address(pool.contract_address, user);
    pool.deposit(token, commitment, amount);
    stop_cheat_caller_address(pool.contract_address);

    start_cheat_caller_address(pool.contract_address, owner);
    pool.update_merkle_root(commitment);
    stop_cheat_caller_address(pool.contract_address);

    let current_time = 1000000_u64;
    start_cheat_block_timestamp(pool.contract_address, current_time);
    
    let merkle_proof: Array<felt252> = array![];
    let path_indices: Array<u8> = array![];

    start_cheat_caller_address(pool.contract_address, user);
    pool.create_htlc(token, nullifier, commitment, commitment, amount, merkle_proof.span(), path_indices.span(), hash_lock, current_time + 7200);
}

#[test]
#[should_panic(expected: 'Amount exceeds limit')]
fn test_create_htlc_exceeds_max_amount() {
    let owner = contract_address_const::<0x123>();
    let pool = deploy_pool(owner);
    let token = deploy_mock_token(owner, 20000000000000000000000_u256);
    let amount = 10000000000000000000001_u256;
    let commitment = generate_commitment(amount, 123_felt252);
    let hash_lock = generate_hash_lock(999_felt252);
    let nullifier = 55555_felt252;
    let root = pool.get_current_root();
    let merkle_proof: Array<felt252> = array![];
    let path_indices: Array<u8> = array![];

    start_cheat_caller_address(pool.contract_address, owner);
    pool.add_supported_token(token);

    let current_time = 1000000_u64;
    start_cheat_block_timestamp(pool.contract_address, current_time);
    pool.create_htlc(token, nullifier, root, commitment, amount, merkle_proof.span(), path_indices.span(), hash_lock, current_time + 7200);
}

#[test]
fn test_withdraw_redemption_with_secret() {
    let owner = contract_address_const::<0x123>();
    let user = contract_address_const::<0x456>();
    let recipient = contract_address_const::<0x789>();
    let pool = deploy_pool(owner);
    let token = deploy_mock_token(user, 1000000_u256);
    let amount = 8000_u256;
    let blinding = 12345_felt252;
    let commitment = generate_commitment(amount, blinding);
    let secret = 99999_felt252;
    let hash_lock = generate_hash_lock(secret);
    let nullifier = 55555_felt252;

    start_cheat_caller_address(pool.contract_address, owner);
    pool.add_supported_token(token);
    stop_cheat_caller_address(pool.contract_address);

    let token_dispatcher = IERC20Dispatcher { contract_address: token };
    start_cheat_caller_address(token, user);
    token_dispatcher.approve(pool.contract_address, amount);
    stop_cheat_caller_address(token);

    start_cheat_caller_address(pool.contract_address, user);
    pool.deposit(token, commitment, amount);
    stop_cheat_caller_address(pool.contract_address);

    start_cheat_caller_address(pool.contract_address, owner);
    pool.update_merkle_root(commitment);
    stop_cheat_caller_address(pool.contract_address);

    let current_time = 1000000_u64;
    start_cheat_block_timestamp(pool.contract_address, current_time);
    let timelock = current_time + 7200;
    
    let merkle_proof: Array<felt252> = array![];
    let path_indices: Array<u8> = array![];

    start_cheat_caller_address(pool.contract_address, owner);
    pool.create_htlc(token, nullifier, commitment, commitment, amount, merkle_proof.span(), path_indices.span(), hash_lock, timelock);
    stop_cheat_caller_address(pool.contract_address);

    let mut spy = spy_events();
    start_cheat_caller_address(pool.contract_address, owner);
    pool.withdraw(token, nullifier, recipient, Option::Some(secret));
    stop_cheat_caller_address(pool.contract_address);
    stop_cheat_block_timestamp(pool.contract_address);

    assert(pool.is_nullifier_spent(nullifier), 'Nullifier not spent');
    assert(token_dispatcher.balance_of(recipient) == amount, 'Wrong recipient balance');
    assert(pool.get_balance(token) == 0, 'Pool not empty');

    let (_, _, _, _, _, state) = pool.get_htlc(nullifier);
    assert(state == 1, 'Wrong state (redeem)');

    spy
        .assert_emitted(
            @array![
                (
                    pool.contract_address,
                    Event::Withdrawal(Withdrawal { nullifier, timestamp: current_time }),
                ),
            ],
        );
}

#[test]
#[should_panic(expected: 'Caller is not the owner')]
fn test_withdraw_not_owner() {
    let owner = contract_address_const::<0x123>();
    let user = contract_address_const::<0x456>();
    let recipient = contract_address_const::<0x789>();
    let pool = deploy_pool(owner);
    let token = deploy_mock_token(user, 1000000_u256);
    let amount = 5000_u256;
    let commitment = generate_commitment(amount, 123_felt252);
    let secret = 99999_felt252;
    let hash_lock = generate_hash_lock(secret);
    let nullifier = 55555_felt252;

    start_cheat_caller_address(pool.contract_address, owner);
    pool.add_supported_token(token);
    stop_cheat_caller_address(pool.contract_address);

    let token_dispatcher = IERC20Dispatcher { contract_address: token };
    start_cheat_caller_address(token, user);
    token_dispatcher.approve(pool.contract_address, amount);
    stop_cheat_caller_address(token);

    start_cheat_caller_address(pool.contract_address, user);
    pool.deposit(token, commitment, amount);
    stop_cheat_caller_address(pool.contract_address);

    start_cheat_caller_address(pool.contract_address, owner);
    pool.update_merkle_root(commitment);
    stop_cheat_caller_address(pool.contract_address);

    let current_time = 1000000_u64;
    start_cheat_block_timestamp(pool.contract_address, current_time);
    
    let merkle_proof: Array<felt252> = array![];
    let path_indices: Array<u8> = array![];

    start_cheat_caller_address(pool.contract_address, owner);
    pool.create_htlc(token, nullifier, commitment, commitment, amount, merkle_proof.span(), path_indices.span(), hash_lock, current_time + 7200);
    stop_cheat_caller_address(pool.contract_address);

    start_cheat_caller_address(pool.contract_address, user);
    pool.withdraw(token, nullifier, recipient, Option::Some(secret));
}

#[test]
fn test_withdraw_refund_after_expiry() {
    let owner = contract_address_const::<0x123>();
    let user = contract_address_const::<0x456>();
    let recipient = contract_address_const::<0x789>();
    let pool = deploy_pool(owner);
    let token = deploy_mock_token(user, 1000000_u256);
    let amount = 7000_u256;
    let commitment = generate_commitment(amount, 123_felt252);
    let hash_lock = generate_hash_lock(999_felt252);
    let nullifier = 55555_felt252;

    start_cheat_caller_address(pool.contract_address, owner);
    pool.add_supported_token(token);
    stop_cheat_caller_address(pool.contract_address);

    let token_dispatcher = IERC20Dispatcher { contract_address: token };
    start_cheat_caller_address(token, user);
    token_dispatcher.approve(pool.contract_address, amount);
    stop_cheat_caller_address(token);

    start_cheat_caller_address(pool.contract_address, user);
    pool.deposit(token, commitment, amount);
    stop_cheat_caller_address(pool.contract_address);

    start_cheat_caller_address(pool.contract_address, owner);
    pool.update_merkle_root(commitment);
    stop_cheat_caller_address(pool.contract_address);

    let current_time = 1000000_u64;
    start_cheat_block_timestamp(pool.contract_address, current_time);
    let timelock = current_time + 7200;
    
    let merkle_proof: Array<felt252> = array![];
    let path_indices: Array<u8> = array![];

    start_cheat_caller_address(pool.contract_address, owner);
    pool.create_htlc(token, nullifier, commitment, commitment, amount, merkle_proof.span(), path_indices.span(), hash_lock, timelock);
    stop_cheat_caller_address(pool.contract_address);
    stop_cheat_block_timestamp(pool.contract_address);

    start_cheat_block_timestamp(pool.contract_address, timelock + 1);
    start_cheat_caller_address(pool.contract_address, owner);
    pool.withdraw(token, nullifier, recipient, Option::None);
    stop_cheat_caller_address(pool.contract_address);

    assert(pool.is_nullifier_spent(nullifier), 'Nullifier not spent');
    let (_, _, _, _, _, state) = pool.get_htlc(nullifier);
    assert(state == 2, 'Wrong state (refund)');
}

#[test]
#[should_panic(expected: 'Invalid secret')]
fn test_withdraw_wrong_secret() {
    let owner = contract_address_const::<0x123>();
    let user = contract_address_const::<0x456>();
    let recipient = contract_address_const::<0x789>();
    let pool = deploy_pool(owner);
    let token = deploy_mock_token(user, 1000000_u256);
    let amount = 6000_u256;
    let commitment = generate_commitment(amount, 123_felt252);
    let correct_secret = 99999_felt252;
    let wrong_secret = 11111_felt252;
    let hash_lock = generate_hash_lock(correct_secret);
    let nullifier = 55555_felt252;

    start_cheat_caller_address(pool.contract_address, owner);
    pool.add_supported_token(token);
    stop_cheat_caller_address(pool.contract_address);

    let token_dispatcher = IERC20Dispatcher { contract_address: token };
    start_cheat_caller_address(token, user);
    token_dispatcher.approve(pool.contract_address, amount);
    stop_cheat_caller_address(token);

    start_cheat_caller_address(pool.contract_address, user);
    pool.deposit(token, commitment, amount);
    stop_cheat_caller_address(pool.contract_address);

    start_cheat_caller_address(pool.contract_address, owner);
    pool.update_merkle_root(commitment);
    stop_cheat_caller_address(pool.contract_address);

    let current_time = 1000000_u64;
    start_cheat_block_timestamp(pool.contract_address, current_time);
    let timelock = current_time + 7200;
    
    let merkle_proof: Array<felt252> = array![];
    let path_indices: Array<u8> = array![];

    start_cheat_caller_address(pool.contract_address, owner);
    pool.create_htlc(token, nullifier, commitment, commitment, amount, merkle_proof.span(), path_indices.span(), hash_lock, timelock);
    pool.withdraw(token, nullifier, recipient, Option::Some(wrong_secret));
}

#[test]
#[should_panic(expected: 'Already spent')]
fn test_withdraw_double_spend() {
    let owner = contract_address_const::<0x123>();
    let user = contract_address_const::<0x456>();
    let recipient = contract_address_const::<0x789>();
    let pool = deploy_pool(owner);
    let token = deploy_mock_token(user, 1000000_u256);
    let amount = 5500_u256;
    let commitment = generate_commitment(amount, 123_felt252);
    let secret = 99999_felt252;
    let hash_lock = generate_hash_lock(secret);
    let nullifier = 55555_felt252;

    start_cheat_caller_address(pool.contract_address, owner);
    pool.add_supported_token(token);
    stop_cheat_caller_address(pool.contract_address);

    let token_dispatcher = IERC20Dispatcher { contract_address: token };
    start_cheat_caller_address(token, user);
    token_dispatcher.approve(pool.contract_address, amount);
    stop_cheat_caller_address(token);

    start_cheat_caller_address(pool.contract_address, user);
    pool.deposit(token, commitment, amount);
    stop_cheat_caller_address(pool.contract_address);

    start_cheat_caller_address(pool.contract_address, owner);
    pool.update_merkle_root(commitment);
    stop_cheat_caller_address(pool.contract_address);

    let current_time = 1000000_u64;
    start_cheat_block_timestamp(pool.contract_address, current_time);
    let timelock = current_time + 7200;

    let merkle_proof: Array<felt252> = array![];
    let path_indices: Array<u8> = array![];

    start_cheat_caller_address(pool.contract_address, owner);
    pool.create_htlc(token, nullifier, commitment, commitment, amount, merkle_proof.span(), path_indices.span(), hash_lock, timelock);
    pool.withdraw(token, nullifier, recipient, Option::Some(secret));
    pool.withdraw(token, nullifier, recipient, Option::Some(secret));
}

#[test]
fn test_emergency_withdraw_success() {
    let owner = contract_address_const::<0x123>();
    let user = contract_address_const::<0x456>();
    let emergency_recipient = contract_address_const::<0x999>();
    let pool = deploy_pool(owner);
    let token = deploy_mock_token(user, 1000000_u256);
    let amount = 9000_u256;

    start_cheat_caller_address(pool.contract_address, owner);
    pool.add_supported_token(token);
    stop_cheat_caller_address(pool.contract_address);

    let token_dispatcher = IERC20Dispatcher { contract_address: token };
    start_cheat_caller_address(token, user);
    token_dispatcher.approve(pool.contract_address, amount);
    stop_cheat_caller_address(token);

    let commitment = generate_commitment(amount, 123_felt252);
    start_cheat_caller_address(pool.contract_address, user);
    pool.deposit(token, commitment, amount);
    stop_cheat_caller_address(pool.contract_address);

    let withdraw_amount = 5000_u256;
    let mut spy = spy_events();

    start_cheat_caller_address(pool.contract_address, owner);
    pool.emergency_withdraw(token, emergency_recipient, withdraw_amount);
    stop_cheat_caller_address(pool.contract_address);

    assert(pool.get_balance(token) == amount - withdraw_amount, 'Wrong pool balance');
    assert(
        token_dispatcher.balance_of(emergency_recipient) == withdraw_amount,
        'Wrong recipient balance',
    );

    spy
        .assert_emitted(
            @array![
                (
                    pool.contract_address,
                    Event::EmergencyWithdraw(
                        EmergencyWithdraw {
                            token, to: emergency_recipient, amount: withdraw_amount,
                        },
                    ),
                ),
            ],
        );
}

#[test]
#[should_panic(expected: 'Caller is not the owner')]
fn test_emergency_withdraw_not_owner() {
    let owner = contract_address_const::<0x123>();
    let non_owner = contract_address_const::<0x999>();
    let pool = deploy_pool(owner);
    let token = deploy_mock_token(owner, 1000000_u256);

    start_cheat_caller_address(pool.contract_address, non_owner);
    pool.emergency_withdraw(token, owner, 1000_u256);
}

#[test]
fn test_multi_token_support() {
    let owner = contract_address_const::<0x123>();
    let user1 = contract_address_const::<0x456>();
    let user2 = contract_address_const::<0x789>();
    let pool = deploy_pool(owner);
    let token1 = deploy_mock_token(user1, 1000000_u256);
    let token2 = deploy_mock_token(user2, 1000000_u256);
    let amount1 = 5000_u256;
    let amount2 = 7000_u256;

    start_cheat_caller_address(pool.contract_address, owner);
    pool.add_supported_token(token1);
    pool.add_supported_token(token2);
    stop_cheat_caller_address(pool.contract_address);

    let commitment1 = generate_commitment(amount1, 111_felt252);
    let token1_dispatcher = IERC20Dispatcher { contract_address: token1 };
    start_cheat_caller_address(token1, user1);
    token1_dispatcher.approve(pool.contract_address, amount1);
    stop_cheat_caller_address(token1);

    start_cheat_caller_address(pool.contract_address, user1);
    pool.deposit(token1, commitment1, amount1);
    stop_cheat_caller_address(pool.contract_address);

    let commitment2 = generate_commitment(amount2, 222_felt252);
    let token2_dispatcher = IERC20Dispatcher { contract_address: token2 };
    start_cheat_caller_address(token2, user2);
    token2_dispatcher.approve(pool.contract_address, amount2);
    stop_cheat_caller_address(token2);

    start_cheat_caller_address(pool.contract_address, user2);
    pool.deposit(token2, commitment2, amount2);
    stop_cheat_caller_address(pool.contract_address);

    assert(pool.get_balance(token1) == amount1, 'Wrong token1 balance');
    assert(pool.get_balance(token2) == amount2, 'Wrong token2 balance');
}
