#[starknet::interface]
trait IMediolanoMarketplace<TState> {
    // Core purchase functions
    fn purchase_multiple_assets(
        ref self: TState, assets: Array<DigitalAsset>, payment_currency: ContractAddress
    );

    // Admin functions
    fn set_commission_rate(ref self: TState, rate: u256);
    fn add_supported_currency(ref self: TState, currency: ContractAddress);
    fn remove_supported_currency(ref self: TState, currency: ContractAddress);

    // Metadata and asset management
    fn register_digital_asset(
        ref self: TState,
        asset_id: u256,
        seller: ContractAddress,
        price: u256,
        metadata_hash: felt252
    );

    // Utility and view functions
    fn get_asset_metadata(self: @TState, asset_id: u256) -> felt252;
    fn get_commission_rate(self: @TState) -> u256;
    fn is_currency_supported(self: @TState, currency: ContractAddress) -> bool;
}

#[starknet::contract]
mod MediolanoMarketplace {
    use starknet::{
        ContractAddress, get_caller_address, get_block_timestamp, contract_address_const
    };
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::security::pausable::PausableComponent;
    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: PausableComponent, storage: pausable, event: PausableEvent);
    use starknet::storage::{StoragePointerWriteAccess, StoragePathEntry, Map};

    #[derive(Drop, Serde)]
    struct DigitalAsset {
        seller: ContractAddress,
        asset_id: u256,
        price: u256,
        metadata_ipfs_hash: felt252
    }

    #[storage]
    struct Storage {
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        pausable: PausableComponent::Storage,
        owner: ContractAddress,
        commission_rate: u256,
        supported_currencies: LegacyMap::<ContractAddress, bool>,
        asset_metadata: LegacyMap::<u256, felt252>,
        asset_ownership: LegacyMap::<u256, ContractAddress>,
        asset_registered: LegacyMap::<u256, bool>
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        AssetPurchased: AssetPurchased,
        AssetRegistered: AssetRegistered,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        PausableEvent: PausableComponent::Event
    }

    #[derive(Drop, starknet::Event)]
    struct AssetPurchased {
        asset_id: u256,
        buyer: ContractAddress,
        seller: ContractAddress,
        price: u256
    }

    #[derive(Drop, starknet::Event)]
    struct AssetRegistered {
        asset_id: u256,
        seller: ContractAddress,
        price: u256
    }

    #[abi(embed_v0)]
    impl MediolanoMarketplaceImpl of super::IMediolanoMarketplace<ContractState> {
        fn purchase_multiple_assets(
            ref self: ContractState, assets: Array<DigitalAsset>, payment_currency: ContractAddress
        ) {
            self.pausable.assert_not_paused();
            assert!(self.supported_currencies.read(payment_currency), "Invalid payment currency");

            let buyer = get_caller_address();
            let total_price = self.calculate_total_price(assets);

            self.process_payments(assets, total_price, payment_currency, buyer);
            self.transfer_asset_ownership(assets, buyer);
        }

        fn register_digital_asset(
            ref self: ContractState,
            asset_id: u256,
            seller: ContractAddress,
            price: u256,
            metadata_hash: felt252
        ) {
            self.ownable.assert_only_owner();
            assert!(!self.asset_registered.read(asset_id), "Asset already registered");

            self.asset_metadata.write(asset_id, metadata_hash);
            self.asset_ownership.write(asset_id, seller);
            self.asset_registered.write(asset_id, true);

            self.emit(AssetRegistered { asset_id, seller, price });
        }

        fn set_commission_rate(ref self: ContractState, rate: u256) {
            self.ownable.assert_only_owner();
            assert!(rate < 10000, "Invalid commission rate");
            self.commission_rate.write(rate);
        }

        fn add_supported_currency(ref self: ContractState, currency: ContractAddress) {
            self.ownable.assert_only_owner();
            self.supported_currencies.write(currency, true);
        }

        fn remove_supported_currency(ref self: ContractState, currency: ContractAddress) {
            self.ownable.assert_only_owner();
            self.supported_currencies.write(currency, false);
        }

        fn get_asset_metadata(self: @ContractState, asset_id: u256) -> felt252 {
            self.asset_metadata.read(asset_id)
        }

        fn get_commission_rate(self: @ContractState) -> u256 {
            self.commission_rate.read()
        }

        fn is_currency_supported(self: @ContractState, currency: ContractAddress) -> bool {
            self.supported_currencies.read(currency)
        }
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn calculate_total_price(self: @ContractState, assets: Array<DigitalAsset>) -> u256 {
            let mut total = 0;
            for asset in assets
                .span() {
                    assert!(self.asset_registered.read(asset.asset_id), "Unregistered asset");
                    total += asset.price;
                }
            total
        }

        fn process_payments(
            ref self: ContractState,
            assets: Array<DigitalAsset>,
            total_price: u256,
            currency: ContractAddress,
            buyer: ContractAddress
        ) {
            let commission_rate = self.commission_rate.read();
            let commission = total_price * commission_rate / 10000;
            let mediolano_address = self.owner.read();
            let currency_contract = IERC20Dispatcher { contract_address: currency };

            // Transfer commission to Mediolano
            currency_contract.transferFrom(buyer, mediolano_address, commission);

            // Distribute remaining funds to sellers
            for asset in assets
                .span() {
                    let seller_amount = asset.price;
                    currency_contract.transferFrom(buyer, asset.seller, seller_amount);

                    self
                        .emit(
                            AssetPurchased {
                                asset_id: asset.asset_id,
                                buyer,
                                seller: asset.seller,
                                price: seller_amount
                            }
                        );
                }
        }

        fn transfer_asset_ownership(
            ref self: ContractState, assets: Array<DigitalAsset>, buyer: ContractAddress
        ) {
            for asset in assets
                .span() {
                    let current_owner = self.asset_ownership.read(asset.asset_id);
                    assert!(current_owner == asset.seller, "Invalid asset ownership");

                    // Transfer ownership to buyer
                    self.asset_ownership.write(asset.asset_id, buyer);
                }
        }
    }
}
