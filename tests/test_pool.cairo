use core::num::traits::Zero;
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use pool::interface::{IBridgePoolDispatcher, IBridgePoolDispatcherTrait};
use snforge_std::{
    CheatSpan, ContractClassTrait, DeclareResultTrait, declare, start_cheat_caller_address,
    stop_cheat_caller_address,
};
use starknet::{ContractAddress, SyscallResultTrait, contract_address_const, get_contract_address};


fn deploy_mock_token(recipient: ContractAddress, supply: u256) -> ContractAddress {
    let contract = declare("ERC20").unwrap_syscall().contract_class();
    let args = array![recipient.into(), supply.low.into(), supply.high.into()];
    let (contract_address, _) = contract.deploy(@args).unwrap_syscall();
    contract_address
}

fn deploy_pool(
    owner: ContractAddress, token: ContractAddress, max_single_lock: u256,
) -> IBridgePoolDispatcher {
    let contract = declare("Pool").unwrap_syscall().contract_class();
    let args = array![
        owner.into(), token.into(), max_single_lock.low.into(), max_single_lock.high.into(),
    ];
    let (pool_address, _) = contract.deploy(@args).unwrap_syscall();
    IBridgePoolDispatcher { contract_address: pool_address }
}

#[test]
fn test_pool_deployment_success() {
    let owner = contract_address_const::<0x123>();
    let token = deploy_mock_token(owner, 1000000_u256);
    let max_lock = 10000_u256;

    let pool = deploy_pool(owner, token, max_lock);

    assert(pool.contract_address.is_non_zero(), 'Pool not deployed');
    assert(pool.get_max_lock() == max_lock, 'Wrong max lock');
    assert(pool.get_balance() == 0, 'Initial balance not zero');
}


#[test]
fn test_lock_for_htlc_success() {
    let owner = contract_address_const::<0x123>();
    let htlc = contract_address_const::<0x456>();
    let initial_supply = 100000_u256;
    let lock_amount = 1000_u256;
    let max_lock = 10000_u256;

    let token = deploy_mock_token(owner, initial_supply);
    let pool = deploy_pool(owner, token, max_lock);

    let token_dispatcher = IERC20Dispatcher { contract_address: token };
    start_cheat_caller_address(token, owner);
    token_dispatcher.transfer(pool.contract_address, initial_supply);
    stop_cheat_caller_address(token);

    assert(pool.get_balance() == initial_supply, 'Wrong pool balance');

    start_cheat_caller_address(pool.contract_address, owner);
    pool.lock_for_htlc(htlc, lock_amount);
    stop_cheat_caller_address(pool.contract_address);

    assert(pool.get_balance() == initial_supply - lock_amount, 'Wrong pool balance after lock');
    assert(token_dispatcher.balance_of(htlc) == lock_amount, 'HTLC didnt receive tokens');
}

#[test]
fn test_pool_deployment_validates_inputs() {
    let owner = contract_address_const::<0x123>();
    let token = deploy_mock_token(owner, 1000_u256);
    let pool = deploy_pool(owner, token, 1000_u256);

    assert(pool.contract_address.is_non_zero(), 'Valid deployment failed');
}


#[test]
#[should_panic(expected: 'Caller is not the owner')]
fn test_lock_for_htlc_not_owner() {
    let owner = contract_address_const::<0x123>();
    let non_owner = contract_address_const::<0x999>();
    let htlc = contract_address_const::<0x456>();
    let lock_amount = 1000_u256;
    let max_lock = 10000_u256;

    let token = deploy_mock_token(owner, 100000_u256);
    let pool = deploy_pool(owner, token, max_lock);

    // Non-owner tries to lock
    start_cheat_caller_address(pool.contract_address, non_owner);
    pool.lock_for_htlc(htlc, lock_amount);
}

#[test]
#[should_panic(expected: 'Invalid HTLC address')]
fn test_lock_for_htlc_zero_htlc() {
    let owner = contract_address_const::<0x123>();
    let htlc = contract_address_const::<0x0>();
    let lock_amount = 1000_u256;
    let max_lock = 10000_u256;

    let token = deploy_mock_token(owner, 100000_u256);
    let pool = deploy_pool(owner, token, max_lock);

    start_cheat_caller_address(pool.contract_address, owner);
    pool.lock_for_htlc(htlc, lock_amount);
}


