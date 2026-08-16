#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
margin_bin="${1:-$project_dir/build/margin}"

fail() {
    printf 'CLI contract failure: %s\n' "$1" >&2
    exit 1
}

[[ -x "$margin_bin" ]] || fail "Margin binary is not executable at $margin_bin"

test_root="$(mktemp -d "${TMPDIR:-/tmp}/margin-cli-contracts.XXXXXX")"
cleanup() {
    if [[ -n "${test_root:-}" && -d "$test_root" ]]; then
        rm -rf -- "$test_root"
    fi
}
trap cleanup EXIT

document="$test_root/review.md"
fixture="$project_dir/Fixtures/agent-benchmark/atlas-launch-review.md"
cp "$fixture" "$document"

export MARGIN_ACTOR_ID="urn:margin:contract:test-agent"
export MARGIN_ACTOR_NAME="Margin CLI Contract"
export MARGIN_ACTOR_TYPE="software"

"$margin_bin" --help > "$test_root/help.txt"
grep -q "margin comments COMMAND" "$test_root/help.txt" || fail "main help omits comment discovery"
grep -q "creates an empty file" "$test_root/help.txt" || fail "main help omits the new-file contract"

"$margin_bin" inspect "$document" --json > "$test_root/inspect.json"
"$margin_bin" outline "$document" --json > "$test_root/outline.json"
"$margin_bin" slice "$document" --heading "Signals" --context 1 --json > "$test_root/slice.json"
python3 - "$test_root/inspect.json" "$test_root/outline.json" "$test_root/slice.json" <<'PY'
import json
import sys

inspect, outline, section = (json.load(open(path, encoding="utf-8")) for path in sys.argv[1:])
assert inspect["schema"] == "urn:margin:cli:v1" and inspect["ok"] is True
assert inspect["command"] == "inspect" and inspect["result"]["annotations"] == 0
assert outline["command"] == "outline" and outline["result"]["headings"]
assert section["command"] == "slice" and "shared signal" in section["result"]["text"]
PY

root_id="00000000-0000-4000-8000-000000008101"
reply_id="00000000-0000-4000-8000-000000008102"
nested_id="00000000-0000-4000-8000-000000008103"

set +e
"$margin_bin" comments add "$document" \
    --quote "shared signal" \
    -m "This must be disambiguated." \
    --id "00000000-0000-4000-8000-000000008100" \
    > "$test_root/ambiguous.out" 2> "$test_root/ambiguous.json"
ambiguous_exit=$?
set -e
[[ "$ambiguous_exit" -eq 65 ]] || fail "ambiguous quote returned $ambiguous_exit instead of 65"
python3 - "$test_root/ambiguous.json" <<'PY'
import json
import sys

error = json.load(open(sys.argv[1], encoding="utf-8"))
assert error["ok"] is False
assert error["error"]["code"] == "ANCHOR_AMBIGUOUS"
assert error["error"]["details"]["candidateCount"] == "2"
PY

"$margin_bin" comments add "$document" \
    --quote "launch budget" \
    -m "Set a measurable target." \
    --id "$root_id" > "$test_root/add.json"
"$margin_bin" comments add "$document" \
    --quote "launch budget" \
    -m "Set a measurable target." \
    --id "$root_id" > "$test_root/retry.json"
python3 - "$test_root/add.json" "$test_root/retry.json" <<'PY'
import json
import sys

first, retry = (json.load(open(path, encoding="utf-8")) for path in sys.argv[1:])
assert first["result"]["changed"] is True
assert retry["result"]["changed"] is False
assert first["result"]["annotation"]["id"] == retry["result"]["annotation"]["id"]
assert first["revision"] == retry["revision"] == 1
PY

set +e
"$margin_bin" comments add "$document" \
    --document \
    -m "This stale mutation must fail." \
    --id "00000000-0000-4000-8000-000000008104" \
    --if-revision 0 > "$test_root/conflict.out" 2> "$test_root/conflict.json"
conflict_exit=$?
set -e
[[ "$conflict_exit" -eq 75 ]] || fail "revision conflict returned $conflict_exit instead of 75"
python3 - "$test_root/conflict.json" <<'PY'
import json
import sys

error = json.load(open(sys.argv[1], encoding="utf-8"))
assert error["error"]["code"] == "REVISION_CONFLICT"
PY

"$margin_bin" comments reply "$document" "$root_id" \
    -m "Measure warm and cold starts." --id "$reply_id" > "$test_root/reply.json"
"$margin_bin" comments reply "$document" "$reply_id" \
    -m "Include sample size and variance." --id "$nested_id" > "$test_root/nested.json"
"$margin_bin" comments resolve "$document" "$root_id" > "$test_root/resolve.json"
"$margin_bin" comments reopen "$document" "$nested_id" > "$test_root/reopen.json"
"$margin_bin" comments list "$document" --status all > "$test_root/list.json"
"$margin_bin" comments list "$document" --status all --thread "$nested_id" > "$test_root/thread.json"
"$margin_bin" comments validate "$document" > "$test_root/validate.json"
python3 - "$test_root/list.json" "$test_root/thread.json" "$test_root/validate.json" <<'PY'
import json
import sys

listed = json.load(open(sys.argv[1], encoding="utf-8"))
thread = json.load(open(sys.argv[2], encoding="utf-8"))
validated = json.load(open(sys.argv[3], encoding="utf-8"))
comments = {item["annotation"]["id"]: item for item in listed["result"]["comments"]}
root = "urn:uuid:00000000-0000-4000-8000-000000008101"
reply = "urn:uuid:00000000-0000-4000-8000-000000008102"
nested = "urn:uuid:00000000-0000-4000-8000-000000008103"
assert comments[root]["threadStatus"] == "open"
assert comments[reply]["parentID"] == root and comments[reply]["depth"] == 1
assert comments[nested]["parentID"] == reply and comments[nested]["depth"] == 2
thread_comments = thread["result"]["comments"]
assert len(thread_comments) == 3
assert {item["rootID"] for item in thread_comments} == {root}
assert validated["result"]["valid"] is True
assert validated["result"]["annotationCount"] == 3
PY

"$margin_bin" read "$document" > "$test_root/logical.md"
cmp -s "$fixture" "$test_root/logical.md" || fail "comment operations changed logical Markdown bytes"

missing_app="$test_root/NotMargin.app"
new_document="$test_root/new-document.md"
set +e
MARGIN_APP_PATH="$missing_app" "$margin_bin" "$new_document" \
    > "$test_root/new-open.out" 2> "$test_root/new-open.err"
new_open_exit=$?
set -e
[[ "$new_open_exit" -eq 78 ]] || fail "invalid explicit app returned $new_open_exit instead of 78"
[[ -f "$new_document" && ! -s "$new_document" ]] || fail "opening a new path did not create an empty file"
grep -q "specified by MARGIN_APP_PATH" "$test_root/new-open.err" || fail "explicit app error was not stable"

missing_document="$test_root/no-such-parent/new-document.md"
set +e
MARGIN_APP_PATH="$missing_app" "$margin_bin" "$missing_document" \
    > "$test_root/missing-parent.out" 2> "$test_root/missing-parent.err"
missing_parent_exit=$?
set -e
[[ "$missing_parent_exit" -eq 66 ]] || fail "missing parent returned $missing_parent_exit instead of 66"
[[ ! -e "$test_root/no-such-parent" ]] || fail "opening a new path created missing parent directories"

printf 'Margin CLI contracts: PASS\n'
