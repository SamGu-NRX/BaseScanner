# Commands for this experiment. CI (.github/workflows/measure-lab.yml) runs the same ones.

XCODEGEN ?= xcodegen
# Must match XCODEGEN_VERSION in .github/workflows/measure-lab.yml; other versions write a different project.
XCODEGEN_VERSION := 2.46.0

.PHONY: check test build project

check: test build

test:
	cd Geometry && swift test

build:
	xcodebuild -project MeasureLab.xcodeproj -scheme MeasureLab -configuration Debug \
		-destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO build

# Regenerates MeasureLab.xcodeproj from project.yml. Point XCODEGEN at another binary if the one on
# PATH is not $(XCODEGEN_VERSION): make project XCODEGEN=/path/to/xcodegen
project:
	@found="$$($(XCODEGEN) --version 2>/dev/null)"; \
	if [ "$$found" != "Version: $(XCODEGEN_VERSION)" ]; then \
		echo "project needs XcodeGen $(XCODEGEN_VERSION), but $(XCODEGEN) reports: $${found:-nothing (not installed?)}." >&2; \
		echo "Download https://github.com/yonaskolb/XcodeGen/releases/download/$(XCODEGEN_VERSION)/xcodegen.zip, check its SHA-256 against .github/workflows/measure-lab.yml, and rerun with XCODEGEN=/path/to/xcodegen/bin/xcodegen." >&2; \
		exit 1; \
	fi
	$(XCODEGEN) generate --spec project.yml