#[test]
#[should_panic(expected: 'Amount must be positive')]
fn test_lock_for_htlc_zero_amount() {
    let owner = contract_address_const::<0x123>();
    let htlc = contract_address_const::<0x456>();
    let lock_amount = 0_u256;
    let max_lock = 10000_u256;

    let token = deploy_mock_token(owner, 100000_u256);
    let pool = deploy_pool(owner, token, max_lock);

    start_cheat_caller_address(pool.contract_address, owner);
    pool.lock_for_htlc(htlc, lock_amount);
}

#[test]
#[should_panic(expected: 'Exceeds max lock amount')]
fn test_lock_for_htlc_exceeds_max() {
    let owner = contract_address_const::<0x123>();
    let htlc = contract_address_const::<0x456>();
    let max_lock = 10000_u256;
    let lock_amount = 15000_u256; // Exceeds max

    let token = deploy_mock_token(owner, 100000_u256);
    let pool = deploy_pool(owner, token, max_lock);

    let token_dispatcher = IERC20Dispatcher { contract_address: token };
    start_cheat_caller_address(token, owner);
    token_dispatcher.transfer(pool.contract_address, 50000_u256);
    stop_cheat_caller_address(token);

    start_cheat_caller_address(pool.contract_address, owner);
    pool.lock_for_htlc(htlc, lock_amount);
}

#[test]
#[should_panic(expected: 'Insufficient pool balance')]
fn test_lock_for_htlc_insufficient_balance() {
    let owner = contract_address_const::<0x123>();
    let htlc = contract_address_const::<0x456>();
    let lock_amount = 5000_u256;
    let max_lock = 10000_u256;

    let token = deploy_mock_token(owner, 100000_u256);
    let pool = deploy_pool(owner, token, max_lock);

    start_cheat_caller_address(pool.contract_address, owner);
    pool.lock_for_htlc(htlc, lock_amount);
}

#[test]
fn test_lock_for_htlc_multiple_locks() {
    let owner = contract_address_const::<0x123>();
    let htlc1 = contract_address_const::<0x456>();
    let htlc2 = contract_address_const::<0x789>();
    let initial_supply = 100000_u256;
    let lock_amount = 1000_u256;
    let max_lock = 10000_u256;

    let token = deploy_mock_token(owner, initial_supply);
    let pool = deploy_pool(owner, token, max_lock);

    let token_dispatcher = IERC20Dispatcher { contract_address: token };
    start_cheat_caller_address(token, owner);
    token_dispatcher.transfer(pool.contract_address, initial_supply);
    stop_cheat_caller_address(token);

    start_cheat_caller_address(pool.contract_address, owner);
    pool.lock_for_htlc(htlc1, lock_amount);
    stop_cheat_caller_address(pool.contract_address);

    assert(token_dispatcher.balance_of(htlc1) == lock_amount, 'HTLC1 wrong balance');

    start_cheat_caller_address(pool.contract_address, owner);
    pool.lock_for_htlc(htlc2, lock_amount);
    stop_cheat_caller_address(pool.contract_address);

    assert(token_dispatcher.balance_of(htlc2) == lock_amount, 'HTLC2 wrong balance');
    assert(
        pool.get_balance() == initial_supply - (lock_amount * 2), 'Wrong pool balance after locks',
    );
}

#[test]
fn test_set_max_lock_success() {
    let owner = contract_address_const::<0x123>();
    let token = deploy_mock_token(owner, 1000_u256);
    let initial_max = 10000_u256;
    let new_max = 20000_u256;

    let pool = deploy_pool(owner, token, initial_max);

    assert(pool.get_max_lock() == initial_max, 'Wrong initial max');

    start_cheat_caller_address(pool.contract_address, owner);
    pool.set_max_lock(new_max);
    stop_cheat_caller_address(pool.contract_address);

    assert(pool.get_max_lock() == new_max, 'Max not updated');
}

#[test]
#[should_panic(expected: 'Caller is not the owner')]
fn test_set_max_lock_not_owner() {
    let owner = contract_address_const::<0x123>();
    let non_owner = contract_address_const::<0x999>();
    let token = deploy_mock_token(owner, 1000_u256);
    let max_lock = 10000_u256;

    let pool = deploy_pool(owner, token, max_lock);

    start_cheat_caller_address(pool.contract_address, non_owner);
    pool.set_max_lock(20000_u256);
}

