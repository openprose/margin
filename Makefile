PROJECT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BUILD_DEVELOPER_DIR ?= /Library/Developer/CommandLineTools
TEST_DEVELOPER_DIR ?=
SCRATCH_ROOT ?= $(PROJECT_DIR)/.build/toolchains
BUILD_SCRATCH_PATH ?= $(SCRATCH_ROOT)/command-line-tools
TEST_SCRATCH_PATH ?= $(SCRATCH_ROOT)/xcode-15.4
OUTPUT_DIR ?= $(PROJECT_DIR)/build

.PHONY: debug test test-linux release package installer install smoke benchmark eval eval-preflight eval-collaboration clean

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
