pragma solidity ^0.7.5;

interface IBondCalculator {
    function valuation(address pair_, uint256 amount_) external view returns (uint256 value_);

    function markdown(address pair_, address gyro_) external view returns (uint256);
}
