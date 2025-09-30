use starknet::ContractAddress;
#[starknet::interface]
pub trait IBtcYield<TContractState> {
    // --- Staking ---
    fn deposit_wbtc_to_external(ref self: TContractState, amount: u256);
    fn withdraw(ref self: TContractState, amount: u256);


    fn pool_balance(self: @TContractState) -> u256;
    fn total_stake(self: @TContractState) -> u256;
    fn stake_of(self: @TContractState, user: ContractAddress) -> u256;
}

#[starknet::interface]
trait IERC4626<TContractState> {
    fn asset(self: @TContractState) -> ContractAddress;
    fn total_assets(self: @TContractState) -> u256;
    fn convert_to_shares(self: @TContractState, assets: u256) -> u256;
    fn convert_to_assets(self: @TContractState, shares: u256) -> u256;
    fn max_deposit(self: @TContractState, receiver: ContractAddress) -> u256;
    fn preview_deposit(self: @TContractState, assets: u256) -> u256;
    fn deposit(ref self: TContractState, assets: u256, receiver: ContractAddress) -> u256;
    fn max_mint(self: @TContractState, receiver: ContractAddress) -> u256;
    fn preview_mint(self: @TContractState, shares: u256) -> u256;
    fn mint(ref self: TContractState, shares: u256, receiver: ContractAddress) -> u256;
    fn max_withdraw(self: @TContractState, owner: ContractAddress) -> u256;
    fn preview_withdraw(self: @TContractState, assets: u256) -> u256;
    fn withdraw(
        ref self: TContractState, assets: u256, receiver: ContractAddress, owner: ContractAddress,
    ) -> u256;
    fn max_redeem(self: @TContractState, owner: ContractAddress) -> u256;
    fn preview_redeem(self: @TContractState, shares: u256) -> u256;
    fn redeem(
        ref self: TContractState, shares: u256, receiver: ContractAddress, owner: ContractAddress,
    ) -> u256;
}

#[starknet::contract]
pub mod BtcYield {
    use openzeppelin_access::ownable::OwnableComponent;
    use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use super::{IBtcYield, IERC4626Dispatcher, IERC4626DispatcherTrait};

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    pub const FELT_STRK_CONTRACT: felt252 =
        0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d;

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        OwnableEvent: OwnableComponent::Event,
    }
    #[storage]
    struct Storage {
        pool_token: ContractAddress,
        pool_balance: u256,
        total_stake: u256,
        stakes: Map<ContractAddress, u256>,
        claim_count: u256,
        claim_submitter: Map<u256, ContractAddress>,
        claim_amount: Map<u256, u256>,
        claim_description: Map<u256, ByteArray>,
        claim_open: Map<u256, bool>,
        claim_finalized: Map<u256, bool>,
        claim_yes: Map<u256, u256>,
        claim_no: Map<u256, u256>,
        voted: Map<(u256, ContractAddress), bool>,
        governance_threshold_pct: u64,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress, pool_token: ContractAddress) {
        self.pool_token.write(pool_token);
        self.governance_threshold_pct.write(51);
        self.pool_balance.write(0);
        self.total_stake.write(0);
        self.claim_count.write(0);
        self.ownable.initializer(owner);
    }

    // --------------------
    // Implement Interface
    // --------------------
    #[abi(embed_v0)]
    impl BtcYieldImpl of IBtcYield<ContractState> {
        fn deposit_wbtc_to_external(ref self: ContractState, amount: u256) {
            let caller = get_caller_address();
            let address_as_felt: felt252 =
                0x04861ba938aed21f2cd7740acd3765ac4d2974783a3218367233de0153490cb6;

            // Step 1: Pull WBTC from caller
            let wbtc_token = IERC20Dispatcher {
                contract_address: address_as_felt.try_into().unwrap(),
            };
            wbtc_token.transfer_from(caller, get_contract_address(), amount);
            // Step 2: Approve external yield contract
            let external_contract_address: felt252 =
                0x033d52ef1746ab58c5a22f8e4d80eaaf7c5a08fcfaa6c5e5365680d0ed482f34;
            wbtc_token.approve(external_contract_address.try_into().unwrap(), amount);

            // Step 3: Call deposit on external contract
            let external_contract = IERC4626Dispatcher {
                contract_address: external_contract_address.try_into().unwrap(),
            };
            external_contract.deposit(amount, get_contract_address());

            // Optional: update internal accounting if needed
            let prev_stake = self.stakes.read(caller);
            self.stakes.write(caller, prev_stake + amount);
            self.total_stake.write(self.total_stake.read() + amount);
            self.pool_balance.write(self.pool_balance.read() + amount);
        }

        fn withdraw(ref self: ContractState, amount: u256) {
            let caller = get_caller_address();
            let st = self.stakes.read(caller);
            assert(st >= amount, 'Insufficient stake');
            let external_contract_address: felt252 =
                0x033d52ef1746ab58c5a22f8e4d80eaaf7c5a08fcfaa6c5e5365680d0ed482f34;
            let external_contract = IERC4626Dispatcher {
                contract_address: external_contract_address.try_into().unwrap(),
            };
            let shares = external_contract.convert_to_shares(amount);
            external_contract.redeem(shares, get_contract_address(), get_contract_address());
            self.stakes.write(caller, st - amount);
            self.total_stake.write(self.total_stake.read() - amount);
            self.pool_balance.write(self.pool_balance.read() - amount);
            let address_as_felt: felt252 =
                0x04861ba938aed21f2cd7740acd3765ac4d2974783a3218367233de0153490cb6;

            // Step 1: Pull WBTC from caller
            let token = IERC20Dispatcher { contract_address: address_as_felt.try_into().unwrap() };
            token.transfer(caller, amount);
        }


        fn pool_balance(self: @ContractState) -> u256 {
            self.pool_balance.read()
        }
        fn total_stake(self: @ContractState) -> u256 {
            self.total_stake.read()
        }
        fn stake_of(self: @ContractState, user: ContractAddress) -> u256 {
            self.stakes.read(user)
        }
    }
}
