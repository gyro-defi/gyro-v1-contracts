pragma solidity ^0.7.5;

import "./libs/ERC20.sol";
import "./libs/Ownable.sol";

contract vGyro is Ownable, ERC20 {
    constructor(address treasury_) ERC20("Voucher Gyro", "vGYRO", 9) {
        require(treasury_ != address(0), "Treasury undefined");
        _mint(treasury_, 50000000000000);
    }

    function burn(uint256 amount_) external {
        _burn(msg.sender, amount_);
    }
}
