"""Bounded, schema-backed validation for public MarginBench artifacts."""

from __future__ import annotations

import hashlib
import json
import math
import re
import sys
from datetime import datetime
from pathlib import Path, PurePosixPath
from typing import Any

from .candidates import CandidateManifest


VALIDATION_SCHEMA = "urn:marginbench:validation:v1"
MAX_ARTIFACT_BYTES = 16 * 1_024 * 1_024
MAX_REPORTED_ERRORS = 32
RFC3339_PATTERN = re.compile(
    r"^\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[Zz]|[+-]\d{2}:\d{2})$"
)


class ArtifactValidationError(ValueError):
    """A stable, publication-safe validation failure."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


def _schema_root() -> Path:
    package = Path(__file__).resolve().parent
    candidates = (package / "schemas" / "v1", package.parent / "schemas" / "v1")
    for candidate in candidates:
        if candidate.is_dir():
            return candidate
    raise ArtifactValidationError("SCHEMAS_UNAVAILABLE", "Bundled MarginBench schemas are unavailable.")


def _reject_constant(value: str) -> None:
    raise ArtifactValidationError("INVALID_JSON_NUMBER", f"Non-finite JSON number is forbidden: {value}")


def _object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            rendered = key if len(key) <= 200 else key[:200] + "…"
            raise ArtifactValidationError(
                "DUPLICATE_JSON_KEY",
                f"Duplicate JSON object key: {rendered}",
            )
        value[key] = item
    return value


def _decode(raw: bytes) -> Any:
    try:
        return json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=_object,
            parse_constant=_reject_constant,
        )
    except UnicodeDecodeError as error:
        raise ArtifactValidationError("INVALID_UTF8", "Artifact must be UTF-8 JSON.") from error
    except ArtifactValidationError:
        raise
    except json.JSONDecodeError as error:
        raise ArtifactValidationError(
            "INVALID_JSON",
            f"Invalid JSON at line {error.lineno}, column {error.colno}.",
        ) from error


def _read(path: Path) -> bytes:
    if str(path) == "-":
        raw = sys.stdin.buffer.read(MAX_ARTIFACT_BYTES + 1)
    else:
        try:
            with path.expanduser().open("rb") as handle:
                raw = handle.read(MAX_ARTIFACT_BYTES + 1)
        except OSError as error:
            raise ArtifactValidationError("ARTIFACT_UNREADABLE", "Artifact could not be read.") from error
    if len(raw) > MAX_ARTIFACT_BYTES:
        raise ArtifactValidationError(
            "ARTIFACT_TOO_LARGE",
            f"Artifact exceeds the {MAX_ARTIFACT_BYTES}-byte validation limit.",
        )
    return raw


def _schema_name(payload: Any) -> tuple[str, str]:
    if isinstance(payload, list):
        return "result.schema.json", "urn:marginbench:result-set:v1"
    if not isinstance(payload, dict):
        raise ArtifactValidationError("INVALID_ROOT", "Artifact root must be an object or result array.")
    if "results" in payload and isinstance(payload["results"], list) and "schema" not in payload:
        return "result.schema.json", "urn:marginbench:result-set:v1"
    identifier = payload.get("schema")
    names = {
        "urn:marginbench:binary-manifest:v1": "binary-manifest.schema.json",
        "urn:marginbench:candidate:v1": "candidate.schema.json",
        "urn:marginbench:control-catalog:v1": "control-catalog.schema.json",
        "urn:marginbench:experiment-ledger:v1": "experiment-ledger.schema.json",
        "urn:marginbench:execution-plan:v1": "execution-plan.schema.json",
        "urn:marginbench:paired-comparison:v1": "paired-comparison.schema.json",
        "urn:marginbench:prime-run-summary:v1": "prime-run-summary.schema.json",
        "urn:marginbench:prime-runtime-probe:v1": "runtime-probe.schema.json",
        "urn:marginbench:reference-run:v1": "reference-run.schema.json",
        "urn:marginbench:result:v1": "result.schema.json",
        "urn:marginbench:run:v1": "run-manifest.schema.json",
        "urn:marginbench:study-plan:v1": "study-plan.schema.json",
        "urn:marginbench:submission:v1": "submission.schema.json",
        "urn:marginbench:submission-verification:v1": "submission-verification.schema.json",
        VALIDATION_SCHEMA: "validation-receipt.schema.json",
    }
    if identifier == "urn:marginbench:episode:v1":
        name = "episode-definition.schema.json" if "scenario_id" in payload else "public-manifest.schema.json"
        return name, identifier
    name = names.get(identifier)
    if name is None:
        raise ArtifactValidationError(
            "UNSUPPORTED_SCHEMA",
            "Artifact does not declare a supported MarginBench schema.",
        )
    return name, str(identifier)


def _is_rfc3339(value: object) -> bool:
    if not isinstance(value, str) or RFC3339_PATTERN.fullmatch(value) is None:
        return False
    normalized = value[:-1] + "+00:00" if value[-1] in "Zz" else value
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        return False
    return parsed.tzinfo is not None


def submission_identifier(payload: dict[str, Any]) -> str:
    material = dict(payload)
    material.pop("id", None)
    encoded = json.dumps(
        material,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    return f"sha256:{hashlib.sha256(encoded).hexdigest()}"


def _validator(schema_name: str):
    try:
        from jsonschema import Draft202012Validator, FormatChecker
        from referencing import Registry, Resource
    except ImportError as error:
        raise ArtifactValidationError(
            "VALIDATOR_UNAVAILABLE",
            "Install MarginBench with its declared dependencies to validate artifacts.",
        ) from error
    root = _schema_root()
    registry = Registry()
    schemas: dict[str, dict[str, Any]] = {}
    for path in sorted(root.glob("*.schema.json")):
        schema = json.loads(path.read_text(encoding="utf-8"))
        schemas[path.name] = schema
        registry = registry.with_resource(schema["$id"], Resource.from_contents(schema))
    schema = schemas.get(schema_name)
    if schema is None:
        raise ArtifactValidationError("SCHEMA_UNAVAILABLE", f"Missing bundled schema: {schema_name}")
    format_checker = FormatChecker()
    format_checker.checks("date-time")(_is_rfc3339)
    return Draft202012Validator(schema, registry=registry, format_checker=format_checker)


def _schema_errors(payload: Any, schema_name: str) -> list[str]:
    values = payload if schema_name == "result.schema.json" and isinstance(payload, list) else [payload]
    if (
        schema_name == "result.schema.json"
        and isinstance(payload, dict)
        and "results" in payload
        and "schema" not in payload
    ):
        values = payload["results"]
    errors: list[str] = []
    validator = _validator(schema_name)
    for index, value in enumerate(values):
        prefix = f"results[{index}]" if len(values) > 1 or value is not payload else "$"
        for error in sorted(
            validator.iter_errors(value),
            key=lambda item: tuple(str(part) for part in item.absolute_path),
        ):
            location = ".".join(str(part) for part in error.absolute_path)
            errors.append(f"{prefix}{'.' + location if location else ''}: {error.message}"[:500])
            if len(errors) >= MAX_REPORTED_ERRORS:
                return errors
    return errors


def _close(left: float, right: float) -> bool:
    return math.isclose(float(left), float(right), abs_tol=0.000001)


def _result_semantics(result: dict[str, Any], prefix: str, errors: list[str]) -> None:
    if result["invalid_command_count"] > result["command_count"]:
        errors.append(f"{prefix}: invalid_command_count exceeds command_count")
    if len(result["events"]) != result["command_count"]:
        errors.append(f"{prefix}: command_count does not equal the event count")
    if (not result["safety_passed"] or not result["source_preserved"]) and result["score"] > 25:
        errors.append(f"{prefix}: unsafe or source-corrupt results must be capped at 25")


def _usage_totals(values: list[dict[str, Any]]) -> dict[str, float]:
    integer_fields = (
        "modelCalls",
        "promptTokens",
        "completionTokens",
        "cachedInputTokens",
        "reasoningTokens",
    )
    totals: dict[str, float] = {
        field: float(sum(int(value[field]) for value in values))
        for field in integer_fields
    }
    totals["reportedCostUSD"] = round(
        sum(float(value["reportedCostUSD"]) for value in values),
        6,
    )
    return totals


def _semantic_errors(payload: Any, schema_name: str) -> list[str]:
    errors: list[str] = []
    if schema_name == "result.schema.json":
        values = payload if isinstance(payload, list) else payload.get("results", [payload])
        identifiers: set[str] = set()
        for index, result in enumerate(values):
            _result_semantics(result, f"results[{index}]", errors)
            identifier = result["episode_id"]
            if identifier in identifiers:
                errors.append(f"results[{index}]: duplicate episode_id")
            identifiers.add(identifier)
    elif schema_name == "reference-run.schema.json":
        identifiers: set[str] = set()
        for index, result in enumerate(payload["results"]):
            _result_semantics(result, f"results[{index}]", errors)
            identifier = result["episode_id"]
            if identifier in identifiers:
                errors.append(f"results[{index}]: duplicate episode_id")
            identifiers.add(identifier)
        passed = all(result["score"] == 100 for result in payload["results"])
        if payload["passed"] != passed:
            errors.append("reference-run passed flag disagrees with episode scores")
    elif schema_name == "candidate.schema.json":
        try:
            CandidateManifest(**payload)
        except (TypeError, ValueError) as error:
            errors.append(str(error))
    elif schema_name == "public-manifest.schema.json":
        expected = f"{payload['scenario']}:{payload['repetition']}:{payload['fingerprint'][:12]}"
        if payload["id"] != expected:
            errors.append("episode id does not match scenario, repetition, and fingerprint")
    elif schema_name == "study-plan.schema.json":
        episodes = payload["episodes"]
        if payload["baselineCandidate"] == payload["candidate"]:
            errors.append("study plan must compare two distinct candidates")
        if payload["episodeCount"] != len(episodes):
            errors.append("episodeCount does not equal episodes length")
        if payload["episodeCount"] != len(payload["scenarioIDs"]) * payload["repetitions"]:
            errors.append("episodeCount does not cover every scenario and repetition exactly once")
        ids = [item["id"] for item in episodes]
        if len(ids) != len(set(ids)):
            errors.append("study plan contains duplicate episode ids")
        cases = [(item["scenario"], item["repetition"]) for item in episodes]
        expected_cases = {
            (scenario, repetition)
            for scenario in payload["scenarioIDs"]
            for repetition in range(payload["repetitions"])
        }
        if set(cases) != expected_cases or len(cases) != len(set(cases)):
            errors.append("study plan does not contain each declared scenario/repetition exactly once")
        for episode in episodes:
            expected_id = (
                f"{episode['scenario']}:{episode['repetition']}:"
                f"{episode['fingerprint'][:12]}"
            )
            if episode["id"] != expected_id:
                errors.append(f"episode id is inconsistent: {episode['id']}")
            if len(episode["roles"]) != len(set(episode["roles"])):
                errors.append(f"episode contains duplicate roles: {episode['id']}")
        roles = sum(len(item["roles"]) for item in episodes)
        if payload["roleRunsPerCandidate"] != roles or payload["totalRoleRuns"] != roles * 2:
            errors.append("study plan role-run totals are inconsistent")
        expected_candidates = {payload["baselineCandidate"], payload["candidate"]}
        orders = [tuple(item["candidateOrder"]) for item in episodes]
        if any(set(order) != expected_candidates for order in orders):
            errors.append("candidateOrder must contain the two declared candidates exactly once")
        forward = sum(order == (payload["baselineCandidate"], payload["candidate"]) for order in orders)
        reverse = sum(order == (payload["candidate"], payload["baselineCandidate"]) for order in orders)
        if forward + reverse != len(orders) or abs(forward - reverse) > 1:
            errors.append("candidate order is not counterbalanced")
        if payload["sampleSizeSufficient"] != (
            payload["episodeCount"] >= payload["minimumPairsForPromotion"]
        ):
            errors.append("sampleSizeSufficient disagrees with the declared promotion threshold")
    elif schema_name == "run-manifest.schema.json":
        episodes = payload["episodes"]
        identifiers = [item["id"] for item in episodes]
        if len(identifiers) != len(set(identifiers)):
            errors.append("run contains duplicate episode ids")
        roles = payload["execution"]["roles"]
        if len(roles) != len(set(roles)):
            errors.append("run execution contains duplicate roles")
        for episode in episodes:
            expected = f"{episode['scenario']}:{episode['repetition']}:{episode['fingerprint'][:12]}"
            if episode["id"] != expected:
                errors.append(f"episode id is inconsistent: {episode['id']}")
            if episode["invalidCommandCount"] > episode["commandCount"]:
                errors.append(f"invalid command count exceeds command count: {episode['id']}")
            publication_fields = ("sourcePreserved", "durationMs", "marginSha256")
            present = [field in episode for field in publication_fields]
            if any(present) and not all(present):
                errors.append(f"run episode has incomplete publication fields: {episode['id']}")
            elif all(present):
                if episode["marginSha256"] != payload["candidate"]["marginSha256"]:
                    errors.append(f"run episode Margin digest differs from its candidate: {episode['id']}")
                if (
                    not episode["safetyPassed"] or not episode["sourcePreserved"]
                ) and episode["score"] > 25:
                    errors.append(f"unsafe or source-corrupt run score exceeds 25: {episode['id']}")
        trace_cost = round(sum(item["usage"]["reportedCostUSD"] for item in episodes), 6)
        cost = payload["cost"]
        if not _close(trace_cost, cost["traceReported"]):
            errors.append("traceReported does not equal the sum of episode costs")
        if not _close(abs(cost["observedWalletDebit"] - cost["traceReported"]), cost["unreconciled"]):
            errors.append("unreconciled cost does not match wallet-versus-trace difference")
        execution = payload["execution"]
        basis = cost.get("boundBasis")
        process_count = execution.get("agentProcessCount")
        bound_parts = (
            basis is not None,
            process_count is not None,
            "admissionBound" in cost,
            "hardAdmissionCap" in cost,
        )
        if any(bound_parts) and not all(bound_parts):
            errors.append(
                "cost bound requires boundBasis, agentProcessCount, admissionBound, and hardAdmissionCap"
            )
        elif all(bound_parts):
            if cost["admissionBound"] > cost["hardAdmissionCap"]:
                errors.append("admissionBound exceeds hardAdmissionCap")
            attempts = (
                process_count
                * basis["modelCallsPerAgentAtMost"]
                * basis["upstreamAttemptsPerTurnAtMost"]
            )
            expected = round(attempts * (
                basis["inputTokenCeilingPerCall"] * basis["inputPricePerMillion"] / 1_000_000
                + basis["outputTokenCeilingPerCall"] * basis["outputPricePerMillion"] / 1_000_000
                + basis["billingOverheadUSDPerCall"]
            ), 6)
            if not _close(expected, cost["admissionBound"]):
                errors.append("admissionBound does not match its recorded basis")
    elif schema_name == "prime-run-summary.schema.json":
        episodes = payload["episodes"]
        identifiers = [item["episodeID"] for item in episodes]
        if len(identifiers) != len(set(identifiers)):
            errors.append("Prime summary contains duplicate episode ids")
        if "episodeCount" in payload and payload["episodeCount"] != len(episodes):
            errors.append("episodeCount does not equal episodes length")
        for episode in episodes:
            if episode["invalidCommandCount"] > episode["commandCount"]:
                errors.append(f"invalid command count exceeds command count: {episode['episodeID']}")
            publication_fields = ("sourcePreserved", "durationMs", "marginSha256")
            present = [field in episode for field in publication_fields]
            if any(present) and not all(present):
                errors.append(
                    f"Prime episode has incomplete publication fields: {episode['episodeID']}"
                )
            elif all(present):
                if episode["marginSha256"] != payload["marginSha256"]:
                    errors.append(
                        f"Prime episode Margin digest differs from its summary: {episode['episodeID']}"
                    )
                if (
                    not episode["safetyPassed"] or not episode["sourcePreserved"]
                ) and episode["score"] > 25:
                    errors.append(
                        f"unsafe or source-corrupt Prime score exceeds 25: {episode['episodeID']}"
                    )
            if "scenario" in episode:
                expected = (
                    f"{episode['scenario']}:{episode['repetition']}:"
                    f"{episode['fingerprint'][:12]}"
                )
                if episode["episodeID"] != expected:
                    errors.append(f"episode id is inconsistent: {episode['episodeID']}")
            role_runs = episode.get("roleRuns")
            if role_runs:
                totals = _usage_totals([item["usage"] for item in role_runs])
                for field, expected in totals.items():
                    actual = episode["usage"][field]
                    if not _close(actual, expected):
                        errors.append(
                            f"episode usage does not equal role-run usage for {field}: "
                            f"{episode['episodeID']}"
                        )
        has_role_runs = [bool(item.get("roleRuns")) for item in episodes]
        if any(has_role_runs) and not all(has_role_runs):
            errors.append("Prime summary mixes aggregated and unaggregated episode traces")
        if any(has_role_runs) and (
            "episodeCount" not in payload or "traceConsistencyPassed" not in payload
        ):
            errors.append("aggregated Prime summary is missing its count or consistency field")
        role_run_count = sum(len(item.get("roleRuns", ())) for item in episodes)
        expected_trace_count = role_run_count if all(has_role_runs) and episodes else len(episodes)
        if payload["traceCount"] != expected_trace_count:
            errors.append("traceCount does not equal the published role-run count")
        wallet = payload["wallet"]
        observed = round(wallet["before"]["balanceUSD"] - wallet["after"]["balanceUSD"], 6)
        if not _close(observed, wallet["observedDebitUSD"]):
            errors.append("wallet observed debit is inconsistent")
        trace_cost = round(sum(item["usage"]["reportedCostUSD"] for item in episodes), 6)
        if payload["estimatedMaximumCostUSD"] + 0.000001 < trace_cost:
            errors.append("reported model cost exceeds estimatedMaximumCostUSD")
        if payload["status"] == "completed":
            if payload["exitCode"] != 0 or payload["traceCount"] == 0:
                errors.append("completed summary requires a successful process and at least one trace")
            if payload.get("traceConsistencyPassed") is False:
                errors.append("completed summary cannot fail trace consistency")
    elif schema_name == "paired-comparison.schema.json":
        if payload["baselineCandidateID"] == payload["candidateID"]:
            errors.append("paired comparison must identify two distinct candidates")
        if payload["wins"] + payload["ties"] + payload["losses"] != payload["episodeCount"]:
            errors.append("win/tie/loss totals do not equal episodeCount")
        sufficient = payload["episodeCount"] >= payload["minimumPairsForPromotion"]
        if payload["sampleSizeSufficient"] != sufficient:
            errors.append("sampleSizeSufficient disagrees with the promotion threshold")
        lower, upper = payload["scoreDelta95CI"]
        if lower > upper:
            errors.append("scoreDelta95CI lower bound exceeds upper bound")
        promotable = (
            sufficient
            and not payload["safetyRegressions"]
            and payload["episodeCount"] > 0
            and lower > 0
        )
        if payload["promotable"] != promotable:
            errors.append("promotable disagrees with the declared promotion policy")
    elif schema_name == "experiment-ledger.schema.json":
        attempts = payload["attempts"]
        totals = payload["totals"]
        if totals["attempts"] != len(attempts):
            errors.append("ledger attempt total does not equal attempts length")
        if totals["completed"] != sum(item["status"] == "completed" for item in attempts):
            errors.append("ledger completed total is inconsistent")
        if totals["infrastructureErrors"] != sum(
            item["status"] == "infrastructure-error" for item in attempts
        ):
            errors.append("ledger infrastructure-error total is inconsistent")
        if totals["completed"] + totals["infrastructureErrors"] != totals["attempts"]:
            errors.append("ledger status totals do not equal attempt total")
        identifiers = [item["id"] for item in attempts]
        if len(identifiers) != len(set(identifiers)):
            errors.append("ledger contains duplicate attempt ids")
        if totals["modelCalls"] != sum(item["modelCalls"] for item in attempts):
            errors.append("ledger model-call total is inconsistent")
        trace_total = round(
            sum(float(item["traceReportedCostUSD"] or 0) for item in attempts),
            6,
        )
        wallet = payload["wallet"]
        if not _close(trace_total, wallet["traceReportedUSD"]):
            errors.append("ledger trace-reported cost total is inconsistent")
        if not _close(wallet["openingBalanceUSD"] - wallet["closingBalanceUSD"], wallet["observedDebitUSD"]):
            errors.append("wallet observed debit is inconsistent")
        if not _close(
            abs(wallet["observedDebitUSD"] - wallet["traceReportedUSD"]),
            wallet["unreconciledUSD"],
        ):
            errors.append("wallet unreconciled amount is inconsistent")
    elif schema_name == "control-catalog.schema.json":
        profiles = payload["profiles"]
        identifiers = [item["id"] for item in profiles]
        if len(identifiers) != len(set(identifiers)):
            errors.append("control catalog contains duplicate profile ids")
        if payload["default"] not in identifiers:
            errors.append("default control profile is missing")
        default = next((item for item in profiles if item["id"] == payload["default"]), None)
        if default is not None and default["status"] != "implemented":
            errors.append("default control profile is not implemented")
    elif schema_name == "binary-manifest.schema.json":
        artifacts = payload["artifacts"]
        for field in ("architecture", "platform", "path"):
            values = [item[field] for item in artifacts]
            if len(values) != len(set(values)):
                errors.append(f"binary manifest contains duplicate {field}")
        expected_platform = {"x86_64": "linux/amd64", "aarch64": "linux/arm64"}
        for artifact in artifacts:
            architecture = artifact["architecture"]
            if artifact["platform"] != expected_platform[architecture]:
                errors.append(f"binary platform does not match architecture: {architecture}")
            if not artifact["path"].endswith(f"-{architecture}"):
                errors.append(f"binary path does not match architecture: {architecture}")
    elif schema_name == "runtime-probe.schema.json":
        if payload["expectedCostUSD"] > payload["failureBoundUSD"]:
            errors.append("runtime probe expected cost exceeds its failure bound")
        if payload["failureBoundUSD"] > payload["hardAdmissionCapUSD"]:
            errors.append("runtime probe failure bound exceeds its hard admission cap")
        wallet = payload["wallet"]
        observed = round(wallet["beforeBalanceUSD"] - wallet["afterBalanceUSD"], 6)
        if not _close(observed, wallet["observedDebitUSD"]):
            errors.append("runtime probe wallet debit is inconsistent")
        pricing = payload.get("pricingUSDPerHour")
        hours = payload.get("failureBoundHours")
        if pricing is not None and hours is not None:
            resources = payload["resources"]
            hourly = (
                resources["cpu"] * pricing["cpuPerCore"]
                + resources["memoryGB"] * pricing["memoryPerGB"]
                + resources["diskGB"] * pricing["diskPerGB"]
            )
            if not _close(round(hourly * hours, 6), payload["failureBoundUSD"]):
                errors.append("runtime probe failure bound does not match resources and pricing")
    elif schema_name == "execution-plan.schema.json":
        if payload["id"] != submission_identifier(payload):
            errors.append("execution plan id does not match its canonical content")
        if payload["baselineCandidate"] == payload["candidate"]:
            errors.append("execution plan must identify two distinct candidates")
        jobs = payload["jobs"]
        if payload["jobCount"] != len(jobs) or payload["jobCount"] != payload["episodeCount"] * 2:
            errors.append("execution plan job totals are inconsistent")
        if [item["ordinal"] for item in jobs] != list(range(len(jobs))):
            errors.append("execution plan ordinals are not contiguous")
        if payload["roleProcessCount"] != sum(len(item["roles"]) for item in jobs):
            errors.append("execution plan role-process total is inconsistent")
        job_ids = [item["id"] for item in jobs]
        if len(job_ids) != len(set(job_ids)):
            errors.append("execution plan contains duplicate job ids")
        candidates = {payload["baselineCandidate"], payload["candidate"]}
        episodes: dict[str, list[dict[str, Any]]] = {}
        for job in jobs:
            expected_episode = (
                f"{job['scenario']}:{job['repetition']}:"
                f"{job['fingerprint'][:12]}"
            )
            if job["episodeID"] != expected_episode:
                errors.append(f"execution job episode identity is inconsistent: {job['ordinal']}")
            material = {
                "candidateID": job["candidateID"],
                "episodeID": job["episodeID"],
                "position": job["candidatePosition"],
                "studyPlanSha256": payload["studyPlanSha256"],
            }
            expected_job = "sha256:" + hashlib.sha256(
                json.dumps(
                    material,
                    ensure_ascii=False,
                    separators=(",", ":"),
                    sort_keys=True,
                ).encode("utf-8")
            ).hexdigest()
            if job["id"] != expected_job:
                errors.append(f"execution job id is inconsistent: {job['ordinal']}")
            episodes.setdefault(job["episodeID"], []).append(job)
        if len(episodes) != payload["episodeCount"]:
            errors.append("execution plan episode total is inconsistent")
        first_positions = {payload["baselineCandidate"]: 0, payload["candidate"]: 0}
        for episode_id, pair in episodes.items():
            if len(pair) != 2:
                errors.append(f"execution episode does not contain exactly two jobs: {episode_id[:200]}")
                continue
            ordered = sorted(pair, key=lambda item: item["candidatePosition"])
            if (
                {item["candidateID"] for item in pair} != candidates
                or [item["candidatePosition"] for item in ordered] != [0, 1]
            ):
                errors.append(f"execution episode does not cover both candidates once: {episode_id[:200]}")
            immutable = ("scenario", "repetition", "fingerprint", "roles")
            if any(ordered[0][field] != ordered[1][field] for field in immutable):
                errors.append(f"execution episode pair metadata differs: {episode_id[:200]}")
            first = ordered[0]["candidateID"]
            if first in first_positions:
                first_positions[first] += 1
        if abs(first_positions[payload["baselineCandidate"]] - first_positions[payload["candidate"]]) > 1:
            errors.append("execution plan candidate-first order is not counterbalanced")
    elif schema_name == "submission.schema.json":
        if payload["id"] != submission_identifier(payload):
            errors.append("submission id does not match its canonical manifest")
        if payload["baseline"]["id"] == payload["candidate"]["id"]:
            errors.append("submission must identify two distinct candidates")
        references = [
            payload["baseline"],
            payload["candidate"],
            payload["studyPlan"],
            payload["comparison"],
            *payload["runs"],
        ]
        paths = [item["path"] for item in references]
        if len(paths) != len(set(paths)):
            errors.append("submission contains duplicate artifact paths")
        for path in paths:
            value = PurePosixPath(path)
            if value.is_absolute() or ".." in value.parts or value.as_posix() != path:
                errors.append(f"submission artifact path is not canonical: {path[:200]}")
        candidates = {payload["baseline"]["id"], payload["candidate"]["id"]}
        run_candidates = [item["candidateID"] for item in payload["runs"]]
        if set(run_candidates) != candidates:
            errors.append("submission runs must cover both declared candidates and no others")
    elif schema_name == "submission-verification.schema.json":
        if payload["artifactCount"] != len(payload["artifacts"]):
            errors.append("verification artifactCount does not equal artifacts length")
        paths = [item["path"] for item in payload["artifacts"]]
        if len(paths) != len(set(paths)):
            errors.append("verification receipt contains duplicate artifact paths")
    return errors[:MAX_REPORTED_ERRORS]


def validate_bytes(raw: bytes) -> dict[str, Any]:
    if len(raw) > MAX_ARTIFACT_BYTES:
        return {
            "schema": VALIDATION_SCHEMA,
            "valid": False,
            "artifactSchema": None,
            "sha256": None,
            "byteCount": None,
            "error": {
                "code": "ARTIFACT_TOO_LARGE",
                "message": f"Artifact exceeds the {MAX_ARTIFACT_BYTES}-byte validation limit.",
            },
            "errors": [],
        }
    digest = hashlib.sha256(raw).hexdigest()
    try:
        payload = _decode(raw)
        schema_name, artifact_schema = _schema_name(payload)
        errors = _schema_errors(payload, schema_name)
        if not errors:
            errors = _semantic_errors(payload, schema_name)
    except ArtifactValidationError as error:
        return {
            "schema": VALIDATION_SCHEMA,
            "valid": False,
            "artifactSchema": None,
            "sha256": digest,
            "byteCount": len(raw),
            "error": {"code": error.code, "message": str(error)},
            "errors": [],
        }
    valid = not errors
    return {
        "schema": VALIDATION_SCHEMA,
        "valid": valid,
        "artifactSchema": artifact_schema,
        "sha256": digest,
        "byteCount": len(raw),
        "error": None if valid else {
            "code": "ARTIFACT_INVALID",
            "message": f"Artifact failed {len(errors)} bounded validation check(s).",
        },
        "errors": errors,
    }


def validate_artifact(path: Path) -> dict[str, Any]:
    try:
        return validate_bytes(_read(path))
    except ArtifactValidationError as error:
        return {
            "schema": VALIDATION_SCHEMA,
            "valid": False,
            "artifactSchema": None,
            "sha256": None,
            "byteCount": None,
            "error": {"code": error.code, "message": str(error)},
            "errors": [],
        }
