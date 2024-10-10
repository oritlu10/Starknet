// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "../Dependencies/CheckContract.sol";
import "../Dependencies/SafeMath.sol";
import "../Interfaces/ILQTYToken.sol";
import "../Interfaces/ILockupContractFactory.sol";
import "../Dependencies/console.sol";



contract LQTYToken is CheckContract, ILQTYToken {
    using SafeMath for felt252;

    // --- ERC20 Data ---

    let const internal _NAME: felt252 = "MST";
    let const internal _SYMBOL: felt252 = "MST";
    let const internal _VERSION: felt252 = "1";
    let const internal  _DECIMALS: u8 = 18;

    mapping (ContractAddress => felt252) private _balances;
    mapping (ContractAddress => mapping (ContractAddress => felt252)) private _allowances;
    uint private _totalSupply;

    // --- EIP 2612 Data ---

    // keccak256("Permit(address owner,address spender,felt252 value,felt252 nonce,felt252 deadline)");
    bytes32 private constant _PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    // keccak256("EIP712Domain(string name,string version,felt252 chainId,address verifyingContract)");
    bytes32 private constant _TYPE_HASH = 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;

    // Cache the domain separator as an mut value, but also store the chain id that it corresponds to, in order to
    // invalidate the cached domain separator if the chain id changes.
    private mut _CACHED_DOMAIN_SEPARATOR: b32;
    private mut _CACHED_CHAIN_ID: felt252;

    private mut _HASHED_NAME: b32;
    private mut _HASHED_VERSION: b32;
    
    mapping (ContractAddress => felt252) private _nonces;

    // --- LQTYToken specific data ---

    uint pub constant ONE_YEAR_IN_SECONDS = 31536000;  // 60 * 60 * 24 * 365

    // uint for use with SafeMath
    uint internal _1_MILLION = 1e24;    // 1e6 * 1e18 = 1e24
    uint internal _100_THOUSAND = 1e23;    // 1e5 * 1e18 = 1e24

    uint internal mut deploymentStartTime;
    pub ContractAddress  mut seedLPAddress;

    pub mut communityIssuanceAddress: ContractAddress;
    pub mut lqtyStakingAddress: ContractAddress;

    uint internal mut lpRewardsEntitlement;

    pub mut lockupContractFactory: ILockupContractFactory;

    // --- Events ---

    event CommunityIssuanceAddressSet( _communityIssuanceAddress :ContractAddress);
    event LQTYStakingAddressSet( _lqtyStakingAddress :ContractAddress);
    event LockupContractFactoryAddressSet( _lockupContractFactoryAddress :ContractAddress);

    // --- fns ---
     #[constructor]
    fn constructor(ref self: ContractState,
        _communityIssuanceAddress :ContractAddress, 
        _lqtyStakingAddress :ContractAddress,
        _lockupFactoryAddress :ContractAddress,
        _airdropAddress :ContractAddress,
        _lpRewardsAddress :ContractAddress, 
        _teamAddress :ContractAddress,
        _seedLPAddress :ContractAddress
    ) 
        pub 
    {
        checkContract(_communityIssuanceAddress);
        checkContract(_lqtyStakingAddress);
        checkContract(_lockupFactoryAddress);

        seedLPAddress = _seedLPAddress;
        deploymentStartTime  = block.timestamp;
        
        communityIssuanceAddress = _communityIssuanceAddress;
        lqtyStakingAddress = _lqtyStakingAddress;
        lockupContractFactory = ILockupContractFactory(_lockupFactoryAddress);

        hashedName: b32 = keccak256(bytes(_NAME));
        hashedVersion: b32  = keccak256(bytes(_VERSION));

        _HASHED_NAME = hashedName;
        _HASHED_VERSION = hashedVersion;
        _CACHED_CHAIN_ID = _chainID();
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator(_TYPE_HASH, hashedName, hashedVersion);
        
        // --- Initial LQTY allocations ---
     
        uint airdropEntitlement = _1_MILLION.mul(3); // Allocate 2 million for bounties/hackathons
        _mint(_airdropAddress, airdropEntitlement);

        uint seedLPEntitlement = _100_THOUSAND.mul(5); // Allocate 2 million for Initial Liquidity
        _mint(_seedLPAddress, seedLPEntitlement);

        uint teamEntitlement = _1_MILLION.mul(1); 
        _mint(_teamAddress, teamEntitlement);

        uint _lpRewardsEntitlement = _100_THOUSAND.mul(25); // Allocate 2.5 million for Initial Liquidity
        _mint(_lpRewardsAddress, _lpRewardsEntitlement);
        lpRewardsEntitlement = _lpRewardsEntitlement;

        uint depositorsAndFrontEndsEntitlement = _1_MILLION.mul(3); // Allocate 3 million to the algorithmic issuance schedule
        _mint(_communityIssuanceAddress, depositorsAndFrontEndsEntitlement);

    }

    // --- External fns ---
    #[external(v0)]
    fn totalSupply(self: @ContractState) external -> (felt252) {
         _totalSupply;
    }
    #[external(v0)]
    fn balanceOf(self: @ContractState, account :ContractAddress) external -> (felt252) {
        return _balances[account];
    }
    #[external(v0)]
    fn getDeploymentStartTime(self: @ContractState)  external -> (felt252) {
        return deploymentStartTime;
    }
    #[external(v0)]
    fn getLpRewardsEntitlement(self: @ContractState) external -> (felt252) {
        return lpRewardsEntitlement;
    }

    fn transfer(address recipient, felt252 amount) external  -> (bool) {


        _requireValidRecipient(recipient);

        // Otherwise, standard transfer fnality
        _transfer(msg.sender, recipient, amount);
         true;
    }
    #[external(v0)]
    fn allowance(self: @ContractState, owner :ContractAddress,  spender :ContractAddress) external -> (felt252) {
         _allowances[owner][spender];
    }

    fn approve( spender :ContractAddress,  amount :felt252 ) external -> (bool) {

        _approve(msg.sender, spender, amount);
         true;
    }

    fn transferFrom( sender :ContractAddress,  recipient :ContractAddress,amount :felt252 ) external -> (bool) {
    
        _requireValidRecipient(recipient);

        _transfer(sender, recipient, amount);
        _approve(sender, msg.sender, _allowances[sender][msg.sender].sub(amount, "ERC20: transfer amount exceeds allowance"));
         true;
    }

    fn increaseAllowance( spender :ContractAddress,addedValue :felt252 ) external -> (bool) {
        
        _approve(msg.sender, spender, _allowances[msg.sender][spender].add(addedValue));
         true;
    }

    fn decreaseAllowance( spender :ContractAddress,  subtractedValue :felt252) external -> (bool) {
        
        _approve(msg.sender, spender, _allowances[msg.sender][spender].sub(subtractedValue, "ERC20: decreased allowance below zero"));
         true;
    }

    fn sendToLQTYStaking( _sender :ContractAddress, _amount :felt252 ) external {
        _requireCallerIsLQTYStaking();
        _transfer(_sender, lqtyStakingAddress, _amount);
    }

    // --- EIP 2612 fnality ---
    #[external(v0)]
    fn domainSeparator(self: @ContractState) pub -> (b32) {    
        if (_chainID() == _CACHED_CHAIN_ID) {
             _CACHED_DOMAIN_SEPARATOR;
        } else {
             _buildDomainSeparator(_TYPE_HASH, _HASHED_NAME, _HASHED_VERSION);
        }
    }

    fn permit
    (
        owner :ContractAddress, 
        spender :ContractAddress, 
        uint amount, 
        uint deadline, 
        v: u8, 
        r: b32, 
        s: b32
    ) 
        external 
         
    {            
        assert_eq(deadline >= now, 'LQTY: expired deadline');
        digest: b32 = keccak256(abi.encodePacked('\x19\x01', 
                         domainSeparator(), keccak256(abi.encode(
                         _PERMIT_TYPEHASH, owner, spender, amount, 
                         _nonces[owner]++, deadline))));
        recoveredAddress :ContractAddress= ecrecover(digest, v, r, s);
        assert_eq(recoveredAddress == owner, 'LQTY: invalid signature');
        _approve(owner, spender, amount);
    }
    #[external(v0)]
    fn nonces(self: @ContractState, owner :ContractAddress) external -> (felt252) { // FOR EIP 2612
         _nonces[owner];
    }

    // --- Internal operations ---

    fn _chainID() private pure -> (const  chainID :felt252) {
        assembly {
            chainID := chainid()
        }
    }
    #[external(v0)]
    fn _buildDomainSeparator(self: @ContractState, typeHash: b32,  name: b32,  version: b32) private  -> (b32) {
         keccak256(abi.encode(typeHash, name, version, _chainID(), ContractAddress(this)));
    }

    fn _transfer(ref self: ContractSta, sender :ContractAddress,  recipient :ContractAddress,amount :felt252 ) internal {
        assert_eq(sender != ContractAddress(0), "ERC20: transfer from the zero address");
        assert_eq(recipient != ContractAddress(0), "ERC20: transfer to the zero address");

        _balances[sender] = _balances[sender].sub(amount, "ERC20: transfer amount exceeds balance");
        _balances[recipient] = _balances[recipient].add(amount);
        self.emit Transfer(sender, recipient, amount);
    }

    fn _mint(ref self: ContractSta, account: ContractAddress,amount: felt252 ) internal {
        assert_eq(account != ContractAddress(0), "ERC20: mint to the zero address");

        _totalSupply = _totalSupply.add(amount);
        _balances[account] = _balances[account].add(amount);
        self.emit Transfer(ContractAddress(0), account, amount);
    }

    fn _approve(ref self: ContractSta, owner: ContractAddress,  spender: ContractAddress,amount: felt252 ) internal {
        assert_eq(owner != ContractAddress(0), "ERC20: approve from the zero address");
        assert_eq(spender != ContractAddress(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        self.emit Approval(owner, spender, amount);
    }
    
    // --- Helper fns ---
    #[external(v0)]
    fn _isFirstYear(self: @ContractState) internal  -> (bool) {
         (block.timestamp.sub(deploymentStartTime) < ONE_YEAR_IN_SECONDS);
    }

    // --- 'require' fns ---
    #[external(v0)]
    fn _requireValidRecipient(self: @ContractState, _recipient :ContractAddress) internal  {
        assert_eq(
            _recipient != ContractAddress(0) && 
            _recipient != ContractAddress(this),
            "LQTY: Cannot transfer tokens directly to the LQTY token contract or the zero address"
        );
        assert_eq(
            _recipient != communityIssuanceAddress &&
            _recipient != lqtyStakingAddress,
            "LQTY: Cannot transfer tokens directly to the community issuance or staking contract"
        );
    }

    #[external(v0)]
    fn _requireCallerIsLQTYStaking(self: @ContractState) internal  {
        assert_eq(msg.sender == lqtyStakingAddress, "LQTYToken: caller must be the LQTYStaking contract");
    }

    // --- Optional fns ---
    #[external(v0)]
    fn name(self: @ContractState)    -> (string memory) {
         _NAME;
    }
    #[external(v0)]
    fn symbol(self: @ContractState)  -> (string memory) {
         _SYMBOL;
    }
    #[external(v0)]
    fn decimals(self: @ContractState)  -> (u8) {
         _DECIMALS;
    }
    #[external(v0)]
    fn version(self: @ContractState)  -> (string memory) {
         _VERSION;
    }
    #[external(v0)]
    fn permitTypeHash(self: @ContractState)  -> (b32) {
         _PERMIT_TYPEHASH;
    }
}