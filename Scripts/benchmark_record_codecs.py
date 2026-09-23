#!/usr/bin/env python3
"""Local prototype comparison, not a published CodexKit wire-format specification.

Prints byte sizes, optional o200k_base token counts, and median local parse time.
Does NOT measure model generation reliability or network/generation latency.
No optional dependency is installed or downloaded automatically.
"""
import argparse
import json
import statistics
import time

KEYS = ["id", "title", "priority", "text"]
HEADER = "@prototype-arrays " + json.dumps(KEYS, separators=(",", ":")) + "\n"


def compact(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def encode(records, codec):
    if codec == "jsonlines":
        return "".join(compact(record) + "\n" for record in records)
    if codec == "positional-arrays":
        return HEADER + "".join(compact([record[key] for key in KEYS]) + "\n" for record in records)
    if codec == "keyed-pipes":
        return "".join("|".join(key + "=" + compact(record[key]) for key in KEYS) + "\n" for record in records)
    if codec == "field-blocks":
        return "".join("@record\n" + "".join(key + ":" + compact(record[key]) + "\n" for key in KEYS) + "@end\n" for record in records)
    raise ValueError(codec)


def decode(source, codec):
    lines = source.split("\n")
    if lines[-1] == "":
        lines.pop()
    if codec == "jsonlines":
        return [json.loads(line) for line in lines]
    if codec == "positional-arrays":
        if lines.pop(0) + "\n" != HEADER:
            raise ValueError("invalid header")
        result = []
        for line in lines:
            values = json.loads(line)
            if len(values) != len(KEYS):
                raise ValueError("incorrect field count")
            result.append(dict(zip(KEYS, values)))
        return result
    if codec == "keyed-pipes":
        result = []
        decoder = json.JSONDecoder()
        for line in lines:
            record, index = {}, 0
            while index < len(line):
                separator = line.index("=", index)
                key = line[index:separator]
                if key not in KEYS or key in record:
                    raise ValueError("invalid or duplicate key")
                value, end = decoder.raw_decode(line, separator + 1)
                record[key] = value
                if end < len(line) and line[end] != "|":
                    raise ValueError("invalid separator")
                index = end + 1
            if set(record) != set(KEYS):
                raise ValueError("missing field")
            result.append(record)
        return result
    if codec == "field-blocks":
        result, record = [], None
        for line in lines:
            if line == "@record" and record is None:
                record = {}
            elif line == "@end" and record is not None and set(record) == set(KEYS):
                result.append(record)
                record = None
            elif record is not None and ":" in line:
                key, value = line.split(":", 1)
                if key not in KEYS or key in record:
                    raise ValueError("invalid or duplicate field")
                record[key] = json.loads(value)
            else:
                raise ValueError("invalid framing")
        if record is not None:
            raise ValueError("incomplete record")
        return result
    raise ValueError(codec)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iterations", type=int, default=30)
    parser.add_argument("--tokens", action="store_true", help="Use an already installed/cached tiktoken o200k_base tokenizer.")
    args = parser.parse_args()
    tokenizer = None
    if args.tokens:
        import tiktoken
        tokenizer = tiktoken.get_encoding("o200k_base")
    escaped = 'Quotes "x", pipe |, equals =, colon :, backslash \\, XML <&>, emoji 😀, CR\rLF\n@record\n@end\n'
    datasets = {
        "short-cards": [{"id": i, "title": f"Item {i}", "priority": "high", "text": "A short recommendation."} for i in range(100)],
        "long-prose": [{"id": i, "title": f"Item {i}", "priority": "low", "text": ("Evidence with caveats. " * 100) + escaped} for i in range(30)],
        "escaping-heavy": [{"id": i, "title": escaped, "priority": "medium", "text": escaped * 5} for i in range(50)],
    }
    results = []
    for label, records in datasets.items():
        for codec in ["jsonlines", "positional-arrays", "keyed-pipes", "field-blocks"]:
            source = encode(records, codec)
            assert decode(source, codec) == records
            samples = []
            for _ in range(args.iterations):
                started = time.perf_counter_ns()
                assert decode(source, codec) == records
                samples.append((time.perf_counter_ns() - started) / 1_000_000)
            results.append({"dataset": label, "codec": codec, "utf8_bytes": len(source.encode()),
                            "o200k_tokens": len(tokenizer.encode(source)) if tokenizer else None,
                            "median_parse_ms": round(statistics.median(samples), 3), "roundtrip": True})
    print(json.dumps({"results": results,
                      "generation_reliability": "not measured", "end_to_end_latency": "not measured",
                      "decision": "No compact format is promoted by this local benchmark alone."}, indent=2))


if __name__ == "__main__":
    main()
