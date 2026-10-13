# Contributor test coverage

Run the offline suite from the repository root with `forge build` and `forge test`.
All dependencies are already vendored. These tests require no RPC, environment variables,
FFI, keys, or files outside the repository. Fuzz settings live in Solidity comments.

The additions build on the existing contract, rendering, deployment, and real v4 tests:

| Tests | Additional guarantees checked |
| --- | --- |
| `DeskAdversarial.t.sol` | Late fee/payment failures roll back swaps, positions, statistics, allowances, and cooldowns; measured output and net slippage; donations cannot become card credit; HIC custody remains separate from burning; proportional basis conservation; fee rounding; independent authority for cards sharing a holder. |
| `DeskEdges.t.sol` | All 256 possible name bytes; valid names and nonexistent IDs; signed v4 delta limits; accumulated positions above a single-swap limit remain withdrawable; repeated dust round trips; reuse after a full exit. |
| `DeskAccountingInvariant.t.sol` | Three cards and distinct agents, including two cards with one holder; independently tracked custody, cost, realized profit, statistics, rules, fees, and donations across changing prices and owners. Every sequence ends with full holder withdrawals. |
| `LaunchTokenInvariant.t.sol` | Fixed supply and exact account/allowance accounting across random transfers, self-transfers, approvals, revocations, delegated spending, and rejected calls. |
| Additions to `UniswapIntegration.t.sol` | Round-trip loss under real v4 fees across both currency orderings; six-decimal output accounting; no-return ERC-20 settlement in both directions. |

The two new invariant campaigns each use 256 runs at depth 128 with failure on unexpected
reverts. Only explicitly selected actions are fuzz targets. Expected rejection paths check
the exact revert data; valid calls must succeed. A deterministic handler test exercises
success, rejection, donations, fee-recipient changes, and exit paths. New stateless fuzz
properties use 1,000 runs. Known boundaries also have deterministic examples.

The Desk reference ledger is updated from action inputs and independently configured mock
exchange rates, never copied from Desk balances or position getters. It checks
`assets = card liabilities + burn reserve + donations`, along with
`open cost + sold cost + withdrawn cost = cumulative buy cost` and realized sale proceeds
minus sold cost. Withdrawal assertions also check actual holder token receipts.

The accounting model uses honest, non-rebasing balances and bounded execution rates;
separate adversarial tests cover taxed transfers, false/no-return values, and failed
payments. The real v4 tests use the vendored PoolManager locally, with the existing fixture's
relocated immutable address and simulated initialization hook. Production IMD/hook identity,
current chain liquidity, and execution against live deployed state still need a fork check
with the launch's chain and pool handoff. No live fork is part of this offline suite.
