# Each suite target runs the commands of its CI job in .github/workflows/.
# `make check` runs server, web and ios, then scoring, measure-lab, evals, recon
# and meter-closeup where the branch has them. It needs no Simulator, so it leaves out the
# iOS UI suite that CI also runs; run that with `make ios-ui`.
# tests/makefile.sh checks this dispatch with stub suites.

XCODEGEN ?= xcodegen
# Must match XCODEGEN_VERSION in .github/workflows/ios.yml; other versions write a different project.
XCODEGEN_VERSION := 2.46.0

# The file each experiment suite's target needs. These suites arrive in separate pull requests, so
# `check` includes one only when its file exists and the Makefile works before and after each
# merge. Once all five are on main, list them in `check` directly so a deleted folder fails.
SCORING := experiments/scoring/pyproject.toml
MEASURE_LAB := experiments/measure-lab/Makefile
EVALS := experiments/evals/Makefile
RECON := recon/Makefile
METER_CLOSEUP := experiments/meter-closeup/Makefile

# $(call present,FILE,TARGET) is TARGET when FILE exists, otherwise nothing.
present = $(if $(wildcard $(1)),$(2))
# $(call require,FILE,PR): stop before any command runs when the suite's file is missing.
require = @test -f $(1) || { echo "make $@: $(1) is missing; the suite arrives with pull request $(2)." >&2; exit 1; }

.PHONY: check server web ios ios-package ios-build ios-ui ios-project smoke scoring measure-lab evals recon meter-closeup

check: server web ios \
	$(call present,$(SCORING),scoring) \
	$(call present,$(MEASURE_LAB),measure-lab) \
	$(call present,$(EVALS),evals) \
	$(call present,$(RECON),recon) \
	$(call present,$(METER_CLOSEUP),meter-closeup)

server:
	cd server && uv sync --locked
	cd server && uv run ruff check .
	cd server && uv run ruff format --check .
	cd server && uv run pytest -q

web:
	cd web && pnpm install --frozen-lockfile
	cd web && pnpm run check

# The headless steps of .github/workflows/ios.yml: the HouseScanKit tests, then the app build.
# Recipe lines, not prerequisites, so the build waits for the tests and is skipped when they
# fail, even under make -j. CI also regenerates the project and fails on drift; run
# `make ios-project` for that.
ios:
	$(MAKE) ios-package
	$(MAKE) ios-build

# CI sets HOUSESCAN_REQUIRE_UPSTREAM=1 after fetching the server contract. Here the schema drift
# tests compare against server/ when the checkout has it and skip otherwise.
ios-package:
	swift test --package-path ios/HouseScanKit -Xswiftc -warnings-as-errors

ios-build:
	xcodebuild -project ios/HouseScan.xcodeproj -scheme HouseScan -configuration Debug \
		-destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO build

# The UI suite step of .github/workflows/ios.yml. It boots a Simulator, so `check` leaves it out.
# It skips the every-state accessibility audit (about 10 minutes) unless FULL_UI=1, as pull
# requests do in CI. Pick the Simulator with IOS_DESTINATION, for example "id=<UDID>".
IOS_DESTINATION ?= platform=iOS Simulator,name=iPhone 17
IOS_AUDIT := HouseScanUITests/ScreenStatesUITests/testEveryStatePassesTheAccessibilityAudit
ios-ui:
	xcodebuild -project ios/HouseScan.xcodeproj -scheme HouseScan -configuration Debug \
		-destination "$(IOS_DESTINATION)" -only-testing:HouseScanUITests \
		$(if $(filter 1,$(FULL_UI)),,-skip-testing:$(IOS_AUDIT)) test

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

# The commands of .github/workflows/scoring.yml. The folder has no Makefile of its own.
scoring:
	$(call require,$(SCORING),#4)
	cd experiments/scoring && uv sync --locked
	cd experiments/scoring && uv run ruff check .
	cd experiments/scoring && uv run ruff format --check .
	cd experiments/scoring && uv run pytest -q

# The Geometry package's tests, then the app build.
measure-lab:
	$(call require,$(MEASURE_LAB),#7)
	$(MAKE) -C experiments/measure-lab check

# The folder's `make test` lints and tests but leaves out the `uv sync --locked` that
# .github/workflows/evals.yml runs first, and a plain `uv run` rewrites a stale uv.lock instead of failing.
evals:
	$(call require,$(EVALS),#12)
	cd experiments/evals && uv sync --locked
	$(MAKE) -C experiments/evals test

recon:
	$(call require,$(RECON),#20)
	$(MAKE) -C recon test

# Lint and unit tests only. The separate leak scan needs a private key and must not run here.
meter-closeup:
	$(call require,$(METER_CLOSEUP),#16)
	$(MAKE) -C experiments/meter-closeup check

# Posts each scene in server/examples to a placement server and prints its decision:
# make smoke URL=https://house-scanning-server.vercel.app [KEY_FILE=server/.env.private.local]
smoke:
	@test -n "$(URL)" || { echo "usage: make smoke URL=<server> [KEY_FILE=<file with HOUSESCAN_API_KEY=...>]" >&2; exit 2; }
	python3 server/examples/smoke.py "$(URL)" $(if $(KEY_FILE),--key-file "$(KEY_FILE)")
