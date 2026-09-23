# Kairos: pricing the cost a trade imposes on liquidity

> καιρός — *the opportune moment*. Every mechanism in this protocol is about **when**: when a price
> moved, when a position was opened, when in the block a trade lands.

This document derives the three mechanisms in Kairos from first principles, states exactly what each
one is and is not claimed to do, and points at the code and the simulation that check the claims.

---

## 1. The problem

A constant-product pool holds reserves `(x, y)` with `x·y = k` and quotes marginal price `P = y/x`.
Its mark-to-market value at an external price `P` is

$$V(P) \;=\; x(P)\,P + y(P) \;=\; 2\sqrt{kP}$$

Between blocks the external price moves and the pool does not. When the next block opens, whoever
notices first trades against the stale quote. Suppose the external log price moved by `m`, so
`P → P e^{m}`. The pool's reserves are unchanged, and the value an arbitrageur can lift out of it is
the difference between what the old reserves are now worth and what the pool will trade them for:

$$\text{LVR}(m) \;=\; \underbrace{x(P)Pe^{m} + y(P)}_{\text{hold the old reserves}} \;-\;
\underbrace{2\sqrt{kPe^{m}}}_{\text{pool value at the new price}}
\;=\; \sqrt{kP}\left(e^{m/2}-1\right)^{2}$$

For small `m` this is `V·m²/8`, and with `E[m²] = σ²Δt` the expected cost per unit time is

$$\boxed{\;\mathbb{E}[\text{LVR}] \;=\; \frac{\sigma^{2}}{8}\,V\;}$$

the standard result of Milionis, Moallemi, Roughgarden and Zhang (2022). At 80% annualised
volatility that is **8% of pool value per year**, paid by liquidity providers to arbitrageurs, before
a single retail trade happens. `sim/kairos_sim.py` reproduces this number to within a few basis
points as a check on the simulator itself.

The trade that extracts it has notional `≈ V|m|/4`. So a proportional fee `γ` returns `γV|m|/4` to
LPs, and the fee that would exactly offset the loss is

$$\gamma^{\star} = \frac{|m|}{2}$$

Charging exactly `γ*` would drive arbitrage profit to zero and freeze price discovery entirely. The
design problem is to charge a *fraction* of it — and to charge it to the flow that causes it.

---

## 2. The impact premium

Let `d = ln(P / P_{\text{block open}})` be the signed log displacement of the pool price from where
the current block opened. Kairos defines a **marginal** fee rate

$$\rho(d) \;=\; \theta\,|d|$$

and charges a swap that carries the pool from `d_0` to `d_1` the *average of `ρ` over that interval*:

$$\gamma(d_0, d_1) \;=\; \frac{1}{d_1 - d_0}\int_{d_0}^{d_1}\rho(u)\,\mathrm{d}u
\;=\;\theta\cdot\frac{|d_0| + |d_1|}{2} \quad\text{(same signs)}$$

Two things follow immediately.

**A trade starting from a clean block pays `θ|m|/2`** — exactly `θ` times the LVR-neutral fee `γ*`.
That is what `θ` means.

**The schedule is path-additive.** Because the charge is the integral of a marginal rate, splitting
one swap into any number of consecutive swaps yields the same total. There is no fragmentation
strategy. (`test/unit/ImpactFee.t.sol::testFuzz_pathAdditivity` fuzzes the identity directly.)

### 2.1 Where the clamp goes

The premium needs an upper bound, or a manipulated price could make swapping arbitrarily expensive.
The obvious move — clamp the charge — silently destroys additivity. The marginal rate of a late
fragment exceeds the average rate of the whole trade, so a trader can split, keep every fragment
under the clamp, and pay strictly less.

This is not hypothetical. It was caught by the split-proofness test during development, and the
measured leak matched the arithmetic exactly: with eight fragments and a clamp binding on the last
three, the fragmented trade paid `27.5/32 = 85.9%` of the single trade.

Kairos therefore clamps the **marginal rate** and integrates that instead:

$$\rho(d) = \theta\cdot\min(|d|,\, d_{\max}), \qquad d_{\max} := \gamma_{\max}/\theta$$

which is bounded by `γ_max` everywhere *and* remains exactly additive. The closed form of the
integral is in [`ImpactFee.sol`](../src/libraries/ImpactFee.sol).

---

## 3. What the arbitrageur does about it

Normalise `P_0 = 1`, `k = 1`, so `x = y = 1` and `V = 2`. The external price is `e^{m}`; write
`α = m/2`. The arbitrageur chooses how far to move the pool, to `m'`; write `b = m'/2`.

