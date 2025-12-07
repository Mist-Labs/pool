#[starknet::contract]
pub mod FastPool {
    use core::hash::{HashStateExTrait, HashStateTrait};
    use core::num::traits::Zero;
    use core::poseidon::PoseidonTrait;
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::security::reentrancyguard::ReentrancyGuardComponent;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use pool::interface::IShieldedPool;
    use starknet::event::EventEmitter;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address, get_contract_address};

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: ReentrancyGuardComponent, storage: reentrancy, event: ReentrancyGuardEvent);

    impl InternalImpl = ReentrancyGuardComponent::InternalImpl<ContractState>;
    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    const ROOT_HISTORY_SIZE: u32 = 100;
    const MAX_DEPOSIT_AMOUNT: u256 = 10000000000000000000000; // $10K equivalent in wei

    #[storage]
    struct Storage {
        supported_tokens: Map<ContractAddress, bool>,
        nullifiers: Map<felt252, bool>,
        current_root: felt252,
        root_history: Map<u32, felt252>,
        root_history_index: u32,
        known_roots: Map<felt252, bool>,
        next_leaf_index: u32,
        pool_type: felt252,
        htlcs: Map<felt252, VirtualHTLC>,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        reentrancy: ReentrancyGuardComponent::Storage,
    }

    #[derive(Copy, Serde, Drop, starknet::Store)]
    pub struct VirtualHTLC {
        pub root: felt252,
        pub token: ContractAddress,
        pub hash_lock: felt252,
        pub timelock: u64,
        pub amount: u256,
        pub state: u8,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        Deposit: Deposit,
        HTLCCreated: HTLCCreated,
        Withdrawal: Withdrawal,
        MerkleRootUpdated: MerkleRootUpdated,
        TokenAdded: TokenAdded,
        TokenRemoved: TokenRemoved,
        EmergencyWithdraw: EmergencyWithdraw,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        ReentrancyGuardEvent: ReentrancyGuardComponent::Event,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Deposit {
        #[key]
        pub commitment: felt252,
        pub leaf_index: u32,
        pub pool_type: felt252,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct HTLCCreated {
        #[key]
        pub nullifier: felt252,
        pub hash_lock: felt252,
        pub timelock: u64,
        pub pool_type: felt252,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Withdrawal {
        #[key]
        pub nullifier: felt252,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct MerkleRootUpdated {
        pub old_root: felt252,
        pub new_root: felt252,
        pub leaf_count: u32,
    }

    #[derive(Drop, starknet::Event)]
    pub struct TokenAdded {
        #[key]
        pub token: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct TokenRemoved {
        #[key]
        pub token: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct EmergencyWithdraw {
        #[key]
        pub token: ContractAddress,
        pub to: ContractAddress,
        pub amount: u256,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        assert(owner.is_non_zero(), 'Invalid owner');
        self.ownable.initializer(owner);
        self.current_root.write(0);
        self.root_history_index.write(0);
        self.next_leaf_index.write(0);
        self.pool_type.write('0');
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn verify_secret_hash(self: @ContractState, secret: felt252, hash_lock: felt252) -> bool {
            let computed = PoseidonTrait::new().update(secret).finalize();
            computed == hash_lock
        }

        fn verify_merkle_proof(
            self: @ContractState,
            leaf: felt252,
            proof: Span<felt252>,
            path_indices: Span<u8>,
            root: felt252,
        ) -> bool {
            let mut current_hash = leaf;
            let mut i: usize = 0;

            let proof_len = proof.len();

            while i < proof_len {
                let proof_element = *proof.at(i);
                let is_left = *path_indices.at(i) == 0;

                current_hash =
                    if is_left {
                        PoseidonTrait::new().update(current_hash).update(proof_element).finalize()
                    } else {
                        PoseidonTrait::new().update(proof_element).update(current_hash).finalize()
                    };

                i += 1;
            }

            current_hash == root
        }

        fn is_known_root(self: @ContractState, root: felt252) -> bool {
            if root == self.current_root.read() {
                return true;
            }
            self.known_roots.read(root)
        }

        fn add_root_to_history(ref self: ContractState, root: felt252) {
            let current_index = self.root_history_index.read();
            self.root_history.write(current_index, root);
            self.known_roots.write(root, true);

            let next_index = (current_index + 1) % ROOT_HISTORY_SIZE;

            if next_index < current_index {
                let old_root = self.root_history.read(next_index);
                if old_root != 0 {
                    self.known_roots.write(old_root, false);
                }
            }

            self.root_history_index.write(next_index);
        }
    }

    #[abi(embed_v0)]
    impl ShieldedPoolImpl of IShieldedPool<ContractState> {
        fn deposit(
            ref self: ContractState, token: ContractAddress, commitment: felt252, amount: u256,
        ) {
            self.reentrancy.start();

            assert(self.supported_tokens.read(token), 'Token not supported');
            assert(commitment != 0, 'Invalid commitment');
            assert(amount > 0, 'Zero amount');
            assert(amount <= MAX_DEPOSIT_AMOUNT, 'Amount exceeds limit');

            let token_dispatcher = IERC20Dispatcher { contract_address: token };
            let caller = get_caller_address();
            let success = token_dispatcher.transfer_from(caller, get_contract_address(), amount);
            assert(success, 'Transfer failed');

            let pool_type = self.pool_type.read();
            let leaf_index = self.next_leaf_index.read();
            self.emit(Deposit { commitment, leaf_index, pool_type, timestamp: get_block_timestamp() });

            self.next_leaf_index.write(leaf_index + 1);

            self.reentrancy.end();
        }

        fn create_htlc(
            ref self: ContractState,
            token: ContractAddress,
            nullifier: felt252,
            root: felt252,
            commitment: felt252,
            amount: u256,
            merkle_proof: Span<felt252>,
            path_indices: Span<u8>,
            hash_lock: felt252,
            timelock: u64,
        ) {
            self.reentrancy.start();

            self.ownable.assert_only_owner();

            assert(self.supported_tokens.read(token), 'Token not supported');
            assert(nullifier != 0, 'Invalid nullifier');
            assert(commitment != 0, 'Invalid commitment');
            assert(hash_lock != 0, 'Invalid hash lock');
            assert(amount > 0, 'Invalid amount');
            assert(amount <= MAX_DEPOSIT_AMOUNT, 'Amount exceeds limit');

            assert(!self.nullifiers.read(nullifier), 'Nullifier spent');

            assert(InternalFunctions::is_known_root(@self, root), 'Unknown root');

            assert(
                InternalFunctions::verify_merkle_proof(
                    @self, commitment, merkle_proof, path_indices, root,
                ),
                'Invalid merkle proof',
            );

            let now = get_block_timestamp();
            assert(timelock > now + 3600, 'Timelock too short');
            assert(timelock < now + 604800, 'Timelock too long');

            let htlc = VirtualHTLC { root, token, hash_lock, timelock, amount, state: 0 };

            self.htlcs.write(nullifier, htlc);
            let pool_type = self.pool_type.read();

            self
                .emit(
                    HTLCCreated {
                        nullifier, hash_lock, timelock, pool_type, timestamp: get_block_timestamp(),
                    },
                );

            self.reentrancy.end();
        }

         fn withdraw(
            ref self: ContractState,
            token: ContractAddress,
            nullifier: felt252,
            recipient: ContractAddress,
            secret: Option<felt252>,
        ) {
            self.reentrancy.start();

            self.ownable.assert_only_owner();

            assert(self.supported_tokens.read(token), 'Token not supported');
            assert(nullifier != 0, 'Invalid nullifier');
            assert(recipient.is_non_zero(), 'Invalid recipient');

            assert(!self.nullifiers.read(nullifier), 'Already spent');

            let htlc = self.htlcs.read(nullifier);
            assert(htlc.state == 0, 'Inactive HTLC');
            assert(token == htlc.token, 'Token mismatch');

            let now = get_block_timestamp();

            match secret {
                Option::Some(s) => {
                    assert(htlc.timelock > now, 'HTLC expired');
                    assert(
                        InternalFunctions::verify_secret_hash(@self, s, htlc.hash_lock),
                        'Invalid secret',
                    );
                },
                Option::None => { 
                    assert(htlc.timelock <= now, 'HTLC not expired'); 
                },
            }

            self.nullifiers.write(nullifier, true);

            let new_state = if secret.is_some() { 1 } else { 2 };
            let updated_htlc = VirtualHTLC {
                root: htlc.root,
                token: htlc.token,
                hash_lock: htlc.hash_lock,
                timelock: htlc.timelock,
                amount: htlc.amount,
                state: new_state,
            };
            self.htlcs.write(nullifier, updated_htlc);

            let token_dispatcher = IERC20Dispatcher { contract_address: token };
            let success = token_dispatcher.transfer(recipient, htlc.amount);
            assert(success, 'Transfer failed');

            self.emit(Withdrawal { nullifier, timestamp: get_block_timestamp() });

            self.reentrancy.end();
        }

        fn update_merkle_root(ref self: ContractState, new_root: felt252) {
            self.ownable.assert_only_owner();
            assert(new_root != 0, 'Invalid root');

            let old_root = self.current_root.read();
            
            if old_root != 0 {
                InternalFunctions::add_root_to_history(ref self, old_root);
            }

            self.current_root.write(new_root);
            self.known_roots.write(new_root, true);

            let leaf_count = self.next_leaf_index.read();

            self.emit(MerkleRootUpdated { 
                old_root, 
                new_root, 
                leaf_count 
            });
        }

        fn add_supported_token(ref self: ContractState, token: ContractAddress) {
            self.ownable.assert_only_owner();
            assert(token.is_non_zero(), 'Invalid token');
            assert(!self.supported_tokens.read(token), 'Token already supported');

            self.supported_tokens.write(token, true);
            self.emit(TokenAdded { token });
        }

        fn remove_supported_token(ref self: ContractState, token: ContractAddress) {
            self.ownable.assert_only_owner();
            assert(self.supported_tokens.read(token), 'Token not supported');

            self.supported_tokens.write(token, false);
            self.emit(TokenRemoved { token });
        }

        fn emergency_withdraw(
            ref self: ContractState, 
            token: ContractAddress, 
            to: ContractAddress, 
            amount: u256,
        ) {
            self.ownable.assert_only_owner();
            assert(self.supported_tokens.read(token), 'Token not supported');
            assert(to.is_non_zero(), 'Invalid recipient');
            assert(amount > 0, 'Zero amount');

            let token_dispatcher = IERC20Dispatcher { contract_address: token };
            let balance = token_dispatcher.balance_of(get_contract_address());
            assert(balance >= amount, 'Insufficient balance');

            let success = token_dispatcher.transfer(to, amount);
            assert(success, 'Transfer failed');

            self.emit(EmergencyWithdraw { token, to, amount });
        }

        fn is_token_supported(self: @ContractState, token: ContractAddress) -> bool {
            self.supported_tokens.read(token)
        }

        fn is_nullifier_spent(self: @ContractState, nullifier: felt252) -> bool {
            self.nullifiers.read(nullifier)
        }

        fn is_known_root(self: @ContractState, root: felt252) -> bool {
            InternalFunctions::is_known_root(self, root)
        }

        fn get_current_root(self: @ContractState) -> felt252 {
            self.current_root.read()
        }

        fn get_next_leaf_index(self: @ContractState) -> u32 {
            self.next_leaf_index.read()
        }

        fn get_htlc(
            self: @ContractState, nullifier: felt252
        ) -> (felt252, ContractAddress, felt252, u64, u256, u8) {
            let htlc = self.htlcs.read(nullifier);
            (htlc.root, htlc.token, htlc.hash_lock, htlc.timelock, htlc.amount, htlc.state)
        }

        fn get_balance(self: @ContractState, token: ContractAddress) -> u256 {
            let token_dispatcher = IERC20Dispatcher { contract_address: token };
            token_dispatcher.balance_of(get_contract_address())
        }

    }
}
