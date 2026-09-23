# Streaming output codec benchmark

The compact record-codec gate is intentionally separate from the streaming-output API. JSON Lines remains the supported and preferred record format. This local prototype comparison is not enough to promote another wire codec.

## Method

Run `python3 Scripts/benchmark_record_codecs.py --iterations 30` to compare JSON Lines with positional arrays, keyed pipes, and field blocks using three representative synthetic payload sets. The script verifies round-trip equality, reports UTF-8 bytes and median local Python parse time, and optionally reports cached `o200k_base` token counts with `--tokens` when `tiktoken` is already installed. It does not install dependencies.

The measurements below are the local prototype run recorded during implementation. Parse times are illustrative for this host/interpreter, not a platform or end-to-end performance claim.

| Dataset | Codec | UTF-8 bytes | Median parse (ms) |
| --- | --- | ---: | ---: |
| 100 short cards | JSON Lines | 7,880 | 0.092 |
|  | Positional arrays | 4,831 | 0.096 |
|  | Keyed pipes | 6,880 | 0.186 |
|  | Field blocks | 8,180 | 0.388 |
| 30 prose-heavy records | JSON Lines | 73,600 | 0.118 |
|  | Positional arrays | 72,721 | 0.134 |
|  | Keyed pipes | 73,300 | 0.146 |
|  | Field blocks | 73,690 | 0.206 |
| 50 escaping-heavy records | JSON Lines | 32,240 | 0.109 |
|  | Positional arrays | 30,741 | 0.112 |
|  | Keyed pipes | 31,740 | 0.154 |
|  | Field blocks | 32,390 | 0.237 |

## Decision

Positional arrays reduced bytes materially for short cards, but provided almost no byte reduction for prose-heavy records and did not improve local parse time. The other candidates were also slower to parse in this prototype. Token counts were unavailable in the recorded run; model generation latency, valid-generation rate, malformed-output recovery, and escaping reliability were not measured. Round-trip parser tests alone do not establish that a model will reliably generate the formats.

Therefore no compact codec is promoted or exposed as a versioned CodexKit wire format. JSON Lines remains the only `AgentRecordCodec` case. Revisit the decision only with tokenizer results and model-backed generation/reliability measurements over escaped, prose-heavy, and schema-rich workloads, showing meaningful token or end-to-end latency savings without materially reducing generation, parsing, or escaping reliability.