#[test]
#[should_panic(expected: 'Max lock must be positive')]
fn test_set_max_lock_zero() {
    let owner = contract_address_const::<0x123>();
    let token = deploy_mock_token(owner, 1000_u256);
    let max_lock = 10000_u256;

    let pool = deploy_pool(owner, token, max_lock);

    start_cheat_caller_address(pool.contract_address, owner);
    pool.set_max_lock(0_u256);
}

#[test]
fn test_withdraw_success() {
    let owner = contract_address_const::<0x123>();
    let recipient = contract_address_const::<0x456>();
    let initial_supply = 100000_u256;
    let withdraw_amount = 5000_u256;
    let max_lock = 10000_u256;

    let token = deploy_mock_token(owner, initial_supply);
    let pool = deploy_pool(owner, token, max_lock);

    let token_dispatcher = IERC20Dispatcher { contract_address: token };
    start_cheat_caller_address(token, owner);
    token_dispatcher.transfer(pool.contract_address, initial_supply);
    stop_cheat_caller_address(token);

    assert(pool.get_balance() == initial_supply, 'Wrong pool balance');

    start_cheat_caller_address(pool.contract_address, owner);
    pool.withdraw(recipient, withdraw_amount);
    stop_cheat_caller_address(pool.contract_address);

    assert(pool.get_balance() == initial_supply - withdraw_amount, 'Wrong pool balance after');
    assert(token_dispatcher.balance_of(recipient) == withdraw_amount, 'Recipient wrong balance');
}

#[test]
#[should_panic(expected: 'Caller is not the owner')]
fn test_withdraw_not_owner() {
    let owner = contract_address_const::<0x123>();
    let non_owner = contract_address_const::<0x999>();
    let recipient = contract_address_const::<0x456>();
    let max_lock = 10000_u256;

    let token = deploy_mock_token(owner, 100000_u256);
    let pool = deploy_pool(owner, token, max_lock);

    start_cheat_caller_address(pool.contract_address, non_owner);
    pool.withdraw(recipient, 1000_u256);
}

#[test]
#[should_panic(expected: 'Invalid recipient address')]
fn test_withdraw_zero_recipient() {
    let owner = contract_address_const::<0x123>();
    let recipient = contract_address_const::<0x0>();
    let max_lock = 10000_u256;

    let token = deploy_mock_token(owner, 100000_u256);
    let pool = deploy_pool(owner, token, max_lock);

    start_cheat_caller_address(pool.contract_address, owner);
    pool.withdraw(recipient, 1000_u256);
}

#[test]
#[should_panic(expected: 'Amount must be positive')]
fn test_withdraw_zero_amount() {
    let owner = contract_address_const::<0x123>();
    let recipient = contract_address_const::<0x456>();
    let max_lock = 10000_u256;

    let token = deploy_mock_token(owner, 100000_u256);
    let pool = deploy_pool(owner, token, max_lock);

    start_cheat_caller_address(pool.contract_address, owner);
    pool.withdraw(recipient, 0_u256);
}

#[test]
#[should_panic(expected: 'Insufficient pool balance')]
fn test_withdraw_insufficient_balance() {
    let owner = contract_address_const::<0x123>();
    let recipient = contract_address_const::<0x456>();
    let max_lock = 10000_u256;

    let token = deploy_mock_token(owner, 100000_u256);
    let pool = deploy_pool(owner, token, max_lock);

    start_cheat_caller_address(pool.contract_address, owner);
    pool.withdraw(recipient, 1000_u256);
}

#[test]
fn test_withdraw_full_balance() {
    let owner = contract_address_const::<0x123>();
    let recipient = contract_address_const::<0x456>();
    let initial_supply = 100000_u256;
    let max_lock = 10000_u256;

    let token = deploy_mock_token(owner, initial_supply);
    let pool = deploy_pool(owner, token, max_lock);

    let token_dispatcher = IERC20Dispatcher { contract_address: token };
    start_cheat_caller_address(token, owner);
    token_dispatcher.transfer(pool.contract_address, initial_supply);
    stop_cheat_caller_address(token);

    start_cheat_caller_address(pool.contract_address, owner);
    pool.withdraw(recipient, initial_supply);
    stop_cheat_caller_address(pool.contract_address);

    assert(pool.get_balance() == 0, 'Pool should be empty');
    assert(token_dispatcher.balance_of(recipient) == initial_supply, 'Recipient wrong balance');
}

