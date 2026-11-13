# How to run: XDC network on laptop A + reth on laptop B

One script for both laptops: `xdc-net.sh`. It runs in Ubuntu (or Ubuntu inside WSL on Windows).

| Laptop | Runs | RAM needed |
|---|---|---|
| **A** (other laptop) | 4 XDC sealers + geth, erigon, nethermind, besu, xone | ~4 GB free |
| **B** (this laptop) | reth only | ~3.5 GB free (stop chain 20119 first) |

The two laptops are on different networks, so they are linked with **Tailscale** (free).
Create one Tailscale account first at https://tailscale.com and use it on both laptops.

## Get the script (both laptops)

Inside Ubuntu (on Windows: `wsl --install -d Ubuntu` in PowerShell first). No GitHub account needed:

```bash
git clone https://github.com/XDCIndia/ItWorksinMyLocal
cp "ItWorksinMyLocal/Harsh work/xdc-net.sh" ~/ && cd ~ && chmod +x xdc-net.sh
```

The script makes its own separate copy of the repo for the network (`~/xdc-net-<CHAIN_ID>`).

## Laptop A: the network

```bash
./xdc-net.sh tailscale      # installs Tailscale, shows a login link -> log in
./xdc-net.sh start          # sets up everything + starts the network (~20-40 min first time)
./xdc-net.sh status         # every node: block, peers, "all nodes agree" check
./xdc-net.sh connect-info   # creates connect-20120.json (also on the Windows Desktop)
```

Send `connect-20120.json` to laptop B (Tailscale "Send file", WhatsApp, email...).

## Laptop B: reth

```bash
./xdc-net.sh tailscale                      # same Tailscale account as laptop A
./xdc-net.sh join-reth connect-20120.json   # downloads reth, connects, waits until it follows the chain
./xdc-net.sh reth-status
./xdc-net.sh reth-stop
```

## Stopping

- Laptop A: `./xdc-net.sh stop` (data kept; `start` again = brand-new chain)
- Laptop B: `./xdc-net.sh reth-stop`

## Options (put in front of the command)

- `CHAIN_ID=20121` use another chain id (default 20120)
- `CLIENTS="geth erigon xone"` fewer followers (if RAM is short)
- `ETHSTATS=off` don't report to SkyNet
- `FORCE=1` start even when RAM looks too low

SkyNet: https://skynet.xdcindia.com/stats?net=20120
