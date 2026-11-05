// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Minimal stand-ins used only by test-export-delta-exits.sh against a local anvil.

contract MockBridge {
    uint32 public networkID = 1;
    address public gasTokenAddress;
    uint32 public gasTokenNetwork;
    mapping(address => uint32) public originNetwork;
    mapping(address => address) public originAddress;

    function setOrigin(address token, uint32 net, address orig) external {
        originNetwork[token] = net;
        originAddress[token] = orig;
    }

    function wrappedTokenToTokenInfo(address token) external view returns (uint32, address) {
        return (originNetwork[token], originAddress[token]);
    }
}

contract MockToken {
    event Transfer(address indexed from, address indexed to, uint256 value);
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 v) external {
        balanceOf[to] += v;
        emit Transfer(address(0), to, v);
    }

    function transfer(address to, uint256 v) external returns (bool) {
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        emit Transfer(msg.sender, to, v);
        return true;
    }
}

// A locker that pays out ETH (internal call, no event) and tokens to `to`.
contract Locker {
    address public owner;

    constructor() payable {
        owner = msg.sender;
    }

    function withdraw(address to, address token, uint256 tokenAmount, uint256 ethAmount) external {
        require(msg.sender == owner, "owner");
        if (ethAmount > 0) {
            (bool ok, ) = to.call{value: ethAmount}("");
            require(ok, "eth");
        }
        if (tokenAmount > 0) MockToken(token).transfer(to, tokenAmount);
    }
}
