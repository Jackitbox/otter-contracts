// SPDX-License-Identifier: AGPL-3.0-or-later\
pragma solidity 0.7.5;

import '../types/ERC20.sol';
import '../types/Ownable.sol';

import '../libraries/SafeMath.sol';
import '../libraries/SafeERC20.sol';

interface ITreasury {
    function deposit(
        uint256 _amount,
        address _token,
        uint256 _profit
    ) external returns (uint256);
}

interface IPreOtterClam {
    function burnFrom(address account_, uint256 amount_) external;
}

interface ICirculatingCLAM {
    function CLAMCirculatingSupply() external view returns (uint256);
}

contract ExercisePreClam is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public immutable pCLAM;
    address public immutable CLAM;
    address public immutable DAI;
    address public immutable treasury;
    address public immutable circulatingCLAMContract;

    struct Term {
        uint256 percent; // 4 decimals ( 5000 = 0.5% )
        uint256 claimed;
        uint256 max;
    }
    mapping(address => Term) public terms;

    mapping(address => address) public walletChange;

    constructor(
        address _pCLAM,
        address _clam,
        address _dai,
        address _treasury,
        address _circulatingCLAMContract
    ) {
        require(_pCLAM != address(0));
        pCLAM = _pCLAM;
        require(_clam != address(0));
        CLAM = _clam;
        require(_dai != address(0));
        DAI = _dai;
        require(_treasury != address(0));
        treasury = _treasury;
        require(_circulatingCLAMContract != address(0));
        circulatingCLAMContract = _circulatingCLAMContract;
    }

    // Sets terms for a new wallet
    function setTerms(
        address _vester,
        uint256 _amountCanClaim,
        uint256 _rate
    ) external onlyOwner returns (bool) {
        require(
            _amountCanClaim >= terms[_vester].max,
            'cannot lower amount claimable'
        );
        require(_rate >= terms[_vester].percent, 'cannot lower vesting rate');

        terms[_vester].max = _amountCanClaim;
        terms[_vester].percent = _rate;

        return true;
    }

    // Allows wallet to redeem pCLAM for CLAM
    function exercise(uint256 _amount) external returns (bool) {
        Term memory info = terms[msg.sender];
        require(redeemable(info) >= _amount, 'Not enough vested');
        require(info.max.sub(info.claimed) >= _amount, 'Claimed over max');

        IERC20(DAI).safeTransferFrom(msg.sender, address(this), _amount);
        IPreOtterClam(pCLAM).burnFrom(msg.sender, _amount);

        IERC20(DAI).approve(treasury, _amount);
        uint256 CLAMToSend = ITreasury(treasury).deposit(_amount, DAI, 0);

        terms[msg.sender].claimed = info.claimed.add(_amount);

        IERC20(CLAM).safeTransfer(msg.sender, CLAMToSend);

        return true;
    }

    // Allows wallet owner to transfer rights to a new address
    function pushWalletChange(address _newWallet) external returns (bool) {
        require(terms[msg.sender].percent != 0);
        walletChange[msg.sender] = _newWallet;
        return true;
    }

    // Allows wallet to pull rights from an old address
    function pullWalletChange(address _oldWallet) external returns (bool) {
        require(walletChange[_oldWallet] == msg.sender, 'wallet did not push');

        walletChange[_oldWallet] = address(0);
        terms[msg.sender] = terms[_oldWallet];
        delete terms[_oldWallet];

        return true;
    }

    // Amount a wallet can redeem based on current supply
    function redeemableFor(address _vester) public view returns (uint256) {
        return redeemable(terms[_vester]);
    }

    function redeemable(Term memory _info) internal view returns (uint256) {
        return
            (
                ICirculatingCLAM(circulatingCLAMContract)
                    .CLAMCirculatingSupply()
                    .mul(_info.percent)
                    .mul(1000)
            ).sub(_info.claimed);
    }
}
