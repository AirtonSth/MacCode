#!/usr/bin/env python3
"""Exact stdin token counter adapter for RCW1EfficiencyCorpusTests.

Protocol:
  --diagnostic  prints stable counter metadata as JSON
  --count       prints only the integer token count for UTF-8 stdin
"""

import argparse
import importlib.metadata
import json
import os
import sys


def main() -> int:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--diagnostic", action="store_true")
    mode.add_argument("--count", action="store_true")
    args = parser.parse_args()

    try:
        import tiktoken
    except ImportError:
        print("tiktoken is required; install it in the Python environment used by this executable", file=sys.stderr)
        return 2

    encoding_name = os.environ.get("RCW1_TIKTOKEN_ENCODING", "o200k_base")
    try:
        encoding = tiktoken.get_encoding(encoding_name)
    except Exception as error:
        print(f"unable to load tiktoken encoding {encoding_name}: {error}", file=sys.stderr)
        return 2

    if args.diagnostic:
        print(json.dumps({
            "encoding": encoding_name,
            "measurement_kind": "exact-local-tokenizer",
            "name": "tiktoken",
            "version": importlib.metadata.version("tiktoken"),
        }, sort_keys=True, separators=(",", ":")))
        return 0

    try:
        text = sys.stdin.buffer.read().decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        print(f"stdin is not valid UTF-8: {error}", file=sys.stderr)
        return 2
    print(len(encoding.encode(text, disallowed_special=())))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
