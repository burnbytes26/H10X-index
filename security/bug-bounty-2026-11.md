# H10X bug bounty: results

**Hedera testnet · ended 6 November 2026 · H10XVault 1.3.0 (mainnet 0.0.10907483)**

For the bug bounty we offered **$2,000 in HBAR** to anyone who could, from an account without the team's keys, steal
from the H10X vault, mint H10X without putting the basket in, or seriously alter what backs it. **Nobody could.** Every
report was checked against the source code and the live networks.

The vault has had a self-review by the H10X team and this public bug bounty. It is not an independent audit.

| | |
|---|---|
| Critical issues | **0** |
| Researchers | 6 |
| Findings | 13, grouped below into 12 topics |
| Restricted functions tried on testnet | 17, all reverted |
| Changes to the contract | 0 (the fixes were in tooling, monitoring, tests and documentation) |

## Every finding

| # | Finding | Reported by | Assessment | What we did |
|---|---|---|---|---|
| 1 | Wipe keys on WBTC and WETH could burn the vault's balance | Kupia, Juan Alfonsus | Informational (current basket) | The key is held by contract 0.0.9675688, an ownerless ERC-20 to HTS wrapper whose only `wipeTokenAccount` call burns the caller's own tokens when unwrapping (`msg.sender`), so it can't burn the vault's. New basket rule, enforced by our governance tooling: a wipe key is only accepted if it's held by a reviewed contract that can't burn the vault's balance. Our monitoring now also alerts if a component's backing per H10X drops without a rebalance. |
| 2 | The vault has no auto-renew account and 0 HBAR, and expires on 4 January 2027 | Juan Alfonsus | Operational | Hedera doesn't enforce expiry or renewals today. When it does, the renewals of the vault and of the H10X token (whose auto-renew account is the vault) will be paid from the vault's own balance, so we fund it with HBAR, and our monitoring alerts if that balance runs low. |
| 3 | The per-trade cap applies per call, and the multisig chooses routes and minimum outputs | Kupia | Known trust assumption (F-1) | Already documented in the review: the 2-of-3 multisig is trusted with rebalancing. Our monitoring checks every proposal before it's signed: routes through tokens outside the basket, low minimum outputs and, now, amounts above the cap. |
| 4 | After `setTargetWeights` sets a weight to 0, a rebalance runs without the per-trade cap (no `configVersion` on rebalances) | Franklyn | Informational | A swap never sells more than the `amountIn` the signers approved; trades sized within the cap are unaffected; the owner and the rebalancer are the same multisig. Our monitoring now flags proposals above the cap for tokens that still have weight. New test. |
| 5 | `setFeeRecipient(address(this))` makes `claimFees` revert (HTS rejects a transfer to the same account) | hayokakoweda75 | Informational (owner only) | Only the multisig can do it, nothing is lost, and it's fixed by setting a real recipient again. Our tooling now refuses the vault as recipient and our monitoring flags it. New test. |
| 6 | `issue` and `redeem` with the vault as recipient revert | hayokakoweda75 | Informational | They revert with an explicit error, which is the safe outcome: otherwise the caller would be donating to the vault. New test. |
| 7 | A donation above the signed margin delays an exit by one round | hayokakoweda75 | Documentation (known, F-8) | Already documented as F-8. The review now says that its live verification ran 1.2.0, and how 1.3.0 differs. |
| 8 | The mutation-testing harness isn't in the repository | hayokakoweda75 | Documentation | The review, the website and the whitepaper now say that the 35-of-36 result comes from the reviewers' suite. |
| 9 | Could a component's admin key add a blocked key type (freeze, fee schedule) after admission? | Franklyn | Not possible on Hedera | A key that is absent when a token is created can never be added, not even by its admin (HIP-540; `TokenUpdate` resolves to `TOKEN_HAS_NO_FREEZE_KEY` and similar). The admission checks hold for the component's whole life. |
| 10 | The redeem sentinel (`expectedConfigVersion = type(uint256).max`) doesn't enforce `skipMask = 0` | Franklyn | Informational (affects only the caller) | Left unenforced on purpose: with a deleted component and a configuration that keeps changing, the sentinel plus a mask is the only way out. Our redeem tool refuses the combination. |
| 11 | `freezeDefault` isn't checked in `_addComponent` | Anonymous researcher | Not possible on Hedera | A token can't be created frozen by default without a freeze key (all 172 such tokens on mainnet and all 8,626 on testnet have one), and `_addComponent` rejects components with a freeze key. Our HTS mock now matches the network. New test. |
| 12 | `claimFees` can't succeed on mainnet (recipient not associated) | Muhammad Harley | Not an issue | The recipient's address was converted to the wrong account: `0x…9dfcfc` is 0.0.10353916, our fee account, associated with H10X since October 2026. |

One report also said that the repository runs 122 tests. A clean `forge test` of the public commit `60b0c25` runs 124,
and 128 with the 4 tests added after the bounty.

## What happened on testnet

The testnet vault ran the same code as the mainnet vault, with our keeper keeping its pools at the NAV. One account
tried 17 restricted functions one by one (fees, components, weights, roles, pausing, rebalancing, initialization and
seeding), and every call reverted, as did `burnStrayShares`, which had nothing to burn. It then called `claimFees`,
which anyone can call: the testnet fees went to the configured fee account, as they should. Apart from our own keeper's
normal issues and redemptions, nobody issued or redeemed, nothing left the vault outside those operations, and its backing per H10X
never dropped.

## What changed

- **Governance tooling.** It refuses the vault as fee recipient, and it only proposes a basket token with a wipe key if
  that key is held by a reviewed contract that can't burn the vault's balance.
- **Monitoring.** New alerts when a component's backing per H10X drops without a rebalance, when a rebalance proposal
  goes above the per-trade cap or makes the vault its own fee recipient, and when the vault's HBAR for future renewals
  runs low.
- **Tests.** 4 new Foundry tests document the findings (`test/H10XVault.bounty.t.sol`, 128 in total), and the
  simulated Hedera Token Service now rejects transfers from an account to itself and `freezeDefault` without a freeze
  key, like the real network.
- **Documentation.** Two clarifications in the review, and the basket rule for wipe keys on the website and in the
  whitepaper.
- **Operations.** The vault now holds HBAR for its future renewals and those of the H10X token.

## Rewards

No report met the critical criteria, so the $2,000 reward was not paid. We are sending thank-you rewards in HBAR to the
researchers whose reports were most useful, and we will contact each of them directly.

## Thank you

To Kupia, hayokakoweda75, Franklyn, Muhammad Harley, Juan Alfonsus and the anonymous researcher, for their time and for
keeping their reports private until we answered.
