# Security assumptions and validation

## Authority and custody

Only the permanent holder withdraws or configures their card. Only the current agent trades, and freeze stops both directions. The contract exposes no arbitrary calls or approvals and grants no PoolManager token allowance: settlement transfers only exact owed input during a verified callback. Owner authority is limited to mint price and two-step ownership; fee receipts grant no access to card liabilities. HIC and Cards have no administrative escape hatch. Direct constructors use explicit dependencies without calling outside contracts; the factory cannot become owner by default.

Balances are token units, not shares or prices. Card liabilities are separate from the burn reserve. Swaps use measured balances; IMD deposits must receive the exact requested amount; v4 settlement must receive the exact debt; full input must be consumed. A failing interaction rolls back everything. Withdrawn coin basis is removed proportionally without a trading result. Total-liability getters support an independently summable solvency check.

Card mutation, trading, minting, fee changes and burns use OpenZeppelin's storage reentrancy guard. The callback intentionally runs inside that guard, with pinned-sender, pending-operation, exact-data hash and one-use checks. Pending authorization is cleared before manager/token calls, blocking replay/nested callbacks. Safe NFT receivers cannot reenter setup during mint. Callback is not an agent API.

## External assumptions and limits

- The pinned mainnet manager must implement the supplied v4 interfaces and storage layout. StateLibrary reads pool slot 6 as defined by core 1.0.2.
- The pinned hook must restrict exact-key initialization to the IMD factory. Permission bits 0x6000 enable initialization callbacks only. No swap hook or oracle is used. Services/reviewers must verify production code and the handoff.
- IMD and launch coins must not rebase, seize assets, lie about balances or impose sender-side debits beyond nominal transfers. Eligibility does not guarantee ongoing liquidity/benign behavior. Output measurement does not make malicious tokens safe. Unsupported behavior can revert or strand funds; there is no privileged recovery.
- Caller-supplied positive minimum outputs constrain slippage but establish no fair price, maximum-loss oracle or deadline. A caller can queue a stale transaction or choose poor slippage. The public burn's minimum is caller-selected; manipulation/MEV can reduce reserve value without violating conservation.
- Fees and proportional basis round down, with full position exit removing residual basis. Odd fee units favor burn. Tiny trades can pay zero fee. Financial arithmetic uses Math.mulDiv, checked Solidity arithmetic, and checked signed P&L conversions.
- UTC boundaries and hourly intervals depend on block timestamps. No valuable randomness exists; the ID-derived decorative sigil is deterministic.
- Stats measure realized sell calls. Partial profitable sells increase win count, open losses are omitted, and withdrawals remove basis without realization. Public history cannot be rewritten, but headline rankings are not total financial performance.
- Permanent ownership has no key-loss recovery. On-chain getters/events provide no wallet privacy. Direct token donations and accidentally forced ETH have no recovery; the Desk has no payable deposit/fallback.

## Local checks

Tests are self-contained, parallel/order-independent, and use no environment, network, FFI, filesystem permissions, signing or broadcasting.

| Area | Evidence |
| --- | --- |
| Fixed token | Exact deployer supply/metadata/transfers; allowance failures; absent mint/admin selectors; fuzz conservation |
| Empty-chain construction | Factory deploys token/Art/Desk/Cards with dependencies absent; supply preserved; explicit owner; runtime size/opcode checks |
| Soulbound NFT | Desk-only mint, duplicate failure, transfer overload/approval failures, locked/interfaces, nonexistent checks |
| Custody/permission | Two-card isolation, unauthorized holder/agent/owner actions, frozen withdrawal, rule/agent/freeze changes |
| Trading/record | Fee/basis, win/loss/break-even, partial-sale and withdrawal basis, events, UTC limits/reset |
| Failure atomicity | Mint slippage/NFT rejection, bad names, zero/overspend, unavailable pools, zero/unmet minimum, partial fill, short settlement, taxed IMD, failed transfers |
| Reentrancy/callback | Receiver, token and manager reentry; unauthorized/missing/wrong callback; replay |
| Burn | Reserve isolation, public execution, output minimum, rollback, hour boundary |
| Metadata | Decoded JSON/SVG, live stats/rename, hostile escaping, signed extremes, leap dates, deterministic sigil |
| Real v4 | Upstream PoolManager, seeded full-range liquidity, real mint/buy/sell/burn, both orderings, exact-key restriction, initialization hook, no-liquidity/slippage failure |
| Stateful | Interleaved two-card deposits, trades, withdrawals, rules/freeze/agent changes, burns/time; backed liabilities, basis/balances, action-derived P&L/stats |

The integration test relocates real manager runtime to the pinned address and adjusts only its immutable NoDelegateCall original-address constant. Pools, swap math, deltas, transient accounting, sync/settle/take and unlock checks are upstream code. The initialization hook/test coins are local models, not production-code identity evidence.

Required checks: forge build, forge test, forge fmt --check. The configured stateful campaign uses 256 runs at depth 128 (32,768 modeled actions), plus 256 cases for each fuzz test. Runtime/opcode checks cover all four deployed project contracts, including child Cards. Runtime fits EIP-170 and constructor code fits EIP-3860. ABI export checks for unresolved external library links.

This is local implementation validation and self-review. No independent audit, Slither/Mythril run, live Ethereum fork, deployment, broadcast or explorer verification is claimed. The separate independent review must inspect accepted source and manifest together before services release contracts holding others' funds.
