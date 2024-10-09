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

    string constant internal _NAME = "MST";
    string constant internal _SYMBOL = "MST";
    string constant internal _VERSION = "1";
    uint8 constant internal  _DECIMALS = 18;

    mapping (ContractAddress => felt252) private _balances;
    mapping (ContractAddress => mapping (ContractAddress => felt252)) private _allowances;
    uint private _totalSupply;

    // --- EIP 2612 Data ---

    // keccak256("Permit(address owner,address spender,felt252 value,felt252 nonce,felt252 deadline)");
    bytes32 private constant _PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    // keccak256("EIP712Domain(string name,string version,felt252 chainId,address verifyingContract)");
    bytes32 private constant _TYPE_HASH = 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;

    // Cache the domain separator as an immutable value, but also store the chain id that it corresponds to, in order to
    // invalidate the cached domain separator if the chain id changes.
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    felt252 private immutable _CACHED_CHAIN_ID;

    bytes32 private immutable _HASHED_NAME;
    bytes32 private immutable _HASHED_VERSION;
    
    mapping (ContractAddress => felt252) private _nonces;

    // --- LQTYToken specific data ---

    uint public constant ONE_YEAR_IN_SECONDS = 31536000;  // 60 * 60 * 24 * 365

    // uint for use with SafeMath
    uint internal _1_MILLION = 1e24;    // 1e6 * 1e18 = 1e24
    uint internal _100_THOUSAND = 1e23;    // 1e5 * 1e18 = 1e24

    uint internal immutable deploymentStartTime;
    address public immutable seedLPAddress;

    address public immutable communityIssuanceAddress;
    address public immutable lqtyStakingAddress;

    uint internal immutable lpRewardsEntitlement;

    ILockupContractFactory public immutable lockupContractFactory;

    // --- Events ---

    event CommunityIssuanceAddressSet( _communityIssuanceAddress :ContractAddress);
    event LQTYStakingAddressSet( _lqtyStakingAddress :ContractAddress);
    event LockupContractFactoryAddressSet( _lockupContractFactoryAddress :ContractAddress);

    // --- fns ---

    constructor
    (
        _communityIssuanceAddress :ContractAddress, 
        _lqtyStakingAddress :ContractAddress,
        _lockupFactoryAddress :ContractAddress,
        _airdropAddress :ContractAddress,
        _lpRewardsAddress :ContractAddress, 
        _teamAddress :ContractAddress,
        _seedLPAddress :ContractAddress
    ) 
        public 
    {
        checkContract(_communityIssuanceAddress);
        checkContract(_lqtyStakingAddress);
        checkContract(_lockupFactoryAddress);

        seedLPAddress = _seedLPAddress;
        deploymentStartTime  = block.timestamp;
        
        communityIssuanceAddress = _communityIssuanceAddress;
        lqtyStakingAddress = _lqtyStakingAddress;
        lockupContractFactory = ILockupContractFactory(_lockupFactoryAddress);

        bytes32 hashedName = keccak256(bytes(_NAME));
        bytes32 hashedVersion = keccak256(bytes(_VERSION));

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
    fn domainSeparator(self: @ContractState) public -> (bytes32) {    
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
        uint8 v, 
        bytes32 r, 
        bytes32 s
    ) 
        external 
         
    {            
        require(deadline >= now, 'LQTY: expired deadline');
        bytes32 digest = keccak256(abi.encodePacked('\x19\x01', 
                         domainSeparator(), keccak256(abi.encode(
                         _PERMIT_TYPEHASH, owner, spender, amount, 
                         _nonces[owner]++, deadline))));
        recoveredAddress :ContractAddress= ecrecover(digest, v, r, s);
        require(recoveredAddress == owner, 'LQTY: invalid signature');
        _approve(owner, spender, amount);
    }
    #[external(v0)]
    fn nonces(self: @ContractState, owner :ContractAddress) external -> (felt252) { // FOR EIP 2612
         _nonces[owner];
    }

    // --- Internal operations ---

    fn _chainID() private pure -> (felt252 chainID) {
        assembly {
            chainID := chainid()
        }
    }
    #[external(v0)]
    fn _buildDomainSeparator(self: @ContractState,bytes32 typeHash, bytes32 name, bytes32 version) private  -> (bytes32) {
         keccak256(abi.encode(typeHash, name, version, _chainID(), address(this)));
    }

    fn _transfer( sender :ContractAddress,  recipient :ContractAddress,amount :felt252 ) internal {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");

        _balances[sender] = _balances[sender].sub(amount, "ERC20: transfer amount exceeds balance");
        _balances[recipient] = _balances[recipient].add(amount);
        emit Transfer(sender, recipient, amount);
    }

    fn _mint( account :ContractAddress,amount :felt252 ) internal {
        require(account != address(0), "ERC20: mint to the zero address");

        _totalSupply = _totalSupply.add(amount);
        _balances[account] = _balances[account].add(amount);
        emit Transfer(address(0), account, amount);
    }

    fn _approve( owner :ContractAddress,  spender :ContractAddress,amount f:elt252 ) internal {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
    
    // --- Helper fns ---
    #[external(v0)]
    fn _isFirstYear(self: @ContractState) internal  -> (bool) {
         (block.timestamp.sub(deploymentStartTime) < ONE_YEAR_IN_SECONDS);
    }

    // --- 'require' fns ---
    #[external(v0)]
    fn _requireValidRecipient(self: @ContractState, _recipient :ContractAddress) internal  {
        require(
            _recipient != address(0) && 
            _recipient != address(this),
            "LQTY: Cannot transfer tokens directly to the LQTY token contract or the zero address"
        );
        require(
            _recipient != communityIssuanceAddress &&
            _recipient != lqtyStakingAddress,
            "LQTY: Cannot transfer tokens directly to the community issuance or staking contract"
        );
    }

    #[external(v0)]
    fn _requireCallerIsLQTYStaking(self: @ContractState) internal  {
         require(msg.sender == lqtyStakingAddress, "LQTYToken: caller must be the LQTYStaking contract");
    }

    // --- Optional fns ---
    #[external(v0)]
    fn name(self: @ContractState) external   -> (string memory) {
         _NAME;
    }
    #[external(v0)]
    fn symbol(self: @ContractState) external -> (string memory) {
         _SYMBOL;
    }
    #[external(v0)]
    fn decimals(self: @ContractState) external -> (uint8) {
         _DECIMALS;
    }
    #[external(v0)]
    fn version(self: @ContractState) external -> (string memory) {
         _VERSION;
    }
    #[external(v0)]
    fn permitTypeHash(self: @ContractState) external -> (bytes32) {
         _PERMIT_TYPEHASH;
    }
}