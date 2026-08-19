PROJECT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BUILD_DEVELOPER_DIR ?= /Library/Developer/CommandLineTools
TEST_DEVELOPER_DIR ?=
SCRATCH_ROOT ?= $(PROJECT_DIR)/.build/toolchains
BUILD_SCRATCH_PATH ?= $(SCRATCH_ROOT)/command-line-tools
TEST_SCRATCH_PATH ?= $(SCRATCH_ROOT)/xcode-15.4
OUTPUT_DIR ?= $(PROJECT_DIR)/build

.PHONY: debug test test-linux check-version marginbench-test marginbench-audit marginbench-preflight marginbench-control-preflight marginbench-neutral-preflight marginbench-remote-plan marginbench-linux-binary marginbench-package release package package-linux installer install smoke benchmark benchmark-matrix eval eval-preflight eval-collaboration clean

check-version:
	"$(PROJECT_DIR)/Scripts/check-version.sh"

debug:
	DEVELOPER_DIR="$(BUILD_DEVELOPER_DIR)" \
	MARGIN_SWIFT_SCRATCH_PATH="$(BUILD_SCRATCH_PATH)" \
	MARGIN_BUILD_OUTPUT_DIR="$(OUTPUT_DIR)" \
		"$(PROJECT_DIR)/Scripts/build-app.sh" debug

test:
	MARGIN_TEST_DEVELOPER_DIR="$(TEST_DEVELOPER_DIR)" \
	MARGIN_TEST_SCRATCH_PATH="$(TEST_SCRATCH_PATH)" \
		"$(PROJECT_DIR)/Scripts/run-tests.sh"

test-linux:
	"$(PROJECT_DIR)/Scripts/test-linux.sh"

marginbench-test: release
	PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$(PROJECT_DIR)/Evals/marginbench" \
		python3 -m unittest discover -s "$(PROJECT_DIR)/Evals/marginbench/tests" -p 'test_*.py'
	PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$(PROJECT_DIR)/Evals/marginbench" \
		"$(HOME)/.local/share/uv/tools/prime/bin/python" -m unittest discover \
		-s "$(PROJECT_DIR)/Evals/marginbench/tests" -p 'test_*.py'
	PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$(PROJECT_DIR)/Evals/marginbench" \
		python3 -m marginbench.cli self-test --margin-bin "$(OUTPUT_DIR)/margin"
	PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$(PROJECT_DIR)/Evals/marginbench" \
		python3 -m marginbench.cli neutral-feasibility
	$(MAKE) marginbench-neutral-preflight
	$(MAKE) marginbench-audit

