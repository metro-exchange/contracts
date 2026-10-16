// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRateLimitedForwarder} from "./interfaces/IRateLimitedForwarder.sol";

contract RateLimitedForwarder is IRateLimitedForwarder, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    address public recipient;
    bool public paused;
    address public owner;
    address public pendingOwner;

    uint256 public dripRate;
    uint256 public dripPeriod;
    uint256 public maxReserve;
    uint256 public bucket;
    uint256 public lastAccrual;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Paused");
        _;
    }

    constructor(
        address _token,
        address _recipient,
        address _owner,
        uint256 _dripRate,
        uint256 _dripPeriod,
        uint256 _maxReserve
    ) {
        require(_owner != address(0), "Zero owner");
        require(_token != address(0), "Zero token");
        require(_token.code.length > 0, "Token has no code");
        IERC20(_token).balanceOf(address(this));
        _checkLimit(_dripRate, _dripPeriod);
        token = IERC20(_token);
        _checkRecipient(_recipient);
        owner = _owner;
        recipient = _recipient;
        dripRate = _dripRate;
        dripPeriod = _dripPeriod;
        maxReserve = _maxReserve;
        lastAccrual = block.timestamp;
        paused = true;
        emit OwnershipTransferred(address(0), _owner);
        emit RecipientUpdated(address(0), _recipient);
        emit DripLimitUpdated(_dripRate, _dripPeriod, _maxReserve);
        emit Paused(true);
    }

    function _checkRecipient(address candidate) internal view {
        require(candidate != address(0), "Zero recipient");
        require(candidate != address(this), "Recipient is self");
        require(candidate != address(token), "Recipient is token");
    }

    function _checkLimit(uint256 rate, uint256 period) internal pure {
        require(rate == 0 || period > 0, "Zero period");
    }

    function forward() external whenNotPaused {
        uint256 amount = _reserve();
        require(amount > 0, "Nothing to forward");
        _sweep(amount);
    }

    function tryForward() external returns (uint256 forwarded) {
        if (paused) return 0;
        forwarded = _reserve();
        if (forwarded > 0) _sweep(forwarded);
    }

    function _sweep(uint256 amount) internal {
        token.safeTransfer(recipient, amount);
        emit Forwarded(address(token), recipient, amount);
    }

    function _reserve() internal returns (uint256 amount) {
        if (dripRate == 0) {
            return token.balanceOf(address(this));
        }
        _refill();
        uint256 bal = token.balanceOf(address(this));
        amount = bucket < bal ? bucket : bal;
        bucket -= amount;
    }

    function availableBalance() external view returns (uint256) {
        if (paused) return 0;
        if (dripRate == 0) {
            return token.balanceOf(address(this));
        }
        uint256 refilled = _previewBucket();
        uint256 bal = token.balanceOf(address(this));
        return refilled < bal ? refilled : bal;
    }

    function _rawAccrued() internal view returns (uint256) {
        return ((block.timestamp - lastAccrual) * dripRate) / dripPeriod;
    }

    function _previewBucket() internal view returns (uint256) {
        uint256 replenished = bucket + _rawAccrued();
        return replenished > maxReserve ? maxReserve : replenished;
    }

    function _refill() internal {
        if (_rawAccrued() == 0) return;
        bucket = _previewBucket();
        lastAccrual = block.timestamp;
    }

    function setRecipient(address newRecipient) external onlyOwner {
        _checkRecipient(newRecipient);
        emit RecipientUpdated(recipient, newRecipient);
        recipient = newRecipient;
    }

    function setDripLimit(uint256 rate, uint256 period, uint256 maxReserve_) external onlyOwner {
        _checkLimit(rate, period);
        if (dripRate != 0) {
            _refill();
        } else {
            bucket = 0;
        }
        lastAccrual = block.timestamp;
        if (bucket > maxReserve_) bucket = maxReserve_;
        dripRate = rate;
        dripPeriod = period;
        maxReserve = maxReserve_;
        emit DripLimitUpdated(rate, period, maxReserve_);
    }

    function pause() external onlyOwner {
        if (!paused && dripRate != 0) _refill();
        paused = true;
        emit Paused(true);
    }

    function unpause() external onlyOwner {
        if (paused && dripRate != 0) lastAccrual = block.timestamp;
        paused = false;
        emit Paused(false);
    }

    function rescueToken(address asset, address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "Zero address");
        IERC20(asset).safeTransfer(to, amount);
        emit TokenRescued(asset, to, amount);
    }

    function rescueETH(address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "Zero address");
        (bool ok,) = to.call{value: amount}("");
        require(ok, "ETH transfer failed");
        emit EthRescued(to, amount);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != owner, "Already owner");
        pendingOwner = newOwner;
        emit OwnershipTransferProposed(owner, newOwner);
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "Not pending owner");
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }
}
