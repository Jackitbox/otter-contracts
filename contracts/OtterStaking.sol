// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;

import './interfaces/IOtterStaking.sol';
import './interfaces/IsCLAM.sol';

import './types/ERC20.sol';
import './types/Ownable.sol';

import './libraries/SafeMath.sol';
import './libraries/SafeERC20.sol';

interface IWarmup {
    function retrieve(address staker_, uint256 amount_) external;
}

interface IDistributor {
    function distribute() external returns (bool);
}

contract OtterStaking is Ownable, IOtterStaking {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public immutable CLAM;
    address public immutable sCLAM;

    struct Epoch {
        uint256 length; // in seconds
        uint256 number;
        uint256 endTime; // unix epoch time in seconds
        uint256 distribute;
    }
    Epoch public epoch;

    address public distributor;

    address public locker;
    uint256 public totalBonus;

    address public warmupContract;
    uint256 public warmupPeriod;

    constructor(
        address _CLAM,
        address _sCLAM,
        uint256 _epochLength,
        uint256 _firstEpochNumber,
        uint256 _firstEpochTime
    ) {
        require(_CLAM != address(0));
        CLAM = _CLAM;
        require(_sCLAM != address(0));
        sCLAM = _sCLAM;

        epoch = Epoch({
            length: _epochLength,
            number: _firstEpochNumber,
            endTime: _firstEpochTime,
            distribute: 0
        });
    }

    struct Claim {
        uint256 deposit;
        uint256 gons;
        uint256 expiry;
        bool lock; // prevents malicious delays
    }
    mapping(address => Claim) public warmupInfo;

    /**
        @notice stake CLAM to enter warmup
        @param _amount uint
        @return bool
     */
    function stake(uint256 _amount, address _recipient)
        external
        override
        returns (bool)
    {
        rebase();

        IERC20(CLAM).safeTransferFrom(msg.sender, address(this), _amount);

        Claim memory info = warmupInfo[_recipient];
        require(!info.lock, 'Deposits for account are locked');

        warmupInfo[_recipient] = Claim({
            deposit: info.deposit.add(_amount),
            gons: info.gons.add(IsCLAM(sCLAM).gonsForBalance(_amount)),
            expiry: epoch.number.add(warmupPeriod),
            lock: false
        });

        IERC20(sCLAM).safeTransfer(warmupContract, _amount);
        return true;
    }

    /**
        @notice retrieve sCLAM from warmup
        @param _recipient address
     */
    function claim(address _recipient) external override {
        Claim memory info = warmupInfo[_recipient];
        if (epoch.number >= info.expiry && info.expiry != 0) {
            delete warmupInfo[_recipient];
            IWarmup(warmupContract).retrieve(
                _recipient,
                IsCLAM(sCLAM).balanceForGons(info.gons)
            );
        }
    }

    /**
        @notice forfeit sCLAM in warmup and retrieve CLAM
     */
    function forfeit() external {
        Claim memory info = warmupInfo[msg.sender];
        delete warmupInfo[msg.sender];

        IWarmup(warmupContract).retrieve(
            address(this),
            IsCLAM(sCLAM).balanceForGons(info.gons)
        );
        IERC20(CLAM).safeTransfer(msg.sender, info.deposit);
    }

    /**
        @notice prevent new deposits to address (protection from malicious activity)
     */
    function toggleDepositLock() external {
        warmupInfo[msg.sender].lock = !warmupInfo[msg.sender].lock;
    }

    /**
        @notice redeem sCLAM for CLAM
        @param _amount uint
        @param _trigger bool
     */
    function unstake(uint256 _amount, bool _trigger) external override {
        if (_trigger) {
            rebase();
        }
        IERC20(sCLAM).safeTransferFrom(msg.sender, address(this), _amount);
        IERC20(CLAM).safeTransfer(msg.sender, _amount);
    }

    /**
        @notice returns the sCLAM index, which tracks rebase growth
        @return uint
     */
    function index() public view returns (uint256) {
        return IsCLAM(sCLAM).index();
    }

    /**
        @notice trigger rebase if epoch over
     */
    function rebase() public {
        if (epoch.endTime <= block.timestamp) {
            IsCLAM(sCLAM).rebase(epoch.distribute, epoch.number);

            epoch.endTime = epoch.endTime.add(epoch.length);
            epoch.number++;

            if (distributor != address(0)) {
                IDistributor(distributor).distribute();
            }

            uint256 balance = contractBalance();
            uint256 staked = IsCLAM(sCLAM).circulatingSupply();

            if (balance <= staked) {
                epoch.distribute = 0;
            } else {
                epoch.distribute = balance.sub(staked);
            }
        }
    }

    /**
        @notice returns contract CLAM holdings, including bonuses provided
        @return uint
     */
    function contractBalance() public view returns (uint256) {
        return IERC20(CLAM).balanceOf(address(this)).add(totalBonus);
    }

    /**
        @notice provide bonus to locked staking contract
        @param _amount uint
     */
    function giveLockBonus(uint256 _amount) external {
        require(msg.sender == locker);
        totalBonus = totalBonus.add(_amount);
        IERC20(sCLAM).safeTransfer(locker, _amount);
    }

    /**
        @notice reclaim bonus from locked staking contract
        @param _amount uint
     */
    function returnLockBonus(uint256 _amount) external {
        require(msg.sender == locker);
        totalBonus = totalBonus.sub(_amount);
        IERC20(sCLAM).safeTransferFrom(locker, address(this), _amount);
    }

    enum CONTRACTS {
        DISTRIBUTOR,
        WARMUP,
        LOCKER
    }

    /**
        @notice sets the contract address for LP staking
        @param _contract address
     */
    function setContract(CONTRACTS _contract, address _address)
        external
        onlyOwner
    {
        if (_contract == CONTRACTS.DISTRIBUTOR) {
            // 0
            distributor = _address;
        } else if (_contract == CONTRACTS.WARMUP) {
            // 1
            require(
                warmupContract == address(0),
                'Warmup cannot be set more than once'
            );
            warmupContract = _address;
        } else if (_contract == CONTRACTS.LOCKER) {
            // 2
            require(
                locker == address(0),
                'Locker cannot be set more than once'
            );
            locker = _address;
        }
    }

    /**
     * @notice set warmup period for new stakers
     * @param _warmupPeriod uint
     */
    function setWarmup(uint256 _warmupPeriod) external onlyOwner {
        warmupPeriod = _warmupPeriod;
    }
}