marginbench-audit:
	@for bundle in "$(PROJECT_DIR)"/Evals/marginbench/results/crossover/v*; do \
		[ -d "$$bundle" ] || continue; \
		PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$(PROJECT_DIR)/Evals/marginbench" \
			python3 -m marginbench.cli audit-crossover "$$bundle" || exit $$?; \
	done
	@for submission in "$(PROJECT_DIR)"/Evals/marginbench/results/candidate-studies/*/submission.json; do \
		[ -f "$$submission" ] || continue; \
		PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$(PROJECT_DIR)/Evals/marginbench" \
			python3 -m marginbench.cli submission verify "$$submission" || exit $$?; \
	done

marginbench-linux-binary:
	"$(PROJECT_DIR)/Scripts/build-marginbench-linux.sh" amd64 arm64

marginbench-package:
	"$(PROJECT_DIR)/Scripts/package-marginbench.sh"

marginbench-preflight: release
	PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$(PROJECT_DIR)/Evals/marginbench" \
		"$(PROJECT_DIR)/Evals/marginbench/preflight.py" --margin-bin "$(OUTPUT_DIR)/margin"
	PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$(PROJECT_DIR)/Evals/marginbench" \
		"$(PROJECT_DIR)/Evals/marginbench/preflight.py" --margin-bin "$(OUTPUT_DIR)/margin" --server

marginbench-control-preflight: release
	PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$(PROJECT_DIR)/Evals/marginbench" \
		"$(PROJECT_DIR)/Evals/marginbench/preflight.py" --margin-bin "$(OUTPUT_DIR)/margin" \
		--control-profile single-agent-margin-v1
	PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$(PROJECT_DIR)/Evals/marginbench" \
		"$(PROJECT_DIR)/Evals/marginbench/preflight.py" --margin-bin "$(OUTPUT_DIR)/margin" \
		--control-profile single-agent-margin-v1 --server

marginbench-neutral-preflight:
	mkdir -p "$(OUTPUT_DIR)/benchmarks"
	PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$(PROJECT_DIR)/Evals/marginbench" \
		python3 -m marginbench.cli neutral-prompt-audit \
		> "$(OUTPUT_DIR)/benchmarks/neutral-prompt-audit.json"
	PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$(PROJECT_DIR)/Evals/marginbench" \
		python3 -m marginbench.cli validate \
		"$(OUTPUT_DIR)/benchmarks/neutral-prompt-audit.json" > /dev/null
	PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$(PROJECT_DIR)/Evals/marginbench" \
		"$(HOME)/.local/share/uv/tools/prime/bin/python" -m marginbench.cli \
		neutral-served-preflight > "$(OUTPUT_DIR)/benchmarks/neutral-served-preflight.json"
	PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$(PROJECT_DIR)/Evals/marginbench" \
		python3 -m marginbench.cli validate \
		"$(OUTPUT_DIR)/benchmarks/neutral-served-preflight.json" > /dev/null
	PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$(PROJECT_DIR)/Evals/marginbench" \
		"$(HOME)/.local/share/uv/tools/prime/bin/python" -m marginbench.cli \
		neutral-isolation-preflight \
		> "$(OUTPUT_DIR)/benchmarks/neutral-isolation-preflight.json"
	PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$(PROJECT_DIR)/Evals/marginbench" \
		python3 -m marginbench.cli validate \
		"$(OUTPUT_DIR)/benchmarks/neutral-isolation-preflight.json" > /dev/null
	PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$(PROJECT_DIR)/Evals/marginbench" \
		"$(HOME)/.local/share/uv/tools/prime/bin/python" -m marginbench.cli \
		neutral-production-preflight \
		> "$(OUTPUT_DIR)/benchmarks/neutral-production-preflight.json"
	PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$(PROJECT_DIR)/Evals/marginbench" \
		python3 -m marginbench.cli validate \
		"$(OUTPUT_DIR)/benchmarks/neutral-production-preflight.json" > /dev/null
	PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$(PROJECT_DIR)/Evals/marginbench" \
		python3 -m marginbench.cli efficiency-report \
		"$(OUTPUT_DIR)/benchmarks/neutral-served-preflight.json" \
		"$(PROJECT_DIR)/Evals/marginbench/results/crossover/v17/cells/0001-parallel-shards-role-5cdfb0a164.run.json" \
		"$(PROJECT_DIR)/Evals/marginbench/results/crossover/v17/cells/0002-parallel-shards-continuing-422c21b182.run.json" \
			"$(PROJECT_DIR)/Evals/marginbench/results/representation/v1/plain-parallel-shards-r0.run.json" \
			"$(PROJECT_DIR)/Evals/marginbench/results/representation/v1/plain-parallel-shards-r0-v2.run.json" \
			"$(PROJECT_DIR)/Evals/marginbench/results/representation/v1/handoff-r2-margin-v17.run.json" \
			"$(PROJECT_DIR)/Evals/marginbench/results/representation/v1/handoff-r2-plain-v2.run.json" \
			"$(PROJECT_DIR)/Evals/marginbench/results/representation/v1/handoff-r3-margin-v17.run.json" \
			"$(PROJECT_DIR)/Evals/marginbench/results/representation/v1/handoff-r3-plain-v2.run.json" \
			> "$(OUTPUT_DIR)/benchmarks/efficiency-report.json"
	PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$(PROJECT_DIR)/Evals/marginbench" \
		python3 -m marginbench.cli validate \
		"$(OUTPUT_DIR)/benchmarks/efficiency-report.json" > /dev/null

marginbench-remote-plan:
	PYTHONDONTWRITEBYTECODE=1 \
		"$(PROJECT_DIR)/Evals/marginbench/remote_runtime_probe.py" \
		--margin-bin "$(PROJECT_DIR)/Evals/marginbench/marginbench/bin/margin-linux-x86_64"

release:
	DEVELOPER_DIR="$(BUILD_DEVELOPER_DIR)" \
	MARGIN_SWIFT_SCRATCH_PATH="$(BUILD_SCRATCH_PATH)" \
	MARGIN_BUILD_OUTPUT_DIR="$(OUTPUT_DIR)" \
		"$(PROJECT_DIR)/Scripts/build-app.sh" release

package: release
	MARGIN_BUILD_OUTPUT_DIR="$(OUTPUT_DIR)" \
		"$(PROJECT_DIR)/Scripts/package-release.sh"
	MARGIN_BUILD_OUTPUT_DIR="$(OUTPUT_DIR)" \
		"$(PROJECT_DIR)/Scripts/package-installer.sh"

package-linux:
	MARGIN_BUILD_OUTPUT_DIR="$(OUTPUT_DIR)" \
		"$(PROJECT_DIR)/Scripts/package-linux-release.sh" amd64 arm64

installer: release
	MARGIN_BUILD_OUTPUT_DIR="$(OUTPUT_DIR)" \
		"$(PROJECT_DIR)/Scripts/package-installer.sh"

install: release
	MARGIN_BUILD_OUTPUT_DIR="$(OUTPUT_DIR)" \
		"$(PROJECT_DIR)/Scripts/install.sh"

smoke: release
	DEVELOPER_DIR="$(BUILD_DEVELOPER_DIR)" \
	MARGIN_BUILD_OUTPUT_DIR="$(OUTPUT_DIR)" \
	MARGIN_PERFORMANCE_SCRATCH_PATH="$(PROJECT_DIR)/.build/performance" \
		"$(PROJECT_DIR)/Scripts/smoke-test.sh"

benchmark: release
	DEVELOPER_DIR="$(BUILD_DEVELOPER_DIR)" \
	MARGIN_BUILD_OUTPUT_DIR="$(OUTPUT_DIR)" \
	MARGIN_PERFORMANCE_SCRATCH_PATH="$(PROJECT_DIR)/.build/performance" \
		"$(PROJECT_DIR)/Scripts/benchmark-performance.sh"

benchmark-matrix: release
	DEVELOPER_DIR="$(BUILD_DEVELOPER_DIR)" \
	MARGIN_BUILD_OUTPUT_DIR="$(OUTPUT_DIR)" \
	MARGIN_PERFORMANCE_SCRATCH_PATH="$(PROJECT_DIR)/.build/performance" \
		"$(PROJECT_DIR)/Scripts/benchmark-startup-matrix.sh"

eval: release
	PYTHONDONTWRITEBYTECODE=1 \
		python3 -m unittest discover -s "$(PROJECT_DIR)/Evals/cli/tests" -p 'test_*.py'
	PYTHONDONTWRITEBYTECODE=1 \
		"$(PROJECT_DIR)/Evals/cli/self_test.py" --margin-bin "$(OUTPUT_DIR)/margin"
	PYTHONDONTWRITEBYTECODE=1 \
		python3 -m unittest discover -s "$(PROJECT_DIR)/Evals/collaboration/tests" -p 'test_*.py'
	PYTHONDONTWRITEBYTECODE=1 \
		"$(PROJECT_DIR)/Evals/collaboration/self_test.py" --margin-bin "$(OUTPUT_DIR)/margin"

eval-preflight: release
	PYTHONDONTWRITEBYTECODE=1 \
		"$(PROJECT_DIR)/Evals/cli/run.py" --margin-bin "$(OUTPUT_DIR)/margin"
	PYTHONDONTWRITEBYTECODE=1 \
		"$(PROJECT_DIR)/Evals/collaboration/run.py" --margin-bin "$(OUTPUT_DIR)/margin"

eval-collaboration: release
	PYTHONDONTWRITEBYTECODE=1 \
		python3 -m unittest discover -s "$(PROJECT_DIR)/Evals/collaboration/tests" -p 'test_*.py'
	PYTHONDONTWRITEBYTECODE=1 \
		"$(PROJECT_DIR)/Evals/collaboration/self_test.py" --margin-bin "$(OUTPUT_DIR)/margin" --require-all-capabilities

clean:
	"$(PROJECT_DIR)/Scripts/clean.sh"
