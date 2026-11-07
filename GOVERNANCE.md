# Basket selection and the DAO

How tokens get into the H10X basket, how they leave, and how holders choose the tokens for the free slots.

| Who | What |
|---|---|
| **The vault** (on-chain, immutable) | Refuses any component whose issuer could block it (freeze, pause, KYC or fee-schedule keys, custom fees). At most 10 components |
| **The selection rules** (below) | Decide which tokens qualify and with what weight, and when a token has to leave |
| **H10X holders** (the DAO) | Propose and vote on the tokens that fill the free slots, with a secret ballot on Hedera |
| **The 2-of-3 multisig** | Carries out the changes in the vault (adds the component, sets the weights, rebalances) |

Only the first row is enforced by the contract. The selection rules and the DAO's result are commitments of the team
and its multisig, and every step is public: the DAO's messages in its HCS topic, and every change in the vault on-chain.

The live basket and the DAO are at [h10xindex.xyz](https://h10xindex.xyz) (basket section and
[`#dao`](https://h10xindex.xyz/#dao)). The vault's composition can always be read on-chain with `getBasket()`.

## Current basket

8 tokens and 2 free slots.

| Token | Hedera token ID | Weight |
|---|---|---|
| HBAR (held as WHBAR, SaucerSwap's wrapped HBAR) | [`0.0.1456986`](https://hashscan.io/mainnet/token/0.0.1456986) | 20% |
| Bitcoin (HTS-WBTC) | [`0.0.10082597`](https://hashscan.io/mainnet/token/0.0.10082597) | 20% |
| xSAUCE (staked SAUCE) | [`0.0.1460200`](https://hashscan.io/mainnet/token/0.0.1460200) | 15% |
| Ether (HTS-WETH) | [`0.0.9770617`](https://hashscan.io/mainnet/token/0.0.9770617) | 10% |
| DOVU | [`0.0.3716059`](https://hashscan.io/mainnet/token/0.0.3716059) | 10% |
| PACK (HashPack) | [`0.0.4794920`](https://hashscan.io/mainnet/token/0.0.4794920) | 10% |
| HBARX (Stader staked HBAR) | [`0.0.834116`](https://hashscan.io/mainnet/token/0.0.834116) | 10% |
| GIB | [`0.0.7893707`](https://hashscan.io/mainnet/token/0.0.7893707) | 5% |

## Selection rules

1. A Hedera (HTS) token with a SaucerSwap pool against HBAR.
2. Its issuer cannot block the vault: no freeze, pause, KYC or fee keys (the contract itself checks this). A key that
   can burn balances (wipe) is only accepted if it's held by a reviewed contract that can't burn the vault's, as with
   WBTC and WETH.
3. SaucerSwap liquidity in line with its weight, as a 90-day average (not a one-day snapshot): at least $50k for 5%,
   $250k for 10% and $1M for 15–20%, plus at least $500 of average daily volume. For xSAUCE, SAUCE's liquidity counts:
   it converts to SAUCE, and back, at any time in SaucerSwap's staking contract.
4. A market cap of at least $1M for 5% and $3M for 10% or more (for BTC and ETH, the original asset's counts).
5. An active project with at least 12 months of history (for BTC and ETH, the original asset's history counts).
6. A buffer against noise: a new token gets in if it beats the minimums by 20%; a token in the basket leaves if it
   misses them at two reviews in a row, or sooner if there is a serious risk (an exploit, a deleted token, new keys).
7. Up to 10 tokens. Reviewed every quarter: holders propose and vote on the tokens for the free slots and the 2-of-3
   multisig carries out the change. If no candidate meets the rules or "leave empty" wins, the slot stays empty.

When a token leaves, its target weight goes to 0, the vault sells it for the other components in a rebalance, and then
it's removed from the basket.

## The DAO

H10X holders propose and vote on which tokens fill the free slots. Everything is recorded in a Hedera Consensus
Service (HCS) topic with **no admin key and no submit key**: nobody can delete or censor messages, the team included.

### A round

One round per quarterly review, named after the quarter (for example `2026Q4`). The values below are copied into the
message that opens each round, so a change only applies to later rounds.

| Phase | Length | What happens |
|---|---|---|
| **Proposals** | 14 days | Holders propose tokens |
| **Rules check** | 3 days | Each candidate is measured against the selection rules |
| **Voting** | 7 days | Secret ballot among the candidates that passed, plus "leave the slot empty" |
| **Result** | 48 h at most | The votes are opened, the vault buys the winners and the result is published |

### Proposing

- Hold at least **500 H10X** when you pay the fee, and also **7 days earlier**.
- Pay a **10 H10X** fee to the project's revenue wallet [`0.0.10353916`](https://hashscan.io/mainnet/account/0.0.10353916)
  with the exact memo `H10X-DAO <round> <token>`, then send the proposal to the topic. The fee is not refunded, even if
  the token doesn't pass the rules check.
- One token per proposal. If a token was already proposed in the round, the first proposal counts.

### Rules check

The selection rules are measured: keys, the HBAR pool, 90-day liquidity and volume, market cap and history, with the
20% entry buffer. The entry thresholds are the 5% minimums plus that buffer:

| 90-day average liquidity | Average daily volume | Market cap | History |
|---|---|---|---|
| $60,000 | $600 | $1.2M | 365 days |

The team publishes each result in the topic, with the figures, and can only **rule a candidate out**, over a rule or a
serious risk, with the reason made public.

### Voting

- Each account picks one candidate or "leave the slot empty". Its last valid vote counts.
- A vote's weight is the account's H10X balance in the snapshot taken when voting opens. Balances held by smart
  contracts (such as the vault and the liquidity pools) don't vote.
- Team accounts vote like anyone else and are labelled "team" in the results.

**Secret ballot.** Each vote is encrypted in the voter's browser in two layers. The outer one is a time lock from
[drand](https://drand.love), the League of Entropy's public randomness network: nobody can open it before voting
closes, the team included. Inside, the vote is encrypted again with the round key. While voting is open you can only
see who has voted and with what weight, never for what. Each vote also carries the round and the voter's account, so
copying someone else's encrypted vote is useless.

### Result

- A **quorum of 10%** of the voting power is required.
- Candidates with more votes than "leave empty" fill the slots, in order of votes. Ties go to the earlier proposal.
- At the close, the team opens the votes and the vault buys the winning tokens **before** the result is published, so
  nobody can front-run that purchase. The changes are signed by the 2-of-3 multisig.
- The result is published with the round's private key no later than **48 hours** after the close, so anyone can open
  every vote and repeat the count. That key is in the topic from the start, locked with its own drand time lock until
  48 hours after the close: even if the team never published it, every vote would open on its own at that point.

### Messages in the topic

Official messages are the ones paid by the project's operations account
[`0.0.10894592`](https://hashscan.io/mainnet/account/0.0.10894592); any holder can send the others.

| Type | Sent by | Content |
|---|---|---|
| `round` | Official | Opens a round: deadlines, slots, minimums, fee, rule thresholds and the basket at that moment |
| `key` | Official | The round's public key for the secret ballot, and its private key under a time lock |
| `propose` | Holder | A token proposal, with the transaction that paid the fee |
| `filter` | Official | The rules-check result for a candidate: pass or fail, the figures and, if it fails, the reason |
| `vote` | Holder | An encrypted vote for a candidate or for "leave empty" |
| `result` | Official | The winners and the round's private key, which opens every vote |

## Changes to the basket

| Date | Change |
|---|---|
| October 2026 | BONZO leaves after a serious event, the Bonzo Lend exploit in July; its market cap and liquidity had also fallen below the rules. Its 5% goes to xSAUCE, which rises to 15%. 8 tokens and two free slots |
| October 2026 | GCoin leaves (its average liquidity was below the 5% rule). SAUCE becomes xSAUCE. Bitcoin goes up to 20%, PACK and HBARX to 10%; BONZO and GIB go down to 5%. 9 tokens and one free slot |
| 11 October 2026 | HBARX and GCoin join (5% each). GRELF and DAVINCI leave because of low liquidity and volume |
| 6 October 2026 | Mainnet launch with the first basket |
