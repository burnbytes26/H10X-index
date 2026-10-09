# H10XVault — pre-audit static analysis, manual review and fix

**Date:** 30 September 2026 · **updated 5 October 2026** (1.3.0)
**Scope:** `src/H10XVault.sol` and `src/interfaces/ISaucerSwap.sol`
**Versions:** 1.1.0 (reviewed) → 1.2.0 (fix for M-1, verified on Hedera testnet) → **1.3.0** (fixes from an independent pre-mainnet review; rehearsed on Hedera testnet on 5 October 2026)
**Compiler:** solc 0.8.28, EVM `cancun`, optimizer 200 runs, `bytecode_hash = "ipfs"`
**Runtime size (1.3.0):** 23,882 bytes (694 bytes under the 24,576-byte limit; 1.2.0 was 23,994 with the metadata hash)
**Tests (1.3.0):** 124 Foundry tests passing in the repository; the reviewers' extended suites (141 and 153 tests, stateful campaigns and mutation testing) also pass

This is a self-review made before a professional audit. It is not an audit.

## Tools

| Tool | Version | Detectors | 1.1.0 | 1.2.0 | 1.3.0 |
|---|---|---|---|---|---|
| Slither | 0.11.6 | 102 | 26 (0 High, 6 Medium, 17 Low, 3 Informational) | 31 (0 High, 10 Medium, 19 Low, 2 Informational) | 28 (0 High, 10 Medium, 18 Low, 0 Informational) |
| Aderyn | 0.6.8 | 88 | 11 (1 High, 10 Low) | 11 (1 High, 10 Low) | 10 types (1 High, 9 Low), 50 instances |

Raw output is in this folder: `slither-1.1.0.json`, `slither-1.2.0.json`, `slither-1.3.0.json`, `aderyn-1.1.0.md`, `aderyn-1.2.0.md` and `aderyn-1.3.0.md`. Slither runs with dependencies (`node_modules`, `lib`) and tests filtered out, as in every previous run.

## Summary

- **No exploitable vulnerability was found by the tools** in either version. Every finding was triaged by hand.
- **Manual review found one Low/Medium issue (M-1)** in 1.1.0: anyone could block `removeComponent` by donating 1 unit of the component. **It is fixed in 1.2.0.**
- The Slither findings that are new in 1.2.0 come from the fix itself: state is written after the router call, and zero checks use exact equality. They are triaged below; none is exploitable.
- **The fix was verified on the live Hedera testnet** on 30 September 2026: a donation made while the sale was pending was sold with the rest, and the component left the basket in the same transaction. Issue and redeem still work. See "Testnet verification of 1.2.0" below.
- **1.3.0 (5 October 2026):** an independent pre-mainnet review found three Medium and several Low issues in 1.2.0. None let an outsider take funds from the vault directly; one (F-8) let a well-timed outsider profit from a pending exit swap through a sandwich. 1.3.0 fixes all of them except F-1, which is the documented trust in the multisig, and F-5, a harmless dust case with a workaround. See the next section.

## 1.3.0 — independent pre-mainnet review and fixes (4–5 October 2026)

Before the mainnet deployment of an immutable contract, a second, deeper self-review ran in four separate tracks, each by a reviewer working only from the code, the tests and live network data (this is still not a professional audit):
1. **Manual review with proofs of concept:** line-by-line review, 12 PoCs and a stateful fuzz campaign that also changes the basket.
2. **Adversarial testing:** stateful invariant campaigns (up to 1.25M calls per run), 20,000-step random walks, 25 fuzz tests and a mutation harness.
3. **Hedera platform research**: behaviour of the HTS system contract on mainnet v0.77.2 (key queries, deleted tokens, hooks, rent, EVM version), checked against the consensus-node source and live mainnet data.
4. **Deployment review**: deploy, seed, governance and multisig scripts, and live checks of the 10 mainnet components and the SaucerSwap contracts.

