// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// Minimal stand-in for a "locked" smart contract: it holds ETH that only its owner can move.
contract Vault {
    address public owner;

    constructor() {
        owner = msg.sender;
    }

    receive() external payable {}

    // Lets the e2e hand a vault to another contract (a stand-in for a multisig/controller).
    function transferOwnership(address newOwner) external {
        require(msg.sender == owner, "not owner");
        owner = newOwner;
    }

    function withdraw(address payable to, uint256 amount) external {
        require(msg.sender == owner, "not owner");
        (bool ok,) = to.call{value: amount}("");
        require(ok, "transfer failed");
    }
}
