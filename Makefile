SHELL := /bin/bash
.DEFAULT_GOAL := build
CONFIGURATION ?= Debug
DERIVED := $(CURDIR)/build/DerivedData
APP := $(DERIVED)/Build/Products/$(CONFIGURATION)/Tok.app
ACTIONLINT ?= actionlint
XCODEBUILD := ./Scripts/xcodebuild.sh -project Tok.xcodeproj -scheme Tok -configuration $(CONFIGURATION) -derivedDataPath "$(DERIVED)" -destination 'platform=macOS'

.PHONY: install clean check format lint generate build run test package test-live distribute containers notarize-app notarize-dmg profile-microphone icon check-updates settings-tool settings-reference check-settings test-cleanup-live check-ci report harness-clips harness-build harness harness-smoke harness-direct harness-report

install:
	@command -v xcodegen >/dev/null || brew install xcodegen
	xcrun swift format --version
	$(MAKE) generate

generate:
	xcodegen generate

icon:
	python3 Scripts/bounded_run.py --seconds 30 --label icon -- xcrun swift Scripts/generate_icon.swift

check-updates: build
	python3 Scripts/bounded_run.py --seconds 120 --label update-signing -- python3 Scripts/check_updates.py

report:
	python3 Scripts/bounded_run.py --seconds 30 --label turn-report -- python3 Scripts/turn_report.py $(ARGS)

harness-clips:
	python3 Scripts/bounded_run.py --seconds 1200 --label harness-clips -- python3 Scripts/harness_clips.py $(ARGS)

harness-build: generate
	./Scripts/xcodebuild.sh -project Tok.xcodeproj -scheme TokHarness -configuration Debug -derivedDataPath "$(DERIVED)" -destination 'platform=macOS' build

# Unattended run: lid open, built-in speakers audible, quiet room. HARNESS_SECONDS bounds it.
HARNESS_SECONDS ?= 25200
# Each run executes its own copy, so a rebuild never replaces a running signed binary.
HARNESS_RUN = bin="build/harness/bin/TokHarness-$$$$"; mkdir -p build/harness/bin && cp "$(DERIVED)/Build/Products/Debug/TokHarness" "$$bin" && TOK_PROJECT_ROOT="$(CURDIR)" TOK_BUILD_ID="$$(git rev-parse --short=12 HEAD)" python3 Scripts/bounded_run.py

harness: harness-build
	@$(HARNESS_RUN) --seconds $(HARNESS_SECONDS) --label harness -- "$$bin" $(ARGS)

harness-smoke: harness-build
	@$(HARNESS_RUN) --seconds 300 --label harness-smoke -- "$$bin" --smoke $(ARGS)

harness-direct: harness-build
	@$(HARNESS_RUN) --seconds 7200 --label harness-direct -- "$$bin" --direct $(ARGS)

harness-report:
	python3 Scripts/bounded_run.py --seconds 60 --label harness-report -- python3 Scripts/harness_report.py $(ARGS)

settings-tool: generate
	./Scripts/xcodebuild.sh -project Tok.xcodeproj -scheme TokSettingsReference -configuration Debug -derivedDataPath "$(DERIVED)" -destination 'platform=macOS' build

settings-reference: settings-tool
	"$(DERIVED)/Build/Products/Debug/TokSettingsReference" --write README.md PRIVACY.md .env.example

check-settings: settings-tool
	"$(DERIVED)/Build/Products/Debug/TokSettingsReference" --check README.md PRIVACY.md .env.example

build: generate
	$(XCODEBUILD) build
	@if codesign -dv "$(APP)" 2>&1 | grep -q 'Signature=adhoc'; then codesign --force --sign - --options runtime --preserve-metadata=entitlements "$(APP)"; fi

run: build
	./Scripts/run.sh "$(APP)"

profile-microphone: build
	TOK_PROFILE_MIC=1 ./Scripts/run.sh "$(APP)"

test: generate
	$(XCODEBUILD) test

test-live:
	./Scripts/live_check.sh

test-cleanup-live: generate
	./Scripts/xcodebuild.sh -project Tok.xcodeproj -scheme TokLiveChecks -configuration Debug -derivedDataPath "$(DERIVED)" -destination 'platform=macOS' -only-testing:TokEngineTests/PostProcessingLiveTests test

lint:
	xcrun swift format lint --strict --recursive Sources Tests Scripts Tools

format:
	xcrun swift format format --in-place --recursive Sources Tests Scripts Tools

check: lint test check-settings
	cmp LICENSE Resources/Tok-LICENSE.txt
	python3 Scripts/license_headers.py --check
	git diff --check
	@for script in Scripts/*.sh; do bash -n "$$script" || exit; done
	python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'

package:
	$(MAKE) build CONFIGURATION=Release
	./Scripts/package_app.sh "$(DERIVED)/Build/Products/Release/Tok.app"

distribute:
	./Scripts/package_distribution.sh

containers:
	./Scripts/package_containers.sh

notarize-app:
	./Scripts/notarize_distribution.sh app
	$(MAKE) containers

notarize-dmg:
	./Scripts/notarize_distribution.sh dmg
	python3 Scripts/bounded_run.py --seconds 30 --label gatekeeper -- spctl --assess --type execute --verbose build/distribution/Tok.app

clean:
	rm -rf "$(CURDIR)/build"

check-ci:
	python3 Scripts/bounded_run.py --seconds 20 --label workflow-lint -- $(ACTIONLINT)
	python3 Scripts/bounded_run.py --seconds 30 --label ci-identity-typecheck -- xcrun swiftc -typecheck Scripts/ci/import_identity.swift
	python3 Scripts/bounded_run.py --seconds 30 --label ci-signature-typecheck -- xcrun swiftc -typecheck Scripts/ci/verify_signature.swift
	python3 Scripts/bounded_run.py --seconds 60 --label ci-python-lint -- uvx ruff check --isolated --select E4,E7,E9,F,I,SIM,PLW1510 Scripts/ci Tests/ScriptTests/test_ci_release.py Scripts/turn_report.py Tests/ScriptTests/test_turn_report.py Scripts/harness_clips.py Scripts/harness_report.py Tests/ScriptTests/test_harness_report.py Scripts/license_headers.py Tests/ScriptTests/test_license_headers.py
