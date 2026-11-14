"""Print the description + default of reth's memory/cache flags from `reth node --help` output."""
import re, sys
text = open(sys.argv[1]).read().splitlines()
want = re.compile(r"^\s+--(tx-channel-memory-limit|rpc-cache\.max-(blocks|receipts|bals)(-bytes)?|rpc\.evm-memory-limit|"
                  r"db\.(max-size|growth-step|rocksdb-block-cache-size|balstore-cache-size)|"
                  r"engine\.(persistence-threshold|persistence-backpressure-threshold|memory-block-buffer-target|"
                  r"disable-state-cache|cross-block-cache-size|reserved-cpu-cores|prewarming-threads|"
                  r"disable-sparse-trie-cache-pruning|disable-precompile-cache)|jit\.code-cache-bytes|"
                  r"txpool\.(pending|basefee|queued)-max-size|txpool\.max-cached-entries|full)\b")
i = 0
while i < len(text):
    if want.match(text[i]):
        flag = text[i].strip()
        body = []
        j = i + 1
        while j < len(text) and not re.match(r"^\s+-", text[j]) and not re.match(r"^\S", text[j]):
            if text[j].strip(): body.append(text[j].strip())
            j += 1
        desc = " ".join(body)
        default = re.search(r"\[default: ([^\]]+)\]", desc)
        desc = re.sub(r"\s*\[default: [^\]]+\]", "", desc)
        print("%s\t%s\t%s" % (flag, default.group(1) if default else "-", desc[:260]))
        i = j
    else:
        i += 1
