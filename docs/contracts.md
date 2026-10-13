# ABI reference

Complete ABI JSON arrays are exported from the pinned Foundry build:

- [LaunchToken.json](abi/LaunchToken.json)
- [HandlerDesk.json](abi/HandlerDesk.json)
- [HandlerCards.json](abi/HandlerCards.json)
- [HandlerArt.json](abi/HandlerArt.json)

Regenerate with `forge build` then `python3 tools/export_abis.py`. The exporter refuses artifacts containing linked external-library references. All financial token amounts are integers in the token's own minor units; IMD and HIC have 18 decimals. ABI `int256` P&L is signed IMD minor units.

## HandlerDesk actions

| Function | Caller | Behavior / result |
| --- | --- | --- |
| `mint(string name,uint256 minHicOut)` | Anyone paying IMD | Pull current price; pay half to owner; swap/burn remainder; safe mint permanent card; returns card ID |
| `deposit(uint256 id,uint256 imd)` | Holder | Pull exact IMD into this card's credited balance |
| `withdraw(uint256 id,address token,uint256 amount)` | Holder | Send credited assets only to caller/holder; proportionally remove withdrawn coin basis |
| `setAgent(uint256 id,address agent)` | Holder | Set agent; zero revokes |
| `setRules(uint256 id,uint256 dailyCap,uint256 maxPerTrade)` | Holder | Set buy limits; no spending reset |
| `freeze(uint256 id)` / `unfreeze(uint256 id)` | Holder | Block / unblock both trade directions; same-state call reverts |
| `rename(uint256 id,string name)` | Holder | Apply mint's name validation |
| `buy(uint256 id,address token,uint256 imdIn,uint256 minOut)` | Current agent, unfrozen | Spend gross IMD inclusive of fee; return measured coin output |
| `sell(uint256 id,address token,uint256 amountIn,uint256 minImdOut)` | Current agent, unfrozen | Sell exact coin amount; return net IMD after fee; minimum applies to net |
| `buyAndBurn(uint256 minOut)` | Anyone | Swap entire accrued reserve and burn HIC, subject to successful-burn hourly interval; return HIC output |
| `setMintPrice(uint256 price)` | Owner | Set inclusive 0.05–2 IMD range |
| `transferOwnership(address next)` / `acceptOwnership()` | Owner / pending owner | Standard Ownable2Step; zero pending address cancels a pending transfer |
| `renounceOwnership()` | Any caller | Always reverts |
| `unlockCallback(bytes data)` | Pinned manager, during one authenticated own unlock | Internal v4 settlement entry point; never an agent API |

All user actions that affect card or reserve accounting are `nonReentrant`. Calling trade as the holder does not work unless that holder is also the configured agent. Withdrawals, configuration and renaming remain available while frozen. A successful burn requires a positive reserve and positive minimum output; a reverted burn leaves the timer and reserve unchanged.

## Reads

`getCard(id)` returns the named `Card` tuple in this declaration order:

| Field | Type | Meaning |
| --- | --- | --- |
| `name` | string | Validated holder-selected card name |
| `agent` | address | Current authorized agent, zero if revoked |
| `frozen` | bool | Trading disabled |
| `dailyCap` | uint256 | Gross buy IMD allowed per UTC day |
| `maxPerTrade` | uint256 | Maximum gross buy IMD per call |
| `day` | uint256 | UTC day of stored buy counter (`timestamp / 86400`) |
| `spentToday` | uint256 | Stored day counter; use the standalone getter for current-day value |
| `mintedAt` | uint256 | Mint Unix timestamp |
| `trades` | uint256 | Successful buy and sell calls |
| `wins` | uint256 | Sells whose net proceeds exceed removed basis |
| `losses` | uint256 | Other sells, including break-even |
| `pnl` | int256 | Cumulative realized net IMD proceeds minus sold basis |
| `volume` | uint256 | Gross IMD budgets on buys plus gross IMD output on sells |

Other reads:

- `cards()`, `hic()`, `owner()`, `pendingOwner()`, `totalCards()`, `mintPrice()`.
- `balances(id,token)`: credited card balance; `positions(id,token)`: `(quantity,cost)`.
- `cardCoins(id)`: all coins ever credited, including IMD and coins now at zero. IDs are contiguous from 1; index `Minted` events or query `ownerOf` to enumerate a holder's cards.
- `spentToday(id)`: zero after a day boundary until the next buy; changing agent/rules/freeze never resets it.
- `burnImd()`, `hasBurned()`, `lastBurnTime()`, `BURN_INTERVAL()`.
- `totalLiability(token)`: sum of credited card balances. Desk IMD must back this plus `burnImd`; other coins must back their own liabilities. Uncredited donations can create surplus.
- `poolKey(token)`: sorted `(currency0,currency1,fee,tickSpacing,hooks)`; rejects zero or IMD.
- `isTradable(token)`: initialized exact launch pool and token code. Zero/IMD/EOAs return false; a missing/broken manager can make the read revert.
- Constant getters expose the pinned IMD, manager, hook, burn destination, fees, spacing and price bounds.

Raw mappings return zero for absent IDs, like normal Solidity mappings. Card-aware reads/actions validate existence; clients should validate with `getCard` or `cards.ownerOf` before treating a zero mapping result as a live card.

## Events

The ABI contains the exact indexed fields:

```solidity
Minted(uint256 indexed id,address indexed holder,string name,uint256 price,uint256 hicBurned)
Deposited(uint256 indexed id,uint256 imd)
Withdrawn(uint256 indexed id,address indexed token,uint256 amount)
RulesSet(uint256 indexed id,uint256 dailyCap,uint256 maxPerTrade)
AgentSet(uint256 indexed id,address indexed agent)
Frozen(uint256 indexed id,bool frozen)
Renamed(uint256 indexed id,string name)
Traded(uint256 indexed id,address indexed token,bool isBuy,uint256 imdAmount,uint256 tokenAmount,int256 pnl,bool win)
Burned(uint256 imd,uint256 hic)
MintPriceSet(uint256 price)
```

For `Traded`, buy `imdAmount` is the gross inclusive debit; sell `imdAmount` is net credited IMD. Buy `pnl=0, win=false` is not a loss: classify closed results only when `isBuy=false`. For timestamps read the event block's timestamp. All listed events occur only on a fully successful transaction. ERC-20/ERC-721 transfers and Ownable2Step events are also standard ABI events.

## HandlerCards and HandlerArt

Cards supports ERC-165, ERC-721, metadata, and ERC-5192 (`0xb45a3c0e`). `locked(id)` returns true for an existing card. `approve` and `setApprovalForAll` always revert; transfers and burns revert. `mint(address holder,uint256 id)` accepts only the immutable Desk. `tokenURI(id)` validates existence then calls `HandlerArt.tokenURI(desk,id)`.

Art exposes `tokenURI(address desk,uint256 id)` and `svg(address desk,uint256 id)`. The URI is Base64 JSON with an embedded Base64 SVG. Names are escaped separately for JSON and XML. Attributes preserve ID, integer win percentage, wins, losses, signed P&L, gross IMD volume, trades and mint timestamp; exact large numeric metadata should be read with arbitrary-precision tooling or the ABI, not JavaScript floats. Image P&L/volume truncate to four decimal places; the mint date is Gregorian UTC. The pixel sigil is deterministic from the ID and is decorative, not randomness for any financial operation.
