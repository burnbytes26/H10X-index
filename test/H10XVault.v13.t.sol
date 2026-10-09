// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {H10XVault} from "../src/H10XVault.sol";
import {BaseVaultTest} from "./BaseVaultTest.sol";
import {CfgVersion} from "./utils/CfgVersion.sol";

/// @notice Changes in H10XVault 1.3.0, from the pre-mainnet review of 4 October 2026:
///         - configVersion: position-indexed arguments are bound to the basket/fees they were quoted for;
///         - exits: `amountIn` is an upper bound for weight-0 components (the signed minAmountOut stays meaningful);
///         - admission rules: no KYC/freeze/pause/fee-schedule keys, no custom fees, not deleted;
///         - a component deleted by its issuer can be removed (it used to brick issuance forever);
///         - removeComponent requires weight 0; no HBAR withdrawal function.
contract H10XVaultV13Test is BaseVaultTest {
    uint256 internal constant ALL = type(uint256).max;

    function _cv() internal view returns (uint256) {
        return CfgVersion.get(address(vault));
    }

    function _w3(uint16 a, uint16 b, uint16 c) internal pure returns (uint16[] memory w) {
        w = new uint16[](3);
        w[0] = a;
        w[1] = b;
        w[2] = c;
    }

    /// Sets component `i` to weight 0 (exit decided), the rest pro rata of the base weights.
    function _exit(uint256 i) internal {
        uint16[] memory w = i == 0 ? _w3(0, 6000, 4000) : i == 1 ? _w3(7000, 0, 3000) : _w3(7000, 3000, 0);
        uint256 v = _cv();
        vm.prank(owner);
        vault.setTargetWeights(w, v);
    }

    function _maxIn(uint256 n) internal pure returns (uint256[] memory m) {
        m = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            m[i] = type(uint256).max;
        }
    }

    // ═══════════════════ configVersion ═══════════════════

    function test_version() public view {
        assertEq(vault.VERSION(), "H10XVault 1.3.0");
    }

    function test_configVersion_slotMatchesGetter_andStartsAtComponentCount() public view {
        assertEq(_cv(), vault.configVersion());
        assertEq(vault.configVersion(), 3); // three components added at initialization
    }

    function test_configVersion_bumpsOnAddRemoveFeesAndAutoRemoval_notOnWeights() public {
        uint256 v0 = vault.configVersion();
        address extra = _createToken("Extra", "EXT", 8, 1e18);
        _addComp(extra);
        assertEq(vault.configVersion(), v0 + 1);

        vm.prank(owner);
        vault.setFees(40, 40);
        assertEq(vault.configVersion(), v0 + 2);

        uint16[] memory w = new uint16[](4);
        w[0] = 5000;
        w[1] = 3000;
        w[2] = 2000;
        vm.prank(owner);
        vault.setTargetWeights(w, v0 + 2); // the extra goes back to weight 0 (exit), weights do not bump
        assertEq(vault.configVersion(), v0 + 2, "weights do not change positions or fees");

        vm.prank(owner);
        vault.removeComponent(extra); // weight 0, balance 0
        assertEq(vault.configVersion(), v0 + 3);

        _exit(2);
        r2.setRate(1, 400);
        vm.prank(rebalancer);
        vault.rebalanceV2(_v2Path(comps[2], comps[0]), ALL, 1, block.timestamp);
        assertFalse(vault.isComponent(comps[2]));
        assertEq(vault.configVersion(), v0 + 4, "auto-removal bumps too");
    }

    function test_issue_staleConfig_reverts_feeChangeCannotLandFirst() public {
        _approveAll(alice);
        uint256 stale = vault.configVersion();
        vm.prank(owner);
        vault.setFees(100, 100); // the owner raises the fee between quote and execution
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(H10XVault.ConfigChanged.selector, stale, stale + 1));
        vault.issue(1e8, _maxIn(), alice, stale);
        vm.prank(alice);
        vault.issue(1e8, _maxIn(), alice, stale + 1);
    }

    function test_redeem_staleConfig_reverts() public {
        uint256 stale = vault.configVersion();
        address extra = _createToken("Extra", "EXT", 8, 1e18);
        _addComp(extra);
        _approveAll(owner);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(H10XVault.ConfigChanged.selector, stale, stale + 1));
        vault.redeem(1e8, new uint256[](4), owner, 0, stale);
    }

    /// A no-op setFees does not bump the version, so the owner cannot invalidate pending orders for free.
    function test_setFees_noOp_doesNotBump() public {
        uint256 v0 = vault.configVersion();
        vm.prank(owner);
        vault.setFees(FEE_BPS, FEE_BPS);
        assertEq(vault.configVersion(), v0);
    }

    /// Redeem with expectedConfigVersion = max skips the check: a holder can always leave (with skipMask = 0),
    /// whatever governance does in between.
    function test_redeem_anyVersionSentinel_alwaysExits() public {
        uint256 stale = vault.configVersion();
        vm.prank(owner);
        vault.setFees(100, 100);
        _approveAll(owner);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(H10XVault.ConfigChanged.selector, stale, stale + 1));
        vault.redeem(1e8, new uint256[](3), owner, 0, stale);
        vm.prank(owner);
        uint256[] memory out = vault.redeem(1e8, new uint256[](3), owner, 0, type(uint256).max);
        assertGt(out[0], 0);
        assertGt(out[2], 0);
    }

    function test_setTargetWeights_staleConfig_reverts() public {
        uint256 stale = vault.configVersion();
        vm.prank(owner);
        vault.setFees(40, 40);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(H10XVault.ConfigChanged.selector, stale, stale + 1));
        vault.setTargetWeights(_w3(5000, 3000, 2000), stale);
    }

    /// The adversarial campaign's counterexample: a same-length replacement (exit + add) between building and
    /// executing a redeem re-mapped its skipMask onto another token. Now the stale redeem reverts.
    function test_staleSkipMask_afterReplacement_reverts() public {
        _approveAll(alice);
        vm.prank(alice);
        vault.issue(100e8, _maxIn(), alice, _cv());
        uint256 quoted = _cv();

        _exit(1); // governance replaces tSAUCE (index 1)…
        r2.setRate(1, 400);
        vm.prank(rebalancer);
        vault.rebalanceV2(_v2Path(comps[1], comps[0]), ALL, 1, block.timestamp);
        address x = _createToken("New", "NEW", 8, 1e18);
        _addComp(x); // …with a new token: still 3 components, positions moved
        assertEq(vault.components().length, 3);
        assertEq(vault.components()[1], comps[2], "swap-and-pop moved tDOVU into slot 1");

        uint256 current = _cv();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(H10XVault.ConfigChanged.selector, quoted, current));
        vault.redeem(10e8, new uint256[](3), alice, 1 << 1, quoted); // meant "skip tSAUCE", would now skip tDOVU
    }

    function test_staleWeights_afterReplacement_reverts() public {
        uint256 quoted = _cv();
        _exit(1);
        r2.setRate(1, 400);
        vm.prank(rebalancer);
        vault.rebalanceV2(_v2Path(comps[1], comps[0]), ALL, 1, block.timestamp);
        address x = _createToken("New", "NEW", 8, 1e18);
        _addComp(x);
        uint256 current = _cv();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(H10XVault.ConfigChanged.selector, quoted, current));
        vault.setTargetWeights(_w3(5000, 5000, 0), quoted); // meant "exit tDOVU" in the old order
    }

    // ═══════════════════ exits: amountIn is an upper bound ═══════════════════

    /// Between proposal and execution, issuance can grow the exiting balance. Only the signed bound is sold, under
    /// the signed floor; the rest needs another round (before 1.3.0 SELL_ALL sold everything under a stale floor).
    function test_exit_growthBeyondBound_isNotSold() public {
        _exit(2);
        uint256 planned = _vaultBal(2);
        uint256 bound = planned + planned / 100; // planned + 1 %

        _approveAll(alice);
        vm.prank(alice);
        vault.issue(1_000e8, _maxIn(), alice, _cv()); // doubles supply → the exiting balance doubles too
        uint256 grown = _vaultBal(2);
        assertEq(grown, 2 * planned);

        r2.setRate(1, 400);
        vm.prank(rebalancer);
        uint256 got = vault.rebalanceV2(_v2Path(comps[2], comps[0]), bound, (planned * 99) / 100 / 400, block.timestamp);
        assertEq(got, bound / 400);
        assertEq(_vaultBal(2), grown - bound, "only the signed amount is sold");
        assertTrue(vault.isComponent(comps[2]), "stays until another round");

        uint256 rest = _vaultBal(2);
        vm.prank(rebalancer);
        vault.rebalanceV2(_v2Path(comps[2], comps[0]), rest + rest / 100, 1, block.timestamp);
        assertEq(_vaultBal(2), 0);
        assertFalse(vault.isComponent(comps[2]));
    }

    /// A donation within the margin is sold with the rest and the component still leaves atomically (M-1 stays fixed).
    function test_exit_donationWithinBound_isSoldAndComponentRemoved() public {
        _exit(2);
        uint256 planned = _vaultBal(2);
        vm.prank(bob);
        IERC20(comps[2]).transfer(address(vault), planned / 200); // +0.5 %
        r2.setRate(1, 400);
        vm.prank(rebalancer);
        vault.rebalanceV2(_v2Path(comps[2], comps[0]), planned + planned / 100, 1, block.timestamp);
        assertEq(_vaultBal(2), 0);
        assertFalse(vault.isComponent(comps[2]));
    }

    /// A donation larger than the margin cannot block the exit for free: the excess stays in the vault (a gift to
    /// holders) and the next round sells it.
    function test_exit_donationBeyondBound_onlyDelaysAtTheDonorsCost() public {
        _exit(2);
        uint256 planned = _vaultBal(2);
        uint256 bound = planned + planned / 100;
        vm.prank(bob);
        IERC20(comps[2]).transfer(address(vault), planned / 10); // +10 %
        r2.setRate(1, 400);
        vm.prank(rebalancer);
        vault.rebalanceV2(_v2Path(comps[2], comps[0]), bound, 1, block.timestamp);
        assertEq(_vaultBal(2), planned + planned / 10 - bound);
        uint256 rest = _vaultBal(2);
        vm.prank(rebalancer);
        vault.rebalanceV2(_v2Path(comps[2], comps[0]), rest, 1, block.timestamp);
        assertFalse(vault.isComponent(comps[2]));
    }

    function test_exit_sellAllConstantStillMeansWholeBalance() public {
        _exit(2);
        r1.setRate(1, 400);
        uint256 bal = _vaultBal(2);
        vm.prank(rebalancer);
        uint256 got = vault.rebalanceV1(_v1(comps[2], comps[0]), ALL, 1, block.timestamp);
        assertEq(got, bal / 400);
        assertFalse(vault.isComponent(comps[2]));
    }

    function _v1(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    // ═══════════════════ admission rules ═══════════════════

    function _tokenWithKeys(uint256 extraKeyMask, address supplyContract) internal returns (address t) {
        t = hts.hapiCreate(address(this), supplyContract, extraKeyMask, 8, 1e18);
    }

    function test_addComponent_rejectsKycFreezeFeeSchedulePauseKeys() public {
        uint256[4] memory bad = [uint256(2), 4, 32, 64];
        for (uint256 i; i < bad.length; ++i) {
            address t = _tokenWithKeys(bad[i], address(0));
            uint16[] memory w = _weightsPlusOne(vault);
            uint256 cv = _cv();
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(H10XVault.TokenHasForbiddenKey.selector, bad[i]));
            vault.addComponent(t, w, cv);
        }
    }

    function test_addComponent_acceptsAdminWipeSupplyKeys_likeSAUCE_PACK_WBTC() public {
        address t = _tokenWithKeys(1 | 8, address(0xBEEF)); // admin + wipe + supply (a contract)
        _addComp(t);
        assertTrue(vault.isComponent(t));
    }

    function test_addComponent_rejectsCustomFees() public {
        address t = _createToken("Fee", "FEE", 8, 1e18);
        hts.setHasCustomFees(t, true);
        uint16[] memory w = _weightsPlusOne(vault);
        uint256 cv = _cv();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(H10XVault.ComponentHasCustomFees.selector, t));
        vault.addComponent(t, w, cv);
    }

    function test_addComponent_rejectsDeletedToken() public {
        address t = _createToken("Del", "DEL", 8, 1e18);
        hts.setTokenFlags(t, false, false, true, false);
        uint16[] memory w = _weightsPlusOne(vault);
        uint256 cv = _cv();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(H10XVault.ComponentDeleted.selector, t));
        vault.addComponent(t, w, cv);
    }

    function test_addComponent_rejectsUnknownToken() public {
        uint16[] memory w = _weightsPlusOne(vault);
        uint256 cv = _cv();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(H10XVault.HtsError.selector, int64(167))); // INVALID_TOKEN_ID
        vault.addComponent(address(0xDEAD), w, cv);
    }

    function test_addComponent_setsWeightsAtomically_newComponentNeverInExitMode() public {
        address t = _createToken("New", "NEW", 8, 1e18);
        uint16[] memory w = new uint16[](4);
        w[0] = 5000;
        w[1] = 3000;
        w[2] = 2000;
        uint256 cv = _cv();
        vm.prank(owner);
        vm.expectRevert(H10XVault.InvalidBps.selector); // weight 0 for the new component is rejected
        vault.addComponent(t, w, cv);

        w[0] = 4000;
        w[3] = 1000;
        vm.prank(owner);
        vault.addComponent(t, w, cv);
        assertEq(vault.targetWeightBps(t), 1000);
        assertEq(vault.targetWeightBps(comps[0]), 4000);
    }

    function test_addComponent_staleConfigOrBadWeights_revert() public {
        address t = _createToken("New", "NEW", 8, 1e18);
        uint16[] memory w = _weightsPlusOne(vault);
        uint256 cv = _cv();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(H10XVault.ConfigChanged.selector, cv + 1, cv));
        vault.addComponent(t, w, cv + 1);

        w[0] += 1; // sum 10001
        vm.prank(owner);
        vm.expectRevert(H10XVault.WeightsMustSum10000.selector);
        vault.addComponent(t, w, cv);

        uint16[] memory short = new uint16[](3); // missing the new entry
        short[0] = 5000;
        short[1] = 3000;
        short[2] = 2000;
        vm.prank(owner);
        vm.expectRevert(H10XVault.LengthMismatch.selector);
        vault.addComponent(t, short, cv);
    }

    // ═══════════════════ a component deleted by its issuer ═══════════════════

    /// SAUCE and PACK have admin keys, so their issuers could delete them. Before 1.3.0 that bricked issuance forever:
    /// the token could not be sold, and removeComponent required a zero balance.
    function test_deletedComponent_canBeRemoved_issuanceResumes_neverReadded() public {
        _approveAll(alice);
        vm.prank(alice);
        vault.issue(10e8, _maxIn(), alice, _cv());

        hts.setTokenFlags(comps[1], false, false, true, false); // the issuer deletes tSAUCE
        uint256 v = _cv();

        vm.prank(alice);
        vm.expectRevert(); // TOKEN_WAS_DELETED: the deleted token cannot move
        vault.issue(1e8, _maxIn(), alice, v);

        vm.prank(alice);
        vault.redeem(1e8, new uint256[](3), alice, 1 << 1, v); // holders can still leave, skipping it

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(H10XVault.ComponentHasWeight.selector, comps[1]));
        vault.removeComponent(comps[1]);

        _exit(1);
        assertGt(_vaultBal(1), 0, "the vault still holds the (now worthless) tokens");
        vm.prank(owner);
        vault.removeComponent(comps[1]);
        assertFalse(vault.isComponent(comps[1]));

        uint256 v2 = _cv();
        vm.prank(alice);
        vault.issue(1e8, _maxIn(2), alice, v2);

        uint16[] memory w3 = _weightsPlusOne(vault);
        uint256 cv3 = _cv();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(H10XVault.ComponentDeleted.selector, comps[1]));
        vault.addComponent(comps[1], w3, cv3);
    }

    /// A live (not deleted) component with a balance still cannot be removed directly.
    function test_liveComponentWithBalance_stillNeedsToBeSold() public {
        _exit(1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(H10XVault.ComponentNotEmpty.selector, comps[1]));
        vault.removeComponent(comps[1]);
    }

    // ═══════════════════ fuzz ═══════════════════

    /// Any exit bound sells exactly min(bound, balance) and removes the component only when it sold everything.
    function testFuzz_exitBound(uint256 bound, uint96 donation) public {
        _exit(2);
        if (donation > 0) {
            vm.prank(bob);
            IERC20(comps[2]).transfer(address(vault), uint256(donation) % 1e15);
        }
        uint256 bal = _vaultBal(2);
        bound = bound == ALL ? ALL : bound % (2 * bal + 1);
        vm.assume(bound >= 400); // the mock pool pays 1/400; the output must be at least 1
        r2.setRate(1, 400);
        vm.prank(rebalancer);
        vault.rebalanceV2(_v2Path(comps[2], comps[0]), bound, 1, block.timestamp);
        uint256 sold = bound >= bal ? bal : bound;
        assertEq(_vaultBal(2), bal - sold);
        assertEq(vault.isComponent(comps[2]), sold != bal);
    }
}
