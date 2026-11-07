// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {H10XVault} from "../src/H10XVault.sol";
import {BaseVaultTest} from "./BaseVaultTest.sol";
import {CfgVersion} from "./utils/CfgVersion.sol";

/// @notice Hallazgos del programa de recompensas (noviembre de 2026), documentados como tests sobre el contrato tal cual
///         (no cambia). El HTS simulado reproduce ahora dos reglas de Hedera que importan aquí: una transferencia de una
///         cuenta a sí misma se rechaza (ACCOUNT_REPEATED_IN_ACCOUNT_AMOUNTS) y un token con freezeDefault siempre tiene
///         clave freeze (TOKEN_HAS_NO_FREEZE_KEY al crearlo sin ella).
contract H10XVaultBountyTest is BaseVaultTest {
    bytes internal constant SELF_TRANSFER = bytes("ACCOUNT_REPEATED_IN_ACCOUNT_AMOUNTS");

    /// hayokakoweda75 #1: con la propia bóveda como wallet de comisiones, claimFees revierte y burnStrayShares no las toca.
    /// Solo lo puede provocar el owner; no se pierde nada y se arregla poniendo otra vez una wallet.
    function test_feeRecipientVault_claimFeesReverts_andRecovers() public {
        _approveAll(alice);
        uint256 cv = CfgVersion.get(address(vault));
        vm.prank(alice);
        vault.issue(10e8, _maxIn(), alice, cv);
        uint256 acc = vault.accruedFeeShares();
        assertGt(acc, 0, "la emision deja comisiones");

        vm.prank(owner);
        vault.setFeeRecipient(address(vault));
        vm.expectRevert(SELF_TRANSFER);
        vault.claimFees();
        vm.expectRevert(H10XVault.ZeroAmount.selector);
        vault.burnStrayShares();
        assertEq(vault.accruedFeeShares(), acc, "las comisiones siguen anotadas");

        vm.prank(owner);
        vault.setFeeRecipient(feeRec);
        vault.claimFees();
        assertEq(IERC20(h10x).balanceOf(feeRec), acc, "se cobran enteras");
        assertEq(vault.accruedFeeShares(), 0);
    }

    /// hayokakoweda75 #2: emitir o reembolsar con la bóveda como destino revierte con un error (no en silencio). Es lo
    /// seguro: si funcionara, quien llama estaría regalando sus tokens a la bóveda.
    function test_issueAndRedeem_toVault_revert() public {
        _approveAll(alice);
        uint256 cv = CfgVersion.get(address(vault));
        uint256 supply = IERC20(h10x).totalSupply();
        vm.prank(alice);
        vm.expectRevert(SELF_TRANSFER);
        vault.issue(10e8, _maxIn(), address(vault), cv);

        vm.prank(owner);
        vm.expectRevert(SELF_TRANSFER);
        vault.redeem(10e8, _zeros(), address(vault), 0, cv);
        assertEq(IERC20(h10x).totalSupply(), supply, "nada cambia");
    }

    /// Franklyn #3: poner un peso a 0 (salida decidida) quita el tope por operación, pero un rebalanceo nunca vende más del
    /// amountIn firmado. Uno dentro del tope vende lo mismo antes o después del cambio de peso; uno por encima del tope
    /// revierte mientras el token tenga peso y, solo tras el cambio, vende lo firmado (como mucho, el saldo).
    function test_rebalanceAfterWeightZero_neverSellsMoreThanSigned() public {
        uint256 bal = _vaultBal(2);
        uint256 cap = (bal * 2000) / 10_000;
        r2.setRate(1, 400);

        vm.prank(rebalancer);
        vm.expectRevert(abi.encodeWithSelector(H10XVault.TradeTooLarge.selector, bal, cap));
        vault.rebalanceV2(_v2Path(comps[2], comps[0]), bal, 1, block.timestamp);

        uint16[] memory w = new uint16[](3);
        w[0] = 7000;
        w[1] = 3000;
        w[2] = 0;
        uint256 cv = CfgVersion.get(address(vault));
        vm.prank(owner);
        vault.setTargetWeights(w, cv);

        vm.prank(rebalancer);
        vault.rebalanceV2(_v2Path(comps[2], comps[0]), cap, 1, block.timestamp);
        assertEq(_vaultBal(2), bal - cap, "dentro del tope: exactamente lo firmado");

        uint256 rest = _vaultBal(2);
        vm.prank(rebalancer);
        vault.rebalanceV2(_v2Path(comps[2], comps[0]), rest + 1e8, 1, block.timestamp);
        assertEq(_vaultBal(2), 0, "por encima del saldo: vende el saldo, nunca mas");
        assertFalse(vault.isComponent(comps[2]), "y la misma operacion lo retira");
    }

    /// Informe del freezeDefault: en Hedera un token con freezeDefault siempre tiene clave freeze, y la bóveda rechaza
    /// cualquier componente con clave freeze. El HTS simulado ya no deja crear el caso imposible.
    function test_freezeDefault_alwaysHasFreezeKey_rejectedAtAdmission() public {
        address plain = _createToken("Plain", "tPLN", 8, 1e18);
        vm.expectRevert(bytes("TOKEN_HAS_NO_FREEZE_KEY"));
        hts.setTokenFlags(plain, false, true, false, false);

        address frozen = hts.hapiCreate(address(this), address(0), 4, 8, 1e18); // con clave freeze
        hts.setTokenFlags(frozen, false, true, false, false);
        uint16[] memory w = _weightsPlusOne(vault);
        uint256 cv = CfgVersion.get(address(vault));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(H10XVault.TokenHasForbiddenKey.selector, 4));
        vault.addComponent(frozen, w, cv);
    }
}