#[test]
fn test_get_balance_empty() {
    let owner = contract_address_const::<0x123>();
    let token = deploy_mock_token(owner, 1000_u256);
    let max_lock = 10000_u256;

    let pool = deploy_pool(owner, token, max_lock);

    assert(pool.get_balance() == 0, 'Balance should be zero');
}

#[test]
fn test_get_balance_after_funding() {
    let owner = contract_address_const::<0x123>();
    let funding_amount = 50000_u256;
    let max_lock = 10000_u256;

    let token = deploy_mock_token(owner, 100000_u256);
    let pool = deploy_pool(owner, token, max_lock);

    let token_dispatcher = IERC20Dispatcher { contract_address: token };
    start_cheat_caller_address(token, owner);
    token_dispatcher.transfer(pool.contract_address, funding_amount);
    stop_cheat_caller_address(token);

    assert(pool.get_balance() == funding_amount, 'Wrong balance');
}

#[test]
fn test_full_lifecycle() {
    let owner = contract_address_const::<0x123>();
    let htlc = contract_address_const::<0x456>();
    let recipient = contract_address_const::<0x789>();
    let initial_supply = 100000_u256;
    let lock_amount = 5000_u256;
    let withdraw_amount = 3000_u256;
    let max_lock = 10000_u256;

    let token = deploy_mock_token(owner, initial_supply);
    let pool = deploy_pool(owner, token, max_lock);
    let token_dispatcher = IERC20Dispatcher { contract_address: token };

    // 1. Fund pool
    start_cheat_caller_address(token, owner);
    token_dispatcher.transfer(pool.contract_address, initial_supply);
    stop_cheat_caller_address(token);
    assert(pool.get_balance() == initial_supply, 'Step 1 failed');

    // 2. Lock for HTLC
    start_cheat_caller_address(pool.contract_address, owner);
    pool.lock_for_htlc(htlc, lock_amount);
    stop_cheat_caller_address(pool.contract_address);
    assert(pool.get_balance() == initial_supply - lock_amount, 'Step 2 failed');

    // 3. Withdraw some funds
    start_cheat_caller_address(pool.contract_address, owner);
    pool.withdraw(recipient, withdraw_amount);
    stop_cheat_caller_address(pool.contract_address);
    assert(
        pool.get_balance() == initial_supply - lock_amount - withdraw_amount, 'Step 3 failed'
    );

    // 4. Update max lock
    let new_max = 20000_u256;
    start_cheat_caller_address(pool.contract_address, owner);
    pool.set_max_lock(new_max);
    stop_cheat_caller_address(pool.contract_address);
    assert(pool.get_max_lock() == new_max, 'Step 4 failed');

    // 5. Verify final balances
    assert(token_dispatcher.balance_of(htlc) == lock_amount, 'HTLC balance wrong');
    assert(token_dispatcher.balance_of(recipient) == withdraw_amount, 'Recipient balance wrong');
}

#[test]
fn test_max_lock_enforcement() {
    let owner = contract_address_const::<0x123>();
    let htlc = contract_address_const::<0x456>();
    let initial_supply = 100000_u256;
    let max_lock = 5000_u256;

    let token = deploy_mock_token(owner, initial_supply);
    let pool = deploy_pool(owner, token, max_lock);

    // Fund pool
    let token_dispatcher = IERC20Dispatcher { contract_address: token };
    start_cheat_caller_address(token, owner);
    token_dispatcher.transfer(pool.contract_address, initial_supply);
    stop_cheat_caller_address(token);

    // Lock at max limit (should succeed)
    start_cheat_caller_address(pool.contract_address, owner);
    pool.lock_for_htlc(htlc, max_lock);
    stop_cheat_caller_address(pool.contract_address);
    assert(token_dispatcher.balance_of(htlc) == max_lock, 'Max lock failed');

    // Increase max lock
    let new_max = 10000_u256;
    start_cheat_caller_address(pool.contract_address, owner);
    pool.set_max_lock(new_max);
    stop_cheat_caller_address(pool.contract_address);

    // Now can lock more
    let htlc2 = contract_address_const::<0xABC>();
    start_cheat_caller_address(pool.contract_address, owner);
    pool.lock_for_htlc(htlc2, new_max);
    stop_cheat_caller_address(pool.contract_address);
    assert(token_dispatcher.balance_of(htlc2) == new_max, 'New max lock failed');
}
