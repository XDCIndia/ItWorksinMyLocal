"""Copy of chain 20119's genesis with the XDC fork heights xOne requires spelled out.
Values = what oldxdc uses for an unknown chain id: MainnetConstant in
XDPoSChain common/constants.mainnet.go (CopyConstants only overrides chain ids 51, 551, 5151)."""
import json, os
src = os.path.expanduser("~/iwiml-20119/nodes/net20119/genesis.json")
dst = os.path.expanduser("~/xone-bench/genesis-20119-xone.json")
g = json.load(open(src))
mainnet_tips = {
    "tip2019Block": 1,
    "tipSigningBlock": 3000000,
    "tipRandomizeBlock": 3464000,
    "tipNoHalvingMNRewardBlock": 38383838,
    "tipXDCXBlock": 38383838,
    "tipXDCXCancellationFeeBlock": 38383838,
    "tipTRC21FeeBlock": 38383838,
    "gas50xBlock": 80370000,
    "tipXDCXMinerDisableBlock": 80370000,
    "tipXDCXReceiverDisableBlock": 80370900,
}
added = {k: v for k, v in mainnet_tips.items() if k not in g["config"]}
g["config"].update(added)
# XDPoS.v2: xOne parses strictly (camelCase, every field required, no defaults).
v2 = g["config"]["XDPoS"]["v2"]
if "SwitchEpoch" in v2:   # legacy puppeth spelling; Go reads it case-insensitively, value 0 is what oldxdc uses
    v2["switchEpoch"] = v2.pop("SwitchEpoch")
# Fields oldxdc's V2Config does not have. xOne only reads them after tipUpgradePenalty /
# tipProportionalReward, which this chain never activates, so they are inert; values mirror
# oldxdc's hard-coded constants (common/constants.go: MinimunMinerBlockPerEpoch=1, LimitPenaltyEpoch=4).
extra = {"maxProtectorNodes": 0, "maxObserverNodes": 0, "masternodeReward": 0, "protectorReward": 0,
         "observerReward": 0, "minimumMinerBlockPerEpoch": 1, "limitPenaltyEpoch": 4, "minimumSigningTx": 0}
for cfg in list(v2.get("allConfigs", {}).values()) + ([v2["config"]] if "config" in v2 else []):
    for k, v in extra.items():
        cfg.setdefault(k, v)
print("v2 patched: switchEpoch=%s, filled %s" % (v2.get("switchEpoch"), list(extra)))
json.dump(g, open(dst, "w"), indent=1)
print("added:", added)
print("wrote", dst)
