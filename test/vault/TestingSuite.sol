// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;

import "forge-std/Test.sol";

// import {Vault} from "../../contracts/vault/Vault.sol";
import {Bridge} from "../../contracts/vault/Bridge.sol";
import {BridgeConfig} from "../../contracts/vault/BridgeConfigV4.sol";

import {BridgeRouter} from "../../contracts/router/BridgeRouter.sol";
import {BridgeQuoter} from "../../contracts/router/BridgeQuoter.sol";

interface IProxy {
    function upgradeTo(address) external;
}

interface IVault {
    function NODEGROUP_ROLE() external view returns (bytes32);

    function bridgeVersion() external view returns (uint256);
}

contract TestingSuite is Test {
    address public constant BRIDGE = 0x2796317b0fF8538F253012862c06787Adfb8cEb6;
    address public constant NUSD = 0x1B84765dE8B7566e4cEAF4D0fD3c5aF52D3DdE4F;

    bytes32 public constant ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    function testVault() public {
        bytes memory vaultBytecode = vm.getCode(
            "./artifacts/Vault.sol/Vault.json"
        );
        address _vault;
        assembly {
            _vault := create(0, add(vaultBytecode, 0x20), mload(vaultBytecode))
        }
        IVault vault = IVault(_vault);
        assertEq(vault.NODEGROUP_ROLE(), keccak256("NODEGROUP_ROLE"));

        assertEq(vault.bridgeVersion(), 7);
    }
}