No unprivileged way to steal funds, mint H10X without paying, or block redemptions was found in 1.2.0 or 1.3.0.

### Findings and status in 1.3.0

| ID | Severity | Finding (1.2.0) | 1.3.0 |
|---|---|---|---|
| F-1 | Medium | The owner and rebalancer (the multisig) can move the basket's value out through swaps: the middle hops of a route and the minimum output are chosen by the rebalancer. This contradicted the earlier claim "the owner cannot withdraw basket assets". | **By design, documented.** The multisig is trusted with the basket's value. Mitigations: 2-of-N multisig, the signing page shows every hop and fee tier and warns about tokens outside the basket and minimums far below the current price. A price bound (TWAP) and a timelock remain possible Phase 2 hardening. |
| F-2 | Medium | A component that can no longer be transferred (deleted by its issuer's admin key, or paused/frozen) bricked `issue` forever and could never be removed. | **Fixed.** A component deleted on Hedera can be removed even with a balance (it is worthless and stays stranded) and can never be re-added. Tokens with a pause, freeze or KYC key are rejected when added. |
| F-8 | Medium | Introduced by the 1.2.0 fix: `SELL_ALL` sold whatever balance existed at execution under a `minAmountOut` fixed when the swap was proposed, so balance growth (issuance) weakened the slippage floor and enabled a sandwich. | **Fixed.** For an exiting component `amountIn` is now an upper bound: the swap sells min(amountIn, balance). The tooling signs the planned amount plus 1 %. A donation within that margin is still sold and the component still leaves atomically (M-1 stays fixed); growth beyond it only delays the exit. |
| F-3 | Low | Position-indexed arguments (`maxAmountsIn`, `minAmountsOut`, `skipMask`, weights) could hit a different token after a removal and an addition reordered the basket. | **Fixed.** `configVersion` bumps on every component addition or removal and on every fee change; `issue`, `redeem`, `setTargetWeights` and `addComponent` take the version they were built for and revert with `ConfigChanged` otherwise. |
| F-4 | Low | Weights could stop summing to 10000 after a removal, and a newly added component started at weight 0, i.e. as "exiting" (uncapped). | **Fixed.** Removal requires weight 0; `addComponent` takes the new weight vector and the new component must have a weight above 0. |
| F-6 | Low | `_addComponent` checked only existing custom fees, not a fee-schedule key that could add fees later. | **Fixed.** Components with a KYC (2), freeze (4), fee-schedule (32) or pause (64) key, custom fees, or the deleted flag are rejected; any unexpected answer from HTS reverts. |
| F-7 | Info | `issue` had no protection against a fee change between quote and execution. | **Fixed** by `configVersion` (a fee change bumps it). |
| F-5 | Info | A dust donation can still block `removeComponent` on an empty component. | **Accepted.** Workaround: buy a meaningful amount, then exit it by rebalancing. |
| I-2 | Info | `sweepHbar` could empty the vault's HBAR, which pays the token's auto-renewal. | **Fixed.** `sweepHbar` was removed: the vault accepts HBAR but nothing can take it out. |
| N-1 | Low (new) | With the version check in `redeem`, governance could make pending redemptions revert by bumping the version at will. | **Fixed.** `redeem` accepts `type(uint256).max` as "any version" (with an empty skip mask, since positions may have moved), so a holder can always leave; a `setFees` call that does not change the fees does not bump the version. |
| N-2 | Info (new) | Admission checks add about 50 HTS calls to `initializeWithToken` with 10 components. | **Measured on testnet (5 October).** Gas was not the limit. Hedera allows at most 50 child records per transaction, and every HTS call from the vault, queries included, creates one. `initializeWithToken` makes 8 calls plus 6 per component, 68 with 10 components, and failed with `MAX_CHILD_RECORDS_EXCEEDED`. The contract is unchanged: the deploy script initializes with the first 5 components (38 records) and adds the other 5 with `addComponent` (6 records each) in the same order, so the final basket, weights and `configVersion` are identical. The other functions stay within the limit with the maximum of 10 components: `issue` makes 4 calls per component plus 3 (39 measured with 9 components, so 43 with 10), `seed` 33 and `redeem` 25. |

Unchanged informational items: the `Rebalanced` event logs the requested `amountIn` (on an exit, the upper bound), fees round to 0 on amounts below 200 units, the per-swap cap applies per swap and not per period, and a vault whose entire value is in deleted tokens can only be redeemed.

### What changed in the code (1.2.0 → 1.3.0)

- `configVersion` (public): bumped by `_addComponent`, `_removeComponent` (including the automatic removal after an exit swap) and `setFees` when the fees change. Weight changes do not bump it.
- `issue(shares, maxAmountsIn, to, expectedConfigVersion)` and `redeem(shares, minAmountsOut, to, skipMask, expectedConfigVersion)`; `redeem` also accepts the "any version" sentinel.
- `addComponent(token, weightsBps, expectedConfigVersion)`: adds and sets the weights atomically; the new entry is last and must be above 0.
- `setTargetWeights(weightsBps, expectedConfigVersion)`.
- `removeComponent`: requires weight 0, and a zero balance unless the token is deleted on Hedera.
- Admission rules for components (deleted, custom fees, keys 2/4/32/64) and the same helpers for the adopted H10X token.
- Exit swaps: `amountIn` is an upper bound for a component with weight 0.
- `sweepHbar` removed.

### Evidence

- **Repository tests:** 124 pass, including 24 new tests for 1.3.0 (`test/H10XVault.v13.t.sol`): version bumps and stale orders, the redeem sentinel, the exit bound (growth not sold, donation within the bound sold and removed, fuzz), admission rules, atomic `addComponent`, and removal of a deleted component after which issuance resumes.
- **Manual review track:** 141/141 tests (the PoCs ported as regression tests), and a stateful campaign with issuer deletions, fee changes, capped and uncapped exits and re-adds: 0 violations. Verdict: GO for the contract code.
- **Adversarial track:** 153/153 tests; invariant campaigns of 5 × 50,000 and 2 × 1.25M calls and three 20,000-step walks with 0 violations (solvency, no free mint, round trips, fees, redeem liveness, backing per share, weights, stale orders); mutation testing 35/36 (the survivor is dead code). Verdict: GO.
- **Hedera facts checked on mainnet:** `getTokenKey` returns 44 (`KEY_NOT_PROVIDED`) for a missing key without reverting; all 10 mainnet components pass the admission rules (no KYC, freeze, pause or fee-schedule key, no custom fees, not deleted).
- **Static analysis:** Slither reports 28 results with dependencies filtered, 3 fewer than 1.2.0 and no new detector type. When the dependencies are included, Slither also flags the HTS system-contract calls in `initialize`, `initializeWithToken`, `_addComponent` and `removeComponent` as reentrancy; these are owner-only functions, the HTS system contract does not call back, and HTS tokens have no transfer hooks. Aderyn reports the same 10 issue types as before.

### Testnet rehearsal of 1.3.0 — PASSED (5 October 2026)

The same deployment as mainnet, on the live Hedera testnet with real HTS and SaucerSwap, the 2-of-3 test multisig as guardian and rebalancer, and 10 test tokens valued at mainnet prices.

| Item | ID |
|---|---|
| Vault (H10XVault 1.3.0, immutable, verified on Sourcify with an exact match) | [0.0.10872949](https://hashscan.io/testnet/contract/0.0.10872949) |
| H10X token (treasury and only supply key = vault) | [0.0.10872951](https://hashscan.io/testnet/token/0.0.10872951) |
| Test component deleted by its issuer | 0.0.10876083 (tDEL) |

**What was checked (times UTC, 5 October 2026):**

| # | Step | Result |
|---|---|---|
| 1 | Deploy: bytecode upload, contract with a temporary admin key, HAPI token with a metadata key, admin key removed (13:37–13:38) | SUCCESS |
| 2 | `initializeWithToken` with all 10 components in one call | **Failed: `MAX_CHILD_RECORDS_EXCEEDED`** (see below); nothing changed, 14.5M gas charged (about 12 HBAR) |
| 3 | Deploy resumed with 2.11.1: `initializeWithToken` with 5 components (4,287,574 gas, 38 child records), then 5 × `addComponent` (909,570–945,584 gas each) | SUCCESS; final basket, weights and `configVersion` 10 identical to the plan; 11 post-deploy checks passed |
| 4 | Public verification on Sourcify | exact match |
| 5 | Seed of 20 H10X, `issue` 1, `redeem` 1, `redeem` 0.5 with the "any version" sentinel (17:22) | SUCCESS; supply and fees exact to the last unit |
| 6 | Bounded exit of tGRELF: weight 0, then the swap proposed to the multisig (schedule 0.0.10876054) with an upper bound of 9.902318 and signed 2/2 (17:26) | SUCCESS; the whole 9.804275 balance was sold and tGRELF left the basket in the same transaction (`configVersion` 11) |
| 7 | tDEL added (1%), 1,000 tDEL donated to the vault, then the token **deleted by its issuer** (17:28–17:30) | SUCCESS; `balanceOf` and the vault's balance stay readable |
| 8 | Normal redeem with tDEL in the basket | Stopped by the tooling before sending (a transfer of a deleted token fails) |
| 9 | `redeem` 1 with `skipMask` for tDEL (17:56) | SUCCESS: the holder left with the other 9 components |
| 10 | tDEL weight set to 0, then `removeComponent` **with a balance of 1,000 tDEL** (17:56) | SUCCESS: the vault asked HTS, saw `deleted = true` and removed it (`configVersion` 13) |
| 11 | `issue` 1 after the removal | SUCCESS: issuance works again (F-2 fixed on a live network) |
| 12 | `addComponent(tDEL)` sent directly to the contract | Reverted with `ComponentDeleted` |

**Hedera's child-record limit (new, measured).** Hedera allows at most 50 child records per transaction, and every call from the vault to the HTS system contract, including read-only queries, creates one. Counts measured on this vault match the model exactly:

| Function (10 components) | Child records | Within 50 |
|---|---|---|
| `initializeWithToken` | 8 + 6 per component = 68 | No: initialized with 5 (38), then `addComponent` (6 each) |
| `issue` | 4 per component + 3 = 43 | Yes |
| `seed` | 3 per component + 3 = 33 | Yes |
| `redeem` | 2 per component + 5 = 25 | Yes |

The contract is unchanged: the deploy script initializes in two steps, and `MAX_COMPONENTS` = 10 keeps `issue` within the limit. A future contract that buys the basket and issues in the same transaction (a "zapper") would exceed the limit with 10 components and has to split the work.

**Mirror-node behaviour found during the rehearsal (tooling only, fixed in 2.11.2 and 2.11.3):**
- The public testnet mirror does not serve the account-hooks endpoint (HTTP 404). The deploy and seed checks now fall back to the transaction history: a hook can only be added with the contract's admin key, and the only `ContractUpdate` on the vault while it had one was the deployment's own, which removed it.
- The mirror's `eth_call` simulation does not see a deleted token (its `balanceOf` returns empty data and HTS key queries return `INVALID_TOKEN_ID`). Views that read every balance (`getBasket`, `quoteRedeem`, `backingPerShare`) therefore revert in simulation while a deleted component is in the basket, although the consensus node handles the deleted token as described above. The scripts and the website now rebuild the basket from `components()`, `targetWeightBps` and the REST balances, value the deleted component at 0, and quote a redemption with the contract's formula.

### Mainnet deployment (6 October 2026)

| Item | ID |
|---|---|
| Vault (H10XVault 1.3.0, no admin key, verified on Sourcify with an exact match) | [0.0.10907483](https://hashscan.io/mainnet/contract/0.0.10907483) |
| H10X token (treasury and only supply key = vault; metadata key = 0.0.10353916) | [0.0.10907484](https://hashscan.io/mainnet/token/0.0.10907484) |
| Owner, guardian and rebalancer: 2-of-3 multisig (owner since the seed, 6 October) | [0.0.10907480](https://hashscan.io/mainnet/account/0.0.10907480) |

Deployed with the rehearsed procedure: initialization with 5 components (4,287,318 gas) and 5 `addComponent` calls (909,540–945,553 gas), all 11 post-deployment checks passed, about 77 HBAR in total. Ownership transfer to the multisig was started in the next minute (`pendingOwner` = the multisig); it is accepted when the vault is seeded, so the operations account never holds ownership of a funded vault for longer than the seed itself. **Launch (6 October):** issuance paused; ownership acceptance proposed and signed by one member; seed of 9.697787 H10X ($10 at a NAV of $1.031154, 10 components at their target weights); second signature about 70 seconds later, making the multisig the owner; issuance reopened by the multisig (2 signatures). All three members have signed at least one executed transaction. The team chose to reuse an existing wallet for the metadata key and the fee recipient instead of fresh ones; the metadata key can only change the token's metadata and can be rotated by itself (HIP-540), and the fee recipient can be changed by the multisig.

## M-1 · `removeComponent` griefable with a dust donation — FIXED in 1.2.0

**Issue in 1.1.0:**
- `removeComponent` required the vault's balance of the token to be exactly zero.
- Any account can transfer tokens to the vault, because it is associated with every component. An attacker only had to send 1 unit after the rebalancer had sold the balance and before `removeComponent` executed.
- With the normal `maxTradeBps` (20%), a small residual could never be sold, because `floor(4 × 2000 / 10000) = 0`.
- **Impact:** the basket already holds 10 components (= `MAX_COMPONENTS`), so this could block replacing a component. No funds were at risk.

**Fix in 1.2.0:** the sale and the removal become one atomic step for a component the owner has decided to exit.
1. The owner sets the component's target weight to 0 (`setTargetWeights`; the scripts provide `npm run gov -- exit <token>`).
2. For a component whose target weight is 0, `_preTrade` does not apply the per-swap cap, and `amountIn = SELL_ALL` (`type(uint256).max`) means "the whole balance at execution time". Anything donated before execution is therefore sold too.
3. `_postTrade` removes the component in the same transaction when the swap leaves its balance at 0 and its target weight is 0.
4. `removeComponent` (owner only) still exists for components with a zero balance, for example a component added by mistake.

**Unchanged:**
- The mandatory `minAmountOut`, the overspend and underdelivery checks, and the immutable routers.
- Only the rebalancer can swap.
- Components with a target weight above 0 keep the per-swap cap and cannot use `SELL_ALL`.
- Emptying a component that still has a weight above 0 does not remove it.

**Tests in `test/H10XVault.findings.t.sol`:**
- a donation made before the sale is sold with it, and the component is removed atomically (V2 and V1 routes);
- a donation after removal is harmless, and issue and redeem keep working;
- a zero-weight component ignores the per-swap cap, and a partial sale keeps it in the basket;
- selling the exact full balance also removes it;
- with a weight above 0, the cap stays and `SELL_ALL` is rejected, and an emptied component is not removed;
- `minAmountOut` is still required, and an underdelivered swap reverts without selling or removing anything;
- only the rebalancer can do it;
- the owner's `removeComponent` still requires a zero balance;
- fuzz test: any donation from 0 to 1e15 units is sold, and the component is removed.

**Remaining edge case (accepted):** a component that never had a meaningful balance can receive a 1-unit donation whose sale returns 0 of every other component. The swap then reverts on `minAmountOut`. In practice the rebalancer can route through a component where 1 unit returns at least 1 unit. At worst the component stays in the basket with weight 0 and negligible dust, and nothing is at risk.

## Final build for publication (4 October 2026)

Before public source verification, two changes were made. Neither touches the executable code.

1. **The code comments and NatSpec were translated into English.** A script that strips comments confirms that the code itself is unchanged.
2. **The build now embeds the metadata hash** (`bytecode_hash = "ipfs"` instead of `"none"`). This lets Sourcify and HashScan report an **exact match**.
   - Runtime size: 23,994 bytes, 582 under the limit.
   - The bytes before the CBOR metadata tail are identical to the version tested on testnet.

**Evidence:**
- The English source compiled with `"none"` is byte-for-byte identical, in both creation and runtime code, to the 1.2.0 build deployed on testnet (vault 0.0.10793965). That vault can therefore be verified with the English source, with a "match" result.
- Recompiling the final build on its own from its metadata and sources reproduces the runtime bytecode exactly, including the IPFS hash. This is what Sourcify does, so the expected result for new deployments is "exact match".
- All 99 tests pass.
- Slither: 31 results, the same as before.
- Aderyn: 10 issue types and 49 instances. The "TODO comments" false positive (L-8, caused by the Spanish word "todos") no longer appears.
- Raw output: `slither-1.2.0-final.json` and `aderyn-1.2.0-final.md`.

## Tool findings — triage

| # | Tool · detector | Where | Verdict | Reason |
|---|---|---|---|---|
| 1 | Slither · reentrancy-no-eth / reentrancy-benign (new in 1.2.0) | `rebalanceV1` and `rebalanceV2` → `_postTrade` | Accepted | Removing the component after the swap is the purpose of the fix: it has to happen after the sale. Both functions are `nonReentrant` and restricted to the rebalancer. The routers are immutable SaucerSwap contracts. Components are HTS tokens with no transfer hooks. Every other non-owner state-changing entry point is `nonReentrant`, and the owner functions cannot be reached by the router. |
| 2 | Aderyn H-1 · state change after external call | `issue`, `redeem` | False positive | The calls before the state changes are `balanceOf` (STATICCALL) and HTS transfers, inside `nonReentrant` functions. |
| 3 | Slither · incorrect-equality (×3) | `burnStrayShares`, `_preTrade`, `_postTrade` | Intentional | Exact zero checks: no-op guards, and "balance is exactly 0", which is the removal condition. Nothing can be donated between the router call and the check (same transaction); a donation before the swap within the signed upper bound is sold with the rest (1.3.0). |
| 4 | Slither · uninitialized-local / Aderyn L-10 | `issue`, `initialize`, `_setTargetWeights` | Intentional | Zero-initialisation is intended. |
| 5 | Slither · unused-return / Aderyn L-9 | `rebalanceV1`, `rebalanceV2` | False positive | The received amount is measured from balance deltas in `_postTrade`, which is stricter than trusting the router's return value. |
| 6 | Slither · missing-zero-check / Aderyn L-7 | constructor, `setGuardian`, `setRebalancer` | Intentional | `address(0)` disables a router, the guardian or the rebalancer. `feeRecipient` is checked. |
| 7 | Slither · calls-loop / Aderyn L-6 | `issue`, `redeem`, quotes, `seed` | Accepted | At most 10 components. If a component starts reverting, `issue` fails safely. `redeem` skips masked components before calling them, so `skipMask` remains an emergency exit. |
| 8 | Slither · reentrancy-events / low-level-calls | `sweepHbar` | Removed in 1.3.0 | The function no longer exists. |
| 9 | Aderyn L-5 · `nonReentrant` not first | 8 functions | Accepted | The preceding modifiers make no external calls. |
| 10 | Aderyn L-2 · costly operations in loop | `_removeComponent`, `_initBasket`, `_setTargetWeights` | Accepted | Bounded to 10 elements. |
| 11 | Aderyn L-3, L-4 | constants and path offsets | Style | Literals are clearer here. |
| 12 | Aderyn L-8 · TODO comments | L30 | False positive | Matches the Spanish word "todos" ("all"). |
| 13 | Aderyn L-1 · centralization | owner functions | By design | See below. |
| 14 | Slither · cyclomatic-complexity | `_checkAdoptable` | Accepted | A linear list of on-chain checks. |

## Trust assumptions for auditors

1. **The multisig is trusted with the basket's value (F-1).** The rebalancer chooses the route (including intermediate hops) and `minAmountOut`; there is no on-chain price bound or cooldown. A malicious or compromised owner/rebalancer multisig could move the basket's value out through swaps against pools it controls (with weights untouched it is limited to `maxTradeBps` of a component per swap; the owner can raise that limit or set a weight to 0, which removes it). Mitigations: a 2-of-N multisig, the signing page decodes every hop and fee tier and warns about tokens outside the basket and minimums far below the current price, and members are asked to cross-check on HashScan. Possible Phase 2 hardening: a TWAP price bound, a per-period cap and a timelock.
2. **Owner powers.** The owner can:
   - add components (subject to the admission rules) and remove components with weight 0 and a zero balance, or deleted ones;
   - set target weights, including 0 to exit a component;
   - set fees up to the hard cap of 1%;
   - set `maxTradeBps`, the supply cap and the issuance pause.

   The owner **cannot** mint without the basket, take basket tokens or HBAR out directly, pause redemptions or renounce ownership. Governance changes can make an in-flight `redeem` revert with `ConfigChanged`; the holder can always redeem with the "any version" sentinel.
3. **Component token keys.** From 1.3.0 no component may have a KYC, freeze, pause or fee-schedule key. Admin, wipe and supply keys are allowed: an issuer with an admin key (SAUCE, PACK) could delete its token, and the bridge contracts behind HTS-WBTC and HTS-WETH hold wipe and supply keys. A deleted component can be removed from the basket (its balance is lost); until then `redeem` with `skipMask` lets holders exit with the rest.
4. **No oracle.** `issue` and `redeem` are strictly pro rata, with rounding in the vault's favour. Invariant tests check that backing per share never decreases.
5. **Adopted token.** `initializeWithToken` checks on-chain that the token's treasury and only supply key are the vault, and that it has no forbidden keys or custom fees. This was verified on testnet on 29 September 2026.

## Testnet verification of 1.2.0 — PASSED (30 September 2026)

The fix was tested on the live Hedera testnet, with real HTS tokens, real SaucerSwap routers and the rebalancer as a multisig. The attack was reproduced in its worst-case form: the donation arrived **after** the sale had been proposed and **before** it executed.

**Environment:**

| Item | ID |
|---|---|
| Vault (H10XVault 1.2.0) | [0.0.10793965](https://hashscan.io/testnet/contract/0.0.10793965) |
| H10X token (treasury and only supply key = vault; no admin key) | [0.0.10793966](https://hashscan.io/testnet/token/0.0.10793966) |
| Operator (owner, pays the transactions) | 0.0.10754475 |
| Rebalancer and guardian: 2-of-3 test multisig | 0.0.10762876 |
| Basket | 10 test tokens valued at real mainnet prices; router V1 0.0.19264, router V2 0.0.1414040 |

**Deployment:**
- The full flow ran: contract, then the HAPI token with a metadata key, then ContractUpdate, then `initializeWithToken`. All 8 post-deploy checks passed, and the contract reports `H10XVault 1.2.0`.
- The first attempt stopped twice with `INSUFFICIENT_PAYER_BALANCE`:
  - With 53.5 HBAR in the operator account, the first steps stopped. The account was topped up from the faucet.
  - At step 4, `initializeWithToken` reserved 11.5M gas and the account held only 9.9 HBAR.
- Both times the run resumed from the saved state without creating a duplicate contract or token. The second resume used `GAS_INIT=9000000`.
- Lesson applied to the scripts: Hedera charges only the gas used (HIP-1249), but the payer must hold enough to cover the whole gas limit. The default limit is now 9M, since 7.96M was measured with 10 components.

**Steps (all times UTC, 30 September 2026):**

| # | Step | Transaction | Result |
|---|---|---|---|
| 1 | Seed: 100 H10X at the reference index NAV of $1.089155 | 0.0.10754475@1790781057.462333312 (15:10:57) | SUCCESS |
| 2 | `setTargetWeights`: tGRELF 5% → 0%, rest pro rata | 0.0.10754475@1790781119.514665048 (15:11:59) | SUCCESS |
| 3 | Rebalance proposed as scheduled transaction [0.0.10794087](https://hashscan.io/testnet/schedule/0.0.10794087): route V1 tGRELF → tWHBAR, `amountIn = SELL_ALL`, `minAmountOut` 50.363351 tWHBAR | schedule created | pending signatures |
| 4 | **Attack:** 1 minimal unit of tGRELF donated to the vault **after** the proposal. Vault balance went from 4,966,004,353 to 4,966,004,354 units. | 0.0.10754475@1790781134.128294717 (15:12:14) | SUCCESS |
| 5 | Two multisig members (0.0.10762872, 0.0.10762874) sign. The schedule executes. | schedule 0.0.10794087 | **SUCCESS, 2/2 signatures** |
| 6 | Regression: `issue` 1 H10X (0.995 net after the 0.5% fee) | 0.0.10754475@1790781185.132990545 (15:13:05) | SUCCESS |
| 7 | Regression: `redeem` 1 H10X | 0.0.10754475@1790781197.832873620 (15:13:17) | SUCCESS |

**Observed result:**
- The swap sold **the whole tGRELF balance, including the donated unit**, which was never part of the 49.660043 amount shown when the swap was proposed. The vault's tWHBAR went from 201.51 to 252.12, so the vault received about 50.61 tWHBAR against a quote of 50.616434 and a minimum of 50.363351.
- **tGRELF was removed from the basket in the same transaction.** `status` lists 9 components, with no tGRELF row, and target weights summing to 100%.
- NAV after the exit was $1.090959 per H10X, against a seed NAV of $1.089155. The difference is price movement; the swap cost about 0.47% against the reference price.
- After issuing and redeeming 1 H10X: supply 100.005 H10X, accrued fees 0.01 H10X (0.5% in plus 0.5% out), NAV $1.102351.
- Token keys were unchanged: the vault is the only supply key, there are no other keys, and the contract has no admin key.

**Conclusion:** M-1 is fixed on a live network. A donation made while the sale is pending no longer blocks the exit: the dust is sold with everything else, and the component leaves the basket atomically. Issue and redeem are unaffected.

## Deployment gas and cost (measured on testnet, 4 October 2026)

Gas costs 83 tinybar per unit on both networks (about 0.83 HBAR per million gas).

| Operation | Gas used | Cost |
|---|---|---|
| Bytecode upload (file create and 12 appends) | — | 44.2 HBAR |
| Contract create | 5.32M | 14.4 HBAR |
| Token create (HAPI) | — | 9.9 HBAR |
| `initializeWithToken` with 10 components (1.2.0) | 7.96M | 6.7 HBAR |
| `initializeWithToken` with 5 components (1.3.0, 5 October) | 4.29M | 3.6 HBAR |
| `addComponent` × 5 (1.3.0, 5 October) | 0.91M–0.95M each | 3.9 HBAR in total |
| **Full deployment** | | **about 77 HBAR (about $8)** |

An earlier version of this table overstated the cost about tenfold. The deploy script now requires 120 HBAR before starting, because the payer must be able to cover the whole gas limit when each transaction is submitted, and Hedera fees are fixed in USD. The 1.3.0 initialization is split in two steps because of Hedera's limit of 50 child records per transaction (see the 1.3.0 rehearsal above); together they cost about 7.5 HBAR, and the full 1.3.0 deployment about 76 HBAR. A failed initialization charges its whole gas limit (14.5M gas, about 12 HBAR, on 5 October).
