"""Bounded, schema-backed validation for public MarginBench artifacts."""

from __future__ import annotations

import hashlib
import json
import math
import re
import sys
from collections import Counter
from datetime import datetime
from pathlib import Path, PurePosixPath
from typing import Any

from .accounting import rounded_token_cost_usd
from .candidates import CandidateManifest
from .controls import per_agent_compute_multiplier, planned_topology
from .event_summary import SAFE_PUBLIC_COMMANDS


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
        "urn:marginbench:challenge-catalog:v1": "challenge-catalog.schema.json",
        "urn:marginbench:checkpoint-promotion:v1": "checkpoint-promotion.schema.json",
        "urn:marginbench:control-catalog:v1": "control-catalog.schema.json",
        "urn:marginbench:crossover-plan:v1": "crossover-plan.schema.json",
        "urn:marginbench:crossover-publication-audit:v1": "crossover-publication-audit.schema.json",
        "urn:marginbench:crossover-prime-completion:v1": "crossover-prime-completion.schema.json",
        "urn:marginbench:crossover-prime-plan:v1": "crossover-prime-plan.schema.json",
        "urn:marginbench:crossover-report:v1": "crossover-report.schema.json",
        "urn:marginbench:diagnostic-report:v1": "diagnostic-report.schema.json",
        "urn:marginbench:efficiency-report:v1": "efficiency-report.schema.json",
        "urn:marginbench:experiment-ledger:v1": "experiment-ledger.schema.json",
        "urn:marginbench:neutral-facts:v1": "neutral-facts.schema.json",
        "urn:marginbench:neutral-assessment:v1": "neutral-assessment.schema.json",
        "urn:marginbench:neutral-feasibility:v1": "neutral-feasibility.schema.json",
        "urn:marginbench:no-exchange-feasibility:v1": "no-exchange-feasibility.schema.json",
        "urn:marginbench:neutral-isolation-preflight:v1": "neutral-isolation-preflight.schema.json",
        "urn:marginbench:neutral-prompt-audit:v1": "neutral-prompt-audit.schema.json",
        "urn:marginbench:neutral-production-preflight:v1": "neutral-production-preflight.schema.json",
        "urn:marginbench:neutral-prime-run-summary:v1": "neutral-prime-run-summary.schema.json",
        "urn:marginbench:neutral-run:v1": "neutral-run.schema.json",
        "urn:marginbench:neutral-served-preflight:v1": "neutral-served-preflight.schema.json",
        "urn:marginbench:execution-plan:v1": "execution-plan.schema.json",
        "urn:marginbench:paired-comparison:v1": "paired-comparison.schema.json",
        "urn:marginbench:prime-run-summary:v1": "prime-run-summary.schema.json",
        "urn:marginbench:prime-runtime-probe:v1": "runtime-probe.schema.json",
        "urn:marginbench:provider-contract-probe-plan:v1": "provider-contract-probe-plan.schema.json",
        "urn:marginbench:provider-contract-probe:v1": "provider-contract-probe.schema.json",
        "urn:marginbench:prime-study-completion:v1": "prime-study-completion.schema.json",
        "urn:marginbench:prime-study-job-receipt:v1": "prime-study-job-receipt.schema.json",
        "urn:marginbench:prime-study-plan:v1": "prime-study-plan.schema.json",
        "urn:marginbench:prime-study-progress:v1": "prime-study-progress.schema.json",
        "urn:marginbench:reference-run:v1": "reference-run.schema.json",
        "urn:marginbench:reference-study-receipt:v1": "reference-study-receipt.schema.json",
        "urn:marginbench:result:v1": "result.schema.json",
        "urn:marginbench:run:v1": "run-manifest.schema.json",
        "urn:marginbench:study-plan:v1": "study-plan.schema.json",
        "urn:marginbench:trace-shape-report:v1": "trace-shape-report.schema.json",
        "urn:marginbench:concurrency-probe:v1": "concurrency-probe.schema.json",
        "urn:marginbench:suggestion-convergence-probe:v1": "suggestion-convergence-probe.schema.json",
        "urn:marginbench:contention-matrix:v1": "contention-matrix.schema.json",
        "urn:marginbench:wide-directory-probe:v1": "wide-directory-probe.schema.json",
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


