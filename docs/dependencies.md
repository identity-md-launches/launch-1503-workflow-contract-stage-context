# Vendored dependencies

All dependencies are ordinary files under lib/. No submodules, node_modules, remote imports or package installation are needed to compile this project. The verifier supplies the pinned compiler; no compiler binary is shipped.

| Dependency | Revision | Use | License |
| --- | --- | --- | --- |
| OpenZeppelin Contracts | [v5.1.0](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.1.0) | ERC-20/721, Ownable2Step, SafeERC20, ReentrancyGuard, math/encoding | lib/openzeppelin-contracts/LICENSE (MIT) |
| forge-std | [v1.9.7](https://github.com/foundry-rs/forge-std/tree/v1.9.7) | Tests only | lib/forge-std/LICENSE-MIT and LICENSE-APACHE |
| Uniswap v4 core | npm @uniswap/v4-core@1.0.2, git [59d3ecf53afa9264a16bba0e38f4c5d2231f80bc](https://github.com/Uniswap/v4-core/tree/59d3ecf53afa9264a16bba0e38f4c5d2231f80bc) | Interfaces/types/state reads; real PoolManager in tests only | lib/v4-core/licenses/ and per-file SPDX (MIT / BUSL-1.1 as applicable) |
| Solmate Owned | [89365b880c4f3c786bdd453d4b8e8fe410344a69](https://github.com/transmissions11/solmate/tree/89365b880c4f3c786bdd453d4b8e8fe410344a69) | Real PoolManager test dependency only | lib/solmate/LICENSE (AGPL-3.0 repository license); Owned.sol is MIT by per-file SPDX |

Only the transitive Solidity sources needed by the application and tests are vendored, together with upstream licenses. Each vendor directory contains REVISION. Sources come from tagged archives, the published npm archive or an exact commit and are not modified by application code. The integration test relocates bytecode within an isolated EVM, not vendored Solidity.

Protocol references: [v4 flash accounting](https://developers.uniswap.org/docs/protocols/v4/guides/flash-accounting), [pool state reads](https://developers.uniswap.org/docs/protocols/v4/guides/read-pool-state). Local behavior is determined by submitted pinned code and tests. Chain addresses come from the approved workflow, not unrelated address tables.
