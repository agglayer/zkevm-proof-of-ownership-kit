// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// Test-only ERC-20: anyone can mint, the bridge can burn (wrapped tokens).
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    address public bridge;

    event Transfer(address indexed from, address indexed to, uint256 value);

    constructor(address bridge_) {
        bridge = bridge_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external {
        require(msg.sender == bridge, "only bridge");
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

// Stand-in for the zkEVM bridge (PolygonZkEVMBridgeV2) on the test chain: same bridgeAsset /
// bridgeMessage / networkID / getTokenWrappedAddress signatures and the same BridgeEvent. Network id
// 1, as zkEVM. ETH stays in the bridge, tokens of this network are locked in it, wrapped tokens are
// burned — as the real bridge does.
contract MockBridge {
    event BridgeEvent(
        uint8 leafType,
        uint32 originNetwork,
        address originAddress,
        uint32 destinationNetwork,
        address destinationAddress,
        uint256 amount,
        bytes metadata,
        uint32 depositCount
    );

    uint32 public constant networkID = 1;
    uint32 public depositCount;

    struct Origin {
        uint32 network;
        address token;
    }

    mapping(address => Origin) public wrappedToOrigin;
    mapping(bytes32 => address) internal originToWrapped;

    // Test setup: registers <wrapped> as the wrapped token of (<originNetwork>, <originAddress>).
    function setWrapped(uint32 originNetwork, address originAddress, address wrapped) external {
        wrappedToOrigin[wrapped] = Origin(originNetwork, originAddress);
        originToWrapped[keccak256(abi.encodePacked(originNetwork, originAddress))] = wrapped;
    }

    function getTokenWrappedAddress(uint32 originNetwork, address originAddress) external view returns (address) {
        return originToWrapped[keccak256(abi.encodePacked(originNetwork, originAddress))];
    }

    function bridgeAsset(uint32 destinationNetwork, address destinationAddress, uint256 amount, address token, bool, bytes calldata)
        external
        payable
    {
        uint32 originNetwork;
        address originAddress;
        if (token == address(0)) {
            require(msg.value == amount, "amount != value");
        } else {
            require(msg.value == 0, "no value with a token");
            Origin memory o = wrappedToOrigin[token];
            if (o.token != address(0)) {
                MockERC20(token).burn(msg.sender, amount);
                (originNetwork, originAddress) = (o.network, o.token);
            } else {
                MockERC20(token).transferFrom(msg.sender, address(this), amount);
                (originNetwork, originAddress) = (networkID, token);
            }
        }
        emit BridgeEvent(0, originNetwork, originAddress, destinationNetwork, destinationAddress, amount, "", depositCount++);
    }

    function bridgeMessage(uint32 destinationNetwork, address destinationAddress, bool, bytes calldata metadata) external payable {
        emit BridgeEvent(1, networkID, msg.sender, destinationNetwork, destinationAddress, msg.value, metadata, depositCount++);
    }

    // NOT in the real bridge: emits an ETH BridgeEvent without taking any ETH, so the e2e can check
    // that the balance check catches events the bridge did not back with funds.
    function fakeBridgeEvent(address destinationAddress, uint256 amount) external {
        emit BridgeEvent(0, 0, address(0), 0, destinationAddress, amount, "", depositCount++);
    }
}
