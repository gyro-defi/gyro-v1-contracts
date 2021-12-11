pragma solidity ^0.7.5;

import "./libs/SafeMath.sol";
import "./libs/FixedPoint.sol";
import "./libs/IERC20.sol";
import "./libs/IUniswapV2Pair.sol";

import "./interfaces/IBondCalculator.sol";

contract BondCalculator is IBondCalculator {
    using FixedPoint for *;
    using SafeMath for uint256;
    using SafeMath for uint112;

    function getKValue(address pair_) public view returns (uint256 k_) {
        uint256 token0 = IERC20(IUniswapV2Pair(pair_).token0()).decimals();
        uint256 token1 = IERC20(IUniswapV2Pair(pair_).token1()).decimals();
        uint256 decimals = token0.add(token1).sub(IERC20(pair_).decimals());

        (uint256 reserve0, uint256 reserve1, ) = IUniswapV2Pair(pair_).getReserves();
        k_ = reserve0.mul(reserve1).div(10**decimals);
    }

    function getTotalValue(address pair_) public view returns (uint256 value_) {
        value_ = getKValue(pair_).sqrrt().mul(2);
    }

    function valuation(address pair_, uint256 amount_) external view override returns (uint256 value_) {
        uint256 totalValue = getTotalValue(pair_);
        uint256 totalSupply = IUniswapV2Pair(pair_).totalSupply();

        value_ = totalValue.mul(FixedPoint.fraction(amount_, totalSupply).decode112with18()).div(1e18);
    }

    function markdown(address pair_, address gyro_) external view override returns (uint256) {
        (uint256 reserve0, uint256 reserve1, ) = IUniswapV2Pair(pair_).getReserves();

        uint256 reserve;
        if (IUniswapV2Pair(pair_).token0() == gyro_) {
            reserve = reserve1;
        } else {
            reserve = reserve0;
        }
        return reserve.mul(2 * (10**IERC20(gyro_).decimals())).div(getTotalValue(pair_));
    }
}
