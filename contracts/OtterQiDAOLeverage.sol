// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;

// import 'hardhat/console.sol';

import './types/Ownable.sol';
import './types/ContractOwner.sol';

import './interfaces/IOtterTreasury.sol';
import './interfaces/IProxyUniswapV2Pair.sol';

import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol';
import '@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol';

import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC721/ERC721Holder.sol';

interface IVault {
    function createVault() external;

    function depositCollateral(uint256 vaultID, uint256 amount) external;

    function withdrawCollateral(uint256 vaultID, uint256 amount) external;

    function borrowToken(uint256 vaultID, uint256 amount) external;

    function payBackToken(uint256 vaultID, uint256 amount) external;

    function checkCollateralPercentage(uint256 vaultID) external view returns (uint256);

    function getEthPriceSource() external view returns (uint256);

    function getTokenPriceSource() external view returns (uint256);

    function vaultCollateral(uint256 vaultID) external view returns (uint256);

    function vaultDebt(uint256 vaultID) external view returns (uint256);

    function _minimumCollateralPercentage() external view returns (uint256);
}

interface IQiDAOInvestment is IProxyUniswapV2Pair {
    function stake(uint256 pid_, uint256 amount_) external;

    function unstake(uint256 pid_, uint256 amount_) external;

    function harvest(uint256 pid_) external;

    function totalSupply() external view returns (uint256);
}

interface CurveZapDepositor {
    function exchange_underlying(
        address pool,
        int128 i,
        int128 j,
        uint256 dx,
        uint256 min_dy
    ) external returns (uint256);
}