Adding `a` of token1 gives `a = e^{b} - 1` and a gross output of `a/(1+a) = 1 - e^{-b}`. The fee
comes off the output at rate `γ = θb` (the average of `ρ` from `0` to `m'`). Expanding to second
order in `(α, b)`:

$$\Pi(b) \;=\; \left(1 - e^{-b}\right)(1-\theta b)e^{2\alpha} - \left(e^{b}-1\right)
\;\approx\; 2\alpha b - (1+\theta)b^{2}$$

Maximising over `b`:

$$b^{\star} = \frac{\alpha}{1+\theta} \qquad\Longrightarrow\qquad
\boxed{\;m' = \frac{m}{1+\theta}\;}$$

**The arbitrageur closes exactly `1/(1+θ)` of the gap and walks away from the rest.** The simulation
reproduces this to two decimal places across `θ ∈ [0.25, 8]` — see
[`RESULTS.md`](RESULTS.md), Experiment 1.

The profit it takes is

$$\Pi^{\star} = \frac{\alpha^{2}}{1+\theta}$$

against `α²` with no fee at all.

---

## 4. The result that is easy to get wrong

`Π* = α²/(1+θ)` invites the conclusion that LPs retain `θ/(1+θ)` of LVR — half at `θ = 1`, three
quarters at `θ = 3`, approaching everything as `θ` grows.

**That is wrong, and the simulation says so.** Measured recapture saturates near 44%, not 89%.

The missing term is a feedback. The gap is not drawn fresh each block: whatever the arbitrageur
declines to close carries into the next one. With `ρ_θ := θ/(1+θ)` the retained fraction, the gap
follows an AR(1),

$$G_{k+1} = \rho_\theta\,G_k + \varepsilon_{k+1}, \qquad \varepsilon \sim \mathcal N(0,\sigma^2\Delta t)$$

with stationary variance `σ²Δt/(1-ρ_θ²)`. Since `1 - ρ_θ² = (1+2θ)/(1+θ)²`, the expected arbitrage
profit per block is

$$\mathbb{E}[\Pi^{\star}] = \frac{\mathbb{E}[G^{2}]}{4(1+\theta)}
= \frac{\sigma^{2}\Delta t}{4}\cdot\frac{1+\theta}{1+2\theta}$$

and the fraction of LVR that never reaches the arbitrageur is

$$\boxed{\;\text{recapture} \;=\; 1 - \frac{1+\theta}{1+2\theta} \;=\; \frac{\theta}{1+2\theta}\;}$$

Measured against simulation: `16.56%` vs `16.67%` at `θ = 0.25`, `32.78%` vs `33.33%` at `θ = 1`,
drifting to about three points of error by `θ = 8` where the second-order expansion starts to bind.

**This expression saturates at 50%.** A pool that tracks the market more slowly accumulates wider
gaps, and wider gaps generate more LVR to begin with; past a point, the two effects cancel. No fee
schedule of this family recaptures more than half of loss-versus-rebalancing. Designs that claim
otherwise are, as far as this derivation goes, not carrying the feedback through.

---

## 5. The volatility oracle

The clamp `γ_max` has to come from somewhere, and hard-coding it re-introduces the problem dynamic
fees exist to solve. Each pool therefore estimates its own realised variance from its own price path.

The pool observes its marginal price at most once per block — at the end of a block, the price is
where an arbitrageur was willing to leave it, which makes it a sample of the external price. Given
consecutive observations `(t_{k-1}, p_{k-1})` and `(t_k, p_k)` in log space,

$$v_k = \lambda\,v_{k-1} + (1-\lambda)\,\frac{(p_k - p_{k-1})^2}{t_k - t_{k-1}}$$

with `λ = 0.94`, RiskMetrics' canonical decay. The EWMA runs on the **variance rate**, not on the
squared return, which makes it invariant to irregular sampling — necessary here, because blocks
without swaps produce no observation and the next sample simply covers a longer interval.

`γ_max = 4σ√Δt`, clamped to `[5 bps, 200 bps]`: four standard deviations of a single block move.

Two clamps bound an adversary. A single observation contributes at most `|m| = 0.5`, so no one can
spike the estimate by more than `(1-λ)` of that cap; and the sampling interval is clamped to
`[1s, 1h]`. Details and the residual attack surface are in [SECURITY.md](SECURITY.md).

The estimator is exposed as [`IVolatilityFeed`](../src/interfaces/IKairosPool.sol) and is useful well
beyond the pool — option pricing, dynamic loan-to-value, risk dashboards — with no off-chain
publisher to trust.

---

## 6. Maturity-weighted liquidity

The premium is worth nothing to a liquidity provider who is front-run by one. A just-in-time LP mints
into the block that a large trade lands in, collects a share of the fee proportional to its size, and
burns immediately — supplying no liquidity to anyone at any other moment.

Kairos pays fees in proportion to `liquidity × maturity weight`,

$$w_i(t) = \min\!\left(1, \frac{t - t_i}{D_i}\right)$$

so a position minted and burnt inside one block has weight zero and earns exactly zero. Nothing is
burnt: the forfeited weight simply leaves the denominator, so the fee accrues to whoever was already
there.

The engineering problem is that every position's weight changes every second, so the denominator is a
moving target. While a position ramps, its contribution is *linear in time*, which collapses the
whole cohort into two running sums:

$$E(t) = \underbrace{\left(t\!\cdot\!A - B\right)2^{-64}}_{\text{ramping}} + \underbrace{C}_{\text{matured}},
\qquad A = \sum a_i,\; B = \sum a_i t_i,\; C = \sum_{\text{mature}} L_i$$

with `a_i := L_i·2^64/D_i`. The one event that will not fold into a running sum is a position
*reaching* maturity, which must move it from `(A, B)` into `C`. Kairos handles those the way Uniswap
V3 handles price ticks — but on the time axis. Maturities snap onto a fixed grid of buckets, a bitmap
records which hold liquidity, and buckets are crossed lazily as time advances.

Snapping onto the grid buys two things: it bounds the crossing loop to `BUCKETS + 1 = 33` iterations
regardless of how long the pool sat idle, and it makes settlement **exact**. Fee growth only changes
when the pool syncs, and a bucket boundary always falls strictly after the previous sync — so the
value recorded at crossing time is precisely the value that held at the boundary.

Settlement itself telescopes. With `F` the usual fee-growth accumulator and `G` a time-weighted one
(`G += t·dF`), a ramping position is owed

$$\frac{a_i}{2^{64}}\cdot\frac{\left(G_1 - G_0\right) - t_i\left(F_1 - F_0\right)}{2^{128}}$$

which is `O(1)` and needs no per-position iteration.
See [`MaturityCalendar.sol`](../src/libraries/MaturityCalendar.sol), and
`test/unit/MaturityCalendar.t.sol`, which fuzzes the accumulators against a brute-force evaluation of
the definition.

---

## 7. Fees on the output

Kairos takes its fee from the **output** token and holds it outside the reserves. Three consequences:

1. `x·y` is *exactly* invariant under a swap. Price and displacement are determined by the gross
   input alone, so the fee never feeds back into the quote and there is no fixed point to solve.
2. One logarithm per swap. The post-swap log price is computed once and cached; the displacement
   comes from a subtraction.
3. Donations cannot move the price. Tokens pushed into the pool outside a swap are credited to the
   fee accumulator, not the reserves — otherwise a donation would move the marginal price, and with
   it the volatility oracle.

---

## 8. What the simulation does and does not show

[`RESULTS.md`](RESULTS.md) reports three experiments. The arbitrageur solves its own optimisation
numerically against the exact fee rule the Solidity implements; the closed forms appear only as
comparison columns.

- **Experiment 1** confirms `1/(1+θ)` tracking and `θ/(1+2θ)` recapture, and confirms the simulator
  against the analytic `σ²/8`.
- **Experiment 2**, at constant volatility with fee-elastic uninformed flow, finds a *well-tuned
  static fee is competitive*. This is reported rather than buried. The premium's advantage at fixed
  σ is that it reaches a comparable outcome while charging uninformed flow less and winning more of
  it — not that it dominates.
- **Experiment 3** alternates volatility regimes, which is the case a static fee cannot answer: it
  has to be wrong somewhere, priced either for the calm or for the storm.

The model's central limitation is that its uninformed flow is uninformed *by construction* — it never
picks off a stale pool. That structurally favours high static fees, whose no-arb band is a very
efficient LVR blocker precisely because it lets the price go stale. Read the tables with that in
mind; they are listed in full in [RESULTS.md](RESULTS.md).

---

## 9. References

- Milionis, Moallemi, Roughgarden, Zhang. *Automated Market Making and Loss-Versus-Rebalancing* (2022).
- Milionis, Moallemi, Roughgarden. *Automated Market Making and Arbitrage Profits in the Presence of
  Fees* (2023).
- J.P. Morgan/Reuters. *RiskMetrics Technical Document*, 4th ed. (1996) — the `λ = 0.94` EWMA.
- Adams, Zinsmeister, Salem, Keefer, Robinson. *Uniswap v3 Core* (2021) — the tick-crossing pattern
  the maturity calendar borrows, and the fee-growth accounting it extends.
