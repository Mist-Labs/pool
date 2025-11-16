#[starknet::contract]
pub mod Pool {
    use core::num::traits::Zero;
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use pool::interface::IBridgePool;
    use starknet::event::EventEmitter;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address, get_contract_address};

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    impl OwnableImpl = OwnableComponent::OwnableImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        token: ContractAddress,
        max_single_lock: u256,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        FundsLocked: FundsLocked,
        FundsReceived: FundsReceived,
        FundsWithdrawn: FundsWithdrawn,
        MaxLockUpdated: MaxLockUpdated,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
    }

    #[derive(Drop, starknet::Event)]
    struct FundsLocked {
        htlc: ContractAddress,
        amount: u256,
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct FundsReceived {
        from: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct FundsWithdrawn {
        to: ContractAddress,
        amount: u256,
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct MaxLockUpdated {
        old_max: u256,
        new_max: u256,
    }


    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        token: ContractAddress,
        max_single_lock: u256,
    ) {
        assert(owner.is_non_zero(), 'Invalid owner');
        assert(token.is_non_zero(), 'Invalid token');
        assert(max_single_lock > 0, 'Max lock must be positive');

        self.ownable.initializer(owner);
        self.token.write(token);
        self.max_single_lock.write(max_single_lock);
    }

    #[abi(embed_v0)]
    impl BridgePoolImpl of IBridgePool<ContractState> {
        fn lock_for_htlc(ref self: ContractState, htlc_address: ContractAddress, amount: u256) {
            self.ownable.assert_only_owner();

            assert(htlc_address.is_non_zero(), 'Invalid HTLC address');
            assert(amount > 0, 'Amount must be positive');
            assert(amount <= self.max_single_lock.read(), 'Exceeds max lock amount');

            let token = IERC20Dispatcher { contract_address: self.token.read() };
            let balance = token.balance_of(get_contract_address());
            assert(balance >= amount, 'Insufficient pool balance');

            token.transfer(htlc_address, amount);

            self.emit(FundsLocked { htlc: htlc_address, amount, timestamp: get_block_timestamp() });
        }

        fn get_balance(self: @ContractState) -> u256 {
            let token = IERC20Dispatcher { contract_address: self.token.read() };
            token.balance_of(get_contract_address())
        }

        fn set_max_lock(ref self: ContractState, new_max: u256) {
            self.ownable.assert_only_owner();

            assert(new_max > 0, 'Max lock must be positive');

            let old_max = self.max_single_lock.read();
            self.max_single_lock.write(new_max);

            self.emit(MaxLockUpdated { old_max, new_max });
        }

        fn withdraw(ref self: ContractState, to: ContractAddress, amount: u256) {
            self.ownable.assert_only_owner();

            assert(to.is_non_zero(), 'Invalid recipient address');
            assert(amount > 0, 'Amount must be positive');

            let token = IERC20Dispatcher { contract_address: self.token.read() };
            let balance = token.balance_of(get_contract_address());
            assert(balance >= amount, 'Insufficient pool balance');

            token.transfer(to, amount);

            self.emit(FundsWithdrawn { to, amount, timestamp: get_block_timestamp() });
        }

        fn get_max_lock(self: @ContractState) -> u256 {
            self.max_single_lock.read()
        }
    }
}
