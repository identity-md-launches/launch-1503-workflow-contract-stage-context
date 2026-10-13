# Contract deployment handoff

This is source-stage guidance for the manifest contributor and deployment services. This contribution does not create `launch.json`, publish source, attest, admit, deploy, or claim deployed contract addresses. Policy and signed-artifact linkage belong to services.

## Parameters and dependency order

| Factory artifact | Arguments | Meaning |
| --- | --- | --- |
| `LaunchToken` | `[]` | Launch token, full policy supply to its deployer |
| `HandlerArt` | `[]` | First application entry |
| `HandlerDesk` | `[$owner, $token, $contract:HandlerArt]` | Second application entry; owner, HIC, artwork |

All direct application constructors are nonpayable and fully configure immutable dependencies. Desk has three static address arguments. They perform no calls to pre-existing external contracts and do not require dependency code in their constructors. The Desk constructs `HandlerCards` locally; the child has two address constructor arguments and permanently grants mint authority to that Desk. The manifest should not separately deploy another Cards contract. Services should read and publish `HandlerDesk.cards()` after deployment for clients and source verification.

`$owner` resolves to the requester-approved owner `0xf2a606601bfe2508772e6e293c81d7d88d2d7385`. The owner is passed explicitly and is never inferred from the factory or `tx.origin`. `$token` is the actual launched HIC address. No predicted or dummy address is needed. There are no dynamic constructor arguments, proxies, linked external libraries, initialization transactions, custom hooks deployed by this project, or owner-settable external services.

The constructor rejects zero owner/token/art and HIC equal to IMD. Code identity and correct wiring of the Art and HIC references remain review/service responsibilities; the constructor deliberately does not call them.

## Pinned chain and pool

| Item | Approved value |
| --- | --- |
| Chain | Ethereum, chain id 1 |
| IMD / pool paired currency | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, 18 decimals |
| Uniswap v4 PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| IMD launch initialization hook | `0x784ff9a3ac5d88a30bfff6f7f2a270161fbe6000` |
| Pool fee | `12500` = 1.25% |
| Tick spacing | `60` |
| Canonical manifest initial price field | `"79228162514264337593543950336"` |
| Effective opening-price source | Policy opening cap of 2,500 IMD for the entire supply; derived by services using final token ordering |
| HIC total supply | `1000000000000000000000000000` minor units, 18 decimals |

The Desk computes keys by ascending address order of IMD and the requested token, with exactly this fee, spacing and hook. It accepts a token only when that exact pool's `sqrtPriceX96` is nonzero, read through v4 `StateLibrary.getSlot0`. A different hook, fee or spacing cannot qualify the token.

The 1.25% pool fee is separate from the Desk's 0.25% application fee. The Desk does not initialize pools, set prices, contribute launch liquidity, distribute launch allocations, modify pool fees, or claim protocol pool fees. The factory and services perform those policy operations. No Desk constructor moves any launch tokens. The factory allocation is 10% swarm, 80% pool and 10% payer/treasury under the specified policy.

If the actual launch handoff uses a different hook/key from the approved workflow, that is a concrete source/authorization conflict for independent review and must be resolved before release. A manifest cannot make the Desk's pinned eligibility key accept a different pool.

## Service and operator responsibilities

1. The independent manifest contributor records accepted direct artifacts and exact constructor references.
2. Reviewers inspect accepted source and manifest, including the explicit owner, immutable HIC/Art addresses, internally created Cards contract, pool key, accounting, and chain dependencies.
3. Services publish accepted source, establish policy/artifact linkage, attest, admit, deploy and initialize/fund the policy pool. They verify source and record the resulting addresses and exact poolKey for the frontend. They verify the deployed hook enforces the factory restriction assumed here; the local hook is only a test model.
4. After the HIC pool is initialized and funded, holders can mint. Minting and trading revert safely before the required pool is available. Other coins need their own initialized, liquid IMD launch pool to trade.
5. The owner may call `setMintPrice` within bounds and manage two-step ownership. No other configuration is needed. Holders fund and configure cards individually. Permissionless keepers can burn accrued reserves when the hour interval permits.

The owner receives half the mint IMD and half the Desk trading fee in the same transaction. A later successful ownership transfer changes the beneficiary of future receipts. Failed payment or swap reverts the whole operation. Historical receipts are outside Desk custody.
