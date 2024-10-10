// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "../Dependencies/BaseMath.sol";
import "../Dependencies/SafeMath.sol";
import "../Dependencies/Ownable.sol";
import "../Dependencies/CheckContract.sol";
import "../Dependencies/console.sol";
import "../Interfaces/ILQTYToken.sol";
import "../Interfaces/ILQTYStaking.sol";
import "../Dependencies/LiquityMath.sol";
import "../Interfaces/ILUSDToken.sol";

contract LQTYStaking is ILQTYStaking, Ownable, CheckContract, BaseMath {
    using SafeMath for uint;

    // --- Data ---
    pub const  NAME: felt252 = "MSTStaking";

    mapping( address => uint) pub stakes;
    pub uint  totalLQTYStaked;

    pub uint  F_ETH;  // Running sum of ETH fees per-LQTY-staked
    pub uint  F_LUSD; // Running sum of LQTY fees per-LQTY-staked

    // User snapshots of F_ETH and F_LUSD, taken at the point at which their latest deposit was made
    mapping (address => Snapshot) pub snapshots; 

    struct Snapshot {
        uint F_ETH_Snapshot;
        uint F_LUSD_Snapshot;
    }
    
    pub lqtyToken: ILQTYToken;
    pub lusdToken: ILQTYToken;

    let pub troveManagerAddress: ContractAddress;
    let pub borrowerOperationsAddress: ContractAddress;
    let pub activePoolAddress: ContractAddress;

    // --- Events ---

    event LQTYTokenAddressSet( _lqtyTokenAddress: ContractAddress);
    event LUSDTokenAddressSet( _lusdTokenAddress: ContractAddress);
    event TroveManagerAddressSet( _troveManager: ContractAddress);
    event BorrowerOperationsAddressSet( _borrowerOperationsAddress: ContractAddress);
    event ActivePoolAddressSet( _activePoolAddress: ContractAddress);

    event StakeChanged(address indexed staker, uint newStake);
    event StakingGainsWithdrawn(address indexed staker, uint LUSDGain, uint ETHGain);
    event F_ETHUpdated(uint _F_ETH);
    event F_LUSDUpdated(uint _F_LUSD);
    event TotalLQTYStakedUpdated(uint _totalLQTYStaked);
    event EtherSent( _account: ContractAddress, uint _amount);
    event StakerSnapshotsUpdated( _staker: ContractAddress, uint _F_ETH, uint _F_LUSD);

    // --- fns ---
     #[external(v0)]
    fn setAddresses
    (
         ref self: ContractState,
         _lqtyTokenAddress: ContractAddress,
         _lusdTokenAddress: ContractAddress,
         _troveManagerAddress: ContractAddress, 
         _borrowerOperationsAddress: ContractAddress,
         _activePoolAddress: ContractAddress
    ) 
         
        onlyOwner 
        override 
    {
        checkContract(_lqtyTokenAddress);
        checkContract(_lusdTokenAddress);
        checkContract(_troveManagerAddress);
        checkContract(_borrowerOperationsAddress);
        checkContract(_activePoolAddress);

        lqtyToken = ILQTYToken(_lqtyTokenAddress);
        lusdToken = ILUSDToken(_lusdTokenAddress);
        troveManagerAddress = _troveManagerAddress;
        borrowerOperationsAddress = _borrowerOperationsAddress;
        activePoolAddress = _activePoolAddress;

        self.emit LQTYTokenAddressSet(_lqtyTokenAddress);
        self.emit LQTYTokenAddressSet(_lusdTokenAddress);
        self.emit TroveManagerAddressSet(_troveManagerAddress);
        self.emit BorrowerOperationsAddressSet(_borrowerOperationsAddress);
        self.emit ActivePoolAddressSet(_activePoolAddress);

        _renounceOwnership();
    }

    // If caller has a pre-existing stake, send any accumulated ETH and LUSD gains to them. 
     #[external(v0)]
    fn stake(ref self: ContractState,uint _LQTYamount)  override {
        _requireNonZeroAmount(_LQTYamount);

        uint currentStake = stakes[msg.sender];

        uint ETHGain;
        uint LUSDGain;
        // Grab any accumulated ETH and LUSD gains from the current stake
        if (currentStake != 0) {
            ETHGain = _getPendingETHGain(msg.sender);
            LUSDGain = _getPendingLUSDGain(msg.sender);
        }
    
       _updateUserSnapshots(msg.sender);

        uint newStake = currentStake.add(_LQTYamount);

        // Increase user’s stake and total LQTY staked
        stakes[msg.sender] = newStake;
        totalLQTYStaked = totalLQTYStaked.add(_LQTYamount);
        self.emit TotalLQTYStakedUpdated(totalLQTYStaked);

        // Transfer LQTY from caller to this contract
        lqtyToken.sendToLQTYStaking(msg.sender, _LQTYamount);

        self.emit StakeChanged(msg.sender, newStake);
        self.emit StakingGainsWithdrawn(msg.sender, LUSDGain, ETHGain);

         // Send accumulated LUSD and ETH gains to the caller
        if (currentStake != 0) {
            lusdToken.transfer(msg.sender, LUSDGain);
            _sendETHGainToUser(ETHGain);
        }
    }

    // Unstake the LQTY and send the it back to the caller, along with their accumulated LUSD & ETH gains. 
    // If requested amount > stake, send their entire stake.
    #[external(v0)]
    fn unstake(ref self: ContractState, uint _LQTYamount)  override {
        uint currentStake = stakes[msg.sender];
        _requireUserHasStake(currentStake);

        // Grab any accumulated ETH and LUSD gains from the current stake
        uint ETHGain = _getPendingETHGain(msg.sender);
        uint LUSDGain = _getPendingLUSDGain(msg.sender);
        
        _updateUserSnapshots(msg.sender);

        if (_LQTYamount > 0) {
            uint LQTYToWithdraw = LiquityMath._min(_LQTYamount, currentStake);

            uint newStake = currentStake.sub(LQTYToWithdraw);

            // Decrease user's stake and total LQTY staked
            stakes[msg.sender] = newStake;
            totalLQTYStaked = totalLQTYStaked.sub(LQTYToWithdraw);
            self.emit TotalLQTYStakedUpdated(totalLQTYStaked);

            // Transfer unstaked LQTY to user
            lqtyToken.transfer(msg.sender, LQTYToWithdraw);

            self.emit StakeChanged(msg.sender, newStake);
        }

        self.emit StakingGainsWithdrawn(msg.sender, LUSDGain, ETHGain);

        // Send accumulated LUSD and ETH gains to the caller
        lusdToken.transfer(msg.sender, LUSDGain);
        _sendETHGainToUser(ETHGain);
    }

    // --- Reward-per-unit-staked increase fns. Called by Liquity core contracts ---
     #[external(v0)]
    fn increaseF_ETH(ref self: ContractState, uint _ETHFee)  override {
        _requireCallerIsTroveManager();
        uint ETHFeePerLQTYStaked;
     
        if (totalLQTYStaked > 0) {ETHFeePerLQTYStaked = _ETHFee.mul(DECIMAL_PRECISION).div(totalLQTYStaked);}

        F_ETH = F_ETH.add(ETHFeePerLQTYStaked); 
        self.emit F_ETHUpdated(F_ETH);
    }
    #[external(v0)]
    fn increaseF_LUSD(ref self: ContractState, uint _LUSDFee)  override {
        _requireCallerIsBorrowerOperations();
        uint LUSDFeePerLQTYStaked;
        
        if (totalLQTYStaked > 0) {LUSDFeePerLQTYStaked = _LUSDFee.mul(DECIMAL_PRECISION).div(totalLQTYStaked);}
        
        F_LUSD = F_LUSD.add(LUSDFeePerLQTYStaked);
        self.emit F_LUSDUpdated(F_LUSD);
    }

    // --- Pending reward fns ---
     #[external(v0)]
    fn getPendingETHGain(self: @ContractState,  _user: ContractAddress)   override -> (uint) {
         _getPendingETHGain(_user);
    }

    fn _getPendingETHGain(self: @ContractState, _user: ContractAddress) internal  -> (uint) {
        uint F_ETH_Snapshot = snapshots[_user].F_ETH_Snapshot;
        uint ETHGain = stakes[_user].mul(F_ETH.sub(F_ETH_Snapshot)).div(DECIMAL_PRECISION);
        return ETHGain;
    }

    #[external(v0)]
    fn getPendingLUSDGain(self: @ContractState, _user: ContractAddress)   override -> (uint) {
         _getPendingLUSDGain(_user);
    }

    fn _getPendingLUSDGain(self: @ContractState, _user: ContractAddress) internal  -> (uint) {
        uint F_LUSD_Snapshot = snapshots[_user].F_LUSD_Snapshot;
        uint LUSDGain = stakes[_user].mul(F_LUSD.sub(F_LUSD_Snapshot)).div(DECIMAL_PRECISION);
        LUSDGain;
    }

    // --- Internal helper fns ---

    fn _updateUserSnapshots(ref self: ContractState, _user: ContractAddress) internal {
        snapshots[_user].F_ETH_Snapshot = F_ETH;
        snapshots[_user].F_LUSD_Snapshot = F_LUSD;
        self.emit StakerSnapshotsUpdated(_user, F_ETH, F_LUSD);
    }

    fn _sendETHGainToUser(ref self: ContractState,uint ETHGain) internal {
        self.emit EtherSent(msg.sender, ETHGain);
        (bool success, ) = msg.sender.call{value: ETHGain}("");
        assert_eq(success, "LQTYStaking: Failed to send accumulated ETHGain");
    }

    // --- 'require' fns ---

    fn _requireCallerIsTroveManager(self: @ContractState) internal  {
        assert_eq(msg.sender == troveManagerAddress, "LQTYStaking: caller is not TroveM");
    }

    fn _requireCallerIsBorrowerOperations(self: @ContractState) internal  {
        assert_eq(msg.sender == borrowerOperationsAddress, "LQTYStaking: caller is not BorrowerOps");
    }
    
    fn _requireCallerIsActivePool(self: @ContractState) internal  {
        assert_eq(msg.sender == activePoolAddress, "LQTYStaking: caller is not ActivePool");
    }

    fn _requireUserHasStake(const uint currentStake) internal  {  
        assert_eq(currentStake > 0, 'LQTYStaking: User must have a non-zero stake');  
    }

    fn _requireNonZeroAmount(const uint _amount) internal  {
        assert_eq(_amount > 0, 'LQTYStaking: Amount must be non-zero');
    }
     #[external(v0)]
    receive()  payable {
        _requireCallerIsActivePool();
    }
}