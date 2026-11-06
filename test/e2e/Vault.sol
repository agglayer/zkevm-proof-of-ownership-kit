// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// Minimal stand-in for a "locked" smart contract: it holds ETH that only its owner can move.
contract Vault {
    address public owner;

    constructor() {
        owner = msg.sender;
    }

    receive() external payable {}

    function withdraw(address payable to, uint256 amount) external {
        require(msg.sender == owner, "not owner");
        (bool ok,) = to.call{value: amount}("");
        require(ok, "transfer failed");
    }
}
