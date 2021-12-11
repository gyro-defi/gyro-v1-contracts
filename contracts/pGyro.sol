pragma solidity ^0.7.5;

import "./libs/ERC20.sol";
import "./libs/ERC20Permit.sol";
import "./libs/Ownable.sol";

contract pGyro is Ownable, ERC20Permit {
    using SafeMath for uint256;

    address private treasury;

    bool public requireSellerApproval;
    bool public allowMinting;
    mapping(address => bool) public isApprovedSeller;

    event SellerApproval(address indexed seller);

    constructor(address treasury_) ERC20("Pre-Gyro", "pGYRO", 18) {
        uint256 initialSupply = 1000000000 * 1e18;
        requireSellerApproval = true;
        allowMinting = true;
        treasury = treasury_;
        _addApprovedSeller(address(this));
        _addApprovedSeller(treasury);
        _mint(treasury, initialSupply);
    }

    function allowOpenTrading() external onlyOwner() returns (bool) {
        requireSellerApproval = false;
        return requireSellerApproval;
    }

    function disableMinting() external onlyOwner() returns (bool) {
        allowMinting = false;
        return allowMinting;
    }

    function _addApprovedSeller(address approvedSeller_) internal {
        isApprovedSeller[approvedSeller_] = true;
        emit SellerApproval(approvedSeller_);
    }

    function addApprovedSeller(address approvedSeller_) external onlyOwner() returns (bool) {
        _addApprovedSeller(approvedSeller_);
        return isApprovedSeller[approvedSeller_];
    }

    function addApprovedSellers(address[] calldata approvedSellers_) external onlyOwner() returns (bool) {
        for (uint256 i = 0; approvedSellers_.length > i; i++) {
            _addApprovedSeller(approvedSellers_[i]);
        }
        return true;
    }

    function _removeApprovedSeller(address disapprovedSeller_) internal {
        isApprovedSeller[disapprovedSeller_] = false;
    }

    function removeApprovedSeller(address disapprovedSeller_) external onlyOwner() returns (bool) {
        _removeApprovedSeller(disapprovedSeller_);
        return isApprovedSeller[disapprovedSeller_];
    }

    function removeApprovedSellers(address[] calldata disapprovedSellers_) external onlyOwner() returns (bool) {
        for (uint256 i = 0; disapprovedSellers_.length > i; i++) {
            _removeApprovedSeller(disapprovedSellers_[i]);
        }
        return true;
    }

    function _beforeTokenTransfer(
        address from_,
        address to_,
        uint256
    ) internal view override {
        if (requireSellerApproval) {
            require((_balances[to_] > 0 || isApprovedSeller[from_]), "Account not approved to transfer");
        }
    }

    function mint(address recipient_, uint256 amount_) external virtual onlyOwner() {
        require(allowMinting, "Minting has been disabled");
        _mint(recipient_, amount_);
    }

    function burn(uint256 amount_) external virtual {
        _burn(msg.sender, amount_);
    }

    function burnFrom(address account_, uint256 amount_) external virtual {
        _burnFrom(account_, amount_);
    }

    function _burnFrom(address account_, uint256 amount_) internal virtual {
        uint256 decreasedAllowance_ =
            allowance(account_, msg.sender).sub(amount_, "ERC20: burn amount exceeds allowance");
        _approve(account_, msg.sender, decreasedAllowance_);
        _burn(account_, amount_);
    }
}
