# Metro Exchange Contracts

Solidity contracts for the Metro Exchange affiliate-commission system:

- **CommissionVault** holds affiliate commissions in USDC, settles per-code entitlements on a timelock, and lets affiliates claim what they have earned.
- **Erc20Forwarder** holds a single fixed token and sweeps its full balance to a configured recipient (the vault) whenever anyone calls `forward()`, so affiliate fee configs can point permanently at one address.
- **RateLimitedForwarder** is the same fixed-token sweeper with a token-bucket drip: `forward()` releases only the amount accrued at `dripRate` per `dripPeriod` (capped at `maxReserve`), so a compromised or mis-set recipient can drain at most one bucket per period rather than the whole balance at once.

This repository is published for external security review. It is a self-contained Foundry project with no dependency on the Metro monorepo.

## Audit scope

In scope (`contracts/`):

| File | Description |
|---|---|
| `CommissionVault.sol` | Settlement, entitlements, claims, migration, and admin. |
| `Erc20Forwarder.sol` | Permissionless fixed-token sweeper with an owner-controlled recipient. |
| `RateLimitedForwarder.sol` | Fixed-token sweeper that releases funds through a token-bucket drip. |
| `interfaces/ICommissionVault.sol` | External interface + events for the vault. |
| `interfaces/IErc20Forwarder.sol` | External interface + events for the forwarder. |
| `interfaces/IRateLimitedForwarder.sol` | Extends `IErc20Forwarder` with the drip-limit surface. |

Test-only helpers (in scope for context, not deployed to production):

| File | Description |
|---|---|
| `FakeUSDC.sol` | Mintable 6-decimal ERC20 used by tests and the Base testbed. |
| `FakeDistributor.sol` | Placeholder for the production revenue-distribution contract; receives surplus USDC from the vault in the testbed. |

Out of scope:

