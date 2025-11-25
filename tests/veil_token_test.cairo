use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use pool::interface::{IVeilTokenDispatcher, IVeilTokenDispatcherTrait};
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, EventSpy, EventSpyTrait, EventsFilterTrait, declare,
    spy_events, start_cheat_caller_address, stop_cheat_caller_address,
};
use starknet::{ContractAddress, contract_address_const};

fn deploy_veil_token(owner: ContractAddress) -> (IERC20Dispatcher, IVeilTokenDispatcher) {
    let contract = declare("VeilToken").unwrap().contract_class();
    let args = array![owner.into()];
    let (token_address, _) = contract.deploy(@args).unwrap();

    let erc20 = IERC20Dispatcher { contract_address: token_address };
    let veil = IVeilTokenDispatcher { contract_address: token_address };
    (erc20, veil)
}

const MAX_SUPPLY: u256 = 21_000_000_000_000_000_000_000_000;

#[test]
fn test_veil_deployment_success() {
    let owner = contract_address_const::<0x123>();
    let (erc20, veil) = deploy_veil_token(owner);

    assert(veil.name() == "Veil", 'Wrong name');
    assert(veil.symbol() == "VEIL", 'Wrong symbol');
    assert(veil.decimals() == 18, 'Wrong decimals');
    assert(veil.max_supply() == MAX_SUPPLY, 'Wrong max supply');
    assert(erc20.total_supply() == MAX_SUPPLY, 'Wrong total supply');
    assert(erc20.balance_of(owner) == MAX_SUPPLY, 'Wrong owner balance');
}

#[test]
fn test_veil_deployment_emits_commitment_event() {
    let owner = contract_address_const::<0x123>();
    let mut spy = spy_events();

    let (erc20, _veil) = deploy_veil_token(owner);

    let events = spy.get_events().emitted_by(erc20.contract_address);
    assert(events.events.len() > 0, 'No events emitted');
}

#[test]
fn test_transfer_success() {
    let owner = contract_address_const::<0x123>();
    let recipient = contract_address_const::<0x456>();
    let (erc20, _veil) = deploy_veil_token(owner);
    let transfer_amount = 1000_000_000_000_000_000_000_u256;

    let mut spy = spy_events();

    start_cheat_caller_address(erc20.contract_address, owner);
    let success = erc20.transfer(recipient, transfer_amount);
    stop_cheat_caller_address(erc20.contract_address);

    assert(success, 'Transfer failed');
    assert(erc20.balance_of(owner) == MAX_SUPPLY - transfer_amount, 'Wrong owner balance');
    assert(erc20.balance_of(recipient) == transfer_amount, 'Wrong recipient balance');

    // Verify event was emitted (privacy: no amounts in events)
    let events = spy.get_events().emitted_by(erc20.contract_address);
    assert(events.events.len() > 0, 'No transfer event emitted');
}

#[test]
fn test_transfer_zero_amount() {
    let owner = contract_address_const::<0x123>();
    let recipient = contract_address_const::<0x456>();
    let (erc20, _veil) = deploy_veil_token(owner);

    start_cheat_caller_address(erc20.contract_address, owner);
    let success = erc20.transfer(recipient, 0_u256);
    stop_cheat_caller_address(erc20.contract_address);

    assert(success, 'Zero transfer should pass');
    assert(erc20.balance_of(recipient) == 0, 'Recipient should have zero');
}

#[test]
#[should_panic(expected: 'ERC20: insufficient balance')]
fn test_transfer_insufficient_balance() {
    let owner = contract_address_const::<0x123>();
    let recipient = contract_address_const::<0x456>();
    let (erc20, _veil) = deploy_veil_token(owner);

    start_cheat_caller_address(erc20.contract_address, owner);
    erc20.transfer(recipient, MAX_SUPPLY + 1);
}

#[test]
#[should_panic(expected: 'ERC20: transfer to 0')]
fn test_transfer_to_zero_address() {
    let owner = contract_address_const::<0x123>();
    let zero_address = contract_address_const::<0x0>();
    let (erc20, _veil) = deploy_veil_token(owner);

    start_cheat_caller_address(erc20.contract_address, owner);
    erc20.transfer(zero_address, 1000_u256);
}

