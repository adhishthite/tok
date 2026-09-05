SHELL := /bin/bash
.DEFAULT_GOAL := build
CONFIGURATION ?= Debug
DERIVED := $(CURDIR)/build/DerivedData
APP := $(DERIVED)/Build/Products/$(CONFIGURATION)/Tok.app
XCODEBUILD := ./Scripts/xcodebuild.sh -project Tok.xcodeproj -scheme Tok -configuration $(CONFIGURATION) -derivedDataPath "$(DERIVED)" -destination 'platform=macOS'

.PHONY: install clean check format lint generate build run test package test-live distribute containers notarize-app notarize-dmg

install:
	@command -v xcodegen >/dev/null || brew install xcodegen
	xcrun swift format --version
	$(MAKE) generate

generate:
	xcodegen generate

build: generate
	$(XCODEBUILD) build
	@if codesign -dv "$(APP)" 2>&1 | grep -q 'Signature=adhoc'; then codesign --force --sign - --options runtime --preserve-metadata=entitlements "$(APP)"; fi

run: build
	./Scripts/run.sh "$(APP)"

test: generate
	$(XCODEBUILD) test

test-live:
	./Scripts/live_check.sh

lint:
	xcrun swift format lint --strict --recursive Sources Tests

format:
	xcrun swift format format --in-place --recursive Sources Tests

check: lint test
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
