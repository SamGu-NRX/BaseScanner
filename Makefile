# Each suite target runs the commands of its CI job in .github/workflows/.
# `make check` runs all three.

XCODEGEN ?= xcodegen
# Must match XCODEGEN_VERSION in .github/workflows/ios.yml; other versions write a different project.
XCODEGEN_VERSION := 2.46.0

.PHONY: check server web ios ios-project smoke

check: server web ios

server:
	cd server && uv sync --locked
	cd server && uv run ruff check .
	cd server && uv run ruff format --check .
	cd server && uv run pytest -q

web:
	cd web && pnpm install --frozen-lockfile
	cd web && pnpm run check

# CI also regenerates the project and fails on drift; run `make ios-project` for that.
ios:
	xcodebuild -project ios/HouseScan.xcodeproj -scheme HouseScan -configuration Debug \
		-destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO build

# Regenerates ios/HouseScan.xcodeproj from ios/project.yml. Point XCODEGEN at another binary
# if the one on PATH is not $(XCODEGEN_VERSION): make ios-project XCODEGEN=/path/to/xcodegen
ios-project:
	@found="$$($(XCODEGEN) --version 2>/dev/null)"; \
	if [ "$$found" != "Version: $(XCODEGEN_VERSION)" ]; then \
		echo "ios-project needs XcodeGen $(XCODEGEN_VERSION), but $(XCODEGEN) reports: $${found:-nothing (not installed?)}." >&2; \
		echo "Download https://github.com/yonaskolb/XcodeGen/releases/download/$(XCODEGEN_VERSION)/xcodegen.zip, check its SHA-256 against .github/workflows/ios.yml, and rerun with XCODEGEN=/path/to/xcodegen/bin/xcodegen." >&2; \
		exit 1; \
	fi
	$(XCODEGEN) generate --spec ios/project.yml

# Posts each scene in server/examples to a placement server and prints its decision:
# make smoke URL=https://house-scanning-server.vercel.app [KEY_FILE=server/.env.private.local]
smoke:
	@test -n "$(URL)" || { echo "usage: make smoke URL=<server> [KEY_FILE=<file with HOUSESCAN_API_KEY=...>]" >&2; exit 2; }
	python3 server/examples/smoke.py "$(URL)" $(if $(KEY_FILE),--key-file "$(KEY_FILE)")