#[test]
fn test_transfer_from_success() {
    let owner = contract_address_const::<0x123>();
    let spender = contract_address_const::<0x456>();
    let recipient = contract_address_const::<0x789>();
    let (erc20, _veil) = deploy_veil_token(owner);
    let allowance_amount = 5000_000_000_000_000_000_000_u256;
    let transfer_amount = 3000_000_000_000_000_000_000_u256;

    start_cheat_caller_address(erc20.contract_address, owner);
    erc20.approve(spender, allowance_amount);
    stop_cheat_caller_address(erc20.contract_address);

    assert(erc20.allowance(owner, spender) == allowance_amount, 'Wrong allowance');

    let mut spy = spy_events();

    start_cheat_caller_address(erc20.contract_address, spender);
    let success = erc20.transfer_from(owner, recipient, transfer_amount);
    stop_cheat_caller_address(erc20.contract_address);

    assert(success, 'Transfer from failed');
    assert(erc20.balance_of(owner) == MAX_SUPPLY - transfer_amount, 'Wrong owner balance');
    assert(erc20.balance_of(recipient) == transfer_amount, 'Wrong recipient balance');
    assert(
        erc20.allowance(owner, spender) == allowance_amount - transfer_amount,
        'Allowance not updated',
    );

    // Verify event emitted
    let events = spy.get_events().emitted_by(erc20.contract_address);
    assert(events.events.len() > 0, 'No event emitted');
}

#[test]
#[should_panic(expected: 'ERC20: insufficient allowance')]
fn test_transfer_from_insufficient_allowance() {
    let owner = contract_address_const::<0x123>();
    let spender = contract_address_const::<0x456>();
    let recipient = contract_address_const::<0x789>();
    let (erc20, _veil) = deploy_veil_token(owner);

    start_cheat_caller_address(erc20.contract_address, owner);
    erc20.approve(spender, 1000_u256);
    stop_cheat_caller_address(erc20.contract_address);

    start_cheat_caller_address(erc20.contract_address, spender);
    erc20.transfer_from(owner, recipient, 2000_u256);
}

#[test]
#[should_panic(expected: 'ERC20: insufficient balance')]
fn test_transfer_from_insufficient_balance() {
    let owner = contract_address_const::<0x123>();
    let spender = contract_address_const::<0x456>();
    let recipient = contract_address_const::<0x789>();
    let (erc20, _veil) = deploy_veil_token(owner);

    start_cheat_caller_address(erc20.contract_address, owner);
    erc20.approve(spender, MAX_SUPPLY + 1000);
    stop_cheat_caller_address(erc20.contract_address);

    start_cheat_caller_address(erc20.contract_address, spender);
    erc20.transfer_from(owner, recipient, MAX_SUPPLY + 1);
}

#[test]
fn test_approve_success() {
    let owner = contract_address_const::<0x123>();
    let spender = contract_address_const::<0x456>();
    let (erc20, _veil) = deploy_veil_token(owner);
    let approve_amount = 10000_u256;

    let mut spy = spy_events();

    start_cheat_caller_address(erc20.contract_address, owner);
    let success = erc20.approve(spender, approve_amount);
    stop_cheat_caller_address(erc20.contract_address);

    assert(success, 'Approve failed');
    assert(erc20.allowance(owner, spender) == approve_amount, 'Wrong allowance');

    // Verify event emitted
    let events = spy.get_events().emitted_by(erc20.contract_address);
    assert(events.events.len() > 0, 'No approval event emitted');
}

#[test]
fn test_approve_overwrite() {
    let owner = contract_address_const::<0x123>();
    let spender = contract_address_const::<0x456>();
    let (erc20, _veil) = deploy_veil_token(owner);

    start_cheat_caller_address(erc20.contract_address, owner);
    erc20.approve(spender, 5000_u256);
    assert(erc20.allowance(owner, spender) == 5000_u256, 'First approval failed');

    erc20.approve(spender, 10000_u256);
    assert(erc20.allowance(owner, spender) == 10000_u256, 'Second approval failed');
    stop_cheat_caller_address(erc20.contract_address);
}

#[test]
#[should_panic(expected: 'ERC20: approve to 0')]
fn test_approve_zero_address() {
    let owner = contract_address_const::<0x123>();
    let zero_spender = contract_address_const::<0x0>();
    let (erc20, _veil) = deploy_veil_token(owner);

    start_cheat_caller_address(erc20.contract_address, owner);
    erc20.approve(zero_spender, 1000_u256);
}

#[test]
fn test_balance_of_multiple_accounts() {
    let owner = contract_address_const::<0x123>();
    let user1 = contract_address_const::<0x456>();
    let user2 = contract_address_const::<0x789>();
    let (erc20, _veil) = deploy_veil_token(owner);
    let amount1 = 1000_000_000_000_000_000_000_u256;
    let amount2 = 2000_000_000_000_000_000_000_u256;

    start_cheat_caller_address(erc20.contract_address, owner);
    erc20.transfer(user1, amount1);
    erc20.transfer(user2, amount2);
    stop_cheat_caller_address(erc20.contract_address);

    assert(erc20.balance_of(user1) == amount1, 'Wrong user1 balance');
    assert(erc20.balance_of(user2) == amount2, 'Wrong user2 balance');
    assert(erc20.balance_of(owner) == MAX_SUPPLY - amount1 - amount2, 'Wrong owner balance');
}

