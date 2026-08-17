#!/usr/bin/env python3
"""Create a private holdout key for paired collaboration evaluations."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.dont_write_bytecode = True
from eval_lib import EvalError, create_holdout_key  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    arguments = parser.parse_args()
    try:
        commitment = create_holdout_key(arguments.output)
        print(json.dumps({"commitment": commitment, "created": True, "mode": "0600"}, sort_keys=True))
        return 0
    except (EvalError, OSError, ValueError) as error:
        print(json.dumps({"created": False, "errorType": type(error).__name__}, sort_keys=True), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
