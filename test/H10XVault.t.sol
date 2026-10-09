// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BaseVaultTest} from "./BaseVaultTest.sol";
import {H10XVault} from "../src/H10XVault.sol";
import {MockHTSToken} from "./mocks/MockHTS.sol";
import {CfgVersion} from "./utils/CfgVersion.sol";

contract H10XVaultTest is BaseVaultTest {
    // ═══════════════════ inicialización ═══════════════════

    function test_initialize_tokenHasOnlySupplyKeyHeldByVault() public view {
        assertEq(hts.keyMaskOf(h10x), 16, "solo supply key: sin admin/freeze/wipe/kyc/pause/fee");
        assertEq(hts.supplyContractOf(h10x), address(vault), "supply key = contrato");
        assertEq(hts.treasuryOf(h10x), address(vault), "tesoreria = contrato");
        assertEq(IERC20Metadata(h10x).decimals(), 8);
        assertEq(hts.lastCreateValue(), 20 ether, "el HBAR de la tarifa se reenvia a 0x167");
    }

    function test_initialize_setsBasketAndAssociates() public view {
        address[] memory c = vault.components();
        assertEq(c.length, 3);
        for (uint256 i; i < 3; ++i) {
            assertEq(c[i], comps[i]);
            assertEq(vault.targetWeightBps(comps[i]), weights[i]);
            assertTrue(hts.isAssociated(comps[i], address(vault)));
        }
    }

    function test_ownerIsDeployer() public view {
        assertEq(vault.owner(), owner);
    }

    function test_initialize_onlyOnce() public {
        vm.prank(owner);
        vm.expectRevert(H10XVault.AlreadyInitialized.selector);
        vault.initialize{value: 1 ether}("X", "X", "", comps, weights);
    }

    function test_initialize_onlyOwner() public {
        H10XVault v = _freshVault();
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        v.initialize{value: 1 ether}("X", "X", "", comps, weights);
    }

    function test_initialize_rejectsComponentWithCustomFees() public {
        hts.setHasCustomFees(comps[1], true);
        H10XVault v = _freshVault();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(H10XVault.ComponentHasCustomFees.selector, comps[1]));
        v.initialize{value: 1 ether}("X", "X", "", comps, weights);
    }

    function test_initialize_rejectsBadWeights() public {
        H10XVault v = _freshVault();
        uint16[] memory w = new uint16[](3);
        w[0] = 5000;
        w[1] = 3000;
        w[2] = 1999;
        vm.prank(owner);
        vm.expectRevert(H10XVault.WeightsMustSum10000.selector);
        v.initialize{value: 1 ether}("X", "X", "", comps, w);
    }

    function test_initialize_rejectsDuplicates() public {
        H10XVault v = _freshVault();
        address[] memory c = new address[](2);
        c[0] = comps[0];
        c[1] = comps[0];
        uint16[] memory w = new uint16[](2);
        w[0] = 5000;
        w[1] = 5000;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(H10XVault.DuplicateComponent.selector, comps[0]));
        v.initialize{value: 1 ether}("X", "X", "", c, w);
    }

    function test_nobodyButVaultCanMint() public {
        // Ni el owner puede mintear H10X llamando directamente a HTS.
        vm.prank(owner);
        (bool ok, bytes memory res) =
            address(hts).call(abi.encodeWithSignature("mintToken(address,int64,bytes[])", h10x, int64(1e8), new bytes[](0)));
        assertTrue(ok);
        (int64 rc,,) = abi.decode(res, (int64, int64, int64[]));
        assertEq(rc, 7, "INVALID_SIGNATURE");
    }

    // ═══════════════════ seed ═══════════════════

    function test_seed_state() public view {
        assertEq(vault.totalSupply(), SEED_SHARES);
        assertEq(IERC20(h10x).balanceOf(owner), SEED_SHARES);
        assertEq(_vaultBal(0), 5_000e8);
        assertEq(_vaultBal(1), 30_000e6);
        assertEq(_vaultBal(2), 2_000_000e8);
        uint256[] memory per = vault.backingPerShare();
        assertEq(per[0], 5e8); // 5 tWHBAR por H10X
        assertEq(per[1], 30e6); // 30 tSAUCE por H10X
        assertEq(per[2], 2_000e8); // 2.000 tDOVU por H10X
    }

    function test_seed_onlyOnce() public {
        uint256[] memory a = new uint256[](3);
        a[0] = 1;
        a[1] = 1;
        a[2] = 1;
        vm.prank(owner);
        vm.expectRevert(H10XVault.AlreadySeeded.selector);
        vault.seed(a, 1e8, owner);
    }

    function test_issue_beforeSeed_reverts() public {
        (H10XVault v,) = _freshInitializedVault();
        vm.prank(alice);
        vm.expectRevert(H10XVault.NotSeeded.selector);
        v.issue(1e8, _maxIn(), alice, CfgVersion.get(address(v)));
    }

    function test_seed_tooSmall_reverts() public {
        (H10XVault v,) = _freshInitializedVault();
        uint256[] memory a = new uint256[](3);
        a[0] = 1;
        a[1] = 1;
        a[2] = 1;
        vm.prank(owner);
        vm.expectRevert(H10XVault.SeedTooSmall.selector);
        v.seed(a, 1e8 - 1, owner);
    }

    // ═══════════════════ issue ═══════════════════

    function test_issue_pullsProportionalAndMintsNetOfFee() public {
        _approveAll(alice);
        uint256[] memory before = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            before[i] = IERC20(comps[i]).balanceOf(alice);
        }
        (uint256[] memory quoted, uint256 quotedOut) = vault.quoteIssue(10e8);

        vm.prank(alice);
        (uint256 out, uint256[] memory paid) = vault.issue(10e8, _maxIn(), alice, CfgVersion.get(address(vault)));

        uint256 fee = (10e8 * uint256(FEE_BPS)) / 10_000;
        assertEq(out, 10e8 - fee);
        assertEq(out, quotedOut);
        assertEq(IERC20(h10x).balanceOf(alice), 10e8 - fee);
        assertEq(vault.accruedFeeShares(), fee);
        assertEq(vault.totalSupply(), SEED_SHARES + 10e8);
        // 10 H10X = 1 % del supply → 1 % de cada componente
        assertEq(paid[0], 50e8);
        assertEq(paid[1], 300e6);
        assertEq(paid[2], 20_000e8);
        for (uint256 i; i < 3; ++i) {
            assertEq(paid[i], quoted[i]);
            assertEq(before[i] - IERC20(comps[i]).balanceOf(alice), paid[i]);
        }
    }

    function test_issue_roundsUpInFavourOfVault() public {
        _approveAll(alice);
        vm.prank(alice);
        (, uint256[] memory paid) = vault.issue(1, _maxIn(), alice, CfgVersion.get(address(vault))); // 1 unidad mínima
        // 5.000e8 * 1 / 1.000e8 = 5 exacto; 30.000e6 * 1 / 1.000e8 = 0,3 → 1 (ceil)
        assertEq(paid[0], 5);
        assertEq(paid[1], 1);
        assertEq(paid[2], 2_000);
    }

    function test_issue_respectsMaxAmountsIn() public {
        _approveAll(alice);
        uint256[] memory maxIn = _maxIn();
        maxIn[1] = 300e6 - 1;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(H10XVault.SlippageIn.selector, comps[1], 300e6, 300e6 - 1));
        vault.issue(10e8, maxIn, alice, CfgVersion.get(address(vault)));
    }

    function test_issue_pausedByGuardian_onlyOwnerUnpauses() public {
        _approveAll(alice);
        vm.prank(guardian);
        vault.pauseIssuance();

        vm.prank(alice);
        vm.expectRevert(H10XVault.IssuanceIsPaused.selector);
        vault.issue(1e8, _maxIn(), alice, CfgVersion.get(address(vault)));

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vault.unpauseIssuance();

        vm.prank(owner);
        vault.unpauseIssuance();
        vm.prank(alice);
        vault.issue(1e8, _maxIn(), alice, CfgVersion.get(address(vault)));
    }

    function test_pause_onlyOwnerOrGuardian() public {
        vm.prank(alice);
        vm.expectRevert(H10XVault.Unauthorized.selector);
        vault.pauseIssuance();
    }

    function test_issue_supplyCap() public {
        _approveAll(alice);
        vm.prank(owner);
        vault.setSupplyCap(SEED_SHARES + 5e8);
        vm.prank(alice);
        vm.expectRevert(H10XVault.SupplyCapExceeded.selector);
        vault.issue(5e8 + 1, _maxIn(), alice, CfgVersion.get(address(vault)));
        vm.prank(alice);
        vault.issue(5e8, _maxIn(), alice, CfgVersion.get(address(vault)));
    }

    function test_issue_receiverMustBeAssociated() public {
        _approveAll(alice);
        address stranger = makeAddr("stranger");
        vm.prank(alice);
        vm.expectRevert("TOKEN_NOT_ASSOCIATED_TO_ACCOUNT");
        vault.issue(1e8, _maxIn(), stranger, CfgVersion.get(address(vault)));
    }

    function test_issue_rejectsFeeOnTransferComponent() public {
        _approveAll(alice);
        MockHTSToken(comps[2]).setTransferFeeBps(100);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(H10XVault.TransferAmountMismatch.selector, comps[2], 20_000e8, 19_800e8)
        );
        vault.issue(10e8, _maxIn(), alice, CfgVersion.get(address(vault)));
    }

    function test_issue_withoutAllowance_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.issue(1e8, _maxIn(), alice, CfgVersion.get(address(vault)));
    }

    function test_issue_noFreeMintWhenVaultIsEmpty() public {
        // Si un emisor "wipea" todos los componentes, la emisión no puede mintear gratis.
        for (uint256 i; i < 3; ++i) {
            deal(comps[i], address(vault), 0);
        }
        _approveAll(alice);
        vm.prank(alice);
        vm.expectRevert(H10XVault.NothingDeposited.selector);
        vault.issue(1e8, _maxIn(), alice, CfgVersion.get(address(vault)));
    }

    // ═══════════════════ redeem ═══════════════════

    function test_redeem_returnsProportionalNetOfFee() public {
        _approveAll(alice);
        vm.prank(alice);
        (uint256 got, uint256[] memory paid) = vault.issue(100e8, _maxIn(), alice, CfgVersion.get(address(vault)));

        uint256 supply = vault.totalSupply();
        uint256[] memory quoted = vault.quoteRedeem(got);
        uint256[] memory vb = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            vb[i] = _vaultBal(i);
        }

        vm.prank(alice);
        uint256[] memory out = vault.redeem(got, _zeros(), alice, 0, CfgVersion.get(address(vault)));

        uint256 fee = (got * uint256(FEE_BPS)) / 10_000;
        uint256 net = got - fee;
        assertEq(IERC20(h10x).balanceOf(alice), 0);
        assertEq(vault.totalSupply(), supply - net);
        for (uint256 i; i < 3; ++i) {
            assertEq(out[i], Math.mulDiv(vb[i], net, supply));
            assertEq(out[i], quoted[i]);
            assertLt(out[i], paid[i], "ida y vuelta nunca gana (comisiones)");
        }
    }

    function test_redeem_worksWhileIssuancePaused() public {
        _approveAll(owner);
        vm.prank(guardian);
        vault.pauseIssuance();
        vm.prank(owner);
        vault.redeem(10e8, _zeros(), owner, 0, CfgVersion.get(address(vault)));
        assertEq(IERC20(h10x).balanceOf(owner), SEED_SHARES - 10e8);
    }

    function test_redeem_respectsMinAmountsOut() public {
        _approveAll(owner);
        uint256[] memory q = vault.quoteRedeem(10e8);
        uint256[] memory mins = new uint256[](3);
        mins[0] = q[0] + 1;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(H10XVault.SlippageOut.selector, comps[0], q[0], q[0] + 1));
        vault.redeem(10e8, mins, owner, 0, CfgVersion.get(address(vault)));
    }

    function test_redeem_requiresAllowance() public {
        vm.startPrank(owner);
        IERC20(h10x).approve(address(vault), 0); // _seed() dejó allowance máxima
        vm.expectRevert();
        vault.redeem(10e8, _zeros(), owner, 0, CfgVersion.get(address(vault)));
        vm.stopPrank();
    }

    function test_redeem_skipMask_forfeitsComponentToRemainingHolders() public {
        _approveAll(owner);
        uint256 perBefore = vault.backingPerShare()[1];
        vm.prank(owner);
        uint256[] memory out = vault.redeem(100e8, _zeros(), owner, 1 << 1, CfgVersion.get(address(vault)));
        assertEq(out[1], 0);
        assertGt(out[0], 0);
        assertGt(vault.backingPerShare()[1], perBefore, "el componente saltado queda para el resto");
    }

    function test_redeem_everything_leavesOnlyFeeShares() public {
        _approveAll(owner);
        vm.prank(owner);
        vault.redeem(SEED_SHARES, _zeros(), owner, 0, CfgVersion.get(address(vault)));
        uint256 fee = (SEED_SHARES * uint256(FEE_BPS)) / 10_000;
        assertEq(vault.totalSupply(), fee);
        assertEq(vault.accruedFeeShares(), fee);
        // Lo que queda en la bóveda respalda exactamente esas comisiones
        uint256[] memory q = vault.quoteRedeem(fee);
        assertGt(q[0], 0);
    }

    // ═══════════════════ comisiones y H10X perdidos ═══════════════════

    function test_claimFees_sendsAccruedToRecipient() public {
        _approveAll(alice);
        vm.prank(alice);
        vault.issue(100e8, _maxIn(), alice, CfgVersion.get(address(vault)));
        uint256 fee = vault.accruedFeeShares();
        assertGt(fee, 0);
        vault.claimFees();
        assertEq(IERC20(h10x).balanceOf(feeRec), fee);
        assertEq(vault.accruedFeeShares(), 0);
        vm.expectRevert(H10XVault.ZeroAmount.selector);
        vault.claimFees();
    }

    function test_burnStrayShares_keepsAccruedFees() public {
        _approveAll(alice);
        vm.prank(alice);
        (uint256 got,) = vault.issue(100e8, _maxIn(), alice, CfgVersion.get(address(vault)));
        uint256 fee = vault.accruedFeeShares();
        vm.prank(alice);
        IERC20(h10x).transfer(address(vault), 1e8); // error del usuario
        uint256 supplyBefore = vault.totalSupply();

        uint256 burned = vault.burnStrayShares();
        assertEq(burned, 1e8);
        assertEq(vault.totalSupply(), supplyBefore - 1e8);
        assertEq(vault.accruedFeeShares(), fee);
        assertEq(IERC20(h10x).balanceOf(address(vault)), fee);
        assertEq(IERC20(h10x).balanceOf(alice), got - 1e8);
    }

    function test_setFees_hardCap() public {
        vm.startPrank(owner);
        vm.expectRevert(H10XVault.FeeTooHigh.selector);
        vault.setFees(101, 0);
        vm.expectRevert(H10XVault.FeeTooHigh.selector);
        vault.setFees(0, 101);
        vault.setFees(100, 0);
        vm.stopPrank();
        assertEq(vault.mintFeeBps(), 100);
        assertEq(vault.redeemFeeBps(), 0);
    }

    function test_setters_onlyOwner() public {
        vm.startPrank(alice);
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);
        vm.expectRevert(err);
        vault.setFees(1, 1);
        vm.expectRevert(err);
        vault.setFeeRecipient(alice);
        vm.expectRevert(err);
        vault.setRebalancer(alice);
        vm.expectRevert(err);
        vault.setGuardian(alice);
        vm.expectRevert(err);
        vault.setSupplyCap(1);
        vm.expectRevert(err);
        vault.setMaxTradeBps(1);
        vm.expectRevert(err);
        vault.addComponent(alice, new uint16[](0), 0);
        vm.stopPrank();
    }

    // ═══════════════════ rebalanceo ═══════════════════

    function test_rebalanceV2_swapsWithinLimitsAndResetsAllowance() public {
        uint256 amountIn = _vaultBal(0) / 10; // 10 % < maxTradeBps (20 %)
        r2.setRate(6, 1); // 1 tWHBAR(8d) → 6 unidades de tSAUCE(6d) por unidad: da igual, es un mock
        uint256 in0 = _vaultBal(0);
        uint256 out0 = _vaultBal(1);
        vm.prank(rebalancer);
        uint256 got = vault.rebalanceV2(_v2Path(comps[0], comps[1]), amountIn, 1, block.timestamp);
        assertEq(got, amountIn * 6);
        assertEq(_vaultBal(0), in0 - amountIn);
        assertEq(_vaultBal(1), out0 + got);
        assertEq(IERC20(comps[0]).allowance(address(vault), address(r2)), 0);
    }

    function test_rebalanceV2_multiHopUsesPathEnds() public {
        bytes memory path = abi.encodePacked(comps[2], uint24(3000), comps[0], uint24(500), comps[1]);
        r2.setRate(1, 1);
        vm.prank(rebalancer);
        uint256 got = vault.rebalanceV2(path, 1e8, 1, block.timestamp);
        assertEq(got, 1e8);
    }

    function test_redeem_zeroFee_fullExitEmptiesVault() public {
        vm.prank(owner);
        vault.setFees(0, 0);
        _approveAll(owner);
        vm.prank(owner);
        vault.redeem(SEED_SHARES, _zeros(), owner, 0, CfgVersion.get(address(vault)));
        assertEq(vault.totalSupply(), 0);
        for (uint256 i; i < 3; ++i) {
            assertEq(_vaultBal(i), 0);
        }
    }

    function test_rebalanceV1_swapsWithinLimits() public {
        uint256 amountIn = _vaultBal(2) / 5; // 20 % justo
        address[] memory path = new address[](2);
        path[0] = comps[2];
        path[1] = comps[0];
        r1.setRate(1, 400);
        vm.prank(rebalancer);
        uint256 got = vault.rebalanceV1(path, amountIn, 1, block.timestamp);
        assertEq(got, amountIn / 400);
        assertEq(IERC20(comps[2]).allowance(address(vault), address(r1)), 0);
    }

    function test_rebalance_onlyRebalancer() public {
        vm.prank(owner);
        vm.expectRevert(H10XVault.Unauthorized.selector);
        vault.rebalanceV2(_v2Path(comps[0], comps[1]), 1e8, 1, block.timestamp);
    }

    function test_rebalance_tooLarge() public {
        uint256 maxIn = (_vaultBal(0) * 2000) / 10_000;
        vm.prank(rebalancer);
        vm.expectRevert(abi.encodeWithSelector(H10XVault.TradeTooLarge.selector, maxIn + 1, maxIn));
        vault.rebalanceV2(_v2Path(comps[0], comps[1]), maxIn + 1, 1, block.timestamp);
    }

    function test_rebalance_onlyBetweenComponents() public {
        address outsider = _createToken("Outsider", "OUT", 8, 1e18);
        vm.prank(rebalancer);
        vm.expectRevert(abi.encodeWithSelector(H10XVault.NotAComponent.selector, outsider));
        vault.rebalanceV2(_v2Path(comps[0], outsider), 1e8, 1, block.timestamp);
    }

    function test_rebalance_requiresMinOut() public {
        vm.prank(rebalancer);
        vm.expectRevert(H10XVault.MinOutRequired.selector);
        vault.rebalanceV2(_v2Path(comps[0], comps[1]), 1e8, 0, block.timestamp);
    }

    function test_rebalance_badPath() public {
        vm.prank(rebalancer);
        vm.expectRevert(H10XVault.BadPath.selector);
        vault.rebalanceV2(abi.encodePacked(comps[0], uint24(3000)), 1e8, 1, block.timestamp);
    }

    function test_rebalance_catchesRouterUnderdelivery() public {
        r2.setRate(1, 2);
        r2.setIgnoreMinOut(true); // router malicioso/erróneo que no respeta el mínimo
        vm.prank(rebalancer);
        vm.expectRevert(abi.encodeWithSelector(H10XVault.TradeUnderdelivered.selector, 0.5e8, 1e8));
        vault.rebalanceV2(_v2Path(comps[0], comps[1]), 1e8, 1e8, block.timestamp);
    }

    // ═══════════════════ gestión de la cesta ═══════════════════

    function test_addComponent_newComponentNotRequiredUntilBought() public {
        address extra = _createToken("Extra", "EXT", 8, 1e18);
        uint16[] memory w = new uint16[](4);
        w[0] = 4000;
        w[1] = 3000;
        w[2] = 2000;
        w[3] = 1000;
        vm.prank(owner);
        vault.addComponent(extra, w, CfgVersion.get(address(vault)));
        assertTrue(hts.isAssociated(extra, address(vault)));
        assertEq(vault.targetWeightBps(extra), 1000);

        _approveAll(alice);
        uint256[] memory maxIn = new uint256[](4);
        for (uint256 i; i < 4; ++i) {
            maxIn[i] = type(uint256).max;
        }
        vm.prank(alice);
        (, uint256[] memory paid) = vault.issue(1e8, maxIn, alice, CfgVersion.get(address(vault)));
        assertEq(paid[3], 0);
    }

    function test_removeComponent_requiresZeroWeightAndEmptyBalance_thenWorks() public {
        // 1.3.0: a component with a target weight cannot be removed (keeps the weights summing to 10000)
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(H10XVault.ComponentHasWeight.selector, comps[2]));
        vault.removeComponent(comps[2]);

        // Sell all tDOVU while it still has a weight (cap raised to 100 %): emptied but still a component
        vm.prank(owner);
        vault.setMaxTradeBps(10_000);
        r2.setRate(1, 400);
        uint256 all = _vaultBal(2);
        vm.prank(rebalancer);
        vault.rebalanceV2(_v2Path(comps[2], comps[0]), all, 1, block.timestamp);
        assertTrue(vault.isComponent(comps[2]));

        uint16[] memory w = new uint16[](3);
        w[0] = 7000;
        w[1] = 3000;
        vm.prank(owner);
        vault.setTargetWeights(w, CfgVersion.get(address(vault)));
        vm.prank(owner);
        vault.removeComponent(comps[2]);
        assertEq(vault.components().length, 2);
        assertFalse(vault.isComponent(comps[2]));
    }

    function test_removeComponent_weightZeroButNotEmpty_reverts() public {
        uint16[] memory w = new uint16[](3);
        w[0] = 7000;
        w[1] = 3000;
        vm.prank(owner);
        vault.setTargetWeights(w, CfgVersion.get(address(vault)));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(H10XVault.ComponentNotEmpty.selector, comps[2]));
        vault.removeComponent(comps[2]);
    }

    function test_removeComponent_lastOneAlwaysHasWeight() public {
        (H10XVault v,) = _freshInitializedVault();
        uint16[] memory w = new uint16[](3);
        w[0] = 10_000;
        vm.startPrank(owner);
        v.setTargetWeights(w, CfgVersion.get(address(v)));
        v.removeComponent(comps[2]);
        v.removeComponent(comps[1]);
        // the last component must carry the whole weight, so it can never be removed
        vm.expectRevert(abi.encodeWithSelector(H10XVault.ComponentHasWeight.selector, comps[0]));
        v.removeComponent(comps[0]);
        vm.stopPrank();
    }

    function test_maxComponents() public {
        address[] memory extra = new address[](8);
        for (uint256 i; i < 8; ++i) {
            extra[i] = _createToken("T", "T", 8, 1e18);
        }
        for (uint256 i; i < 7; ++i) {
            _addComp(extra[i]); // 3 + 7 = 10
        }
        uint16[] memory w = _weightsPlusOne(vault);
        uint256 cv = CfgVersion.get(address(vault));
        vm.prank(owner);
        vm.expectRevert(H10XVault.TooManyComponents.selector);
        vault.addComponent(extra[7], w, cv);
    }

    // ═══════════════════ propiedad y HBAR ═══════════════════

    function test_renounceOwnership_disabled() public {
        vm.prank(owner);
        vm.expectRevert(H10XVault.RenounceDisabled.selector);
        vault.renounceOwnership();
    }

    function test_ownership_isTwoStep() public {
        vm.prank(owner);
        vault.transferOwnership(bob);
        assertEq(vault.owner(), owner);
        vm.prank(bob);
        vault.acceptOwnership();
        assertEq(vault.owner(), bob);
    }

    /// 1.3.0: the vault accepts HBAR (reserve for possible future auto-renew fees) but has no way to send it.
    function test_hbar_acceptedButNeverWithdrawable() public {
        vm.deal(alice, 5 ether);
        vm.prank(alice);
        (bool sent,) = address(vault).call{value: 5 ether}("");
        assertTrue(sent);
        vm.prank(owner);
        (bool ok,) = address(vault).call(abi.encodeWithSignature("sweepHbar(address,uint256)", owner, 1 ether));
        assertFalse(ok);
        assertEq(address(vault).balance, 5 ether);
    }

    // ═══════════════════ fuzz ═══════════════════

    /// Emitir y reembolsar nunca devuelve más de lo aportado, y nunca baja el respaldo por H10X.
    function testFuzz_roundTrip_neverProfits_backingNeverDrops(uint256 shares) public {
        shares = bound(shares, 1, 40_000e8);
        _approveAll(alice);
        uint256[] memory perBefore = _backingScaled();

        vm.prank(alice);
        (uint256 got, uint256[] memory paid) = vault.issue(shares, _maxIn(), alice, CfgVersion.get(address(vault)));
        _assertBackingNotBelow(perBefore);

        uint256[] memory perMid = _backingScaled();
        if (got == 0) return;
        vm.prank(alice);
        uint256[] memory out = vault.redeem(got, _zeros(), alice, 0, CfgVersion.get(address(vault)));
        _assertBackingNotBelow(perMid);

        for (uint256 i; i < 3; ++i) {
            assertLe(out[i], paid[i]);
        }
    }

    function testFuzz_quotesMatchExecution(uint256 shares) public {
        shares = bound(shares, 1, 10_000e8);
        _approveAll(alice);
        (uint256[] memory qIn, uint256 qOut) = vault.quoteIssue(shares);
        vm.prank(alice);
        (uint256 got, uint256[] memory paid) = vault.issue(shares, qIn, alice, CfgVersion.get(address(vault)));
        assertEq(got, qOut);
        for (uint256 i; i < 3; ++i) {
            assertEq(paid[i], qIn[i]);
        }
        uint256[] memory qR = vault.quoteRedeem(got);
        vm.prank(alice);
        uint256[] memory out = vault.redeem(got, qR, alice, 0, CfgVersion.get(address(vault)));
        for (uint256 i; i < 3; ++i) {
            assertEq(out[i], qR[i]);
        }
    }

    // ═══════════════════ helpers ═══════════════════

    /// @dev Respaldo por unidad de H10X con escala 1e18 (más fino que la vista del contrato).
    function _backingScaled() internal view returns (uint256[] memory per) {
        uint256 supply = vault.totalSupply();
        per = new uint256[](comps.length);
        for (uint256 i; i < comps.length; ++i) {
            per[i] = (_vaultBal(i) * 1e18) / supply;
        }
    }

    function _assertBackingNotBelow(uint256[] memory prev) internal view {
        uint256[] memory nowPer = _backingScaled();
        for (uint256 i; i < prev.length; ++i) {
            assertGe(nowPer[i], prev[i], "respaldo por H10X no puede bajar");
        }
    }

    function _freshVault() internal returns (H10XVault v) {
        vm.prank(owner);
        v = new H10XVault(feeRec, guardian, rebalancer, address(r1), address(r2), FEE_BPS, FEE_BPS, 2000);
    }

    function _freshInitializedVault() internal returns (H10XVault v, address token) {
        v = _freshVault();
        vm.prank(owner);
        v.initialize{value: 1 ether}("H10X Index", "H10X", "", comps, weights);
        token = v.h10x();
        _assoc(owner, token);
    }
}
