# Security notes

Kairos is **unaudited research software**. It has not been reviewed by a third party and has never
held real value. Do not deploy it with funds you are unwilling to lose.

This document records what the design assumes, what it defends against, and what it does not.

---

## Trust model

- **No admin over pools.** `KairosPool` has no owner, no upgrade path, no pause, and no privileged
  function. Every parameter is immutable from construction.
- **The factory owner can only add configurations.** It cannot touch a deployed pool, move funds, or
  disable anything. Configuration bounds are enforced in code, not by policy
  (`baseFee ≤ 100 bps`, `0 < theta ≤ 8`, `32 min ≤ maturity ≤ 30 days`, maturity divisible by 32).
- **No external oracles.** The volatility estimate is derived from the pool's own price path. There
  is no price feed to corrupt and no publisher to trust.

---

## Manipulating the volatility oracle

The oracle sets the clamp on the impact premium, so an attacker who controls it controls the
protocol's only unbounded-looking quantity. Both directions were considered.

**Inflating σ** raises the clamp, which permits a larger premium. To move the estimate an attacker
must move the pool price — and pay the premium on the way there and back. A single observation is
clamped at `|m| = 0.5`, and the EWMA weights it at `1 - λ = 6%`, so one block of manipulation moves
the variance estimate by at most 6% of the cap. Sustaining an inflated estimate means sustaining the
manipulation, at a cost that scales with the manipulation.

**Suppressing σ** lowers the clamp, which is the more interesting direction: a suppressed clamp caps
the premium an arbitrageur would otherwise pay. Suppression requires *holding the price still* across
many blocks against real order flow, which is the expensive direction of a trade nobody wants. The
absolute floor of 5 bps bounds what suppression achieves.

**A cold pool is conservative by construction.** With no observations the variance estimate is zero,
so the clamp sits at its 5 bps floor — the *most* restrictive setting, not the least.

Two hard bounds sit under all of this and are enforced regardless of oracle state: the premium clamp
is bounded to `[5 bps, 200 bps]`, and `baseFee + premium` can never exceed 500 bps.

---

## Manipulating the price used for displacement

The displacement is measured against the pool's own marginal price, so anything that moves that price
outside a swap is a concern.

- **Donations.** Tokens transferred into the pool are credited to the fee accumulator, never to the
  reserves. A donation therefore cannot move the marginal price, and cannot move the oracle.
  (`test_donationsGoToLPsNotToPrice`.)
- **Mint and burn.** Both are proportional, so they move the price only by rounding — at most one wei
  per reserve. The cached log price is recomputed afterwards, and any residual displacement can only
  *increase* the next swap's fee, which is the conservative direction. A pool small enough for this
  to matter is prevented by the permanently locked `MINIMUM_LIQUIDITY`.
- **Flash swaps and flash loans.** Both settle by balance comparison at the end of the call and are
  behind the reentrancy guard.

---

## Reentrancy

`swap` transfers the output before invoking the caller's callback, which is what makes flash swaps
possible. Every state-changing entry point is behind an EIP-1153 transient-storage guard
(`Lock.sol`), so a callback cannot re-enter the pool. The guard self-clears at the end of the
transaction, so a reverted-and-caught call can never leave the pool wedged.

State is written before the external calls; the balance checks that follow are the only thing the
callback can influence, and they are the checks that make it safe.

---

## Known limitations

**Fragmentation leakage.** The premium is exactly additive in *displacement*, but it is charged on
trade size, and displacement is not exactly linear in trade size. Splitting a trade therefore changes
the total by a second-order amount. `testFuzz_premium_splitProof` bounds the observed leak at under
2% of the premium, against a gas cost that makes exploiting it unprofitable at any realistic size.

**Uninformed flow inside a displaced block.** Displacement is measured from the price the block
opened at, so a trade landing after a large move pays a premium proportional to that move, whether or
not it caused it. This is deliberate — a pool sitting far from its block-open price is more likely to
be stale, and trading against a stale pool is exactly the flow that should pay more — but it is a
real cost, and it is quantified in [RESULTS.md](RESULTS.md). The alternative (measuring each swap's
own price impact) is simulated alongside it there.

**Token assumptions.** Rebasing and fee-on-transfer tokens are **not supported**. The pool asserts it
received exactly what it asked for and credits any surplus to LPs; a token that delivers less will
revert every swap.

**Accumulator wraparound.** Fee-growth accumulators are `uint256` and use unchecked arithmetic, so
differences are correct modulo `2^256`. This is the same assumption Uniswap V3 makes; it holds as
long as the true difference between two settlements fits in 256 bits.

**Rounding dust.** Entitlements floor, so a pool may retain a few wei of fees that no position can
claim. This accumulates in the pool's favour and can never make it insolvent.

**Single-block price epochs.** Epochs key off `block.number`. On chains where several blocks share a
timestamp, the sampling interval clamps to 1 second rather than dividing by zero.

**Position transferability.** Positions are keyed by `(owner, salt)` and are not transferable. Making
them ERC-721 would require deciding whether a transfer resets maturity — a design question, not an
oversight, and deliberately left open.

---

## What is tested

92 tests across nine suites, all passing, including a deep profile at 20,000 fuzz runs and 512
invariant runs of depth 256. Measured against Foundry v1.8.3, which CI pins.

`forge lint src/` reports 47 warnings under that version and exits zero. They break down as
`calls-loop` (18 — batched read helpers in the lens and the router's multi-hop loop),
`unsafe-typecast` (8 — range-checked narrowing casts), `reentrancy-events` and `reentrancy-no-eth`
(10 — every entry point sits behind the transient lock), `divide-before-multiply` (4 — deliberate
quantisation onto the maturity bucket grid), `block-timestamp` (2) and `unused-return` (1). None are
believed to be defects, but they have not been individually suppressed, so a reviewer should expect
to see them and judge for themselves rather than take this paragraph's word for it.

- `MathLib` is differentially tested against 60-significant-digit references generated by Python's
  `decimal` (`sim/gen_math_fixtures.py`), plus the functional identities `ln(ab) = ln a + ln b` and
  `sqrt(x)² ≤ x < (sqrt(x)+1)²`.
- `ImpactFee` fuzzes path-additivity and the clamp bound directly.
- `MaturityCalendar` fuzzes the O(1) accumulators against a brute-force evaluation of the weight
  definition, including mid-ramp closures, and asserts the crossing loop stays bounded after a
  simulated year of inactivity.
- Seven protocol invariants run under a randomised handler: solvency, fee entitlements never
  exceeding the fee pot, weighted liquidity never exceeding supply, reserves staying positive, the
  cached log price never drifting from the reserves, and the fee rate staying inside its bounds.

Two real defects were found this way and fixed: a clamp placement that broke split-proofness (the
measured leak matched the arithmetic exactly), and a pair of public views that read the maturity
calendar before advancing it — one over-reporting eligible liquidity, the other reverting outright.

## Reporting

This is research code with no deployment and no bounty. If you find something wrong with the
mechanism or the mathematics, open an issue — that is the interesting kind of bug here.
