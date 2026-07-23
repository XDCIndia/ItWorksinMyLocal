# netlab topology schema

A **topology** is a JSON file (see `topologies/*.json`) describing a
self-contained private XDPoS network: its own chain parameters, its own
genesis (generated fresh by `fleet.sh up`, never touching `./genesis/genesis.json`),
and an ordered list of nodes. `netlab/topo.sh` parses and validates it;
`netlab/node.sh` starts/stops individual nodes from it; `netlab/fleet.sh`
brings up/tears down the whole topology.

## Top-level fields

| Field            | Type    | Required | Default | Notes |
|-------------------|---------|----------|---------|-------|
| `name`            | string  | yes      | --      | Must equal the filename stem (`topologies/legacy-4.json` -> `"legacy-4"`). Used as the `nodes/<name>/` run-state directory. |
| `description`     | string  | no       | `""`    | Free text, shown by `topo.sh print`. |
| `chainId`         | int     | yes      | --      | Passed to `gen-genesis.sh --chainid` and `join.sh --networkid`. |
| `epoch`           | int     | yes      | --      | **Must be `900`.** Legacy oldxdc hardcodes its own internal checkpoint constant (`EpocBlockRandomize=900`) independent of this genesis field; any other value freezes the chain at the first checkpoint (see `gen-genesis.sh`'s own `--epoch` warning). `topo.sh validate` hard-errors otherwise. |
| `v2block`         | int     | yes      | --      | V1->V2 BFT switch block. **Must be a multiple of `epoch`** (i.e. of 900) -- the switch only happens at an epoch/checkpoint boundary. `topo.sh validate` hard-errors otherwise. |
| `period`          | int     | no       | `1`     | Block time in seconds (post-processed into the genesis like `gen-genesis.sh --period`). |
| `reward`          | int     | no       | `5000`  | Block reward (`gen-genesis.sh --reward`). |
| `gap`             | int     | no       | `450`   | Blocks before checkpoint (`gen-genesis.sh --gap`). |
| `skipV1Validation`| bool    | no       | `false` | **Forbidden -- must be `false`/omitted.** `docs/lab/DESIGN.md`'s "Documented risks & forbidden knobs" section bans this genesis flag outright ("they disable the validation the lab exists to compare"); `topo.sh validate` hard-errors if it is `true`. It exists as a `gen-genesis.sh --skip-v1-validation` passthrough for non-lab uses of that generator, not as a supported netlab knob -- an earlier revision of this table described it as the fix for a follower gas-cost desync, but that "fix" is exactly the validation this lab exists to exercise (see scenario 12 / ItWorksinMyLocal#34, #46). |
| `ethstats`        | bool    | no       | `false` | ItWorksinMyLocal#62 harness fix A. `false`/omitted (the default): `netlab/node.sh` passes every node `--no-ethstats` (unchanged historical behavior -- this fleet is invisible on the public dashboard). `true`: `node.sh` instead lets `join.sh`'s own ON-by-default ethstats reporting through (same target/secret as `run.sh`, `xdc_openscan_stats_2026@stats.xdcindia.com:443`), naming each node `xdclabs-<name>-<nodeId>` so the whole fleet is identifiable on `stats.xdcindia.com`. Set it on **soak/persistent** topologies meant to run for a while (`legacy-4`, `mixed-5`, `all-clients`); leave it off on the `mint-iter*` gate topologies, which are wiped and rebuilt every gate iteration and would just flap on the public page. Independent of this field, `NETLAB_ETHSTATS=1` in the environment forces reporting on for ANY topology for one run, without editing its JSON (e.g. an ad-hoc soak of a normally-transient topology). |
| `peering`         | string  | no       | `"hub"` | `"hub"` (D5's original model): followers dial ONLY the sealers, never each other. `"mesh"` (ItWorksinMyLocal#46 T3.2): `fleet.sh up` additionally hands each follower every EARLIER-started follower's own enode as a bootnode too (still one at a time, still gated on `peers>=1`) -- so followers end up peered with each other as well, not just with the sealers. Sealer<->sealer peering is unaffected by this field either way (always through the topology's own bootnode). |
| `portBase`        | int     | yes      | --      | **Must be >= 34000** (the framework's reserved port band -- never overlaps the live net5151 stack on 9645-10245 or net5050/postgres). Each node gets a distinct 20-wide port block starting here; see "Port math" below. |
| `staggerSeconds`  | int     | no       | `5`     | `fleet.sh up` waits this long (and gates on `peers>=1`, not just the clock) between starting each follower. |
| `nodes`           | array   | yes      | --      | See "Node fields" below. Must contain at least one `sealer`. |

## Node fields

Each entry in `nodes` is expanded (see "Id expansion" below) into one or
more resolved node rows before validation.

| Field     | Type   | Required           | Notes |
|-----------|--------|---------------------|-------|
| `id`      | string | yes                 | Unique after expansion. Becomes the `nodes/<topo>/<id>/` datadir and the node's identity/ethstats-name component. |
| `client`  | string | yes                 | One of `oldxdc \| geth \| erigon \| besu \| nethermind \| reth \| xone` (the same enum `join.sh --client` accepts, minus `all`). |
| `role`    | string | yes                 | `sealer` (mines, `oldxdc` only), `follower` (sync-only), or `proposer` (ItWorksinMyLocal#62: a node under test for client-side sealing -- `client` must be one of `geth \| xone \| reth`, the only clients `netlab/node.sh` + `join.sh` currently wire a sealing attempt for; oldxdc seals via `role=sealer` instead, and erigon/besu/nethermind have no sealing-flag path here yet). |
| `keyRef`  | string | yes iff `role=sealer\|proposer` | Name of an **environment variable** (sourced from `.env`, e.g. `PRIVATE_KEY_1`) holding the raw hex validator private key. Topology JSON files are committed to git and must never contain a private key directly -- only a reference to where the (gitignored) key lives. A `proposer`'s address is derived the same neutral way a `sealer`'s is (`node.sh addr`, via `XDC account import` regardless of the proposer's own `client`) and gets APPENDED to `gen-genesis.sh --signers` by `fleet.sh` -- so it lands in genesis extraData AND the seeded 0x88 masternode SMC alongside the real sealers, before that proposer's own client ever starts. |
| `maxpeers`| int    | no                  | Per-node override, threaded to `join.sh --maxpeers`. Omit it to get the **role-based default** (ItWorksinMyLocal#46 T3.1) instead of the client binary's own hardcoded default: a `sealer` defaults to `node_count + 5` (enough for a full sealer mesh plus every follower dialing in, plus slack for a manual/admin connection) so a large topology can't starve a sealer's peer slots; a `follower` defaults to a fixed `15` regardless of topology size (hub mode only ever needs the sealer count; mesh mode -- see `peering` below -- adds the other followers too), so a follower can't itself become an unbounded peer-storm sink as the topology grows. `topo.sh print`'s `maxpeers` column always shows the resolved value (explicit or role-based default), never blank. |

### Id expansion

`"id": "geth{1..3}"` expands to three node rows `geth1`, `geth2`, `geth3`,
each an identical copy of the rest of that entry (same `client`/`role`/etc),
occupying consecutive port blocks in declaration order. Lets a stress
topology (e.g. Phase 3's `13-all-clients-soak`) declare "N replicas of the
same follower client" without repeating JSON blocks. Not used by the three
shipped presets (each of their nodes needs a distinct `keyRef` or is a
one-off follower), but the parser supports it for topologies that need it.
`{A..B}` requires `A <= B`; reversed or malformed ranges are a hard error.

### Constraints (`topo.sh validate` hard-errors on any violation)

- `epoch` must be `900`.
- `v2block % epoch` must be `0`.
- `portBase` must be `>= 34000`.
- every node `id` must be unique after expansion.
- `client` must be one of the 7 known values.
- `role=sealer` requires `client=oldxdc` (only oldxdc can seal via `join.sh --mine`; the other clients' join profiles are sync-only by construction).
- `role=proposer` requires `client` one of `geth | xone | reth` (the clients `netlab/node.sh` + `join.sh` wire a sealing attempt for -- an honest guard against configuring a proposer for a client with no such wiring at all, not a claim any of the three actually mints yet; see `join.sh`'s own per-client notes).
- at least one `role=sealer` node must exist (a topology with no sealer has no chain to generate/join). A `proposer` does not count toward this -- it is a candidate under test, not (yet) part of the trusted quorum.
- `role=sealer` or `role=proposer` requires `keyRef`; `keyRef` must name a variable that is actually set in the environment at resolve time (checked by `topo.sh print`, which is what `fleet.sh up` runs against -- so a missing `.env` key fails fast, before any process starts).
- `client=nethermind` is rejected whenever `chainId != 5151` -- nethermind loads only its own bundled net5151 Parity-style chainspec, not an arbitrary genesis file (ItWorksinMyLocal#46 open question #2). None of the four shipped presets use nethermind for this reason.
- every topology's own `[portBase, portBase + node_count*20]` port range must not overlap any SIBLING topology file's own range (a sibling being another `*.json` file in the same directory) -- see "Port re-band" below.

## Env-var templating

Before parsing, `topo.sh` substitutes any `${VAR}` / `${VAR:-default}` token
found anywhere in the raw topology file text with that variable's value from
the process environment (`topo.sh` sources `.env` itself, same as
`fleet.sh`/`node.sh`, so `.env` values are visible too), falling back to the
given default (or `""` if there is no `:-default` and the var is unset).
This is generic -- not special-cased to any one field -- so a placeholder
may sit inside a JSON string (`"client": "${CAND_CLIENT:-geth}"`) or bare
where a JSON literal is expected (`"v2block": ${MINT_V2BLOCK:-1800}`), as
long as the substituted text is itself valid JSON at that position. This is
what lets `topologies/mint-iter.json` re-parameterize its candidate node's
`client` and its `v2block` per run via plain env vars, with no per-run file
generation.

## Port math

For a resolved (post-expansion) node at zero-based position `i` in the
`nodes` list:

```
p2p      = portBase + i*20 + 0
rpc      = portBase + i*20 + 1
ws       = portBase + i*20 + 2
authrpc  = portBase + i*20 + 3   (erigon/reth/xone; T0.2's --authrpc-port)
torrent  = portBase + i*20 + 4   (erigon only;       T0.2's --torrent-port)
mcp      = portBase + i*20 + 5   (erigon only;       T0.2's --mcp-port)
privapi  = portBase + i*20 + 6   (erigon only;       T0.2's --privapi, as 127.0.0.1:<port>)
```

Slots 7-19 of each node's block are reserved for future per-node ports
(e.g. a metrics port) without renumbering anything already assigned.

The local bootnode (one per topology, started by `fleet.sh up` from the
shared `./bootnode.key`, same derivation `run.sh` uses) gets the port
**just past the last node's block**: `portBase + N*20` (both its UDP
discovery and TCP listen port), where `N` is the resolved node count. This
keeps it inside the topology's own reserved range regardless of `portBase`,
without stealing a slot from the `{A..B}`-expandable node port formula
above.

## Port re-band

Every shipped topology gets its own non-overlapping sub-band inside the
reserved `34000-34999` range (`topo.sh validate`/`print` hard-errors on any
violation of this -- see the cross-topology overlap check above), with slack
left over for growth:

| Topology            | `portBase` | Own range (nodes + bootnode) | Slack before the next band |
|----------------------|-----------:|-------------------------------|-----------------------------|
| `legacy-4.json`      | `34000`    | `34000-34080` (4 nodes)       | up to `34199` |
| `mixed-5.json`       | `34200`    | `34200-34300` (5 nodes)       | up to `34499` |
| `mint-iter.json`     | `34500`    | `34500-34620` (6 nodes)       | up to `34699` |
| `all-clients.json`   | `34700`    | `34700-34880` (9 nodes)       | up to `34999` |

This replaces an earlier layout (`legacy-4` at `34000`, `mixed-5` at
`34100`, `all-clients` at `34200`) that had a **latent collision**:
`mixed-5`'s 5 nodes put its own bootnode at `34100 + 5*20 = 34200` --
exactly `all-clients`' old `portBase`, i.e. `all-clients`' `node1` p2p port.
The two topologies are never brought up in the same `fleet.sh up` call, but
nothing enforced that they COULDN'T be (e.g. two scenarios run back-to-back
without an intervening `wipe`, or a stale bootnode process left over from an
aborted run) -- the cross-topology overlap check above now makes this class
of mistake a hard `topo.sh validate` error instead of a silent runtime port
clash, for any topology file added in the future too.

## Run-state layout

`fleet.sh up` never touches `./genesis/genesis.json` or the existing
`./nodes/1..4` / `./nodes/<client>-<type>` conventions used by `run.sh` /
`join.sh` directly. Everything for a topology lives under its own
`nodes/<name>/`:

```
nodes/<name>/genesis.json        # generated by gen-genesis.sh --out, this topology's own chain
nodes/<name>/topo.resolved.tsv   # topo.sh print's output -- the normalized node table fleet.sh acts on
nodes/<name>/bootnode.pid        # this topology's bootnode process
nodes/<name>/bootnode.log
nodes/<name>/<nodeId>/           # this node's datadir (join.sh --datadir), keystore included
nodes/<name>/<nodeId>/node.log
nodes/<name>/<nodeId>/node.pid
nodes/<name>/<nodeId>/meta.env   # resolved client/role/ports/bootnodes for stop/status/logs
```

## The shipped presets

| Preset             | Nodes | Purpose |
|--------------------|-------|---------|
| `legacy-4.json`    | 4 oldxdc sealers | Baseline regression / engine smoke test -- mirrors `run.sh`'s default 4-validator net. |
| `mixed-5.json`     | 4 oldxdc sealers + 1 geth follower | The ItWorksinMyLocal#34 topology declaratively: node5 must sync genesis->tip in lockstep across the V1->V2 switch. |
| `all-clients.json` | 4 oldxdc sealers + geth/erigon/besu/reth/xone followers | Full cross-client bring-up (nethermind excluded per the constraint above) -- the peer-starvation / client-matrix regression scenario. |
| `mint-iter.json`   | 3 oldxdc sealers + 1 `role=proposer` candidate (`cand1`, client parameterized via `CAND_CLIENT`) + 1 oldxdc observer (`obs1`) + 1 modern-geth observer (`obs2`) | ItWorksinMyLocal#62's mint loop's own inner topology -- the smallest net that can exercise the full S0-S7 mint-enablement graph for one client at a time; see `lab/scenarios/15-topo-mint-rotation.sh` / `lab/mintlab.sh`. |
