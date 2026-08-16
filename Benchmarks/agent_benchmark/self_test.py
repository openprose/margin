#!/usr/bin/env python3
"""Exercise the benchmark oracle locally without invoking Prime Agent or any model."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.dont_write_bytecode = True
from score import ROOT, render_markdown, score
from run import usage_metrics


FIXTURE = ROOT / "Fixtures" / "agent-benchmark" / "atlas-launch-review.md"
PROXY = Path(__file__).resolve().parent / "margin_proxy.py"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--margin-bin", required=True, type=Path)
    parser.add_argument("--keep", action="store_true")
    arguments = parser.parse_args()
    margin_binary = arguments.margin_bin.resolve()

    synthetic_events = b"\n".join([
        b'{"type":"message_update","message":{"role":"assistant","usage":{"input":999,"output":999,"cacheRead":999,"cacheWrite":999,"cost":{"total":999}}},"assistantMessageEvent":{"type":"text_delta","delta":"x"}}',
        b'{"type":"message_end","message":{"role":"assistant","usage":{"input":10,"output":3,"cacheRead":2,"cacheWrite":1,"cost":{"total":0.25}}}}',
        b'{"type":"agent_end","messages":[{"role":"assistant","usage":{"input":10,"output":3,"cacheRead":2,"cacheWrite":1,"cost":{"total":0.25}}}]}',
    ])
    synthetic_usage = usage_metrics(synthetic_events)
    if synthetic_usage["assistantMessages"] != 1 or synthetic_usage["output"] != 3 or synthetic_usage["cost"] != 0.25:
        raise RuntimeError("Benchmark usage extraction counted streaming or duplicate messages.")

    temporary = tempfile.mkdtemp(prefix="margin-agent-benchmark-self-test-")
    run_dir = Path(temporary)
    workspace = run_dir / "workspace"
    bin_dir = run_dir / "bin"
    workspace.mkdir()
    bin_dir.mkdir()
    document = workspace / "review.md"
    shutil.copy2(FIXTURE, document)
    proxy = bin_dir / "margin"
    shutil.copy2(PROXY, proxy)
    proxy.chmod(0o755)

    environment = os.environ.copy()
    environment["MARGIN_BENCH_REAL_BIN"] = str(margin_binary)
    environment["MARGIN_BENCH_COMMAND_LOG"] = str(run_dir / "command-log.jsonl")
    environment["MARGIN_ACTOR_ID"] = "urn:margin:benchmark:self-test"
    environment["MARGIN_ACTOR_NAME"] = "Benchmark Self Test"
    environment["MARGIN_ACTOR_TYPE"] = "software"

    def invoke(arguments: list[str], expected_exit: int = 0) -> dict[str, object] | None:
        completed = subprocess.run(
            [str(proxy), *arguments],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            check=False,
        )
        if completed.returncode != expected_exit:
            raise RuntimeError(
                f"Margin {' '.join(arguments)} returned {completed.returncode}, expected {expected_exit}: "
                f"{completed.stderr.decode(errors='replace')}"
            )
        if not completed.stdout.strip():
            return None
        try:
            return json.loads(completed.stdout)
        except json.JSONDecodeError:
            return None

    invoke(["--help"])
    invoke(["inspect", str(document), "--json"])
    invoke(["outline", str(document), "--json"])
    invoke(["slice", str(document), "--heading", "Signals", "--json"])

    root_id = "00000000-0000-4000-8000-000000009101"
    reply_id = "00000000-0000-4000-8000-000000009102"
    nested_id = "00000000-0000-4000-8000-000000009103"
    invoke([
        "comments", "add", str(document), "--quote", "launch budget",
        "-m", "Benchmark: define a measurable startup target.", "--id", root_id,
    ])

    sentence = "Cold start must stay below 45 milliseconds on the baseline Mac."
    source = FIXTURE.read_text(encoding="utf-8").replace("\r\n", "\n").replace("\r", "\n")
    start = source.index(sentence)
    invoke([
        "comments", "add", str(document), "--range", f"{start}:{start + len(sentence)}",
        "--expect", sentence, "-m", "Benchmark: verify this range against the implementation.",
        "--id", "00000000-0000-4000-8000-000000009104",
    ])
    invoke([
        "comments", "add", str(document), "--document",
        "-m", "Benchmark: add a compatibility note for macOS 13.",
        "--id", "00000000-0000-4000-8000-000000009105",
    ])
    invoke([
        "comments", "reply", str(document), root_id,
        "-m", "Benchmark reply: capture both warm and cold measurements.", "--id", reply_id,
    ])
    invoke([
        "comments", "reply", str(document), reply_id,
        "-m", "Benchmark nested reply: include sample size and variance.", "--id", nested_id,
    ])
    ambiguous_arguments = [
        "comments", "add", str(document), "--quote", "shared signal",
        "-m", "Benchmark: this refers to the second shared signal.",
        "--id", "00000000-0000-4000-8000-000000009106",
    ]
    invoke(ambiguous_arguments, expected_exit=65)
    invoke([*ambiguous_arguments, "--occurrence", "2"])
    invoke(["comments", "resolve", str(document), root_id])
    invoke(["comments", "list", str(document), "--status", "all"])
    invoke(["comments", "validate", str(document)])

    result = score(run_dir, margin_binary)
    (run_dir / "score.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    (run_dir / "report.md").write_text(render_markdown(result), encoding="utf-8")
    print(json.dumps({"runDir": str(run_dir), "score": result["score"], "sourcePreserved": result["sourcePreserved"]}, indent=2))
    if not arguments.keep:
        shutil.rmtree(run_dir)
    return 0 if result["score"] == 100 else 1


if __name__ == "__main__":
    raise SystemExit(main())
