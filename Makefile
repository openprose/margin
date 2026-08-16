PROJECT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BUILD_DEVELOPER_DIR ?= /Library/Developer/CommandLineTools
TEST_DEVELOPER_DIR ?=
SCRATCH_ROOT ?= $(PROJECT_DIR)/.build/toolchains
BUILD_SCRATCH_PATH ?= $(SCRATCH_ROOT)/command-line-tools
TEST_SCRATCH_PATH ?= $(SCRATCH_ROOT)/xcode-15.4
OUTPUT_DIR ?= $(PROJECT_DIR)/build

.PHONY: debug test release package install smoke benchmark clean

debug:
	DEVELOPER_DIR="$(BUILD_DEVELOPER_DIR)" \
	MARGIN_SWIFT_SCRATCH_PATH="$(BUILD_SCRATCH_PATH)" \
	MARGIN_BUILD_OUTPUT_DIR="$(OUTPUT_DIR)" \
		"$(PROJECT_DIR)/Scripts/build-app.sh" debug

test:
	MARGIN_TEST_DEVELOPER_DIR="$(TEST_DEVELOPER_DIR)" \
	MARGIN_TEST_SCRATCH_PATH="$(TEST_SCRATCH_PATH)" \
		"$(PROJECT_DIR)/Scripts/run-tests.sh"

release:
	DEVELOPER_DIR="$(BUILD_DEVELOPER_DIR)" \
	MARGIN_SWIFT_SCRATCH_PATH="$(BUILD_SCRATCH_PATH)" \
	MARGIN_BUILD_OUTPUT_DIR="$(OUTPUT_DIR)" \
		"$(PROJECT_DIR)/Scripts/build-app.sh" release

package: release
	MARGIN_BUILD_OUTPUT_DIR="$(OUTPUT_DIR)" \
		"$(PROJECT_DIR)/Scripts/package-release.sh"

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

clean:
	"$(PROJECT_DIR)/Scripts/clean.sh"
