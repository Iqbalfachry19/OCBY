 use starknet::{ContractAddress};
#[starknet::interface]
pub trait IMutualPool<TContractState> {
    // --- Staking ---
    fn deposit(ref self: TContractState, amount: u256);
    fn withdraw(ref self: TContractState, amount: u256);

    // --- Claims ---
    fn submit_claim(ref self: TContractState, amount: u256, description: ByteArray) -> u256;
    fn vote(ref self: TContractState, claim_id: u256, support: bool);
    fn finalize_claim(ref self: TContractState, claim_id: u256);

    // --- Views ---
    fn get_claim(
        self: @TContractState,
        claim_id: u256
    ) -> (ContractAddress, u256, ByteArray, u256, u256, bool, bool);

    fn pool_balance(self: @TContractState) -> u256;
    fn total_stake(self: @TContractState) -> u256;
    fn stake_of(self: @TContractState, user: ContractAddress) -> u256;
}



#[starknet::contract]
pub mod MutualPool {
   use openzeppelin_access::ownable::OwnableComponent;
    use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use super::IMutualPool;

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
    impl MutualPoolImpl of IMutualPool<ContractState> {
        fn deposit(ref self: ContractState, amount: u256) {
            let caller = get_caller_address();
            let token = IERC20Dispatcher { contract_address: self.pool_token.read() };
            token.transfer_from(caller, get_contract_address(), amount);

            let prev_stake = self.stakes.read(caller);
            self.stakes.write(caller, prev_stake + amount);
            self.total_stake.write(self.total_stake.read() + amount);
            self.pool_balance.write(self.pool_balance.read() + amount);
        }

        fn withdraw(ref self: ContractState, amount: u256) {
            let caller = get_caller_address();
            let st = self.stakes.read(caller);
            assert(st >= amount, 'Insufficient stake');

            self.stakes.write(caller, st - amount);
            self.total_stake.write(self.total_stake.read() - amount);
            self.pool_balance.write(self.pool_balance.read() - amount);

            let token = IERC20Dispatcher { contract_address: self.pool_token.read() };
            token.transfer(caller, amount);
        }

       fn submit_claim(ref self: ContractState, amount: u256, description: ByteArray) -> u256 {
    let caller = get_caller_address();

    // Cek kalau caller punya cukup stake
    let caller_stake = self.stakes.read(caller);
    assert(caller_stake >= amount, 'Insufficient stake');

    let id = self.claim_count.read() + 1;
    self.claim_count.write(id);

    self.claim_submitter.write(id, caller);
    self.claim_amount.write(id, amount);
    self.claim_description.write(id, description);
    self.claim_open.write(id, true);
    self.claim_finalized.write(id, false);
    self.claim_yes.write(id, 0);
    self.claim_no.write(id, 0);

    id
}


        fn vote(ref self: ContractState, claim_id: u256, support: bool) {
            let caller = get_caller_address();
            assert(self.claim_open.read(claim_id), 'Claim closed');
            assert(!self.voted.read((claim_id, caller)), 'Already voted');

            let weight = self.stakes.read(caller);
            if support {
                self.claim_yes.write(claim_id, self.claim_yes.read(claim_id) + weight);
            } else {
                self.claim_no.write(claim_id, self.claim_no.read(claim_id) + weight);
            }
            self.voted.write((claim_id, caller), true);
        }

        fn finalize_claim(ref self: ContractState, claim_id: u256) {
            assert(self.claim_open.read(claim_id), 'Already closed');
            assert(!self.claim_finalized.read(claim_id), 'Finalized');

            let yes = self.claim_yes.read(claim_id);
            let no = self.claim_no.read(claim_id);
            let total = yes + no;

            let threshold = self.governance_threshold_pct.read();
            let approved = total > 0 && yes * 100 >= threshold.into() * total;

           if approved {
    let submitter = self.claim_submitter.read(claim_id);
    let amt = self.claim_amount.read(claim_id);

    // Cek pool balance cukup
    assert(self.pool_balance.read() >= amt,'Insufficient pool');

    // Kurangi stake submitter dan total_stake
    let submitter_stake = self.stakes.read(submitter);
    assert(submitter_stake >= amt,'Insufficient stake');
    self.stakes.write(submitter, submitter_stake - amt);
    self.total_stake.write(self.total_stake.read() - amt);

    // Kurangi pool_balance
    self.pool_balance.write(self.pool_balance.read() - amt);

    // Transfer token
    let token = IERC20Dispatcher { contract_address: self.pool_token.read() };
    token.transfer(submitter, amt);
}


            self.claim_open.write(claim_id, false);
            self.claim_finalized.write(claim_id, true);
        }

        fn get_claim(
            self: @ContractState, claim_id: u256
        ) -> (ContractAddress, u256, ByteArray, u256, u256, bool, bool) {
            (
                self.claim_submitter.read(claim_id),
                self.claim_amount.read(claim_id),
                self.claim_description.read(claim_id),
                self.claim_yes.read(claim_id),
                self.claim_no.read(claim_id),
                self.claim_open.read(claim_id),
                self.claim_finalized.read(claim_id)
            )
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
