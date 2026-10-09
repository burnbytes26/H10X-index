// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

/// @notice Reads H10XVault.configVersion straight from storage. Unlike a call to `configVersion()`, a cheatcode read
///         does not consume a pending `vm.prank`, so it can be used inside the argument list of a pranked call.
library CfgVersion {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    /// @dev Storage slot of `configVersion` (forge inspect H10XVault storageLayout). Checked by a test.
    uint256 internal constant SLOT = 13;

    function get(address vault) internal view returns (uint256) {
        return uint256(VM.load(vault, bytes32(SLOT)));
    }
}
