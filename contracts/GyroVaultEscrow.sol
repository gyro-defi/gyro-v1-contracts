pragma solidity ^0.7.5;

import "./libs/IERC20.sol";
import "./libs/SafeERC20.sol";

contract GyroVaultEscrow {
    using SafeERC20 for IERC20;

    address public immutable gyroVault;
    address public immutable sGyro;

    constructor(address vault_, address sGyro_) {
        require(vault_ != address(0));
        gyroVault = vault_;
        require(sGyro_ != address(0));
        sGyro = sGyro_;
    }

    function retrieve(address recipient_, uint256 amount_) external {
        require(msg.sender == gyroVault);
        IERC20(sGyro).safeTransfer(recipient_, amount_);
    }
}