def _histogram_numeric_summary(histogram: dict[str, int]) -> dict[str, float | int]:
    values = sorted(
        int(value)
        for value, frequency in histogram.items()
        for _ in range(frequency)
    )
    midpoint = len(values) // 2
    median = (
        float(values[midpoint])
        if len(values) % 2
        else (values[midpoint - 1] + values[midpoint]) / 2
    )
    p95_index = max(0, (95 * len(values) + 99) // 100 - 1)
    return {
        "total": sum(values),
        "min": float(values[0]),
        "median": round(median, 6),
        "p95": float(values[p95_index]),
        "max": float(values[-1]),
    }


def _observed_wallet_debit(wallet: dict[str, Any]) -> float:
    delta = round(wallet["before"]["balanceUSD"] - wallet["after"]["balanceUSD"], 6)
    if (
        wallet.get("observationScope") == "account-wide"
        and wallet.get("debitAttribution") == "unattributed"
    ):
        return max(0.0, delta)
    return delta


def _live_budget_semantics(
    report: dict[str, Any],
    prefix: str,
    errors: list[str],
    *,
    allow_provider_violation: bool = False,
) -> None:
    policy = report["policy"]
    if report["reservedCostUpperBoundUSD"] > policy["maxTotalCostUSD"] + 0.000001:
        errors.append(f"{prefix}: reserved cost exceeds the live budget cap")
    expected_reported_cost = rounded_token_cost_usd(
        report["reportedPromptTokens"],
        report["reportedCompletionTokens"],
        policy["inputPricePerMillion"],
        policy["outputPricePerMillion"],
    )
    if not _close(expected_reported_cost, report["reportedTokenCostUSD"]):
        errors.append(f"{prefix}: reported token cost does not match token counts and prices")
    if report["reportedTokenCostUSD"] > report["reservedCostUpperBoundUSD"] + 0.000001:
        errors.append(f"{prefix}: reported token cost exceeds the reserved upper bound")
    gross_reserved = report.get("grossReservedCostUpperBoundUSD")
    if (
        gross_reserved is not None
        and gross_reserved + 0.000001 < report["reservedCostUpperBoundUSD"]
    ):
        errors.append(f"{prefix}: gross reservation bound is below the live upper bound")
    forwarded = report["forwardedRequestCount"]
    settled = report.get("settledRequestCount")
    uncertain = report.get("uncertainRequestCount", 0)
    outstanding = report.get("outstandingReservationCount")
    if (
        settled is not None
        and outstanding is not None
        and settled + uncertain + outstanding > forwarded
    ):
        errors.append(
            f"{prefix}: settled, uncertain, and outstanding reservations exceed forwarded requests"
        )
    maximum_prompt_tokens = forwarded * min(
        policy["inputTokenCeiling"],
        policy["maxRequestBytes"] * 2 + policy["templateTokenAllowance"],
    )
    maximum_completion_tokens = forwarded * (
        policy["maxOutputTokens"]
        + (policy.get("reasoningTokenCeiling") or 0)
        + policy.get("responseTokenAllowance", 0)
    )
    if report["reportedPromptTokens"] > maximum_prompt_tokens:
        errors.append(f"{prefix}: reported prompt tokens exceed the request-byte bound")
    if (
        report["reportedCompletionTokens"] > maximum_completion_tokens
        and not allow_provider_violation
    ):
        errors.append(f"{prefix}: reported completion tokens exceed the output bound")
    violations = report.get("providerBoundViolationCount", 0)
    latched = report.get("latchedClosed", violations > 0 or uncertain > 0)
    if latched != (violations > 0 or uncertain > 0):
        errors.append(
            f"{prefix}: closed latch disagrees with provider-bound or uncertain requests"
        )
    if violations > 0 and not allow_provider_violation:
        errors.append(f"{prefix}: provider reported usage outside the reserved bound")


def _provider_probe_plan_semantics(payload: dict[str, Any], errors: list[str]) -> None:
    limits = payload["limits"]
    pricing = payload["pricing"]
    maximum = (
        min(
            limits["inputTokenCeiling"],
            limits["maxRequestBytes"] * 2 + limits["templateTokenAllowance"],
        )
        * pricing["inputPricePerMillion"]
        / 1_000_000
        + (
            limits["visibleTokenCeiling"]
            + limits["reasoningTokenCeiling"]
            + limits["responseTokenAllowance"]
        )
        * pricing["outputPricePerMillion"]
        / 1_000_000
        + pricing["billingOverheadUSDPerCall"]
    )
    if not _close(round(maximum, 9), payload["budget"]["maximumReservedCostUSD"]):
        errors.append("provider probe maximum reservation does not match its frozen bounds")
    if maximum > payload["budget"]["hardCapUSD"] + 0.000000001:
        errors.append("provider probe maximum reservation exceeds its hard cap")


def _provider_probe_result_semantics(payload: dict[str, Any], errors: list[str]) -> None:
    live = payload["liveBudget"]
    _live_budget_semantics(
        live,
        "provider contract probe live budget",
        errors,
        allow_provider_violation=payload["status"] == "infrastructure_error",
    )
    observed = payload["observed"]
    policy = live["policy"]
    expected_checks = {
        "providerReturnedSuccessForRequestWithReasoningParameter": (
            observed["httpStatus"] == 200
        ),
        "exactlyOneRequestForwarded": live["forwardedRequestCount"] == 1,
        "usageReportedWithinFrozenBound": (
            observed["completionTokens"] is not None
            and observed["completionTokens"]
            <= policy["maxOutputTokens"]
            + policy["reasoningTokenCeiling"]
            + policy["responseTokenAllowance"]
            and live["providerBoundViolationCount"] == 0
        ),
        "assistantResponsePresent": observed["assistantResponsePresent"],
        "proxyRemainedOpen": live["latchedClosed"] is False,
    }
    if payload["checks"] != expected_checks:
        errors.append("provider probe checks do not match the observed bounded response")
    contract = payload["contract"]
    if contract["visibleTokenCeiling"] != policy["maxOutputTokens"]:
        errors.append("provider probe visible ceiling differs from its enforced policy")
    if contract["reasoningTokenCeiling"] != policy["reasoningTokenCeiling"]:
        errors.append("provider probe reasoning ceiling differs from its enforced policy")
    if contract["responseTokenAllowance"] != policy["responseTokenAllowance"]:
        errors.append("provider probe wrapper allowance differs from its enforced policy")
    passed = all(expected_checks.values()) and not payload["infrastructureCodes"]
    if (payload["status"] == "passed") != passed:
        errors.append("provider probe status does not match its checks and infrastructure codes")
    if payload["paidModelsInvoked"] != (live["forwardedRequestCount"] > 0):
        errors.append("provider probe paidModelsInvoked disagrees with forwarded requests")
    wallet = payload["wallet"]
    if wallet["afterAvailable"] != (wallet["observedDebitUSD"] is not None):
        errors.append("provider probe wallet availability disagrees with its debit observation")


def _result_semantics(result: dict[str, Any], prefix: str, errors: list[str]) -> None:
    if result["invalid_command_count"] > result["command_count"]:
        errors.append(f"{prefix}: invalid_command_count exceeds command_count")
    if len(result["events"]) != result["command_count"]:
        errors.append(f"{prefix}: command_count does not equal the event count")
    if (not result["safety_passed"] or not result["source_preserved"]) and result["score"] > 25:
        errors.append(f"{prefix}: unsafe or source-corrupt results must be capped at 25")


def _event_summary_semantics(
    summary: dict[str, Any],
    expected_command_count: int,
    prefix: str,
    errors: list[str],
) -> None:
    if summary["commandCount"] != expected_command_count:
        errors.append(f"{prefix}: event summary command count differs from the episode")
    if summary["successCount"] + summary["failureCount"] != summary["commandCount"]:
        errors.append(f"{prefix}: event summary success/failure totals are inconsistent")
    if summary["blockedCount"] > summary["failureCount"]:
        errors.append(f"{prefix}: event summary blocked count exceeds failures")

    command_names = [item["name"] for item in summary["commands"]]
    if len(command_names) != len(set(command_names)):
        errors.append(f"{prefix}: event summary repeats a command name")
    if any(name not in SAFE_PUBLIC_COMMANDS for name in command_names):
        errors.append(f"{prefix}: event summary contains a non-public command label")
    for item in summary["commands"]:
        if item["successCount"] + item["failureCount"] != item["count"]:
            errors.append(f"{prefix}: event summary command totals are inconsistent")
        if item["blockedCount"] > item["failureCount"]:
            errors.append(f"{prefix}: event summary command blocked count exceeds failures")
    for row_field, summary_field in (
        ("count", "commandCount"),
        ("successCount", "successCount"),
        ("failureCount", "failureCount"),
        ("blockedCount", "blockedCount"),
    ):
        if sum(item[row_field] for item in summary["commands"]) != summary[summary_field]:
            errors.append(f"{prefix}: event summary command rows do not total {summary_field}")

    error_names = [item["name"] for item in summary["errors"]]
    if len(error_names) != len(set(error_names)):
        errors.append(f"{prefix}: event summary repeats an error label")
    if sum(item["count"] for item in summary["errors"]) != summary["failureCount"]:
        errors.append(f"{prefix}: event summary error rows do not total failures")
    if summary["isTruncated"] != ("OTHER" in error_names):
        errors.append(f"{prefix}: event summary truncation marker is inconsistent")


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
    elif schema_name == "provider-contract-probe-plan.schema.json":
        _provider_probe_plan_semantics(payload, errors)
    elif schema_name == "provider-contract-probe.schema.json":
        _provider_probe_result_semantics(payload, errors)
    elif schema_name == "candidate.schema.json":
        try:
            CandidateManifest(**payload)
        except (TypeError, ValueError) as error:
            errors.append(str(error))
    elif schema_name == "neutral-facts.schema.json":
        from .neutral import NeutralLedger

        try:
            NeutralLedger.from_dict(payload)
        except (KeyError, TypeError, ValueError) as error:
            errors.append(str(error))
    elif schema_name == "neutral-assessment.schema.json":
        checks = payload["checks"]
        expected_dimensions = {
            "outcome": 25 * sum(checks[name] for name in (
                "allExpectedFacts", "noUnexpectedFacts", "exactFactFields", "committedAll"
            )),
            "integrity": 20 * sum(checks[name] for name in (
                "sourceExpected", "ledgerValid", "duplicateFree",
                "allOrNoneFinal", "allOrNoneHistory",
            )),
            "attribution": 50 * sum(checks[name] for name in (
                "trustedAttribution", "trustedDecisions"
            )),
            "continuity": 100 if checks["continuityObserved"] else 0,
            "recovery": 100 if checks["recoveryObserved"] else 0,
        }
        if payload["dimensions"] != expected_dimensions:
            errors.append("neutral assessment dimensions disagree with their exact checks")
        expected_safety = all(checks[name] for name in (
            "sourceExpected", "ledgerValid", "allOrNoneFinal", "allOrNoneHistory"
        ))
        if payload["safetyPassed"] != expected_safety:
            errors.append("neutral assessment safety flag is inconsistent")
        if payload["sourcePreserved"] != checks["sourceExpected"]:
            errors.append("neutral assessment source flag is inconsistent")
        diagnostics = payload["diagnostics"]
        field_mismatches = diagnostics.get("fieldMismatchCounts")
        if field_mismatches is not None:
            if bool(field_mismatches) == checks["exactFactFields"]:
                errors.append("neutral field diagnostics disagree with exactFactFields")
            names = [item["name"] for item in field_mismatches]
            if names != sorted(names) or len(names) != len(set(names)):
                errors.append("neutral field diagnostics are not canonical")
        missing = diagnostics.get("missingExpectedFactCount")
        unexpected = diagnostics.get("unexpectedFactCount")
        if missing is not None and unexpected is not None:
            expected_shared = payload["expectedFactCount"] - missing
            actual_shared = payload["actualFactCount"] - unexpected
            if expected_shared != actual_shared:
                errors.append("neutral fact-count diagnostics disagree on shared facts")
    elif schema_name == "neutral-feasibility.schema.json":
        assessments = payload["assessments"]
        if payload["assessmentCount"] != len(assessments):
            errors.append("neutral feasibility assessment count is inconsistent")
        scenario_ids = {
            assessment["episodeID"].split(":", 1)[0]
            for assessment in assessments
        }
        if payload["scenarioCount"] != len(scenario_ids):
            errors.append("neutral feasibility scenario count is inconsistent")
        passed = all(
            all(assessment["checks"].values())
            and assessment["safetyPassed"]
            and assessment["sourcePreserved"]
            for assessment in assessments
        )
        if payload["implementedChecksPassed"] != passed:
            errors.append("neutral feasibility pass flag is inconsistent")
    elif schema_name == "no-exchange-feasibility.schema.json":
        assessments = payload["assessments"]
        if payload["assessmentCount"] != len(assessments):
            errors.append("no-exchange assessment count is inconsistent")
        if payload["scenarioCount"] != len({item["scenario"] for item in assessments}):
            errors.append("no-exchange scenario count is inconsistent")
        if payload["repetitionCount"] != len({item["repetition"] for item in assessments}):
            errors.append("no-exchange repetition count is inconsistent")
        identities = [(item["scenario"], item["repetition"]) for item in assessments]
        if len(identities) != len(set(identities)):
            errors.append("no-exchange report contains duplicate assessments")
        if identities != sorted(identities, key=lambda item: (item[1], item[0])):
            errors.append("no-exchange assessments are not canonical")
        if payload["assessmentCount"] != payload["scenarioCount"] * payload["repetitionCount"]:
            errors.append("no-exchange selection is not a complete scenario/repetition grid")
        totals = {"independent": 0, "collaborationDependent": 0, "external": 0}
        for assessment in assessments:
            role_independent = 0
            role_dependent = 0
            seats: set[str] = set()
            for role in assessment["roles"]:
                seats.add(role["seat"])
                if any(item["dependency"] != "none" for item in role["independentOutcomes"]):
                    errors.append("no-exchange independent outcome has a dependency")
                if any(item["dependency"] == "none" for item in role["dependentOutcomes"]):
                    errors.append("no-exchange dependent outcome lacks a dependency")
                if role["independentOutcomes"] != sorted(
                    role["independentOutcomes"],
                    key=lambda item: (item["outcome"], item["kind"], item["dependency"]),
                ) or role["dependentOutcomes"] != sorted(
                    role["dependentOutcomes"],
                    key=lambda item: (item["outcome"], item["kind"], item["dependency"]),
                ):
                    errors.append("no-exchange role outcomes are not canonical")
                independent = sum(item["count"] for item in role["independentOutcomes"])
                dependent = sum(item["count"] for item in role["dependentOutcomes"])
                if independent != role["independentOutcomeCount"]:
                    errors.append("no-exchange independent role count is inconsistent")
                if dependent != role["dependentOutcomeCount"]:
                    errors.append("no-exchange dependent role count is inconsistent")
                if role["independentOracleFactCount"] != sum(
                    item["count"] for item in role["independentOutcomes"]
                    if item["outcome"] == "create-fact"
                ):
                    errors.append("no-exchange role oracle count is inconsistent")
                role_independent += independent
                role_dependent += dependent
            if len(seats) != len(assessment["roles"]):
                errors.append("no-exchange assessment contains duplicate role seats")
            if assessment["roles"] != sorted(
                assessment["roles"], key=lambda item: (item["phase"], item["seat"])
            ):
                errors.append("no-exchange roles are not canonical")
            if any(
                item["dependency"] != "external-nonfile-state"
                for item in assessment["externalOutcomes"]
            ):
                errors.append("no-exchange external outcome has an invalid dependency")
            expected = {
                "independent": role_independent,
                "collaborationDependent": role_dependent,
                "external": sum(item["count"] for item in assessment["externalOutcomes"]),
            }
            if assessment["totals"] != expected:
                errors.append("no-exchange assessment totals are inconsistent")
            for name, value in expected.items():
                totals[name] += value
        if payload["totals"] != totals:
            errors.append("no-exchange report totals are inconsistent")
    elif schema_name == "neutral-served-preflight.schema.json":
        assessments = payload["assessments"]
        if payload["assessmentCount"] != len(assessments):
            errors.append("neutral served preflight assessment count is inconsistent")
        if payload["assessmentCount"] != payload["scenarioCount"] * payload["repetitionCount"]:
            errors.append("neutral served preflight selection totals are inconsistent")
        episode_ids = [assessment["episodeID"] for assessment in assessments]
        if len(episode_ids) != len(set(episode_ids)):
            errors.append("neutral served preflight contains duplicate episodes")
        if payload["scenarioCount"] != len({assessment["scenario"] for assessment in assessments}):
            errors.append("neutral served preflight scenario count is inconsistent")
        trace_count = sum(assessment["traceCount"] for assessment in assessments)
        if payload["roleProcessCount"] != trace_count:
            errors.append("neutral served preflight role-process count is inconsistent")
        passed = all(
            assessment["implementedChecksPassed"]
            and all(assessment["checks"].values())
            and assessment["safetyPassed"]
            and assessment["sourcePreserved"]
            for assessment in assessments
        )
        if payload["passed"] != passed:
            errors.append("neutral served preflight pass flag is inconsistent")
        for index, assessment in enumerate(assessments):
            checks = assessment["checks"]
            expected_dimensions = {
                "outcome": 25 * sum(checks[name] for name in (
                    "allExpectedFacts", "noUnexpectedFacts", "exactFactFields", "committedAll"
                )),
                "integrity": 20 * sum(checks[name] for name in (
                    "sourceExpected", "ledgerValid", "duplicateFree",
                    "allOrNoneFinal", "allOrNoneHistory",
                )),
                "attribution": 50 * sum(checks[name] for name in (
                    "trustedAttribution", "trustedDecisions"
                )),
                "continuity": 100 if checks["continuityObserved"] else 0,
                "recovery": 100 if checks["recoveryObserved"] else 0,
            }
            if assessment["dimensions"] != expected_dimensions:
                errors.append(
                    f"neutral served preflight assessment {index} dimensions are inconsistent"
                )
            efficiency = assessment["efficiencyObservations"]
            if efficiency["toolCallCount"] != sum(efficiency["actionCounts"].values()):
                errors.append(
                    f"neutral served preflight assessment {index} call totals are inconsistent"
                )
            if efficiency["failedToolCallCount"] > efficiency["toolCallCount"]:
                errors.append(
                    f"neutral served preflight assessment {index} failure count exceeds calls"
                )
    elif schema_name == "neutral-isolation-preflight.schema.json":
        episodes = payload["episodes"]
        if payload["episodeCount"] != len(episodes):
            errors.append("neutral isolation episode count is inconsistent")
        if payload["episodeCount"] != payload["scenarioCount"] * payload["repetitionCount"]:
            errors.append("neutral isolation selection totals are inconsistent")
        identifiers = [episode["episodeID"] for episode in episodes]
        if len(identifiers) != len(set(identifiers)):
            errors.append("neutral isolation contains duplicate episodes")
        scenario_ids = {episode["scenario"] for episode in episodes}
        if payload["scenarioCount"] != len(scenario_ids):
            errors.append("neutral isolation scenario count is inconsistent")
        expected_cases = {
            (scenario, repetition)
            for scenario in scenario_ids
            for repetition in range(payload["repetitionCount"])
        }
        actual_cases = {(episode["scenario"], episode["repetition"]) for episode in episodes}
        if actual_cases != expected_cases:
            errors.append("neutral isolation does not cover its scenario/repetition grid")
        for episode in episodes:
            expected_prefix = f"{episode['scenario']}:{episode['repetition']}:"
            if not episode["episodeID"].startswith(expected_prefix):
                errors.append("neutral isolation episode id is inconsistent")
            expected_roles = 1 if episode["scenario"] == "human_agent_relay" else 2
            if episode["roleProcessCount"] != expected_roles:
                errors.append("neutral isolation role-process count is inconsistent")
        role_process_count = sum(episode["roleProcessCount"] for episode in episodes)
        if payload["roleProcessCount"] != role_process_count:
            errors.append("neutral isolation aggregate role-process count is inconsistent")
        if payload["distinctRolePromptCount"] != role_process_count:
            errors.append("neutral isolation distinct prompt count is inconsistent")
        expected_echoes = payload["fakeModelRequestCount"] - payload["distinctRolePromptCount"]
        if expected_echoes < 0 or (
            payload["ownCanaryEchoCount"] + payload["ownCanaryMissingCount"]
            != expected_echoes
        ):
            errors.append("neutral isolation canary accounting is inconsistent")
        expected_passed = (
            all(episode["passed"] for episode in episodes)
            and payload["ownCanaryMissingCount"] == 0
            and payload["crossRoleCanaryLeakCount"] == 0
            and payload["malformedRequestCount"] == 0
            and payload["distinctRolePromptCount"] == role_process_count
        )
        if payload["passed"] != expected_passed:
            errors.append("neutral isolation pass flag is inconsistent")
    elif schema_name == "neutral-production-preflight.schema.json":
        episodes = payload["episodes"]
        if payload["episodeCount"] != len(episodes):
            errors.append("neutral production preflight episode count is inconsistent")
        expected_episode_count = payload["scenarioCount"] * payload["repetitionCount"]
        identifiers = [episode["episodeID"] for episode in episodes]
        if len(identifiers) != len(set(identifiers)):
            errors.append("neutral production preflight contains duplicate episodes")
        for episode in episodes:
            expected_prefix = f"{episode['scenario']}:{episode['repetition']}:"
            if not episode["episodeID"].startswith(expected_prefix):
                errors.append("neutral production preflight episode id is inconsistent")
            expected_roles = 1 if episode["scenario"] == "human_agent_relay" else 2
            if episode["roleProcessCount"] != expected_roles:
                errors.append("neutral production preflight role count is inconsistent")
        observed_role_processes = sum(
            episode["roleProcessCount"] for episode in episodes
        )
        expected_echoes = (
            payload["fakeModelRequestCount"] - payload["distinctRolePromptCount"]
        )
        expected_passed = (
            payload["primeExitCode"] == 0
            and payload["episodeCount"] == expected_episode_count
            and payload["traceCount"] == payload["expectedRoleProcessCount"]
            and observed_role_processes == payload["expectedRoleProcessCount"]
            and payload["distinctRolePromptCount"]
            == payload["expectedRoleProcessCount"]
            and expected_echoes >= 0
            and payload["ownCanaryEchoCount"] == expected_echoes
            and payload["ownCanaryMissingCount"] == 0
            and payload["crossRoleCanaryLeakCount"] == 0
            and payload["malformedRequestCount"] == 0
            and payload["traceConsistencyPassed"]
            and payload["officialSummaryValidated"]
            and not payload["officialSummaryValidationErrors"]
            and payload["officialRunValidated"]
            and not payload["officialRunValidationErrors"]
            and payload["officialRunSha256"] is not None
            and all(
                episode["implementedChecksPassed"]
                and episode["safetyPassed"]
                and episode["sourcePreserved"]
                for episode in episodes
            )
        )
        live_budget = payload["liveBudget"]
        _live_budget_semantics(
            live_budget,
            "neutral production preflight live budget",
            errors,
        )
        if live_budget["forwardedRequestCount"] != payload["fakeModelRequestCount"]:
            errors.append("neutral production preflight request count is inconsistent")
        if (
            live_budget["rejectedRequestCount"]
            or live_budget["providerBoundViolationCount"]
            or live_budget.get("uncertainRequestCount", 0)
        ):
            expected_passed = False
        if payload["officialSummaryValidated"] == bool(
            payload["officialSummaryValidationErrors"]
        ):
            errors.append("neutral production summary validation fields disagree")
        if payload["officialRunValidated"] == bool(
            payload["officialRunValidationErrors"]
        ):
            errors.append("neutral production run validation fields disagree")
        if payload["passed"] != expected_passed:
            errors.append("neutral production preflight pass flag is inconsistent")
    elif schema_name == "neutral-prompt-audit.schema.json":
        from .entropy import PUBLIC_DEVELOPMENT_KEY
        from .scenarios import SCENARIO_IDS, generate_episode

        cases = payload["cases"]
        expected_scenarios = [
            scenario for scenario in SCENARIO_IDS if scenario in payload["scenarioIDs"]
        ]
        if payload["scenarioIDs"] != expected_scenarios:
            errors.append("neutral prompt audit scenarios are not canonically ordered")
        if payload["scenarioCount"] != len(payload["scenarioIDs"]):
            errors.append("neutral prompt audit scenario count is inconsistent")
        if payload["rolePromptCount"] != len(cases):
            errors.append("neutral prompt audit role-prompt count is inconsistent")
        expected_case_keys = []
        for repetition in range(payload["repetitionCount"]):
            for scenario in payload["scenarioIDs"]:
                episode = generate_episode(scenario, PUBLIC_DEVELOPMENT_KEY, repetition)
                expected_case_keys.extend(
                    (scenario, repetition, role.seat, role.phase, role.workflow)
                    for role in episode.roles
                )
        actual_case_keys = [
            (
                case["scenario"], case["repetition"], case["seat"],
                case["phase"], case["workflow"],
            )
            for case in cases
        ]
        if actual_case_keys != expected_case_keys:
            errors.append("neutral prompt audit role coverage or order is inconsistent")
        for index, case in enumerate(cases):
            expected_case_passed = all(case["checks"].values())
            if case["passed"] != expected_case_passed:
                errors.append(f"neutral prompt audit case {index} pass flag is inconsistent")
            semantic_equal = (
                case["expectedSemanticSha256"] == case["observedSemanticSha256"]
            )
            if case["checks"]["exactSemanticProjection"] != semantic_equal:
                errors.append(
                    f"neutral prompt audit case {index} semantic digest is inconsistent"
                )
        if payload["passed"] != all(case["passed"] for case in cases):
            errors.append("neutral prompt audit pass flag is inconsistent")
    elif schema_name == "efficiency-report.schema.json":
        from .efficiency import (
            EFFICIENCY_RULES,
            MAX_TOTAL_SOURCE_BYTES,
            _contract_evidence_is_valid,
            _groups,
            _matched_episodes,
        )

        observations = payload["observations"]
        sources = payload["sources"]
        expected_source_order = sorted(
            sources,
            key=lambda value: (value["schema"], value["sha256"]),
        )
        if sources != expected_source_order:
            errors.append("efficiency report sources are not canonically ordered")
        if len({source["sha256"] for source in sources}) != len(sources):
            errors.append("efficiency report contains duplicate source artifacts")
        if sum(source["byteCount"] for source in sources) > MAX_TOTAL_SOURCE_BYTES:
            errors.append("efficiency report source bytes exceed the aggregate bound")
        expected_source_schemas = sorted({source["schema"] for source in sources})
        if payload["sourceSchemas"] != expected_source_schemas:
            errors.append("efficiency report source schemas disagree with sources")
        if payload["rules"] != list(EFFICIENCY_RULES):
            errors.append("efficiency report interpretation rules are not current")
        if payload["observationCount"] != len(observations):
            errors.append("efficiency report observation count is inconsistent")
        episode_ids = {observation["episodeID"] for observation in observations}
        if payload["episodeCount"] != len(episode_ids):
            errors.append("efficiency report episode count is inconsistent")
        expected_order = sorted(
            observations,
            key=lambda value: (
                value["episodeID"], value["controlProfile"], value["candidateID"]
            ),
        )
        if observations != expected_order:
            errors.append("efficiency observations are not canonically ordered")
        observation_identities = [
            (
                observation["episodeID"],
                observation["candidateID"],
                observation["controlProfile"],
                observation["executionKind"],
                observation["modelID"],
            )
            for observation in observations
        ]
        if len(observation_identities) != len(set(observation_identities)):
            errors.append("efficiency report contains duplicate observations")
        if payload["groups"] != _groups(observations):
            errors.append("efficiency report groups disagree with observations")
        grouped: dict[str, list[dict[str, Any]]] = {}
        for observation in observations:
            grouped.setdefault(observation["episodeID"], []).append(observation)
            tool = observation["toolRoundTrips"]
            usage = observation["modelUsage"]
            if tool["invalidCount"] > tool["count"]:
                errors.append("efficiency observation invalid calls exceed total calls")
            if tool["failedCount"] is not None and tool["failedCount"] > tool["count"]:
                errors.append("efficiency observation failed calls exceed total calls")
            expected_missing = sorted([
                name
                for name, value in (
                    ("failed-tool-round-trips", tool["failedCount"]),
                    ("tool-request-bytes", tool["requestBytes"]),
                    ("tool-response-bytes", tool["responseBytes"]),
                    ("cumulative-tool-time", tool["cumulativeToolTimeMs"]),
                    ("reported-cost", usage["reportedCostUSD"]),
                )
                if value is None
            ])
            if observation["missingMeasurements"] != expected_missing:
                errors.append("efficiency missing measurements disagree with null values")
            if not _contract_evidence_is_valid(observation["comparisonContract"]):
                errors.append("efficiency comparison-contract evidence is inconsistent")
            expected_model = observation["executionKind"] == "real-model"
            if observation["modelExecuted"] != expected_model:
                errors.append("efficiency execution kind disagrees with model execution")
            if expected_model != (observation["modelID"] is not None):
                errors.append("efficiency model identity is inconsistent")
            plain_profile = (
                observation["controlProfile"] == "role-separated-plain-markdown-v1"
            )
            expected_basis = (
                "served-workspace-tool-boundary"
                if plain_profile or not expected_model
                else "redacted-margin-command-summary"
            )
            if tool["measurementBasis"] != expected_basis:
                errors.append("efficiency tool measurement basis is inconsistent")
            required_source_schema = (
                "urn:marginbench:neutral-run:v1"
                if plain_profile and expected_model
                else "urn:marginbench:run:v1"
                if expected_model
                else "urn:marginbench:neutral-served-preflight:v1"
            )
            if required_source_schema not in payload["sourceSchemas"]:
                errors.append("efficiency observation lacks its declared source class")
            if not expected_model and any(
                usage[name] != 0
                for name in (
                    "calls", "promptTokens", "cachedInputTokens",
                    "completionTokens", "reasoningTokens",
                )
            ):
                errors.append("scripted efficiency observation contains model usage")
        expected_matches = _matched_episodes(grouped)
        if payload["matchedEpisodes"] != expected_matches:
            errors.append("efficiency matched-episode summaries are inconsistent")
    elif schema_name == "neutral-run.schema.json":
        from .schema import canonical_json

        episodes = payload["episodes"]
        identifiers = [episode["id"] for episode in episodes]
        if len(identifiers) != len(set(identifiers)):
            errors.append("neutral run contains duplicate episode ids")
        for episode in episodes:
            expected_id = (
                f"{episode['scenario']}:{episode['repetition']}:"
                f"{episode['fingerprint'][:12]}"
            )
            if episode["id"] != expected_id:
                errors.append(f"neutral run episode id is inconsistent: {episode['id']}")
            checks = episode["checks"]
            expected_dimensions = {
                "outcome": 25 * sum(checks[name] for name in (
                    "allExpectedFacts", "noUnexpectedFacts", "exactFactFields", "committedAll"
                )),
                "integrity": 20 * sum(checks[name] for name in (
                    "sourceExpected", "ledgerValid", "duplicateFree",
                    "allOrNoneFinal", "allOrNoneHistory",
                )),
                "attribution": 50 * sum(checks[name] for name in (
                    "trustedAttribution", "trustedDecisions"
                )),
                "continuity": 100 if checks["continuityObserved"] else 0,
                "recovery": 100 if checks["recoveryObserved"] else 0,
            }
            if episode["dimensions"] != expected_dimensions:
                errors.append(f"neutral run dimensions are inconsistent: {episode['id']}")
            if episode["implementedChecksPassed"] != all(checks.values()):
                errors.append(f"neutral run pass flag is inconsistent: {episode['id']}")
            expected_safety = all(checks[name] for name in (
                "sourceExpected", "ledgerValid", "allOrNoneFinal", "allOrNoneHistory"
            ))
            if episode["safetyPassed"] != expected_safety:
                errors.append(f"neutral run safety is inconsistent: {episode['id']}")
            if episode["sourcePreserved"] != checks["sourceExpected"]:
                errors.append(f"neutral run source flag is inconsistent: {episode['id']}")
            tool = episode["toolRoundTrips"]
            if tool["invalidCount"] > tool["count"] or tool["failedCount"] > tool["count"]:
                errors.append(f"neutral run tool totals are inconsistent: {episode['id']}")
            logical_roles = [actor["seat"] for actor in episode["logicalActors"]]
            try:
                topology = planned_topology(episode["controlProfile"], logical_roles)
            except ValueError as error:
                errors.append(str(error))
            else:
                if any(episode[field] != topology[field] for field in topology):
                    errors.append(f"neutral run topology is inconsistent: {episode['id']}")
        expected_processes = sum(episode["agentProcessCount"] for episode in episodes)
        if payload["execution"]["agentProcessCount"] != expected_processes:
            errors.append("neutral run execution process count is inconsistent")
        expected_roles = sorted({
            actor["seat"] for episode in episodes for actor in episode["logicalActors"]
        })
        expected_seats = sorted({
            seat for episode in episodes for seat in episode["traceSeats"]
        })
        if payload["execution"]["roles"] != expected_roles:
            errors.append("neutral run execution roles are inconsistent")
        if payload["execution"]["traceSeats"] != expected_seats:
            errors.append("neutral run execution trace seats are inconsistent")
        if (
            payload["candidate"]["controlImplementationSha256"]
            != payload["benchmark"]["implementationSha256"]
        ):
            errors.append("neutral run candidate implementation digest is inconsistent")
        expected_run_id = hashlib.sha256(canonical_json({
            "candidate": payload["candidate"]["id"],
            "controlImplementationSha256": payload["candidate"][
                "controlImplementationSha256"
            ],
            "episodes": identifiers,
            "model": payload["execution"]["model"],
            "startedAt": payload["execution"]["startedAt"],
        })).hexdigest()[:32]
        if payload["runID"] != expected_run_id:
            errors.append("neutral run id is inconsistent")
        trace_reported = round(
            sum(episode["usage"]["reportedCostUSD"] for episode in episodes),
            6,
        )
        if not _close(payload["cost"]["traceReported"], trace_reported):
            errors.append("neutral run trace-reported cost is inconsistent")
        expected_unreconciled = round(abs(
            payload["cost"]["observedWalletDebit"] - payload["cost"]["traceReported"]
        ), 6)
        if not _close(payload["cost"]["unreconciled"], expected_unreconciled):
            errors.append("neutral run unreconciled cost is inconsistent")
        if "liveBudget" in payload["cost"]:
            _live_budget_semantics(payload["cost"]["liveBudget"], "neutral run live budget", errors)
    elif schema_name == "neutral-prime-run-summary.schema.json":
        episodes = payload["episodes"]
        if payload["episodeCount"] != len(episodes):
            errors.append("neutral Prime summary episode count is inconsistent")
        identifiers = [episode["episodeID"] for episode in episodes]
        if len(identifiers) != len(set(identifiers)):
            errors.append("neutral Prime summary contains duplicate episodes")
        role_run_count = 0
        for episode in episodes:
            expected_id = (
                f"{episode['scenario']}:{episode['repetition']}:"
                f"{episode['fingerprint'][:12]}"
            )
            if episode["episodeID"] != expected_id:
                errors.append(f"neutral Prime episode id is inconsistent: {episode['episodeID']}")
            checks = episode["checks"]
            expected_dimensions = {
                "outcome": 25 * sum(checks[name] for name in (
                    "allExpectedFacts", "noUnexpectedFacts", "exactFactFields", "committedAll"
                )),
                "integrity": 20 * sum(checks[name] for name in (
                    "sourceExpected", "ledgerValid", "duplicateFree",
                    "allOrNoneFinal", "allOrNoneHistory",
                )),
                "attribution": 50 * sum(checks[name] for name in (
                    "trustedAttribution", "trustedDecisions"
                )),
                "continuity": 100 if checks["continuityObserved"] else 0,
                "recovery": 100 if checks["recoveryObserved"] else 0,
            }
            if episode["dimensions"] != expected_dimensions:
                errors.append(
                    f"neutral Prime dimensions are inconsistent: {episode['episodeID']}"
                )
            if episode["implementedChecksPassed"] != all(checks.values()):
                errors.append(
                    f"neutral Prime pass flag is inconsistent: {episode['episodeID']}"
                )
            if episode["sourcePreserved"] != checks["sourceExpected"]:
                errors.append(
                    f"neutral Prime source flag is inconsistent: {episode['episodeID']}"
                )
            efficiency = episode["efficiencyObservations"]
            if efficiency["toolCallCount"] != sum(efficiency["actionCounts"].values()):
                errors.append(
                    f"neutral Prime tool totals are inconsistent: {episode['episodeID']}"
                )
            role_runs = episode["roleRuns"]
            role_run_count += len(role_runs)
            totals = _usage_totals([role["usage"] for role in role_runs])
            for field, expected in totals.items():
                if not _close(episode["usage"][field], expected):
                    errors.append(
                        f"neutral Prime usage is inconsistent for {field}: {episode['episodeID']}"
                    )
            logical_roles = [actor["seat"] for actor in episode["logicalActors"]]
            try:
                topology = planned_topology(episode["controlProfile"], logical_roles)
            except ValueError as error:
                errors.append(str(error))
            else:
                if any(episode[field] != topology[field] for field in topology):
                    errors.append(
                        f"neutral Prime topology is inconsistent: {episode['episodeID']}"
                    )
        if payload["traceCount"] != role_run_count:
            errors.append("neutral Prime trace count is inconsistent")
        wallet = payload["wallet"]
        observed = _observed_wallet_debit(wallet)
        if not _close(observed, wallet["observedDebitUSD"]):
            errors.append("neutral Prime wallet debit is inconsistent")
        _live_budget_semantics(
            payload["liveBudget"],
            "neutral Prime live budget",
            errors,
            allow_provider_violation=payload["status"] == "infrastructure_error",
        )
        if not _close(
            min(payload["contractMaximumCostUSD"], payload["liveBudgetCapUSD"]),
            payload["estimatedMaximumCostUSD"],
        ):
            errors.append("neutral Prime estimated maximum does not apply its live budget cap")
        if not _close(
            payload["liveBudgetCapUSD"],
            payload["liveBudget"]["policy"]["maxTotalCostUSD"],
        ):
            errors.append("neutral Prime live budget cap differs from its policy")
        if payload["status"] == "completed" and (
            payload["exitCode"] != 0
            or payload["traceCount"] == 0
            or not payload["traceConsistencyPassed"]
            or payload["infrastructureCodes"]
            or any(
                role["stopCondition"] == "error"
                for episode in episodes
                for role in episode["roleRuns"]
            )
        ):
            errors.append("completed neutral Prime summary is inconsistent")
        if not payload["paidModelsInvoked"] and (
            not _close(wallet["observedDebitUSD"], 0)
            or any(
                not _close(episode["usage"]["reportedCostUSD"], 0)
                for episode in episodes
            )
        ):
            errors.append("no-paid-model neutral Prime summary reports a model charge")
    elif schema_name == "challenge-catalog.schema.json":
        from .challenges import DEMAND_AXES, challenge_catalog
        from .scenarios import SCENARIO_IDS

        axis_ids = [axis["id"] for axis in payload["axes"]]
        if axis_ids != list(DEMAND_AXES):
            errors.append("challenge catalog axes are not in the canonical order")
        challenge_ids = [challenge["scenario"] for challenge in payload["challenges"]]
        if len(challenge_ids) != len(set(challenge_ids)):
            errors.append("challenge catalog contains duplicate scenarios")
        if challenge_ids != list(SCENARIO_IDS):
            errors.append("challenge catalog does not exactly cover the executable scenarios")
        if payload != challenge_catalog():
            errors.append("challenge catalog differs from the frozen executable catalog")
    elif schema_name == "crossover-plan.schema.json":
        from .challenges import challenge_catalog, challenge_profile
        from .crossover import (
            CONTINUING_PROFILE,
            CROSSOVER_BENCHMARK_VERSION,
            MEANINGFUL_SPEED_RATIO,
            MINIMUM_DIRECTIONAL_PAIRS,
            QUALITY_TOLERANCE,
            ROLE_SEPARATED_PROFILE,
        )
        from .schema import canonical_json, sha256_bytes

        expected_catalog_sha = sha256_bytes(canonical_json(challenge_catalog()))
        if payload["benchmarkVersion"] != CROSSOVER_BENCHMARK_VERSION:
            errors.append("crossover plan benchmark version is not current")
        if payload["challengeCatalogSha256"] != expected_catalog_sha:
            errors.append("crossover plan challenge catalog digest is not current")
        if (
            payload["minimumPairsForDirectionalClaim"] != MINIMUM_DIRECTIONAL_PAIRS
            or payload["rules"]
            != {
                "qualityTolerancePoints": QUALITY_TOLERANCE,
                "meaningfulSpeedRatio": MEANINGFUL_SPEED_RATIO,
                "budgetUnit": "logical-role",
                "singleAggregateScore": False,
            }
        ):
            errors.append("crossover plan analysis policy is not current")
        if payload["developmentCases"] != (payload["taskSet"] == "public-development-v1"):
            errors.append("crossover plan task set disagrees with developmentCases")
        episodes = payload["episodes"]
        if payload["episodeCount"] != len(episodes):
            errors.append("crossover plan episodeCount does not equal episodes length")
        expected_count = len(payload["scenarioIDs"]) * payload["repetitions"]
        if payload["episodeCount"] != expected_count:
            errors.append("crossover plan does not cover every scenario and repetition")
        identifiers = [episode["id"] for episode in episodes]
        if len(identifiers) != len(set(identifiers)):
            errors.append("crossover plan contains duplicate episode IDs")
        cases = [(episode["scenario"], episode["repetition"]) for episode in episodes]
        expected_cases = {
            (scenario, repetition)
            for scenario in payload["scenarioIDs"]
            for repetition in range(payload["repetitions"])
        }
        if set(cases) != expected_cases or len(cases) != len(set(cases)):
            errors.append("crossover plan case coverage is inconsistent")
        logical_roles = 0
        expected_processes = {ROLE_SEPARATED_PROFILE: 0, CONTINUING_PROFILE: 0}
        orders = []
        for episode in episodes:
            expected_id = (
                f"{episode['scenario']}:{episode['repetition']}:"
                f"{episode['fingerprint'][:12]}"
            )
            if episode["id"] != expected_id:
                errors.append(f"crossover episode id is inconsistent: {episode['id']}")
            profile = challenge_profile(episode["scenario"])
            if (
                episode["family"] != profile.family
                or episode["hypothesis"] != profile.hypothesis
                or episode["demand"] != dict(profile.demand)
            ):
                errors.append(f"crossover challenge metadata is inconsistent: {episode['id']}")
            logical_roles += len(episode["roles"])
            for topology_profile in expected_processes:
                expected_processes[topology_profile] += planned_topology(
                    topology_profile,
                    episode["roles"],
                )["agentProcessCount"]
            orders.append(tuple(episode["profileOrder"]))
        if payload["logicalRoleRunsPerProfile"] != logical_roles:
            errors.append("crossover logical-role budget is inconsistent")
        if payload["agentProcessesPerProfile"] != expected_processes:
            errors.append("crossover agent-process totals are inconsistent")
        forward = sum(order == (ROLE_SEPARATED_PROFILE, CONTINUING_PROFILE) for order in orders)
        reverse = sum(order == (CONTINUING_PROFILE, ROLE_SEPARATED_PROFILE) for order in orders)
        if forward + reverse != len(orders) or abs(forward - reverse) > 1:
            errors.append("crossover topology order is not counterbalanced")
        for scenario in payload["scenarioIDs"]:
            scenario_orders = [
                tuple(episode["profileOrder"])
                for episode in episodes
                if episode["scenario"] == scenario
            ]
            scenario_forward = scenario_orders.count(
                (ROLE_SEPARATED_PROFILE, CONTINUING_PROFILE)
            )
            scenario_reverse = scenario_orders.count(
                (CONTINUING_PROFILE, ROLE_SEPARATED_PROFILE)
            )
            if abs(scenario_forward - scenario_reverse) > 1:
                errors.append(
                    f"crossover topology order is not balanced within scenario: {scenario}"
                )
        sufficient = payload["episodeCount"] >= payload["minimumPairsForDirectionalClaim"]
        if payload["sampleSizeSufficient"] != sufficient:
            errors.append("crossover plan sample-size flag is inconsistent")
    elif schema_name == "crossover-report.schema.json":
        from .crossover import (
            CONTINUING_PROFILE,
            ROLE_SEPARATED_PROFILE,
            CrossoverMeasurement,
            analyze_crossover,
        )

        separated: list[CrossoverMeasurement] = []
        continuing: list[CrossoverMeasurement] = []
        for observation in payload["observations"]:
            common = {
                "episode_id": observation["episodeID"],
                "scenario": observation["scenario"],
                "repetition": observation["repetition"],
                "fingerprint": observation["fingerprint"],
                "margin_sha256": payload["marginSha256"],
            }
            for profile, field, destination in (
                (ROLE_SEPARATED_PROFILE, "roleSeparated", separated),
                (CONTINUING_PROFILE, "continuing", continuing),
            ):
                measurement = observation[field]
                usage = measurement["usage"]
                destination.append(CrossoverMeasurement(
                    **common,
                    candidate_id=measurement["candidateID"],
                    control_profile=profile,
                    score=measurement["score"],
                    duration_ms=measurement["durationMs"],
                    command_count=measurement["commandCount"],
                    invalid_command_count=measurement["invalidCommandCount"],
                    safety_passed=measurement["safetyPassed"],
                    source_preserved=measurement["sourcePreserved"],
                    dimensions=dict(measurement["dimensions"]),
                    checks=dict(measurement["checks"]),
                    model_calls=usage["modelCalls"],
                    prompt_tokens=usage["promptTokens"],
                    completion_tokens=usage["completionTokens"],
                    cached_input_tokens=usage["cachedInputTokens"],
                    reasoning_tokens=usage["reasoningTokens"],
                    reported_cost_usd=usage["reportedCostUSD"],
                ))
        try:
            expected = analyze_crossover(
                separated,
                continuing,
                analysis_mode=payload["analysisMode"],
                plan=payload["plan"],
                experiment_contract=payload["experimentContract"],
            )
        except ValueError as error:
            errors.append(str(error))
        else:
            if payload != expected:
                errors.append("crossover report does not match its paired measurements")
    elif schema_name == "crossover-publication-audit.schema.json":
        paths = [item["path"] for item in payload["artifacts"]]
        if payload["artifactCount"] != len(payload["artifacts"]):
            errors.append("publication audit artifactCount does not equal artifacts length")
        if len(paths) != len(set(paths)):
            errors.append("publication audit contains duplicate artifact paths")
        expected_valid = (
            not payload["errors"]
            and payload["reportReproduced"]
            and payload["rawArtifactCount"] == 0
        )
        if payload["valid"] != expected_valid:
            errors.append("publication audit valid flag disagrees with its findings")
        if payload["runCount"] != payload["summaryCount"]:
            errors.append("publication audit run and summary counts differ")
        if payload["valid"]:
            if payload["runCount"] != payload["episodeCount"] * 2:
                errors.append("publication audit does not contain both topologies for every episode")
            if payload["candidateID"] is None:
                errors.append("valid publication audit lacks a candidate id")
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
            try:
                topology = planned_topology(payload["controlProfile"], episode["roles"])
            except ValueError as error:
                errors.append(str(error))
            else:
                if any(episode[field] != topology[field] for field in topology):
                    errors.append(f"episode topology is inconsistent: {episode['id']}")
        roles = sum(len(item["roles"]) for item in episodes)
        if payload["roleRunsPerCandidate"] != roles or payload["totalRoleRuns"] != roles * 2:
            errors.append("study plan role-run totals are inconsistent")
        processes = sum(item["agentProcessCount"] for item in episodes)
        if (
            payload["agentProcessesPerCandidate"] != processes
            or payload["totalAgentProcesses"] != processes * 2
        ):
            errors.append("study plan agent-process totals are inconsistent")
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
        published_logical_roles: set[str] = set()
        published_trace_seats: set[str] = set()
        published_agent_processes = 0
        published_topology_episodes = 0
        for episode in episodes:
            expected = f"{episode['scenario']}:{episode['repetition']}:{episode['fingerprint'][:12]}"
            if episode["id"] != expected:
                errors.append(f"episode id is inconsistent: {episode['id']}")
            if episode["invalidCommandCount"] > episode["commandCount"]:
                errors.append(f"invalid command count exceeds command count: {episode['id']}")
            if "eventSummary" in episode:
                _event_summary_semantics(
                    episode["eventSummary"],
                    episode["commandCount"],
                    f"run episode {episode['id']}",
                    errors,
                )
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
            topology_fields = (
                "controlProfile",
                "logicalActors",
                "agentProcessCount",
                "traceSeats",
                "phasePolicy",
            )
            topology_present = [field in episode for field in topology_fields]
            if any(topology_present) and not all(topology_present):
                errors.append(f"run episode has incomplete topology metadata: {episode['id']}")
            elif all(topology_present):
                logical_roles = [actor["seat"] for actor in episode["logicalActors"]]
                if len(logical_roles) != len(set(logical_roles)):
                    errors.append(f"run episode contains duplicate logical actors: {episode['id']}")
                try:
                    topology = planned_topology(episode["controlProfile"], logical_roles)
                except ValueError as error:
                    errors.append(str(error))
                else:
                    if any(episode[field] != topology[field] for field in topology):
                        errors.append(f"run episode topology is inconsistent: {episode['id']}")
                if episode["controlProfile"] != payload["execution"].get("controlProfile"):
                    errors.append(f"run episode control differs from execution: {episode['id']}")
                published_logical_roles.update(logical_roles)
                published_trace_seats.update(episode["traceSeats"])
                published_agent_processes += episode["agentProcessCount"]
                published_topology_episodes += 1
        if published_topology_episodes and published_topology_episodes != len(episodes):
            errors.append("run mixes episodes with and without topology metadata")
        if published_logical_roles and set(roles) != published_logical_roles:
            errors.append("run execution roles differ from published logical actors")
        if published_trace_seats:
            if set(payload["execution"].get("traceSeats", ())) != published_trace_seats:
                errors.append("run execution trace seats differ from episode traces")
            if payload["execution"].get("agentProcessCount") != published_agent_processes:
                errors.append("run execution process count differs from its episodes")
            phase_policies = {
                episode["phasePolicy"]
                for episode in episodes
                if "phasePolicy" in episode
            }
            if (
                len(phase_policies) != 1
                or payload["execution"].get("phasePolicy") not in phase_policies
            ):
                errors.append("run execution phase policy differs from its episodes")
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
            live_parts = (
                "contractBound" in cost,
                "liveBudgetCap" in cost,
                "liveBudget" in cost,
            )
            if any(live_parts) and not all(live_parts):
                errors.append(
                    "live cost bound requires contractBound, liveBudgetCap, and liveBudget"
                )
            elif all(live_parts):
                if not _close(expected, cost["contractBound"]):
                    errors.append("contractBound does not match its recorded basis")
                if not _close(
                    min(cost["contractBound"], cost["liveBudgetCap"]),
                    cost["admissionBound"],
                ):
                    errors.append("admissionBound does not apply the live budget cap")
                if not _close(
                    cost["liveBudgetCap"],
                    cost["liveBudget"]["policy"]["maxTotalCostUSD"],
                ):
                    errors.append("liveBudgetCap differs from the enforced proxy policy")
                if cost["liveBudgetCap"] > cost["hardAdmissionCap"] + 0.000001:
                    errors.append("liveBudgetCap exceeds hardAdmissionCap")
            elif not _close(expected, cost["admissionBound"]):
                errors.append("admissionBound does not match its recorded basis")
        if "liveBudget" in cost:
            _live_budget_semantics(
                cost["liveBudget"],
                "run live budget",
                errors,
                allow_provider_violation=payload["status"] == "infrastructure-error",
            )
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
            if "eventSummary" in episode:
                _event_summary_semantics(
                    episode["eventSummary"],
                    episode["commandCount"],
                    f"Prime episode {episode['episodeID']}",
                    errors,
                )
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
            topology_fields = (
                "controlProfile",
                "logicalActors",
                "agentProcessCount",
                "traceSeats",
                "phasePolicy",
            )
            topology_present = [field in episode for field in topology_fields]
            if any(topology_present) and not all(topology_present):
                errors.append(
                    f"Prime episode has incomplete topology metadata: {episode['episodeID']}"
                )
            elif all(topology_present):
                logical_roles = [actor["seat"] for actor in episode["logicalActors"]]
                if len(logical_roles) != len(set(logical_roles)):
                    errors.append(
                        f"Prime episode contains duplicate logical actors: {episode['episodeID']}"
                    )
                try:
                    topology = planned_topology(episode["controlProfile"], logical_roles)
                except ValueError as error:
                    errors.append(str(error))
                else:
                    if any(episode[field] != topology[field] for field in topology):
                        errors.append(
                            f"Prime episode topology is inconsistent: {episode['episodeID']}"
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
        observed = _observed_wallet_debit(wallet)
        if not _close(observed, wallet["observedDebitUSD"]):
            errors.append("wallet observed debit is inconsistent")
        trace_cost = round(sum(item["usage"]["reportedCostUSD"] for item in episodes), 6)
        if payload["estimatedMaximumCostUSD"] + 0.000001 < trace_cost:
            errors.append("reported model cost exceeds estimatedMaximumCostUSD")
        if "liveBudget" in payload:
            _live_budget_semantics(
                payload["liveBudget"],
                "Prime live budget",
                errors,
                allow_provider_violation=payload["status"] == "infrastructure_error",
            )
        summary_bound_parts = (
            "contractMaximumCostUSD" in payload,
            "liveBudgetCapUSD" in payload,
            "liveBudget" in payload,
        )
        if any(summary_bound_parts) and not all(summary_bound_parts):
            errors.append(
                "Prime live bound requires contractMaximumCostUSD, liveBudgetCapUSD, and liveBudget"
            )
        elif all(summary_bound_parts):
            if not _close(
                min(payload["contractMaximumCostUSD"], payload["liveBudgetCapUSD"]),
                payload["estimatedMaximumCostUSD"],
            ):
                errors.append("Prime estimated maximum does not apply its live budget cap")
            if not _close(
                payload["liveBudgetCapUSD"],
                payload["liveBudget"]["policy"]["maxTotalCostUSD"],
            ):
                errors.append("Prime live budget cap differs from its proxy policy")
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
    elif schema_name == "diagnostic-report.schema.json":
        if payload["artifactCount"] != len(payload["artifacts"]):
            errors.append("diagnostic artifactCount does not equal artifacts length")
        if payload["candidateCount"] != len(payload["candidates"]):
            errors.append("diagnostic candidateCount does not equal candidates length")
        if payload["scenarioCount"] != len(payload["scenarios"]):
            errors.append("diagnostic scenarioCount does not equal scenarios length")
        candidate_episodes = sum(item["episodeCount"] for item in payload["candidates"])
        scenario_episodes = sum(item["episodeCount"] for item in payload["scenarios"])
        if candidate_episodes != payload["episodeCount"]:
            errors.append("diagnostic candidate episode totals are inconsistent")
        if scenario_episodes != payload["episodeCount"]:
            errors.append("diagnostic scenario episode totals are inconsistent")
        if sum(item["commandCount"] for item in payload["candidates"]) != payload["commandCount"]:
            errors.append("diagnostic command total is inconsistent")
        if sum(item["invalidCommandCount"] for item in payload["candidates"]) != payload["invalidCommandCount"]:
            errors.append("diagnostic invalid-command total is inconsistent")
        if sum(item["safetyFailureCount"] for item in payload["candidates"]) != payload["safetyFailureCount"]:
            errors.append("diagnostic safety-failure total is inconsistent")
        if sum(item["sourceFailureCount"] for item in payload["candidates"]) != payload["sourceFailureCount"]:
            errors.append("diagnostic source-failure total is inconsistent")
        overall_failed = {item["name"]: item["count"] for item in payload["failedChecks"]}
        candidate_failed: dict[str, int] = {}
        for candidate in payload["candidates"]:
            for item in candidate["failedChecks"]:
                candidate_failed[item["name"]] = candidate_failed.get(item["name"], 0) + item["count"]
        if candidate_failed != overall_failed:
            errors.append("diagnostic failed-check totals are inconsistent")
        candidate_ids = [item["candidateID"] for item in payload["candidates"]]
        scenario_ids = [item["scenario"] for item in payload["scenarios"]]
        if len(candidate_ids) != len(set(candidate_ids)):
            errors.append("diagnostic report contains duplicate candidate IDs")
        if len(scenario_ids) != len(set(scenario_ids)):
            errors.append("diagnostic report contains duplicate scenario IDs")
        focus = next(
            (
                item for item in payload["candidates"]
                if item["candidateID"] == payload["focusCandidateID"]
            ),
            None,
        )
        if focus is None or focus != payload["focus"]:
            errors.append("diagnostic focus does not match its candidate summary")
        score_summary = payload["scoreSummary"]
        weighted_score = sum(
            item["meanScore"] * item["episodeCount"] for item in payload["candidates"]
        ) / payload["episodeCount"]
        if not _close(weighted_score, score_summary["mean"]):
            errors.append("diagnostic mean score is inconsistent")
        if not _close(min(item["minimumScore"] for item in payload["candidates"]), score_summary["minimum"]):
            errors.append("diagnostic minimum score is inconsistent")
        if not _close(max(item["maximumScore"] for item in payload["candidates"]), score_summary["maximum"]):
            errors.append("diagnostic maximum score is inconsistent")
        for dimension, overall in payload["dimensionMeans"].items():
            if any(dimension not in item["dimensionMeans"] for item in payload["candidates"]):
                errors.append(f"diagnostic candidate is missing dimension: {dimension}")
                continue
            weighted = sum(
                item["dimensionMeans"][dimension] * item["episodeCount"]
                for item in payload["candidates"]
            ) / payload["episodeCount"]
            if not _close(weighted, overall):
                errors.append(f"diagnostic dimension mean is inconsistent: {dimension}")
        for item in (*payload["candidates"], *payload["scenarios"]):
            if not item["minimumScore"] <= item["meanScore"] <= item["maximumScore"]:
                errors.append("diagnostic group score ordering is inconsistent")
            expected_mean_commands = item["commandCount"] / item["episodeCount"]
            if not _close(expected_mean_commands, item["meanCommandCount"]):
                errors.append("diagnostic group mean command count is inconsistent")
        findings = payload["findings"]
        finding_ids = [item["id"] for item in findings]
        if len(finding_ids) != len(set(finding_ids)):
            errors.append("diagnostic report contains duplicate finding IDs")
        if payload["topOpportunity"] != finding_ids[0]:
            errors.append("diagnostic topOpportunity is not the first ranked finding")
        severity_order = {"critical": 0, "high": 1, "medium": 2, "info": 3}
        severities = [severity_order[item["severity"]] for item in findings]
        if severities != sorted(severities):
            errors.append("diagnostic findings are not ranked by severity")
        for finding in findings:
            evidence = finding["evidence"]
            focus_episode_count = focus["episodeCount"] if focus is not None else 0
            focus_invalid_count = focus["invalidCommandCount"] if focus is not None else 0
            if evidence["episodeCount"] > focus_episode_count:
                errors.append("diagnostic finding exceeds the focus episode count")
            if evidence["invalidCommandCount"] > focus_invalid_count:
                errors.append("diagnostic finding exceeds the focus invalid-command count")
            response_sizes = evidence.get("responseSizeEvidence")
            if isinstance(response_sizes, dict):
                buckets = {
                    item["name"]: item["count"]
                    for item in response_sizes.get("buckets", [])
                }
                if sum(buckets.values()) != response_sizes.get("resultCount"):
                    errors.append("diagnostic response-size bucket total is inconsistent")
                heavy = sum(
                    buckets.get(name, 0)
                    for name in ("4097-16384", "16385-65536", "65537+")
                )
                if heavy != response_sizes.get("largerThan4096Count"):
                    errors.append("diagnostic large-response total is inconsistent")
                command = response_sizes.get("command")
                result_count = response_sizes.get("resultCount", 0)
                if command == "context" and (heavy < 2 or heavy * 4 < result_count):
                    errors.append("diagnostic large-response threshold is not met")
                if command == "capabilities":
                    very_heavy = sum(
                        buckets.get(name, 0) for name in ("16385-65536", "65537+")
                    )
                    if very_heavy < 1 and (heavy < 2 or heavy * 2 < result_count):
                        errors.append("diagnostic large-response threshold is not met")
            write_latency = evidence.get("writeLatencyEvidence")
            if isinstance(write_latency, dict):
                buckets = {
                    item["name"]: item["count"]
                    for item in write_latency["preWriteToolCallBuckets"]
                }
                if sum(buckets.values()) != write_latency["traceCount"]:
                    errors.append("diagnostic pre-write bucket total is inconsistent")
                if (
                    write_latency["tracesWithWriteAttempt"]
                    + write_latency["tracesWithoutWriteAttempt"]
                    != write_latency["traceCount"]
                ):
                    errors.append("diagnostic write-latency trace partition is inconsistent")
                if buckets.get("none", 0) != write_latency["tracesWithoutWriteAttempt"]:
                    errors.append("diagnostic no-write bucket is inconsistent")
                delayed = buckets.get("5-6", 0) + buckets.get("7+", 0)
                if delayed != write_latency["fiveOrMorePreWriteCount"]:
                    errors.append("diagnostic delayed-write count is inconsistent")
                if delayed * 2 < write_latency["tracesWithWriteAttempt"]:
                    errors.append("diagnostic delayed-write threshold is not met")
                if write_latency["writeAttemptCount"] < write_latency["tracesWithWriteAttempt"]:
                    errors.append("diagnostic write-attempt count is inconsistent")
            suggestion_mechanisms = evidence.get("suggestionMechanismEvidence")
            if isinstance(suggestion_mechanisms, dict):
                applicable = suggestion_mechanisms["applicableTraceCount"]
                mechanism_fields = (
                    "batchTeachingViewedBeforeWriteTraceCount",
                    "batchAdoptionTraceCount",
                    "batchAdoptionAfterTeachingTraceCount",
                    "individualAddTraceCount",
                    "individualAddAfterTeachingTraceCount",
                    "waitReceiptObservedTraceCount",
                    "waitReceiptTrustedTraceCount",
                    "postWaitReverificationTraceCount",
                )
                if any(suggestion_mechanisms[field] > applicable for field in mechanism_fields):
                    errors.append("diagnostic suggestion mechanism exceeds applicable traces")
                optional_mechanism_fields = (
                    "preWriteStateReadTraceCount",
                    "extraPostWriteStateReadTraceCount",
                )
                if any(
                    suggestion_mechanisms.get(field, 0) > applicable
                    for field in optional_mechanism_fields
                ):
                    errors.append("diagnostic optional suggestion mechanism exceeds applicable traces")
                if suggestion_mechanisms["batchAdoptionAfterTeachingTraceCount"] > min(
                    suggestion_mechanisms["batchTeachingViewedBeforeWriteTraceCount"],
                    suggestion_mechanisms["batchAdoptionTraceCount"],
                ):
                    errors.append("diagnostic taught batch adoption is inconsistent")
                if suggestion_mechanisms["individualAddAfterTeachingTraceCount"] > min(
                    suggestion_mechanisms["batchTeachingViewedBeforeWriteTraceCount"],
                    suggestion_mechanisms["individualAddTraceCount"],
                ):
                    errors.append("diagnostic taught individual-add use is inconsistent")
                if (
                    suggestion_mechanisms["waitReceiptTrustedTraceCount"]
                    + suggestion_mechanisms["postWaitReverificationTraceCount"]
                    != suggestion_mechanisms["waitReceiptObservedTraceCount"]
                ):
                    errors.append("diagnostic wait receipt partition is inconsistent")
        experiment = payload["recommendedNextExperiment"]
        local_gate = focus is None or focus["safetyFailureCount"] > 0 or focus["sourceFailureCount"] > 0
        if experiment["gate"] != ("local-safety" if local_gate else "matched-private-pairs"):
            errors.append("diagnostic experiment gate disagrees with safety totals")
        if experiment["minimumMatchedEpisodes"] != (0 if local_gate else 20):
            errors.append("diagnostic minimum matched episodes disagrees with its gate")
    elif schema_name == "trace-shape-report.schema.json":
        candidate_digests = payload.get("candidateMarginSha256s")
        if candidate_digests is not None and candidate_digests != sorted(set(candidate_digests)):
            errors.append("trace candidate digests are not canonical")
        candidate_ids = payload.get("candidateIDs")
        if candidate_ids is not None and candidate_ids != sorted(set(candidate_ids)):
            errors.append("trace candidate IDs are not canonical")
        write_bucket_names = {"0", "1-2", "3-4", "5-6", "7+", "none"}

        def validate_write_latency(
            latency: dict[str, Any], expected_trace_count: int, context: str
        ) -> dict[str, int]:
            if latency["traceCount"] != expected_trace_count:
                errors.append(f"{context} write-latency trace count is inconsistent")
            if (
                latency["tracesWithWriteAttempt"]
                + latency["tracesWithoutWriteAttempt"]
                != expected_trace_count
            ):
                errors.append(f"{context} write-latency trace partition is inconsistent")
            if latency["writeAttemptCount"] < latency["tracesWithWriteAttempt"]:
                errors.append(f"{context} write-attempt count is inconsistent")
            bucket_counts: dict[str, int] = {}
            for row in latency["preWriteToolCallBuckets"]:
                name = row["name"]
                if name not in write_bucket_names:
                    errors.append(f"{context} contains an unknown pre-write bucket")
                if name in bucket_counts:
                    errors.append(f"{context} repeats a pre-write bucket")
                bucket_counts[name] = row["count"]
            if sum(bucket_counts.values()) != expected_trace_count:
                errors.append(f"{context} pre-write buckets do not cover every trace")
            if bucket_counts.get("none", 0) != latency["tracesWithoutWriteAttempt"]:
                errors.append(f"{context} no-write bucket is inconsistent")
            return bucket_counts

        suggestion_mechanism_fields = (
            "applicableTraceCount",
            "batchTeachingViewedBeforeWriteTraceCount",
            "batchAdoptionTraceCount",
            "batchAdoptionAfterTeachingTraceCount",
            "individualAddTraceCount",
            "individualAddAfterTeachingTraceCount",
            "waitReceiptObservedTraceCount",
            "waitReceiptTrustedTraceCount",
            "postWaitReverificationTraceCount",
        )
        optional_suggestion_mechanism_fields = (
            "preWriteStateReadTraceCount",
            "extraPostWriteStateReadTraceCount",
        )
        all_suggestion_mechanism_fields = (
            suggestion_mechanism_fields + optional_suggestion_mechanism_fields
        )

        def validate_suggestion_mechanisms(
            mechanisms: dict[str, int], expected_applicable: int, context: str
        ) -> None:
            applicable = mechanisms["applicableTraceCount"]
            if applicable != expected_applicable:
                errors.append(f"{context} applicable suggestion traces are inconsistent")
            for field in suggestion_mechanism_fields[1:]:
                if mechanisms[field] > applicable:
                    errors.append(f"{context} {field} exceeds applicable traces")
            for field in optional_suggestion_mechanism_fields:
                if mechanisms.get(field, 0) > applicable:
                    errors.append(f"{context} {field} exceeds applicable traces")
            if mechanisms["batchAdoptionAfterTeachingTraceCount"] > min(
                mechanisms["batchTeachingViewedBeforeWriteTraceCount"],
                mechanisms["batchAdoptionTraceCount"],
            ):
                errors.append(f"{context} taught batch adoption is inconsistent")
            if mechanisms["individualAddAfterTeachingTraceCount"] > min(
                mechanisms["batchTeachingViewedBeforeWriteTraceCount"],
                mechanisms["individualAddTraceCount"],
            ):
                errors.append(f"{context} taught individual-add use is inconsistent")
            if (
                mechanisms["waitReceiptTrustedTraceCount"]
                + mechanisms["postWaitReverificationTraceCount"]
                != mechanisms["waitReceiptObservedTraceCount"]
            ):
                errors.append(f"{context} wait receipt partition is inconsistent")

        if payload["sourceCount"] != len(payload["sources"]):
            errors.append("trace shape sourceCount does not equal sources length")
        if payload["successCount"] + payload["failureCount"] != payload["toolCallCount"]:
            errors.append("trace shape success and failure totals do not equal toolCallCount")
        if payload["blockedCount"] > payload["failureCount"]:
            errors.append("trace shape blockedCount exceeds failureCount")
        if payload["leadingLiteralMarginCount"] > payload["toolCallCount"]:
            errors.append("trace shape leading executable count exceeds toolCallCount")
        unanswered = payload.get("unansweredToolCallCount", 0)
        unanswered_rows = payload.get("unansweredCommands", [])
        if sum(item["count"] for item in unanswered_rows) != unanswered:
            errors.append("trace unanswered command counts disagree with the report")
        command_total = 0
        command_success = 0
        command_failure = 0
        command_blocked = 0
        for command in payload["commands"]:
            if command["successCount"] + command["failureCount"] != command["count"]:
                errors.append(f"trace command totals disagree: {command['name']}")
            if command["blockedCount"] > command["failureCount"]:
                errors.append(f"trace command blocked count exceeds failures: {command['name']}")
            command_total += command["count"]
            command_success += command["successCount"]
            command_failure += command["failureCount"]
            command_blocked += command["blockedCount"]
        if command_total != payload["toolCallCount"]:
            errors.append("trace command counts do not equal toolCallCount")
        if command_success != payload["successCount"] or command_failure != payload["failureCount"]:
            errors.append("trace command outcome totals disagree with the report")
        if command_blocked != payload["blockedCount"]:
            errors.append("trace command blocked totals disagree with the report")
        allowed_size_buckets = {
            "0", "1-1024", "1025-4096", "4097-16384", "16385-65536", "65537+",
        }
        signatures = payload.get("commandSignatures")
        if signatures is not None:
            signature_total = 0
            signature_success = 0
            signature_failure = 0
            signature_blocked = 0
            for signature in signatures:
                if signature["successCount"] + signature["failureCount"] != signature["count"]:
                    errors.append(
                        f"trace command-signature totals disagree: {signature['command']}"
                    )
                if signature["blockedCount"] > signature["failureCount"]:
                    errors.append(
                        "trace command-signature blocked count exceeds failures: "
                        f"{signature['command']}"
                    )
                if signature["flags"] != sorted(signature["flags"]):
                    errors.append(
                        f"trace command-signature flags are not canonical: {signature['command']}"
                    )
                signature_errors = signature.get("errors")
                if signature_errors is not None and sum(
                    item["count"] for item in signature_errors
                ) != signature["failureCount"]:
                    errors.append(
                        "trace command-signature error counts disagree with failures: "
                        f"{signature['command']}"
                    )
                signature_sizes = signature.get("resultSizeBuckets")
                if signature_sizes is not None:
                    seen_signature_sizes: set[str] = set()
                    signature_size_total = 0
                    for row in signature_sizes:
                        if row["name"] not in allowed_size_buckets:
                            errors.append(
                                "trace command-signature contains an unknown result-size bucket"
                            )
                        if row["name"] in seen_signature_sizes:
                            errors.append(
                                "trace command-signature repeats a result-size bucket"
                            )
                        seen_signature_sizes.add(row["name"])
                        signature_size_total += row["count"]
                    if signature_size_total != signature["count"]:
                        errors.append(
                            "trace command-signature result sizes disagree with count: "
                            f"{signature['command']}"
                        )
                signature_total += signature["count"]
                signature_success += signature["successCount"]
                signature_failure += signature["failureCount"]
                signature_blocked += signature["blockedCount"]
            if signature_total != payload["toolCallCount"]:
                errors.append("trace command-signature counts do not equal toolCallCount")
            if (
                signature_success != payload["successCount"]
                or signature_failure != payload["failureCount"]
            ):
                errors.append("trace command-signature outcomes disagree with the report")
            if signature_blocked != payload["blockedCount"]:
                errors.append("trace command-signature blocked totals disagree with the report")
        def size_counts(rows: list[dict[str, Any]], context: str) -> dict[str, int]:
            result: dict[str, int] = {}
            for row in rows:
                name = row["name"]
                if name not in allowed_size_buckets:
                    errors.append(f"{context} contains an unknown result-size bucket")
                if name in result:
                    errors.append(f"{context} repeats a result-size bucket")
                result[name] = row["count"]
            return result

        size_fields = ("resultSizeBuckets", "commandResultSizeBuckets")
        top_size_presence = [field in payload for field in size_fields]
        if any(top_size_presence) and not all(top_size_presence):
            errors.append("trace report has incomplete result-size details")
        top_sizes: dict[str, int] = {}
        top_command_sizes: dict[str, dict[str, int]] = {}
        if all(top_size_presence):
            top_sizes = size_counts(payload["resultSizeBuckets"], "trace report")
            if sum(top_sizes.values()) != payload["toolCallCount"]:
                errors.append("trace result-size buckets disagree with toolCallCount")
            command_counts = {item["name"]: item["count"] for item in payload["commands"]}
            for row in payload["commandResultSizeBuckets"]:
                command = row["command"]
                if command in top_command_sizes:
                    errors.append("trace result-size details repeat a command")
                buckets = size_counts(row["buckets"], f"trace command {command}")
                top_command_sizes[command] = buckets
                if sum(buckets.values()) != command_counts.get(command):
                    errors.append(f"trace command result-size total disagrees: {command}")
            if set(top_command_sizes) != set(command_counts):
                errors.append("trace result-size command set disagrees with commands")
        if sum(item["traceCount"] for item in payload["scenarios"]) != payload["traceCount"]:
            errors.append("trace scenario trace counts do not equal traceCount")
        top_write_buckets = validate_write_latency(
            payload["writeLatency"], payload["traceCount"], "trace report"
        )
        if sum(item["toolCallCount"] for item in payload["scenarios"]) != payload["toolCallCount"]:
            errors.append("trace scenario tool counts do not equal toolCallCount")
        if sum(item["failureCount"] for item in payload["scenarios"]) != payload["failureCount"]:
            errors.append("trace scenario failure counts disagree with the report")
        if sum(item["blockedCount"] for item in payload["scenarios"]) != payload["blockedCount"]:
            errors.append("trace scenario blocked counts disagree with the report")
        if sum(
            item.get("unansweredToolCallCount", 0)
            for item in payload["scenarios"]
        ) != unanswered:
            errors.append("trace scenario unanswered counts disagree with the report")
        scenario_keys: set[tuple[str, str]] = set()
        scenario_size_totals: dict[str, int] = {}
        scenario_command_size_totals: dict[str, dict[str, int]] = {}
        scenario_write_buckets: dict[str, int] = {}
        scenario_write_attempt_count = 0
        scenario_suggestion_totals = {
            field: 0 for field in all_suggestion_mechanism_fields
        }
        top_suggestion_mechanisms = payload.get("suggestionMechanisms")
        scenario_suggestion_presence = [
            "suggestionMechanisms" in item for item in payload["scenarios"]
        ]
        if top_suggestion_mechanisms is not None:
            validate_suggestion_mechanisms(
                top_suggestion_mechanisms,
                sum(
                    item["traceCount"]
                    for item in payload["scenarios"]
                    if item["scenario"] == "suggestion_contention"
                ),
                "trace report",
            )
        if any(scenario_suggestion_presence) and not all(scenario_suggestion_presence):
            errors.append("trace scenarios have incomplete suggestion-mechanism details")
        if payload["scenarios"] and (
            (top_suggestion_mechanisms is not None)
            != all(scenario_suggestion_presence)
        ):
            errors.append("trace report and scenarios disagree on suggestion-mechanism details")
        for scenario in payload["scenarios"]:
            key = (scenario["scenario"], scenario["seat"])
            if key in scenario_keys:
                errors.append("trace report repeats a scenario/seat summary")
            scenario_keys.add(key)
            write_buckets = validate_write_latency(
                scenario["writeLatency"],
                scenario["traceCount"],
                f"trace scenario {scenario['scenario']}:{scenario['seat']}",
            )
            scenario_write_attempt_count += scenario["writeLatency"]["writeAttemptCount"]
            for name, count in write_buckets.items():
                scenario_write_buckets[name] = scenario_write_buckets.get(name, 0) + count
            scenario_suggestion = scenario.get("suggestionMechanisms")
            if scenario_suggestion is not None:
                expected_applicable = (
                    scenario["traceCount"]
                    if scenario["scenario"] == "suggestion_contention"
                    else 0
                )
                validate_suggestion_mechanisms(
                    scenario_suggestion,
                    expected_applicable,
                    f"trace scenario {scenario['scenario']}:{scenario['seat']}",
                )
                for field in all_suggestion_mechanism_fields:
                    scenario_suggestion_totals[field] += scenario_suggestion.get(field, 0)
            scenario_size_presence = [field in scenario for field in size_fields]
            if any(scenario_size_presence) and not all(scenario_size_presence):
                errors.append("trace scenario has incomplete result-size details")
            elif all(scenario_size_presence):
                buckets = size_counts(
                    scenario["resultSizeBuckets"],
                    f"trace scenario {scenario['scenario']}:{scenario['seat']}",
                )
                if sum(buckets.values()) != scenario["toolCallCount"]:
                    errors.append("trace scenario result-size buckets disagree with tool calls")
                for name, count in buckets.items():
                    scenario_size_totals[name] = scenario_size_totals.get(name, 0) + count
                scenario_command_counts = {
                    item["name"]: item["count"] for item in scenario.get("commands", [])
                }
                seen_commands: set[str] = set()
                for row in scenario["commandResultSizeBuckets"]:
                    command = row["command"]
                    if command in seen_commands:
                        errors.append("trace scenario result-size details repeat a command")
                    seen_commands.add(command)
                    command_buckets = size_counts(
                        row["buckets"],
                        f"trace scenario command {command}",
                    )
                    if sum(command_buckets.values()) != scenario_command_counts.get(command):
                        errors.append(
                            f"trace scenario command result-size total disagrees: {command}"
                        )
                    aggregate = scenario_command_size_totals.setdefault(command, {})
                    for name, count in command_buckets.items():
                        aggregate[name] = aggregate.get(name, 0) + count
                if seen_commands != set(scenario_command_counts):
                    errors.append("trace scenario result-size command set disagrees with commands")
            detailed_fields = (
                "commands", "errors", "flags", "unansweredCommands", "sequences"
            )
            detailed = [field in scenario for field in detailed_fields]
            if any(detailed) and not all(detailed):
                errors.append("trace scenario has incomplete command-shape details")
                continue
            if not all(detailed):
                continue
            scenario_command_count = sum(item["count"] for item in scenario["commands"])
            scenario_failure_count = sum(
                item["failureCount"] for item in scenario["commands"]
            )
            scenario_blocked_count = sum(
                item["blockedCount"] for item in scenario["commands"]
            )
            if scenario_command_count != scenario["toolCallCount"]:
                errors.append("trace scenario command counts disagree with tool calls")
            if scenario_failure_count != scenario["failureCount"]:
                errors.append("trace scenario command failures disagree with failures")
            if scenario_blocked_count != scenario["blockedCount"]:
                errors.append("trace scenario command blocked counts disagree with blocked calls")
            if sum(item["count"] for item in scenario["errors"]) != scenario["failureCount"]:
                errors.append("trace scenario error counts disagree with failures")
            if sum(
                item["count"] for item in scenario["unansweredCommands"]
            ) != scenario.get("unansweredToolCallCount", 0):
                errors.append("trace scenario unanswered commands disagree with unanswered calls")
            if sum(item["count"] for item in scenario["sequences"]) > scenario["traceCount"]:
                errors.append("trace scenario sequence counts exceed trace count")
        if all(top_size_presence):
            if scenario_size_totals != top_sizes:
                errors.append("trace scenario result-size buckets disagree with the report")
            if scenario_command_size_totals != top_command_sizes:
                errors.append("trace scenario command result sizes disagree with the report")
        if scenario_write_buckets != top_write_buckets:
            errors.append("trace scenario pre-write buckets disagree with the report")
        if scenario_write_attempt_count != payload["writeLatency"]["writeAttemptCount"]:
            errors.append("trace scenario write-attempt count disagrees with the report")
        if (
            top_suggestion_mechanisms is not None
            and scenario_suggestion_totals != {
                field: top_suggestion_mechanisms.get(field, 0)
                for field in all_suggestion_mechanism_fields
            }
        ):
            errors.append("trace scenario suggestion mechanisms disagree with the report")
        if sum(item["count"] for item in payload["sequences"]) > payload["traceCount"]:
            errors.append("trace sequence counts exceed traceCount")
    elif schema_name == "contention-matrix.schema.json":
        method = payload["method"]
        arms = payload["arms"]
        family_names = [item["name"] for item in method["families"]]
        group_sizes = method["groupSizes"]
        repetitions = method["repetitionsPerCase"]
        expected_keys = {
            (family, group_size)
            for family in family_names
            for group_size in group_sizes
        }
        expected_episode_count = len(expected_keys) * repetitions
        legacy_family_names = [
            "typed-add",
            "suggestion-add",
            "suggestion-reject",
            "suggestion-accept",
            "handoff-add",
        ]
        batch_family_names = [
            "typed-add",
            "suggestion-add",
            "suggestion-batch",
            "suggestion-reject",
            "suggestion-accept",
            "handoff-add",
        ]
        if tuple(family_names) not in {
            tuple(legacy_family_names), tuple(batch_family_names),
        }:
            errors.append("contention family catalog is inconsistent")
        if family_names == batch_family_names:
            if method.get("suggestionsPerBatch") != 4:
                errors.append("contention suggestion batch size is inconsistent")
        elif "suggestionsPerBatch" in method:
            errors.append("legacy contention catalog unexpectedly declares a batch size")
        if group_sizes != sorted(set(group_sizes)):
            errors.append("contention group sizes are not unique and increasing")
        if payload["fixture"]["caseCountPerArm"] != len(expected_keys) * repetitions:
            errors.append("contention fixture case count is inconsistent")
        expected_case_digest = hashlib.sha256(
            "\n".join(
                f"{family}:{group_size}:{repetition}"
                for family in family_names
                for group_size in group_sizes
                for repetition in range(repetitions)
            ).encode("ascii")
        ).hexdigest()
        if payload["fixture"]["caseSetSha256"] != expected_case_digest:
            errors.append("contention fixture case digest is inconsistent")

        indexed_arms: dict[str, dict[tuple[str, int], dict[str, Any]]] = {}
        for label in ("baseline", "candidate"):
            arm = arms[label]
            if arm["episodeCount"] != expected_episode_count:
                errors.append(f"contention {label} episode count is inconsistent")
            indexed: dict[tuple[str, int], dict[str, Any]] = {}
            for case in arm["cases"]:
                key = (case["family"], case["groupSize"])
                if key in indexed:
                    errors.append(f"contention {label} repeats a family/group case")
                indexed[key] = case
                if case["repetitionCount"] != repetitions:
                    errors.append(f"contention {label} repetition count is inconsistent")
                if case["writerIntentCount"] != case["groupSize"] * repetitions:
                    errors.append(f"contention {label} writer-intent count is inconsistent")
                if not (
                    0 <= case["initialSuccessCount"] <= case["finalSuccessCount"]
                    <= case["writerIntentCount"]
                ):
                    errors.append(f"contention {label} success totals are inconsistent")
                if case["mutationCallCount"] != (
                    case["writerIntentCount"] + case["retryCallCount"]
                ):
                    errors.append(f"contention {label} mutation-call total is inconsistent")
                if case["agentVisibleCallCount"] != (
                    case["mutationCallCount"] + case["recoveryReadCount"]
                ):
                    errors.append(f"contention {label} visible-call total is inconsistent")
                if case["retryCallCount"] > case["recoveryReadCount"]:
                    errors.append(f"contention {label} recovery-call total is inconsistent")
                for prefix in ("initial", "final"):
                    histogram = case[f"{prefix}SuccessHistogram"]
                    if sum(histogram.values()) != repetitions:
                        errors.append(
                            f"contention {label} {prefix} histogram count is inconsistent"
                        )
                    if sum(
                        int(value) * count for value, count in histogram.items()
                    ) != case[f"{prefix}SuccessCount"]:
                        errors.append(
                            f"contention {label} {prefix} histogram total is inconsistent"
                        )
                    if any(
                        int(value) > case["groupSize"] for value in histogram
                    ):
                        errors.append(
                            f"contention {label} {prefix} histogram range is inconsistent"
                        )
                if case["visibleConflictEpisodeCount"] > repetitions:
                    errors.append(f"contention {label} conflict episodes are inconsistent")
                if case["visibleConflictEpisodeCount"] > case["visibleConflictCount"]:
                    errors.append(f"contention {label} conflict totals are inconsistent")
                possible_conflict_episodes = sum(
                    count
                    for value, count in case["initialSuccessHistogram"].items()
                    if int(value) < case["groupSize"]
                )
                if case["visibleConflictEpisodeCount"] > possible_conflict_episodes:
                    errors.append(
                        f"contention {label} conflict histogram is inconsistent"
                    )
                if (case["visibleConflictEpisodeCount"] == 0) != (
                    case["visibleConflictCount"] == 0
                ):
                    errors.append(
                        f"contention {label} conflict presence is inconsistent"
                    )
                if sum(case["errorCounts"].values()) != (
                    case["visibleConflictCount"] + case["otherFailureCount"]
                ):
                    errors.append(f"contention {label} error totals are inconsistent")
                if not set(case["errorCounts"]).issubset({
                    "COLLABORATION_PRECONDITION_FAILED",
                    "CONCURRENT_MODIFICATION",
                    "REVISION_CONFLICT",
                    "OTHER_ERROR",
                }):
                    errors.append(f"contention {label} error code is inconsistent")
                if case["durationMs"]["median"] > case["durationMs"]["p95"]:
                    errors.append(f"contention {label} duration percentiles are inconsistent")
                if case["family"] in {
                    "typed-add",
                    "suggestion-add",
                    "suggestion-batch",
                    "suggestion-reject",
                }:
                    expected_case_completion = all(
                        int(value) == case["groupSize"]
                        for value in case["finalSuccessHistogram"]
                    )
                elif case["family"] == "suggestion-accept":
                    expected_case_completion = all(
                        int(value) == 1
                        for value in case["finalSuccessHistogram"]
                    )
                else:
                    expected_case_completion = all(
                        int(value) >= 1
                        for value in case["finalSuccessHistogram"]
                    )
                if case["checks"]["completionPassed"] != expected_case_completion:
                    errors.append(
                        f"contention {label} case completion flag is inconsistent"
                    )
                if case["checks"]["noUnexpectedFailures"] != (
                    case["otherFailureCount"] == 0
                ):
                    errors.append(
                        f"contention {label} unexpected-failure flag is inconsistent"
                    )
                if case["family"] in {"suggestion-accept", "handoff-add"}:
                    if case["recoveryReadCount"] != 0 or case["retryCallCount"] != 0:
                        errors.append(
                            f"contention {label} nonrecoverable calls are inconsistent"
                        )
                    if (
                        case["visibleConflictCount"] + case["otherFailureCount"]
                        != case["writerIntentCount"] - case["finalSuccessCount"]
                    ):
                        errors.append(
                            f"contention {label} nonrecoverable outcomes are inconsistent"
                        )
            if set(indexed) != expected_keys:
                errors.append(f"contention {label} case coverage is inconsistent")
            expected_safety_passed = all(
                all(
                    case["checks"][name]
                    for name in (
                        "documentsValid",
                        "sourcePolicyPassed",
                        "graphIntegrityPassed",
                        "noUnexpectedFailures",
                    )
                )
                for case in arm["cases"]
            )
            expected_completion_passed = all(
                case["checks"]["completionPassed"] for case in arm["cases"]
            )
            if arm["safetyPassed"] != expected_safety_passed:
                errors.append(f"contention {label} safety flag is inconsistent")
            if arm["completionPassed"] != expected_completion_passed:
                errors.append(f"contention {label} completion flag is inconsistent")
            if arm["passed"] != (
                expected_safety_passed and expected_completion_passed
            ):
                errors.append(f"contention {label} pass flag is inconsistent")
            indexed_arms[label] = indexed

        comparisons: dict[tuple[str, int], dict[str, Any]] = {}
        for row in payload["comparison"]:
            key = (row["family"], row["groupSize"])
            if key in comparisons:
                errors.append("contention comparison repeats a family/group case")
            comparisons[key] = row
            baseline = indexed_arms["baseline"].get(key)
            candidate = indexed_arms["candidate"].get(key)
            if baseline is None or candidate is None:
                continue
            expected_deltas = {
                "candidateMinusBaselineFinalSuccesses": (
                    candidate["finalSuccessCount"] - baseline["finalSuccessCount"]
                ),
                "candidateMinusBaselineVisibleConflicts": (
                    candidate["visibleConflictCount"] - baseline["visibleConflictCount"]
                ),
                "candidateMinusBaselineMutationCalls": (
                    candidate["mutationCallCount"] - baseline["mutationCallCount"]
                ),
                "candidateMinusBaselineRecoveryReads": (
                    candidate["recoveryReadCount"] - baseline["recoveryReadCount"]
                ),
                "candidateMinusBaselineAgentVisibleCalls": (
                    candidate["agentVisibleCallCount"]
                    - baseline["agentVisibleCallCount"]
                ),
                "candidateMinusBaselineMedianDurationMs": round(
                    candidate["durationMs"]["median"]
                    - baseline["durationMs"]["median"],
                    3,
                ),
                "candidateMinusBaselineP95DurationMs": round(
                    candidate["durationMs"]["p95"]
                    - baseline["durationMs"]["p95"],
                    3,
                ),
            }
            if any(row[name] != value for name, value in expected_deltas.items()):
                errors.append("contention comparison delta is inconsistent")
        if set(comparisons) != expected_keys:
            errors.append("contention comparison coverage is inconsistent")
        if payload["passed"] != (
            arms["baseline"]["safetyPassed"] and arms["candidate"]["passed"]
        ):
            errors.append("contention matrix pass flag is inconsistent")
    elif schema_name == "concurrency-probe.schema.json":
        fixture = payload["fixture"]
        method = payload["method"]
        arms = payload["arms"]
        if fixture["caseCount"] != method["repetitionsPerArm"]:
            errors.append("concurrency fixture case count is inconsistent")
        for label in ("baseline", "candidate"):
            arm = arms[label]
            if arm["episodeCount"] != method["repetitionsPerArm"]:
                errors.append(f"concurrency {label} episode count is inconsistent")
            histogram = arm["commandCountHistogram"]
            if sum(histogram.values()) != arm["episodeCount"]:
                errors.append(f"concurrency {label} command histogram count is inconsistent")
            if sum(int(count) * frequency for count, frequency in histogram.items()) != arm["commandCount"]:
                errors.append(f"concurrency {label} command histogram total is inconsistent")
            if arm["visibleConflictEpisodeCount"] > arm["episodeCount"]:
                errors.append(f"concurrency {label} conflict episode count is inconsistent")
            if arm["visibleConflictEpisodeCount"] > arm["visibleConflictCount"]:
                errors.append(f"concurrency {label} conflict totals are inconsistent")
            if arm["durationMs"]["median"] > arm["durationMs"]["p95"]:
                errors.append(f"concurrency {label} duration percentiles are inconsistent")
        expected_passed = (
            arms["baseline"]["minimumScore"] == 100
            and arms["baseline"]["safetyPassed"]
            and arms["baseline"]["sourcePreserved"]
            and arms["baseline"]["invalidCommandCount"] == 0
            and arms["candidate"]["minimumScore"] == 100
            and arms["candidate"]["safetyPassed"]
            and arms["candidate"]["sourcePreserved"]
            and arms["candidate"]["invalidCommandCount"] == 0
            and arms["candidate"]["visibleConflictCount"] == 0
            and arms["candidate"]["commandCountHistogram"]
            == {str(method["expectedAgentVisibleCallsPerEpisode"]): method["repetitionsPerArm"]}
        )
        comparison = payload["comparison"]
        if comparison["candidateMinusBaselineVisibleConflicts"] != (
            arms["candidate"]["visibleConflictCount"] - arms["baseline"]["visibleConflictCount"]
        ):
            errors.append("concurrency visible-conflict delta is inconsistent")
        if comparison["candidateMinusBaselineCommandCount"] != (
            arms["candidate"]["commandCount"] - arms["baseline"]["commandCount"]
        ):
            errors.append("concurrency command-count delta is inconsistent")
        if payload["passed"] != expected_passed:
            errors.append("concurrency pass flag is inconsistent")
    elif schema_name == "suggestion-convergence-probe.schema.json":
        fixture = payload["fixture"]
        method = payload["method"]
        arms = payload["arms"]
        comparison = payload["comparison"]
        expected_samples = method["repetitionsPerDelay"] * len(method["delaysMs"])
        if method["delaysMs"] != sorted(method["delaysMs"]):
            errors.append("suggestion convergence delays are not increasing")
        if fixture["sampleCountPerArm"] != expected_samples:
            errors.append("suggestion convergence fixture sample count is inconsistent")
        case_material = [
            f"{delay}:{repetition}"
            for delay in method["delaysMs"]
            for repetition in range(method["repetitionsPerDelay"])
        ]
        expected_case_digest = hashlib.sha256(
            "\n".join(case_material).encode("ascii")
        ).hexdigest()
        if fixture["caseSetSha256"] != expected_case_digest:
            errors.append("suggestion convergence case-set digest is inconsistent")
        for label in ("baseline", "candidate"):
            arm = arms[label]
            if arm["sampleCount"] != expected_samples:
                errors.append(f"suggestion convergence {label} sample count is inconsistent")
            if arm["completedCount"] > arm["sampleCount"]:
                errors.append(f"suggestion convergence {label} completion count is inconsistent")
            delay_values = [item["delayMs"] for item in arm["byDelay"]]
            if delay_values != method["delaysMs"]:
                errors.append(f"suggestion convergence {label} delay coverage is inconsistent")
            if sum(item["sampleCount"] for item in arm["byDelay"]) != arm["sampleCount"]:
                errors.append(f"suggestion convergence {label} delay samples are inconsistent")
            call_summaries = [
                (arm["convergenceCalls"], arm["sampleCount"]),
                *[
                    (item["convergenceCalls"], item["sampleCount"])
                    for item in arm["byDelay"]
                ],
            ]
            for summary, expected_count in call_summaries:
                histogram_count = sum(summary["histogram"].values())
                histogram_total = sum(
                    int(count) * frequency
                    for count, frequency in summary["histogram"].items()
                )
                if histogram_count != expected_count:
                    errors.append(f"suggestion convergence {label} call histogram is inconsistent")
                if histogram_total != summary["total"]:
                    errors.append(f"suggestion convergence {label} call total is inconsistent")
                expected_summary = _histogram_numeric_summary(summary["histogram"])
                if any(
                    not _close(summary[field], expected_summary[field])
                    for field in ("total", "min", "median", "p95", "max")
                ):
                    errors.append(
                        f"suggestion convergence {label} call summary is inconsistent"
                    )
            aggregate_histogram = Counter()
            for item in arm["byDelay"]:
                aggregate_histogram.update(item["convergenceCalls"]["histogram"])
            if dict(aggregate_histogram) != arm["convergenceCalls"]["histogram"]:
                errors.append(
                    f"suggestion convergence {label} aggregate histogram is inconsistent"
                )
            if sum(
                item["convergenceCalls"]["total"] for item in arm["byDelay"]
            ) != arm["convergenceCalls"]["total"]:
                errors.append(f"suggestion convergence {label} delay call totals are inconsistent")
            duration = arm["durationMs"]
            if not duration["min"] <= duration["median"] <= duration["p95"] <= duration["max"]:
                errors.append(f"suggestion convergence {label} duration percentiles are inconsistent")
        baseline_calls = arms["baseline"]["convergenceCalls"]["total"]
        candidate_calls = arms["candidate"]["convergenceCalls"]["total"]
        if comparison["candidateMinusBaselineConvergenceCalls"] != (
            candidate_calls - baseline_calls
        ):
            errors.append("suggestion convergence call delta is inconsistent")
        if not _close(
            comparison["candidateToBaselineConvergenceCallRatio"],
            candidate_calls / baseline_calls,
        ):
            errors.append("suggestion convergence call ratio is inconsistent")
        if [item["delayMs"] for item in comparison["byDelay"]] != method["delaysMs"]:
            errors.append("suggestion convergence comparison delay coverage is inconsistent")
        for item in comparison["byDelay"]:
            delay = item["delayMs"]
            baseline = next(value for value in arms["baseline"]["byDelay"] if value["delayMs"] == delay)
            candidate = next(value for value in arms["candidate"]["byDelay"] if value["delayMs"] == delay)
            if not _close(
                item["candidateMinusBaselineMedianCalls"],
                candidate["convergenceCalls"]["median"]
                - baseline["convergenceCalls"]["median"],
            ):
                errors.append("suggestion convergence median call delta is inconsistent")
            if not _close(
                item["candidateMinusBaselineMedianDurationMs"],
                candidate["durationMs"]["median"] - baseline["durationMs"]["median"],
            ):
                errors.append("suggestion convergence median duration delta is inconsistent")
        expected_passed = (
            all(
                arm["completedCount"] == arm["sampleCount"]
                and arm["writerFailureCount"] == 0
                and arm["convergenceFailureCount"] == 0
                and arm["documentValid"]
                and arm["graphIntegrityPassed"]
                and arm["sourcePreserved"]
                for arm in arms.values()
            )
            and arms["candidate"]["convergenceCalls"]["histogram"]
            == {"1": expected_samples}
            and all(
                item["convergenceCalls"]["min"] >= 2
                for item in arms["baseline"]["byDelay"]
            )
            and baseline_calls > candidate_calls
        )
        if payload["passed"] != expected_passed:
            errors.append("suggestion convergence pass flag is inconsistent")
    elif schema_name == "wide-directory-probe.schema.json":
        fixture = payload["fixture"]
        method = payload["method"]
        arms = payload["arms"]
        comparison = payload["comparison"]
        if fixture["totalContributionCount"] != (
            fixture["fileCount"] * fixture["contributionsPerFile"]
        ):
            errors.append("wide-directory fixture contribution total is inconsistent")
        expected_passed = True
        for label in ("baseline", "candidate"):
            arm = arms[label]
            if arm["sampleCount"] != method["roundCountPerArm"]:
                errors.append(f"wide-directory {label} sample count is inconsistent")
            duration = arm["durationMs"]
            if duration["median"] > duration["p95"]:
                errors.append(f"wide-directory {label} duration percentiles are inconsistent")
            byte_counts = arm["stdoutBytes"]
            if not byte_counts["min"] <= byte_counts["median"] <= byte_counts["max"]:
                errors.append(f"wide-directory {label} byte summary is inconsistent")
            expected_passed = (
                expected_passed
                and arm["responseDeterministic"]
                and arm["responseUsable"]
                and arm["sourcePreserved"]
            )
        baseline_bytes = arms["baseline"]["stdoutBytes"]["median"]
        candidate_bytes = arms["candidate"]["stdoutBytes"]["median"]
        if comparison["candidateMinusBaselineBytes"] != candidate_bytes - baseline_bytes:
            errors.append("wide-directory byte delta is inconsistent")
        if not _close(
            comparison["candidateToBaselineByteRatio"],
            candidate_bytes / baseline_bytes,
        ):
            errors.append("wide-directory byte ratio is inconsistent")
        baseline_duration = arms["baseline"]["durationMs"]["median"]
        candidate_duration = arms["candidate"]["durationMs"]["median"]
        if not _close(
            comparison["candidateToBaselineMedianDurationRatio"],
            candidate_duration / baseline_duration,
        ):
            errors.append("wide-directory duration ratio is inconsistent")
        if payload["passed"] != expected_passed:
            errors.append("wide-directory pass flag is inconsistent")
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
        if payload["agentProcessCount"] != sum(item["agentProcessCount"] for item in jobs):
            errors.append("execution plan agent-process total is inconsistent")
        job_ids = [item["id"] for item in jobs]
        if len(job_ids) != len(set(job_ids)):
            errors.append("execution plan contains duplicate job ids")
        candidates = {payload["baselineCandidate"], payload["candidate"]}
        episodes: dict[str, list[dict[str, Any]]] = {}
        for job in jobs:
            try:
                topology = planned_topology(payload["controlProfile"], job["roles"])
            except ValueError as error:
                errors.append(str(error))
            else:
                if any(job[field] != topology[field] for field in topology):
                    errors.append(f"execution job topology is inconsistent: {job['ordinal']}")
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
            immutable = (
                "scenario", "repetition", "fingerprint", "roles",
                "agentProcessCount", "traceSeats", "phasePolicy",
            )
            if any(ordered[0][field] != ordered[1][field] for field in immutable):
                errors.append(f"execution episode pair metadata differs: {episode_id[:200]}")
            first = ordered[0]["candidateID"]
            if first in first_positions:
                first_positions[first] += 1
        if abs(first_positions[payload["baselineCandidate"]] - first_positions[payload["candidate"]]) > 1:
            errors.append("execution plan candidate-first order is not counterbalanced")
    elif schema_name == "crossover-prime-plan.schema.json":
        if payload["id"] != submission_identifier(payload):
            errors.append("crossover Prime plan id does not match its canonical content")
        if payload["developmentCases"] != (payload["taskSet"] == "public-development-v1"):
            errors.append("crossover Prime plan case partition is inconsistent")
        jobs = payload["jobs"]
        if payload["jobCount"] != len(jobs):
            errors.append("crossover Prime plan jobCount does not equal jobs length")
        if [item["ordinal"] for item in jobs] != list(range(1, len(jobs) + 1)):
            errors.append("crossover Prime plan ordinals are not contiguous")
        if payload["agentProcessCount"] != sum(item["agentProcessCount"] for item in jobs):
            errors.append("crossover Prime plan agent-process total is inconsistent")
        job_ids = [item["id"] for item in jobs]
        if len(job_ids) != len(set(job_ids)):
            errors.append("crossover Prime plan contains duplicate job ids")
        limits = payload["limits"]
        pricing = payload["pricing"]
        per_cell_cap = payload["budget"]["liveProxyCapPerCellUSD"]
        episodes: dict[str, list[dict[str, Any]]] = {}
        for job in jobs:
            if job["candidateID"] != payload["candidate"]["id"]:
                errors.append(f"crossover Prime job names another candidate: {job['ordinal']}")
            expected_episode = (
                f"{job['scenario']}:{job['repetition']}:"
                f"{job['fingerprint'][:12]}"
            )
            if job["episodeID"] != expected_episode:
                errors.append(f"crossover Prime job episode identity is inconsistent: {job['ordinal']}")
            identity = {
                "schema": "urn:marginbench:crossover-prime-job:v1",
                "ordinal": job["ordinal"],
                "episodeID": job["episodeID"],
                "candidateID": job["candidateID"],
                "controlProfile": job["controlProfile"],
            }
            if job["id"] != submission_identifier(identity):
                errors.append(f"crossover Prime job id is inconsistent: {job['ordinal']}")
            try:
                topology = planned_topology(job["controlProfile"], job["roles"])
            except ValueError as error:
                errors.append(str(error))
            else:
                if any(job[field] != topology[field] for field in topology):
                    errors.append(f"crossover Prime job topology is inconsistent: {job['ordinal']}")
            attempts = (
                job["agentProcessCount"]
                * per_agent_compute_multiplier(job["controlProfile"], job["roles"])
                * limits["maxTurns"]
                * limits["upstreamAttemptsPerTurn"]
            )
            contract = round(attempts * (
                limits["inputTokenCeilingPerCall"]
                * pricing["inputPricePerMillion"]
                / 1_000_000
                + (
                    limits["maxTokensPerCall"]
                    + (limits.get("providerReasoningTokenCeiling") or 0)
                    + limits["providerResponseTokenAllowance"]
                )
                * pricing["outputPricePerMillion"]
                / 1_000_000
                + pricing["billingOverheadUSDPerCall"]
            ), 6)
            expected_live_cap = round(min(contract, per_cell_cap), 6)
            if not _close(contract, job["contractMaximumCostUSD"]):
                errors.append(
                    f"crossover Prime job contract bound is inconsistent: {job['ordinal']}"
                )
            if not _close(expected_live_cap, job["liveProxyCapUSD"]):
                errors.append(
                    f"crossover Prime job live proxy cap is inconsistent: {job['ordinal']}"
                )
            episodes.setdefault(job["episodeID"], []).append(job)
        for episode_id, pair in episodes.items():
            if len(pair) != 2:
                errors.append(
                    f"crossover Prime episode does not contain exactly two cells: {episode_id[:200]}"
                )
                continue
            if {item["controlProfile"] for item in pair} != {
                "role-separated-margin-only-v1",
                "single-agent-margin-v1",
            }:
                errors.append(
                    f"crossover Prime episode does not cover both topologies: {episode_id[:200]}"
                )
            immutable = ("scenario", "repetition", "fingerprint", "roles")
            if any(pair[0][field] != pair[1][field] for field in immutable):
                errors.append(f"crossover Prime episode pair metadata differs: {episode_id[:200]}")
        expected_maximum = round(sum(float(item["liveProxyCapUSD"]) for item in jobs), 6)
        if not _close(expected_maximum, payload["budget"]["estimatedMaximumCostUSD"]):
            errors.append("crossover Prime aggregate cost does not equal cell caps")
        expected_contract = round(
            sum(float(item["contractMaximumCostUSD"]) for item in jobs),
            6,
        )
        if not _close(expected_contract, payload["budget"]["contractMaximumCostUSD"]):
            errors.append("crossover Prime aggregate contract bound is inconsistent")
        if (
            payload["budget"]["estimatedMaximumCostUSD"]
            > payload["budget"]["hardStudyCapUSD"] + 0.000001
        ):
            errors.append("crossover Prime estimate exceeds its hard study cap")
    elif schema_name == "crossover-prime-completion.schema.json":
        if payload["jobCount"] % 2 != 0:
            errors.append("crossover Prime completion has an odd cell count")
        if payload["sampleSizeSufficient"] != (payload["jobCount"] // 2 >= 20):
            errors.append("crossover Prime completion sample-size status is inconsistent")
        if payload["allSafe"] != (payload["directionalConclusion"] != "unsafe"):
            errors.append("crossover Prime completion safety conclusion is inconsistent")
    elif schema_name == "prime-study-plan.schema.json":
        if payload["id"] != submission_identifier(payload):
            errors.append("Prime study plan id does not match its canonical content")
        if payload["baseline"]["id"] == payload["candidate"]["id"]:
            errors.append("Prime study plan must identify two distinct candidates")
        jobs = payload["jobs"]
        if payload["jobCount"] != len(jobs):
            errors.append("Prime study plan jobCount does not equal jobs length")
        if [item["ordinal"] for item in jobs] != list(range(len(jobs))):
            errors.append("Prime study plan ordinals are not contiguous")
        if payload["roleProcessCount"] != sum(len(item["roles"]) for item in jobs):
            errors.append("Prime study plan role-process total is inconsistent")
        if payload["agentProcessCount"] != sum(item["agentProcessCount"] for item in jobs):
            errors.append("Prime study plan agent-process total is inconsistent")
        job_ids = [item["id"] for item in jobs]
        if len(job_ids) != len(set(job_ids)):
            errors.append("Prime study plan contains duplicate job ids")
        candidates = {payload["baseline"]["id"], payload["candidate"]["id"]}
        if any(item["candidateID"] not in candidates for item in jobs):
            errors.append("Prime study plan job names an unknown candidate")
        limits = payload["limits"]
        pricing = payload["pricing"]
        requested_live_cap = payload["budget"]["requestedLiveProxyCapPerJobUSD"]
        for job in jobs:
            try:
                topology = planned_topology(payload["controlProfile"], job["roles"])
            except ValueError as error:
                errors.append(str(error))
            else:
                if any(job[field] != topology[field] for field in topology):
                    errors.append(f"Prime study job topology is inconsistent: {job['ordinal']}")
            attempts = (
                job["agentProcessCount"]
                * per_agent_compute_multiplier(payload["controlProfile"], job["roles"])
                * limits["maxTurns"]
                * limits["upstreamAttemptsPerTurn"]
            )
            contract = round(attempts * (
                limits["inputTokenCeilingPerCall"]
                * pricing["inputPricePerMillion"]
                / 1_000_000
                + (
                    limits["maxTokensPerCall"]
                    + (limits.get("providerReasoningTokenCeiling") or 0)
                    + limits.get("providerResponseTokenAllowance", 0)
                )
                * pricing["outputPricePerMillion"]
                / 1_000_000
                + pricing["billingOverheadUSDPerCall"]
            ), 6)
            expected_live_cap = round(min(
                contract,
                requested_live_cap if requested_live_cap is not None else contract,
            ), 6)
            if not _close(contract, job["contractMaximumCostUSD"]):
                errors.append(
                    f"Prime study job contract bound is inconsistent: {job['ordinal']}"
                )
            if not _close(expected_live_cap, job["liveProxyCapUSD"]):
                errors.append(
                    f"Prime study job live proxy cap is inconsistent: {job['ordinal']}"
                )
            if not _close(job["liveProxyCapUSD"], job["estimatedMaximumCostUSD"]):
                errors.append(
                    f"Prime study job admission bound does not apply its proxy cap: {job['ordinal']}"
                )
        expected_maximum = round(
            sum(float(item["estimatedMaximumCostUSD"]) for item in jobs),
            6,
        )
        if not _close(expected_maximum, payload["budget"]["estimatedMaximumCostUSD"]):
            errors.append("Prime study plan aggregate cost does not equal job bounds")
        expected_contract = round(
            sum(float(item["contractMaximumCostUSD"]) for item in jobs),
            6,
        )
        if not _close(expected_contract, payload["budget"]["contractMaximumCostUSD"]):
            errors.append("Prime study plan aggregate contract bound is inconsistent")
        if (
            payload["budget"]["estimatedMaximumCostUSD"]
            > payload["budget"]["hardAdmissionCapUSD"] + 0.000001
        ):
            errors.append("Prime study plan estimate exceeds its hard admission cap")
    elif schema_name == "prime-study-progress.schema.json":
        if payload["completedJobs"] > payload["jobCount"]:
            errors.append("Prime study progress exceeds its job total")
        if "status" in payload and (
            payload["completedJobs"] >= payload["jobCount"]
            or payload["nextOrdinal"] != payload["completedJobs"]
        ):
            errors.append("paused Prime study progress has an inconsistent next job")
    elif schema_name == "submission.schema.json":
        if payload["id"] != submission_identifier(payload):
            errors.append("submission id does not match its canonical manifest")
        if payload["baseline"]["id"] == payload["candidate"]["id"]:
            errors.append("submission must identify two distinct candidates")
        references = [
            payload["baseline"],
            payload["candidate"],
            payload["studyPlan"],
            payload["executionPlan"],
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