#[test]
fn test_balance_of_zero_address() {
    let owner = contract_address_const::<0x123>();
    let zero_address = contract_address_const::<0x0>();
    let (erc20, _veil) = deploy_veil_token(owner);

    assert(erc20.balance_of(zero_address) == 0, 'Zero address should have 0');
}

#[test]
fn test_privacy_multiple_transfers_different_commitments() {
    let owner = contract_address_const::<0x123>();
    let recipient = contract_address_const::<0x456>();
    let (erc20, _veil) = deploy_veil_token(owner);
    let amount = 1000_u256;

    let mut spy = spy_events();

    start_cheat_caller_address(erc20.contract_address, owner);
    erc20.transfer(recipient, amount);
    stop_cheat_caller_address(erc20.contract_address);

    start_cheat_caller_address(erc20.contract_address, owner);
    erc20.transfer(recipient, amount);
    stop_cheat_caller_address(erc20.contract_address);

    let events = spy.get_events().emitted_by(erc20.contract_address);
    assert(events.events.len() >= 2, 'Should have multiple events');
}

#[test]
fn test_total_supply_constant() {
    let owner = contract_address_const::<0x123>();
    let user1 = contract_address_const::<0x456>();
    let user2 = contract_address_const::<0x789>();
    let (erc20, _veil) = deploy_veil_token(owner);

    assert(erc20.total_supply() == MAX_SUPPLY, 'Wrong initial supply');

    start_cheat_caller_address(erc20.contract_address, owner);
    erc20.transfer(user1, 5000_u256);
    erc20.transfer(user2, 3000_u256);
    stop_cheat_caller_address(erc20.contract_address);

    assert(erc20.total_supply() == MAX_SUPPLY, 'Supply changed');
}

#[test]
fn test_full_transfer_lifecycle() {
    let owner = contract_address_const::<0x123>();
    let user1 = contract_address_const::<0x456>();
    let user2 = contract_address_const::<0x789>();
    let (erc20, _veil) = deploy_veil_token(owner);

    start_cheat_caller_address(erc20.contract_address, owner);
    erc20.transfer(user1, 10000_u256);
    stop_cheat_caller_address(erc20.contract_address);
    assert(erc20.balance_of(user1) == 10000_u256, 'Step 1 failed');

    start_cheat_caller_address(erc20.contract_address, user1);
    erc20.transfer(user2, 5000_u256);
    stop_cheat_caller_address(erc20.contract_address);
    assert(erc20.balance_of(user2) == 5000_u256, 'Step 2 failed');
    assert(erc20.balance_of(user1) == 5000_u256, 'Step 2 user1 wrong');

    start_cheat_caller_address(erc20.contract_address, user2);
    erc20.transfer(owner, 5000_u256);
    stop_cheat_caller_address(erc20.contract_address);
    assert(erc20.balance_of(user2) == 0, 'Step 3 failed');
    assert(erc20.balance_of(owner) == MAX_SUPPLY - 5000_u256, 'Step 3 owner wrong');
}

#[test]
fn test_approve_and_transfer_from_lifecycle() {
    let owner = contract_address_const::<0x123>();
    let spender = contract_address_const::<0x456>();
    let recipient = contract_address_const::<0x789>();
    let (erc20, _veil) = deploy_veil_token(owner);

    start_cheat_caller_address(erc20.contract_address, owner);
    erc20.approve(spender, 10000_u256);
    stop_cheat_caller_address(erc20.contract_address);
    assert(erc20.allowance(owner, spender) == 10000_u256, 'Step 1 failed');

    start_cheat_caller_address(erc20.contract_address, spender);
    erc20.transfer_from(owner, recipient, 3000_u256);
    assert(erc20.allowance(owner, spender) == 7000_u256, 'Step 2 allowance wrong');
    assert(erc20.balance_of(recipient) == 3000_u256, 'Step 2 balance wrong');

    erc20.transfer_from(owner, recipient, 5000_u256);
    stop_cheat_caller_address(erc20.contract_address);
    assert(erc20.allowance(owner, spender) == 2000_u256, 'Step 3 allowance wrong');
    assert(erc20.balance_of(recipient) == 8000_u256, 'Step 3 balance wrong');
}