contract OtterQiDAOLeverage is Ownable, ContractOwner, ERC721Holder {
    using SafeMath for uint256;

    IQiDAOInvestment public immutable investment;
    uint256 public immutable investmentPid;

    CurveZapDepositor public immutable curveZapDepositor;
    address public immutable curvePool;
    int128 public immutable curveMaiIndex;
    int128 public immutable curvePairedIndex;
    IUniswapV2Router02 public immutable router;

    IVault public immutable vault;
    IOtterTreasury public immutable treasury;
    IERC20 public immutable collateral; // dQUICK
    IERC20 public immutable mai; // MAI
    IERC20 public immutable paired; // USDC
    IERC20 public immutable target; // USDC/MAI LP
    address public immutable dao;

    constructor(
        address investment_,
        uint256 investmentPid_,
        address curveZapDepositor_,
        address curvePool_,
        int128 curveMaiIndex_,
        int128 curvePairedIndex_,
        address router_,
        address vault_,
        address collateral_, // dQUICK
        address mai_, // MAI
        address paired_, // USDC
        address treasury_,
        address dao_ // for emergency
    ) {
        investment = IQiDAOInvestment(investment_);
        investmentPid = investmentPid_;
        curveZapDepositor = CurveZapDepositor(curveZapDepositor_);
        curvePool = curvePool_;
        curveMaiIndex = curveMaiIndex_;
        curvePairedIndex = curvePairedIndex_;
        router = IUniswapV2Router02(router_);
        vault = IVault(vault_);
        collateral = IERC20(collateral_);
        mai = IERC20(mai_);
        paired = IERC20(paired_);
        treasury = IOtterTreasury(treasury_);
        dao = dao_;
        target = IERC20(IUniswapV2Factory(IUniswapV2Router02(router_).factory()).getPair(mai_, paired_));
    }

    function createVault() external onlyOwner {
        vault.createVault();
    }

    function depositCollateral(uint256 vaultID, uint256 amount_) external onlyOwner {
        treasury.manage(address(collateral), amount_);
        collateral.approve(address(vault), amount_);
        vault.depositCollateral(vaultID, amount_);
    }

    function withdrawCollateral(uint256 vaultID, uint256 amount_) external onlyOwner {
        vault.withdrawCollateral(vaultID, amount_);
        uint256 balance = collateral.balanceOf(address(this));
        collateral.approve(address(treasury), balance);
        uint256 profit = treasury.valueOfToken(address(collateral), balance);
        treasury.deposit(amount_, address(collateral), profit);
    }

    function _borrow(uint256 vaultID, uint256 amount) private {
        // console.log('should borrow %s', amount);
        vault.borrowToken(vaultID, amount);
        uint256 amountHalf = amount.div(2);
        // MAI -> USDC
        mai.approve(address(curveZapDepositor), amountHalf);
        uint256 amountPaired = curveZapDepositor.exchange_underlying(
            curvePool,
            curveMaiIndex,
            curvePairedIndex,
            amountHalf,
            0
        );
        // console.log('exchange %s, paired %s', amountHalf, amountPaired);
        mai.approve(address(router), amountHalf);
        paired.approve(address(router), amountPaired);
        (, , uint256 amountTarget) = router.addLiquidity(
            address(mai),
            address(paired),
            amountHalf,
            amountPaired,
            1,
            1,
            address(treasury),
            block.timestamp
        );
        // console.log('addLiquidity %s, %s, got %s', amountHalf, amountPaired, amountTarget);
        investment.stake(investmentPid, amountTarget);
        uint256 remainMai = mai.balanceOf(address(this));
        mai.transfer(address(treasury), remainMai);
        // console.log('transfer remainMai %s to treasury', remainMai);
        uint256 remainPaired = paired.balanceOf(address(this));
        paired.transfer(address(treasury), remainPaired);
        // console.log('transfer remainPaired %s to treasury', remainPaired);
    }

    function _repay(uint256 vaultID, uint256 amount) private {
        // R = reserve USDC / reserve MAI
        // payback = mai + usdc = mai + mai*R = mai*(1+R)
        // mai = payback / (1+R) = (lp balance / lp total) * reserve MAI * 2
        // lp balance = (payback * lp total) / (2*((1+R)) * reserve MAI)
        //            = (payback * lp total) / (2*(reserve MAI + reserve USDC))
        (uint256 reservePaired, uint256 reserveMai, ) = investment.getReserves();
        // console.log('should payback %s', amount);
        uint256 amountLP = amount.mul(investment.totalSupply()).div(reserveMai.add(reservePaired)).div(2);
        // console.log('should unstak %s LP', amountLP);
        uint256 balanceLP = IERC20(address(investment)).balanceOf(address(treasury));
        if (amountLP > balanceLP) {
            // console.log('not enough LP, max %s', balanceLP);
            amountLP = balanceLP;
        }
        investment.unstake(investmentPid, amountLP);
        treasury.manage(address(target), amountLP);

        target.approve(address(router), amountLP);
        (uint256 amountMai, uint256 amountPaired) = router.removeLiquidity(
            address(mai),
            address(paired),
            amountLP,
            1,
            1,
            address(this),
            block.timestamp
        );
        // console.log('removeLiquidity %s, got mai %s, paired %s', amountLP, amountMai, amountPaired);
        paired.approve(address(curveZapDepositor), amountPaired);
        uint256 amountMaiExchanged = curveZapDepositor.exchange_underlying(
            curvePool,
            curvePairedIndex,
            curveMaiIndex,
            amountPaired,
            0
        );
        // console.log('exchange paired %s to mai %s', amountPaired, amountMaiExchanged);
        uint256 amountMaiPayback = amountMai.add(amountMaiExchanged);
        // console.log('actual payback %s', amountMaiPayback);
        mai.approve(address(vault), amountMaiPayback);
        vault.payBackToken(vaultID, amountMaiPayback);

        uint256 remainMai = mai.balanceOf(address(this));
        mai.transfer(address(treasury), remainMai);
        // console.log('transfer remainMai %s to treasury', remainMai);
        uint256 remainPaired = paired.balanceOf(address(this));
        paired.transfer(address(treasury), remainPaired);
        // console.log('transfer remainPaired %s to treasury', remainPaired);
    }

    function rebalance(uint256 vaultID, uint16 ratio) external onlyOwner {
        require(
            ratio > vault._minimumCollateralPercentage(),
            'ratio must be greater than the minimum collateral percentage'
        );
        if (ratio == vault.checkCollateralPercentage(vaultID)) {
            return;
        }

        uint256 cv = collateralValue(vaultID);
        uint256 lb = _calcLoanBalance(loanValue(vaultID));
        uint256 lbTarget = _calcLoanBalance(cv.mul(100).div(ratio));
        if (lbTarget > lb) {
            _borrow(vaultID, lbTarget.sub(lb));
        } else {
            _repay(vaultID, lb.sub(lbTarget));
        }
    }

    function collateralPercentage(uint256 vaultID) public view returns (uint256) {
        return vault.checkCollateralPercentage(vaultID);
    }

    function _calcLoanValue(uint256 balance_) private view returns (uint256) {
        require(vault.getTokenPriceSource() != 0, 'vault.getTokenPriceSource() is 0');
        return balance_.mul(vault.getTokenPriceSource());
    }

    function _calcLoanBalance(uint256 value_) private view returns (uint256) {
        require(vault.getTokenPriceSource() != 0, 'vault.getTokenPriceSource() is 0');
        return value_.div(vault.getTokenPriceSource());
    }

    function loanValue(uint256 vaultID) public view returns (uint256) {
        return _calcLoanValue(vault.vaultDebt(vaultID));
    }

    function _calcCollateralValue(uint256 balance_) private view returns (uint256) {
        require(vault.getEthPriceSource() != 0, 'vault.getEthPriceSource() is 0');
        return balance_.mul(vault.getEthPriceSource());
    }

    function _calcCollateralBalance(uint256 value_) private view returns (uint256) {
        require(vault.getEthPriceSource() != 0, 'vault.getEthPriceSource() is 0');
        return value_.mul(vault.getEthPriceSource());
    }

    function collateralValue(uint256 vaultID) public view returns (uint256) {
        return _calcCollateralValue(vault.vaultCollateral(vaultID));
    }

    function emergencyWithdraw(address token_) external onlyOwner {
        uint256 balance = IERC20(token_).balanceOf(address(this));
        IERC20(token_).transfer(dao, balance);
    }
}
