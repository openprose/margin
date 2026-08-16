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
watch_pid=""
cleanup() {
    if [[ -n "${watch_pid:-}" ]]; then
        kill -TERM "$watch_pid" 2>/dev/null || true
        wait "$watch_pid" 2>/dev/null || true
    fi
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
grep -q "margin review FILE --json" "$test_root/help.txt" || fail "main help omits bounded review discovery"

"$margin_bin" inspect "$document" --json > "$test_root/inspect.json"
"$margin_bin" outline "$document" --json > "$test_root/outline.json"
"$margin_bin" slice "$document" --heading "Signals" --context 1 --json > "$test_root/slice.json"
"$margin_bin" review "$document" --json > "$test_root/review.json"
python3 - "$test_root/inspect.json" "$test_root/outline.json" "$test_root/slice.json" "$test_root/review.json" <<'PY'
import json
import sys

inspect, outline, section, review = (json.load(open(path, encoding="utf-8")) for path in sys.argv[1:])
assert inspect["schema"] == "urn:margin:cli:v1" and inspect["ok"] is True
assert inspect["command"] == "inspect" and inspect["result"]["annotations"] == 0
assert outline["command"] == "outline" and outline["result"]["headings"]
assert section["command"] == "slice" and "shared signal" in section["result"]["text"]
assert review["command"] == "review" and review["result"]["change"] == "snapshot"
assert review["result"]["document"]["revision"] == 0
assert review["result"]["outline"]["included"] == len(outline["result"]["headings"])
assert review["result"]["truncation"]["limits"]["maxThreads"] > 0
assert len(json.dumps(review)) < 200_000
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
current_revision="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["revision"])' "$test_root/list.json")"
"$margin_bin" review "$document" --json --since-revision 0 > "$test_root/review-advanced.json"
"$margin_bin" review "$document" --json --since-revision "$current_revision" > "$test_root/review-current.json"
python3 - "$test_root/list.json" "$test_root/thread.json" "$test_root/validate.json" "$test_root/review-advanced.json" "$test_root/review-current.json" <<'PY'
import json
import sys

listed = json.load(open(sys.argv[1], encoding="utf-8"))
thread = json.load(open(sys.argv[2], encoding="utf-8"))
validated = json.load(open(sys.argv[3], encoding="utf-8"))
advanced = json.load(open(sys.argv[4], encoding="utf-8"))
current = json.load(open(sys.argv[5], encoding="utf-8"))
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
assert advanced["result"]["change"] == "advanced"
assert advanced["result"]["threads"]["open"]["items"]
assert advanced["result"]["threads"]["open"]["items"][0]["anchor"]["excerpt"]["text"]
assert current["result"]["change"] == "notModified"
assert current["result"]["truncation"]["detailsOmittedBecauseNotModified"] is True
PY

"$margin_bin" comments edit "$document" "$nested_id" \
    -m "Include Unicode sample size — café ✅" \
    --if-revision "$current_revision" > "$test_root/edit.json"
edited_revision="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["revision"])' "$test_root/edit.json")"
python3 - "$test_root/edit.json" <<'PY'
import json
import sys

edited = json.load(open(sys.argv[1], encoding="utf-8"))
result = edited["result"]
assert edited["command"] == "comments.edit"
assert result["changed"] is True
assert result["annotation"]["id"].endswith("8103")
assert result["annotation"]["body"]["value"] == "Include Unicode sample size — café ✅"
assert result["previousAnnotation"]["body"]["value"] == "Include sample size and variance."
assert result["undo"]["message"] == "Include sample size and variance."
assert result["undo"]["ifRevision"] == edited["revision"]
PY

set +e
"$margin_bin" comments delete "$document" "$root_id" \
    --if-revision "$edited_revision" > "$test_root/delete-safe.out" 2> "$test_root/delete-safe.json"
delete_safe_exit=$?
set -e
[[ "$delete_safe_exit" -eq 65 ]] || fail "non-leaf delete returned $delete_safe_exit instead of 65"
python3 - "$test_root/delete-safe.json" <<'PY'
import json
import sys

error = json.load(open(sys.argv[1], encoding="utf-8"))
assert error["error"]["code"] == "COMMENT_HAS_REPLIES"
PY

"$margin_bin" comments delete "$document" "$root_id" --subtree \
    --if-revision "$edited_revision" > "$test_root/delete-subtree.json"
python3 - "$test_root/delete-subtree.json" <<'PY'
import json
import sys

deleted = json.load(open(sys.argv[1], encoding="utf-8"))
result = deleted["result"]
assert deleted["command"] == "comments.delete"
assert result["subtree"] is True and result["deletedCount"] == 3
assert len(result["undo"]["records"]) == 3
assert result["undo"]["ifRevision"] == deleted["revision"]
PY

"$margin_bin" read "$document" > "$test_root/logical.md"
cmp -s "$fixture" "$test_root/logical.md" || fail "comment operations changed logical Markdown bytes"
cmp -s "$fixture" "$document" || fail "deleting the last thread did not restore exact Markdown bytes"

watch_document="$test_root/watch.md"
cp "$fixture" "$watch_document"
"$margin_bin" comments watch "$watch_document" --jsonl --since-revision 0 \
    > "$test_root/watch.jsonl" 2> "$test_root/watch.err" &
watch_pid=$!
for _ in {1..40}; do
    [[ -s "$test_root/watch.jsonl" ]] && break
    sleep 0.05
done
[[ -s "$test_root/watch.jsonl" ]] || fail "watch did not emit its initial event"
"$margin_bin" comments add "$watch_document" --document -m "Watched mutation" \
    --id "00000000-0000-4000-8000-000000008105" > "$test_root/watch-add.json"
for _ in {1..60}; do
    [[ "$(wc -l < "$test_root/watch.jsonl")" -ge 2 ]] && break
    sleep 0.05
done
[[ "$(wc -l < "$test_root/watch.jsonl")" -ge 2 ]] || fail "watch did not emit an atomic change event"
kill -INT "$watch_pid"
wait "$watch_pid"
watch_pid=""
[[ ! -s "$test_root/watch.err" ]] || fail "watch wrote unexpected stderr"
python3 - "$test_root/watch.jsonl" <<'PY'
import json
import sys

events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
assert [event["event"] for event in events] == ["ready", "change", "stopped"]
assert [event["sequence"] for event in events] == [0, 1, 2]
change = events[1]
assert change["current"]["revision"] == 1
assert change["changes"]["fileReplaced"] is True
assert change["changes"]["commentsChanged"] is True
assert change["changes"]["contentChanged"] is False
PY

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
