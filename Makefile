SHELL := /bin/bash
.DEFAULT_GOAL := build
CONFIGURATION ?= Debug
DERIVED := $(CURDIR)/build/DerivedData
APP := $(DERIVED)/Build/Products/$(CONFIGURATION)/Tok.app
ACTIONLINT ?= actionlint
XCODEBUILD := ./Scripts/xcodebuild.sh -project Tok.xcodeproj -scheme Tok -configuration $(CONFIGURATION) -derivedDataPath "$(DERIVED)" -destination 'platform=macOS'

.PHONY: install clean check format lint generate build run test package test-live distribute containers notarize-app notarize-dmg profile-microphone icon check-updates settings-tool settings-reference check-settings test-cleanup-live check-ci

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

settings-tool: generate
	./Scripts/xcodebuild.sh -project Tok.xcodeproj -scheme TokSettingsReference -configuration Debug -derivedDataPath "$(DERIVED)" -destination 'platform=macOS' build

settings-reference: settings-tool
	"$(DERIVED)/Build/Products/Debug/TokSettingsReference" --write README.md

check-settings: settings-tool
	"$(DERIVED)/Build/Products/Debug/TokSettingsReference" --check README.md

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
	python3 Scripts/bounded_run.py --seconds 60 --label ci-python-lint -- uvx ruff check --isolated --select E4,E7,E9,F,I,SIM,PLW1510 Scripts/ci Tests/ScriptTests/test_ci_release.py
