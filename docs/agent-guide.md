# Agent builder guide

Use the accepted deployment handoff on Ethereum (chain ID 1), the complete ABIs in docs/abi/, and the exact poolKey. There is no backend API or signed claim service. The holder's wallet and agent's wallet are separate authorities.

## Holder setup

1. Read mintPrice() and quote the burn half of that price to HIC. Approve the Desk to spend exactly the mint payment in IMD, then call mint(name,minHicOut) with a nonzero minimum. The returned ID and Minted event identify the permanent card. A contract holder must implement ERC-721 receiving.
2. Approve the desired additional IMD deposit and call deposit(id,imd). This card alone is credited.
3. Call setAgent(id,agentAddress) and setRules(id,dailyCap,maxPerTrade). IMD values use 18 decimals. A new card cannot trade until both agent and positive buy limits are set.
4. Keep the holder key separate from the agent key. The holder can replace/revoke an agent, freeze both trade directions, or withdraw funds to themselves. Agent authorization grants no withdrawals, transfers, approvals or general execution.

With a 50 IMD daily cap and a 10 IMD maximum trade, dailyCap=50e18 and maxPerTrade=10e18. A 10 IMD buy consumes 10 IMD of balance and daily allowance; its pool input is 9.975 IMD after the Desk fee. Sells are available even when the buy allowance is exhausted, unless the holder freezes or revokes the agent.

## Quote and submit a buy

Read the card, spentToday(id), coin balance and isTradable(token). Quote the exact poolKey(token) with input IMD, output token, and net pool input:

~~~
grossBudget = imdIn
fee = floor(grossBudget / 400)
poolInput = grossBudget - fee
quotedCoinOut = exactInputV4Quote(poolKey(token), IMD, poolInput)
minOut = quotedCoinOut * (10000 - allowedSlippageBps) / 10000
~~~

The quote above means a client-side v4 quote/simulation against the actual deployed pool, not a Desk function. Choose quote infrastructure from the service handoff; this contribution pins no unprovided quoter/router address. Determine zeroForOne from whether input is currency0. The Desk uses extreme valid sqrt-price bounds, exact input, and empty hook data. Simulate the actual buy call from the agent before submission. Do not quote a different fee, spacing, hook, chain, or generic router route.

Call buy(id,token,imdIn,minOut) from the current agent. Limits and balance must cover the gross budget. Minimum output must be positive. The result is measured coin output; its Traded event has isBuy=true, gross IMD budget, coin output, pnl=0 and win=false.

## Quote and submit a sell

The coin amount must come from this card's credited position. Quote exact input coin to IMD on the same key. Convert the quoted gross IMD to net before choosing a minimum:

~~~
quotedGrossImd = exactInputV4Quote(poolKey(token), token, amountIn)
quotedNetImd = quotedGrossImd - floor(quotedGrossImd / 400)
minImdOut = quotedNetImd * (10000 - allowedSlippageBps) / 10000
~~~

Call sell(id,token,amountIn,minImdOut) from the agent. Minimum applies to net credited IMD, not the pool's gross return. It must be positive. The result and event IMD amount are net proceeds. Removed basis is floor(positionCost * amountIn / positionQuantity); a full sell removes the entire remaining basis. P&L is signed netProceeds minus removed basis. Strictly positive is a win; zero or negative is a loss. Each partial sell is a separate closed result.

Both directions reject partial input consumption; insufficient liquidity, token transfer failure, bad settlement or slippage reverts the entire call, including balance, spending counter, fee payment and stats. Agents cannot supply another recipient, callback target, pool key, or arbitrary approval/call.

## Common errors

| Error | Meaning / recovery |
| --- | --- |
| UnknownCard | ID is zero or has not been minted |
| OnlyAgent | Sender is not current agent; holder must configure it |
| OnlyHolder | Action needs the permanent holder |
| CardFrozen | Holder must unfreeze or withdraw; agent cannot override |
| PerTradeLimit | Reduce gross buy budget or have holder change max |
| DailyLimit | Reduce buy, wait for UTC boundary, or have holder change cap; configuration does not reset spending |
| InsufficientBalance | Card's credited balance is smaller than requested input/withdrawal |
| InvalidAmount | Zero amount, input beyond int128 delta capacity, or no usable output |
| InvalidToken | IMD cannot itself be a traded coin; poolKey also excludes zero |
| PoolNotInitialized | Unsupported token or uninitialized exact pinned pool |
| Slippage | Zero minimum or measured output below minimum; requote rather than blindly lowering it |
| PartialFill | Pool could not consume full input; use smaller input or a liquid pool |
| UnsupportedToken | Measured input/settlement differs from expected; investigate behavior |
| UnexpectedCallback | Callback caller, payload, timing or one-use authorization is wrong |
| BurnTooSoon / NothingToBurn | Keeper must wait or reserve is empty |
| InvalidName | Use 1–24 ASCII letters/digits/spaces/dashes |
| FreezeUnchanged | Already in requested freeze state |
| MintPriceOutOfRange / RenounceDisabled | Owner operation forbidden by fixed rules |

SafeERC20, ERC-20/721, Ownable2Step, ReentrancyGuard and PoolManager errors can bubble up. Decode against ABI and transaction simulation. RPC errors are not automatically contract rule errors.

## History and display

Index Desk Minted, Traded, Withdrawn, Deposited, AgentSet, RulesSet, Frozen and Renamed logs. Get event times from block timestamps, handle reorganizations, and verify the emitter address against the handoff. Filter trades by indexed card ID. Only sells count toward wins + losses; a buy's win=false does not mean loss.

Leaderboard eligibility is wins + losses >= 10; displayed integer win percentage is floor(wins * 100 / (wins + losses)), or zero when there are no sells. Sort exact rational rates or signed P&L without JavaScript floating-point conversion. Holders can selectively realize trades/withdrawals; do not label this total performance. Portfolio valuation needs fresh quotes and separately tracked open positions, not pnl alone.

There is no private balance query. A UI can filter IDs by connected cards.ownerOf(id), while on-chain balances remain readable. Cards are permanent; holder-key loss has no admin recovery. Browser key generation and secure storage belong to the frontend stage.