- OpenZeppelin contracts (`lib/openzeppelin-contracts`, v5.6.1) and forge-std (`lib/forge-std`, v1.16.2), pinned as git submodules.
- The production revenue-distribution contract that `distributor` points at in production. `FakeDistributor` is only a stand-in for it here.
- The off-chain operator/keeper tooling. Its behavior is described below under [Off-chain operation](#off-chain-operation) so the on-chain trust assumptions are clear, but the code is not part of this repository.

## Build and test

Foundry is required (`forge`, `cast`). See https://book.getfoundry.sh/getting-started/installation.

```bash
# Clone with submodules (forge-std + OpenZeppelin)
git clone --recursive git@github.com:metro-exchange/contracts.git
# or, if already cloned:
git submodule update --init --recursive

forge build
forge test
```

Compiler: solc 0.8.26, optimizer on, 200 runs (see `foundry.toml`). The current suite is 279 tests across five files.

## CommissionVault

### Roles

| Role | Set at | Powers |
|---|---|---|
| **owner** | `msg.sender` at deploy | Admin config, unpause, owner-recovery of payout addresses (timelocked), migration functions, `rescueToken` (surplus only), two-step ownership transfer. Intended to be a multisig. |
| **operator** | constructor | `proposeSettlement`, `processIncoming`, `distributeEligible`. A hot key run by the off-chain keeper. |
| **guardian** | constructor | `pause`, `cancelSettlement`, `cancelPayoutChange`, `distributeEligible`. A fast-reacting safety key. |
| **affiliate** | on-chain, per code | `claim`, `registerCode`, `changePayoutAddress` for their own code. |
| **anyone** | permissionless | `activateSettlement`, `activatePayoutChange` once the timelock has elapsed. |

### Design invariants

- **Entitlement is a running cumulative total, never a delta.** `proposeSettlement` sets `cumulativeAmount[code]` to a new absolute value that must be greater than or equal to the current one. Claims track `claimed[code]` cumulatively, and the claimable amount is `cumulative - claimed`. This makes settlement idempotent and re-org tolerant.
- **Address and earnings are stored in separate maps and never clobber each other.** Settlement writes only the amount (and the address on first bind). Payout changes write only the address. This decouples who gets paid from how much is owed, so a payout-address change can never move or reset an entitlement.
- **Two independent timelocks.** `settlementTimelock` gates settlement activation; `payoutTimelock` gates owner-initiated payout-address recovery. They are deliberately separate clocks.
- **Reserve accounting.** `requiredReserve() = totalOwed - totalClaimed` (floored at 0). `processIncoming` forwards only the surplus above this reserve to the distributor, so the vault always retains enough USDC to cover every outstanding claim. `rescueToken` refuses to remove USDC below the reserve.
- **Self-service payout changes are instant and not timelocked.** A compromised affiliate key can already drain via `claim()`, so delaying a self-service `changePayoutAddress` (sent from the current payout address) buys nothing. The timelocked path (`ownerSetPayoutAddress`) exists only for owner recovery of a lost key, and reuses the same pending slot so the guardian can veto it.
- **Batch bounds.** `MAX_BATCH_SIZE = 200` caps every batched call. `maxCodeDelta` and `maxBatchDelta` cap per-code and per-batch entitlement increases in a single settlement, limiting the blast radius of a bad settlement before the guardian can `cancelSettlement` within the timelock window.

### Lifecycle

1. **Settle.** Operator calls `proposeSettlement(codes, addresses, cumulativeAmounts)`. After `settlementTimelock`, anyone calls `activateSettlement()` to apply it. The guardian can `cancelSettlement()` during the window.
2. **Fund.** USDC arrives at the vault (via the forwarder, see below). Operator calls `processIncoming()` to forward the surplus above the reserve to the distributor.
3. **Claim.** An affiliate calls `claim(code)` from their registered payout address, or the operator/guardian/owner calls `distributeEligible(codes)` to push everything already claimable (respecting `minClaimAmount`) to each code's own registered address.
4. **Payout changes.** Affiliates self-serve via `changePayoutAddress`; owner recovery goes through `ownerSetPayoutAddress` (timelocked, guardian-vetoable, publicly activatable).

### Migration

`seedClaimed`, `migrateBalance`, and `finalizeMigration` (all owner-only) exist to import state from a prior vault. They are usable only while `migrationFinalized == false`, which is set at deploy from `_isMigrationTarget`. `processIncoming` is blocked until migration is finalized. Seeded codes are net-zero (`cumulative == claimed`) so the reserve stays correct.

## Erc20Forwarder

Holds one fixed token (set immutably at deploy) and sweeps its whole balance to `recipient` on `forward()`. The recipient is the CommissionVault, so affiliate fee configs point at the forwarder forever and rerouting downstream is a single `setRecipient` call by the owner.

- **Deploys paused.** Going live is an explicit `unpause()` by the owner, which also proves the owner account controls the contract before any funds are routed to it.
- **`forward()` is permissionless and reverts on a zero balance.** `tryForward()` is the non-reverting variant for bundles and composing contracts: it returns 0 when paused or empty, but still reverts if the token transfer itself fails (for example a blacklisted or globally paused USDC).
- **Owner is set explicitly at deploy** (a Safe), so the broadcasting key never holds custody. Owner powers: `setRecipient`, `pause`/`unpause`, `rescueToken`, `rescueETH`, and two-step ownership transfer.
- **Recipient guard.** The constructor and `setRecipient` reject the zero address, the forwarder itself, and the token contract.

### Known operational failure modes

Because `forward()` is permissionless and reads `recipient`/`paused` at execution time, whatever sits in the forwarder is sweepable by anyone to the current recipient in every block. Rerouting away from a recipient you no longer trust is therefore a race: the mitigation is to keep the forwarder swept and submit the reroute as one Safe bundle (`pause`, `setRecipient`, `unpause`) through a private relay. USDC-specific edge cases (recipient blacklisted, forwarder blacklisted, USDC globally paused) are documented inline in the contract and in the deploy runbook comments.

## RateLimitedForwarder

Same shape as `Erc20Forwarder` — one immutable token, an owner-controlled `recipient`, deploys paused, permissionless `forward()`/`tryForward()` — but the amount released per call is metered by a token bucket instead of being the full balance. This caps how fast funds can leave the forwarder if the recipient is ever wrong or compromised, shrinking the reroute race to one bucket per period.

- **Token-bucket drip.** The bucket refills continuously at `dripRate` tokens per `dripPeriod` seconds and is clamped at `maxReserve`. A call forwards `min(bucket, balance)` and debits the bucket by that amount. Any balance above what the bucket allows simply stays in the forwarder until the bucket refills.
- **`dripRate == 0` is the off switch.** With `dripRate == 0` the bucket is bypassed and the contract behaves exactly like `Erc20Forwarder`: `forward()` sweeps the full balance. The constructor and `setDripLimit` enforce `rate == 0 || period > 0`, so a non-zero rate can never pair with a zero period (division by zero).
- **Accrual tracks wall-clock, paused time excluded.** Accrual is computed from `block.timestamp - lastAccrual`. Pausing refills the bucket up to that moment and then freezes it; `unpause` resets `lastAccrual` so paused time grants no retroactive drip. `availableBalance()` previews the currently forwardable amount and returns 0 while paused.
- **Owner powers.** `setRecipient`, `setDripLimit`, `pause`/`unpause`, `rescueToken`, `rescueETH`, and two-step ownership transfer. `setDripLimit` re-accrues the bucket under the old rate before switching parameters and re-clamps it to the new `maxReserve`. The recipient guard (constructor and `setRecipient` reject the zero address, the forwarder itself, and the token) is identical to the base forwarder.

### Known operational failure modes

The permissionless-sweep race from `Erc20Forwarder` still applies, but the drip bounds its blast radius: an attacker who sees a bad `recipient` can only pull `min(bucket, balance)` before the bucket is empty, and must wait a full `dripPeriod` for it to refill. The same mitigation — pause/reroute/unpause as one private-relay Safe bundle — remains the clean path. Setting `dripRate == 0` restores full-sweep behavior and therefore removes this protection, so it is intended only for a deliberate drain under owner control.

## Off-chain operation

The vault is driven by an off-chain keeper (an hourly cron in the Metro app) using the `operator` key. Each run, in order:

1. `activateSettlement()` if a proposal's timelock has elapsed.
2. Activate any payout-address changes whose timelock elapsed.
3. `proposeSettlement(...)` with fresh cumulative totals computed off-chain from affiliate earnings (skipped if step 1 failed, since a proposal likely still exists).
4. `processIncoming()` to forward surplus USDC to the distributor.

Each step is individually recoverable; a failed step does not abort the others, and the run reports which steps failed. The operator key can only ever move entitlements forward within `maxCodeDelta`/`maxBatchDelta` and after a timelock, and can only forward surplus above the reserve. It cannot redirect claims or drain the reserve.

## Deployment

All deploy scripts live in `script/`. Run them from the repo root after `source .env`. Prefer `--account <keystore>` or `--ledger` over `--private-key`.

| Script | Deploys |
|---|---|
| `Deploy.s.sol` | CommissionVault (production). Reads addresses, limits, and timelocks from env. |
| `DeployForwarder.s.sol` | Erc20Forwarder. Asserts chain id, and that owner + recipient have code, before broadcasting. |
| `DeployRateLimitedForwarder.s.sol` | RateLimitedForwarder. Same chain-id/owner/recipient asserts, plus the drip parameters. |
| `DeployTestbed.s.sol` | FakeUSDC + FakeDistributor + CommissionVault, for live testing on Base. |

See `.env.example` for the full set of parameters.

```bash
# Dry run (no broadcast): drop --broadcast
FORWARDER_CHAIN_ID=1 FORWARDER_TOKEN=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 \
FORWARDER_RECIPIENT=0x<vault> FORWARDER_OWNER=0x<safe> \
forge script script/DeployForwarder.s.sol --rpc-url ethereum --account <keystore> --broadcast --verify
```

### Ethereum mainnet deployment

| Contract | Address |
|---|---|
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| CommissionVault | `0x415f2927F93D6C9e98aeb61b487902aB720Ce7FC` |

Deploy parameters: `maxCodeDelta` 10,000 USDC, `maxBatchDelta` 100,000 USDC, `settlementTimelock` and `payoutTimelock` 24h each. The `owner`, `operator`, `guardian`, and `distributor` are readable on-chain via the block explorer.

## Reporting

Please report security findings privately to the Metro Exchange team rather than opening a public issue.

## License

MIT
