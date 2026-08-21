from __future__ import annotations

import json
import tempfile
import threading
import unittest
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from marginbench.schema import canonical_json
from marginbench.validation import validate_bytes
from provider_contract_probe import build_plan, execute_probe
from prime_pilot import load_provider_contract_receipt


class ProviderContractProbeTests(unittest.TestCase):
    @staticmethod
    def _plan() -> dict:
        return build_plan(
            model="qwen/qwen3.7-flash",
            visible_token_ceiling=16,
            reasoning_token_ceiling=None,
            reasoning_token_ceiling_source=None,
            response_token_allowance=10,
            max_request_bytes=4_096,
            template_token_allowance=256,
            input_token_ceiling=1_000_000,
            input_token_ceiling_source="https://example.invalid/input-contract",
            input_price_per_million=0.03,
            output_price_per_million=0.13,
            pricing_source="https://example.invalid/pricing",
            billing_overhead_usd_per_call=0.0002,
            max_cost_usd=0.001,
            minimum_wallet_reserve_usd=190,
            timeout_seconds=5,
            minimum_start_interval_seconds=300,
        )

    def test_plan_is_schema_checked_and_prices_every_possible_token(self) -> None:
        plan = self._plan()
        self.assertEqual(plan["limits"]["reasoningTokenCeiling"], 4_000)
        self.assertEqual(plan["limits"]["responseTokenAllowance"], 10)
        self.assertLessEqual(
            plan["budget"]["maximumReservedCostUSD"],
            plan["budget"]["hardCapUSD"],
        )
        self.assertTrue(validate_bytes(canonical_json(plan))["valid"])

        altered = json.loads(json.dumps(plan))
        altered["budget"]["maximumReservedCostUSD"] = 0
        receipt = validate_bytes(canonical_json(altered))
        self.assertFalse(receipt["valid"])
        self.assertTrue(any("maximum reservation" in error for error in receipt["errors"]))

    def test_probe_forwards_exact_reasoning_cap_without_publishing_response(self) -> None:
        observed: list[dict] = []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, format: str, *args: object) -> None:
                return

            def do_POST(self) -> None:  # noqa: N802
                length = int(self.headers.get("content-length", "0"))
                observed.append(json.loads(self.rfile.read(length)))
                response = json.dumps({
                    "id": "probe",
                    "choices": [{"message": {"role": "assistant", "content": "ready"}}],
                    "usage": {
                        "prompt_tokens": 12,
                        "completion_tokens": 50,
                        "completion_tokens_details": {"reasoning_tokens": 30},
                    },
                }).encode("utf-8")
                self.send_response(200)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(response)))
                self.end_headers()
                self.wfile.write(response)

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            host, port = server.server_address[:2]
            result = execute_probe(
                self._plan(),
                upstream_base_url=f"http://{host}:{port}/api/v1",
                upstream_api_key="test-secret",
            )
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)

        self.assertEqual(len(observed), 1)
        self.assertEqual(observed[0]["thinking_budget"], 4_000)
        self.assertEqual(observed[0]["max_tokens"], 16)
        self.assertEqual(result["status"], "passed")
        self.assertEqual(result["automaticRetryCount"], 0)
        self.assertNotIn("choices", result["observed"])
        self.assertNotIn("content", canonical_json(result).decode("utf-8"))
        self.assertTrue(validate_bytes(canonical_json(result))["valid"])

    def test_provider_rejection_is_censored_infrastructure_evidence(self) -> None:
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, format: str, *args: object) -> None:
                return

            def do_POST(self) -> None:  # noqa: N802
                length = int(self.headers.get("content-length", "0"))
                self.rfile.read(length)
                response = b'{"error":{"message":"private provider detail"}}'
                self.send_response(400)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(response)))
                self.end_headers()
                self.wfile.write(response)

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            host, port = server.server_address[:2]
            result = execute_probe(
                self._plan(),
                upstream_base_url=f"http://{host}:{port}/api/v1",
                upstream_api_key="test-secret",
            )
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)

        self.assertEqual(result["status"], "infrastructure_error")
        self.assertEqual(result["infrastructureCodes"], ["PROVIDER_CONTRACT_REJECTED"])
        self.assertNotIn("private provider detail", canonical_json(result).decode("utf-8"))
        self.assertTrue(validate_bytes(canonical_json(result))["valid"])

    def test_only_fresh_matching_wallet_observed_receipt_can_admit_a_study(self) -> None:
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, format: str, *args: object) -> None:
                return

            def do_POST(self) -> None:  # noqa: N802
                length = int(self.headers.get("content-length", "0"))
                self.rfile.read(length)
                response = json.dumps({
                    "choices": [{"message": {"content": "ready"}}],
                    "usage": {"prompt_tokens": 8, "completion_tokens": 9},
                }).encode("utf-8")
                self.send_response(200)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(response)))
                self.end_headers()
                self.wfile.write(response)

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            host, port = server.server_address[:2]
            result = execute_probe(
                self._plan(),
                upstream_base_url=f"http://{host}:{port}/api/v1",
                upstream_api_key="test-secret",
            )
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
        result["wallet"] = {
            "observationScope": "account-wide",
            "debitAttribution": "unattributed",
            "afterAvailable": True,
            "observedDebitUSD": 0.0001,
        }
        raw = canonical_json(result) + b"\n"
        self.assertTrue(validate_bytes(raw)["valid"])
        with tempfile.TemporaryDirectory(prefix="marginbench-provider-receipt-") as temporary:
            receipt_path = Path(temporary) / "receipt.json"
            receipt_path.write_bytes(raw)
            digest = load_provider_contract_receipt(
                receipt_path,
                model="qwen/qwen3.7-flash",
                reasoning_token_ceiling=4_000,
                reasoning_token_ceiling_source=(
                    "https://help.aliyun.com/en/model-studio/"
                    "qwen-api-via-openai-chat-completions"
                ),
            )
            self.assertEqual(len(digest), 64)
            with self.assertRaisesRegex(ValueError, "does not prove"):
                load_provider_contract_receipt(
                    receipt_path,
                    model="qwen/qwen3.7-flash",
                    reasoning_token_ceiling=4_001,
                    reasoning_token_ceiling_source=(
                        "https://help.aliyun.com/en/model-studio/"
                        "qwen-api-via-openai-chat-completions"
                    ),
                )
            stale = json.loads(json.dumps(result))
            stale["startedAt"] = "2000-01-01T00:00:00Z"
            stale_path = Path(temporary) / "stale.json"
            stale_path.write_bytes(canonical_json(stale) + b"\n")
            with self.assertRaisesRegex(ValueError, "does not prove"):
                load_provider_contract_receipt(
                    stale_path,
                    model="qwen/qwen3.7-flash",
                    reasoning_token_ceiling=4_000,
                    reasoning_token_ceiling_source=(
                        "https://help.aliyun.com/en/model-studio/"
                        "qwen-api-via-openai-chat-completions"
                    ),
                )


if __name__ == "__main__":
    unittest.main()
