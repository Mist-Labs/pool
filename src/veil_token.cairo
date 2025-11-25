#[starknet::contract]
pub mod VeilToken {
    use core::hash::HashStateTrait;
    use core::num::traits::Zero;
    use core::poseidon::PoseidonTrait;
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::token::erc20::interface::IERC20;
    use pool::interface::IVeilToken;
    use starknet::event::EventEmitter;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address};

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    const MAX_SUPPLY: u256 = 21_000_000_000_000_000_000_000_000; // 21M * 10^18

    #[storage]
    struct Storage {
        name: ByteArray,
        symbol: ByteArray,
        decimals: u8,
        total_supply: u256,
        balances: Map<ContractAddress, u256>,
        allowances: Map<(ContractAddress, ContractAddress), u256>,
        transfer_nonces: Map<ContractAddress, u256>,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
    }


    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        TransferCommitment: TransferCommitment,
        ApprovalCommitment: ApprovalCommitment,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
    }


    #[derive(Drop, starknet::Event)]
    pub struct TransferCommitment {
        #[key]
        pub from_commitment: felt252,
        #[key]
        pub to_commitment: felt252,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ApprovalCommitment {
        #[key]
        pub owner_commitment: felt252,
        #[key]
        pub spender_commitment: felt252,
        pub timestamp: u64,
    }


    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        assert(owner.is_non_zero(), 'Invalid owner');

        self.name.write("Veil");
        self.symbol.write("VEIL");
        self.decimals.write(18);

        self.total_supply.write(MAX_SUPPLY);
        self.balances.write(owner, MAX_SUPPLY);

        self.ownable.initializer(owner);

        let owner_commitment = self.generate_commitment(owner);
        let zero_commitment = self.generate_commitment(Zero::zero());

        self
            .emit(
                TransferCommitment {
                    from_commitment: zero_commitment,
                    to_commitment: owner_commitment,
                    timestamp: get_block_timestamp(),
                },
            );
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn generate_commitment(ref self: ContractState, address: ContractAddress) -> felt252 {
            let nonce = self.transfer_nonces.read(address);
            self.transfer_nonces.write(address, nonce + 1);

            PoseidonTrait::new()
                .update(address.into())
                .update(nonce.try_into().unwrap())
                .update(get_block_timestamp().into())
                .finalize()
        }

        fn transfer_internal(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256,
        ) {
            assert(sender.is_non_zero(), 'ERC20: transfer from 0');
            assert(recipient.is_non_zero(), 'ERC20: transfer to 0');

            let sender_balance = self.balances.read(sender);
            assert(sender_balance >= amount, 'ERC20: insufficient balance');

            self.balances.write(sender, sender_balance - amount);
            let recipient_balance = self.balances.read(recipient);
            self.balances.write(recipient, recipient_balance + amount);

            let from_commitment = self.generate_commitment(sender);
            let to_commitment = self.generate_commitment(recipient);
            self
                .emit(
                    TransferCommitment {
                        from_commitment, to_commitment, timestamp: get_block_timestamp(),
                    },
                );
        }
    }

    #[abi(embed_v0)]
    impl ERC20Impl of IERC20<ContractState> {
        fn total_supply(self: @ContractState) -> u256 {
            self.total_supply.read()
        }

        fn balance_of(self: @ContractState, account: ContractAddress) -> u256 {
            self.balances.read(account)
        }

        fn allowance(
            self: @ContractState, owner: ContractAddress, spender: ContractAddress,
        ) -> u256 {
            self.allowances.read((owner, spender))
        }

        fn transfer(ref self: ContractState, recipient: ContractAddress, amount: u256) -> bool {
            let sender = get_caller_address();
            InternalFunctions::transfer_internal(ref self, sender, recipient, amount);
            true
        }

        fn transfer_from(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256,
        ) -> bool {
            let caller = get_caller_address();
            let current_allowance = self.allowances.read((sender, caller));

            assert(current_allowance >= amount, 'ERC20: insufficient allowance');

            self.allowances.write((sender, caller), current_allowance - amount);

            InternalFunctions::transfer_internal(ref self, sender, recipient, amount);
            true
        }

        fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) -> bool {
            let owner = get_caller_address();

            assert(spender.is_non_zero(), 'ERC20: approve to 0');

            self.allowances.write((owner, spender), amount);

            let owner_commitment = InternalFunctions::generate_commitment(ref self, owner);
            let spender_commitment = InternalFunctions::generate_commitment(ref self, spender);
            self
                .emit(
                    ApprovalCommitment {
                        owner_commitment, spender_commitment, timestamp: get_block_timestamp(),
                    },
                );

            true
        }
    }

    #[abi(embed_v0)]
    impl VeilTokenImpl of IVeilToken<ContractState> {
        fn name(self: @ContractState) -> ByteArray {
            self.name.read()
        }

        fn symbol(self: @ContractState) -> ByteArray {
            self.symbol.read()
        }

        fn decimals(self: @ContractState) -> u8 {
            self.decimals.read()
        }

        fn max_supply(self: @ContractState) -> u256 {
            MAX_SUPPLY
        }
    }
}
