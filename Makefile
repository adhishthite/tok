SHELL := /bin/bash
.DEFAULT_GOAL := build
CONFIGURATION ?= Debug
DERIVED := $(CURDIR)/build/DerivedData
APP := $(DERIVED)/Build/Products/$(CONFIGURATION)/Tok.app
XCODEBUILD := ./Scripts/xcodebuild.sh -project Tok.xcodeproj -scheme Tok -configuration $(CONFIGURATION) -derivedDataPath "$(DERIVED)" -destination 'platform=macOS'

.PHONY: install clean check format lint generate build run test package

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

lint:
	xcrun swift format lint --strict --recursive Sources Tests

format:
	xcrun swift format format --in-place --recursive Sources Tests

check: lint test
	git diff --check
	@for script in Scripts/*.sh; do bash -n "$$script" || exit; done

package:
	$(MAKE) build CONFIGURATION=Release
	./Scripts/package_app.sh "$(DERIVED)/Build/Products/Release/Tok.app"

clean:
	rm -rf "$(CURDIR)/build"
