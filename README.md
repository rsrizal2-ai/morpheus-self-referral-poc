# Morpheus DepositPool — Self-Referral PoC

Proof-of-concept for a bug bounty report to Morpheus (mor.org): the stETH
`DepositPool` lets a staker name **themselves** as referrer, capturing both the
+1% referral multiplier and referrer-tier rewards on their own stake.

## The finding

`DepositPool._stake()` never checks `referrer != user`. Staking with
`referrer = own address`:

- `_applyReferrerTier` credits the attacker's own stake to their `ReferrerData`
  (100 stETH reaches tier 4: 15% virtual stake).
- `ReferrerLib.getReferralMultiplier` adds +1% to the user's own multiplier.

Both shares are paid out of the pool's **fixed** daily MOR emission, so the gain
is a dilution of every other staker, not newly created value.

Measured on an Ethereum mainnet fork (block 26458793), identical 100 stETH stakes:

| Scenario | User rewards | Referrer rewards | Total / day |
|---|---|---|---|
| referrer = 0 (honest) | 28.1933 MOR | 0 | 28.1933 MOR |
| referrer = self | 28.4753 MOR | 4.2290 MOR | 32.7043 MOR |

Uplift: **+4.5110 MOR/day (+16.0%)**. It scales with stake (a 1,000 stETH stake
extracts roughly 126 MOR/day). No privileged role, no timing, no specific state
is required.

Suggested fix: `require(referrer_ != user_, "DS: invalid referrer");` in
`DepositPool._stake`, before `_applyReferrerTier`.

Target: `DepositPool` (stETH) `0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790` on
Ethereum mainnet, implementation `0xdB10dAEF167eA2233Ba6811457dD24D676FbD670`
(`version()` = 7).

## Running the PoC

One command, one passing test:

```shell
forge test
```

`test/SelfReferral.t.sol` (`testSelfReferralBeatsHonestStake`) forks Ethereum
mainnet at pinned block 26458793, stakes two identical 100 stETH positions
(control with referrer=0, attacker with referrer=self), advances one
distribution period, distributes, and asserts the loss
(`attackerTotal > controlTotal + 4 ether`).

Setup notes (all inside the test):

- The two stakers are fresh EOAs. They are funded with 100 stETH each by
  transfer from the Curve stETH/ETH pool (a real holder) — funding only; no
  owner, admin, or multisig is pranked.
- The test warps +86401s so a new distribution period elapses. Chainlink feeds
  cannot advance on a fork, so after the warp the six feed contracts
  (third-party Chainlink oracles, not Morpheus) have `latestRoundData` /
  `decimals` mocked via `vm.mockCall` to the fork-block answers with a fresh
  `updatedAt`. Every Morpheus contract executes its real deployed bytecode.
- 0.352 stETH transferred to the Distributor simulates one day of legitimate
  Lido rebase yield (a fork cannot reproduce the rebase). It is present in
  both scenarios and is not an attacker action.

## Cross-check

The same two scenarios were executed as real transactions on a local anvil
mainnet fork (same pinned block): control 28.5465 MOR, self-referral
33.0572 MOR, uplift +4.5108 MOR/day (+15.80%). The two independent
executions agree to 3 decimals (the small absolute difference is because the
Foundry test stakes both positions in one fork, so each dilutes the other
slightly; the uplift is identical).

## Disclosure

Prepared as a proof-of-concept accompanying a bug bounty report to
devs@mor.org. Please do not use it against the live contracts.
