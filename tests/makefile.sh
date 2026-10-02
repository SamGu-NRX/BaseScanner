#!/usr/bin/env bash
# Checks which suites the root Makefile runs, without running any of them. Each case copies the
# Makefile into an empty temporary tree, adds stub experiment folders, and puts stub uv, pnpm,
# swift and xcodebuild first on PATH. Every stub, including the stub folder Makefiles, appends
# "<folder> <command>" to a log, so the log shows which suites ran and with what commands.
# Run it from anywhere: bash tests/makefile.sh
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# Resolved, because the stubs compare it with $PWD, and macOS's /var is a link to /private/var.
work=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$work"' EXIT
export LOG="$work/log" TREE="$work/tree" FAIL_AT="" SLOW_TOOL=""
failures=0

# A stub fails when FAIL_AT is "<folder> <command>" for it, such as "experiments/evals make".
mkdir "$work/bin"
for tool in uv pnpm swift xcodebuild; do
	cat >"$work/bin/$tool" <<'EOF'
#!/bin/sh
# SLOW_TOOL delays one stub, so a step that wrongly runs alongside it logs first.
[ "$(basename "$0")" = "${SLOW_TOOL:-}" ] && sleep 1
dir=${PWD#"$TREE"/}
[ "$dir" = "$PWD" ] && dir=.
echo "$dir $(basename "$0") $*" >>"$LOG"
# The log joins arguments with spaces, so record -destination's value on its own line to show
# whether the Makefile kept it as one argument.
prev=
for arg in "$@"; do
	[ "$prev" = -destination ] && echo "$arg" >>"$LOG.destination"
	prev=$arg
done
[ "$dir $(basename "$0")" != "$FAIL_AT" ]
EOF
	chmod +x "$work/bin/$tool"
done
export PATH="$work/bin:$PATH"

suites="scoring measure-lab evals recon meter-closeup"
folder() {
	case $1 in
	recon) echo recon ;;
	*) echo "experiments/$1" ;;
	esac
}

# Makes a tree with the root Makefile and the named experiment suites. Every suite but scoring
# gets a stub Makefile with the target the root calls; scoring gets only its pyproject.toml.
make_tree() {
	rm -rf "$TREE" "$LOG" "$LOG.destination"
	mkdir -p "$TREE/server" "$TREE/web"
	cp "$root/Makefile" "$TREE/"
	: >"$LOG"
	local suite dir target
	for suite in "$@"; do
		dir=$(folder "$suite")
		mkdir -p "$TREE/$dir"
		case $suite in
		scoring) touch "$TREE/$dir/pyproject.toml"; continue ;;
		measure-lab | meter-closeup) target=check ;;
		*) target=test ;;
		esac
		printf '%s:\n\t@echo "%s make %s" >>"$$LOG"\n\t@test "$$FAIL_AT" != "%s make"\n' \
			"$target" "$dir" "$target" "$dir" >"$TREE/$dir/Makefile"
	done
}

run_make() { make -C "$TREE" "$@" >"$work/out" 2>&1; }

fail() {
	echo "FAIL: $*" >&2
	sed 's/^/  log: /' "$LOG" >&2
	sed 's/^/  make: /' "$work/out" >&2
	failures=$((failures + 1))
}

# 1. `make check` runs server, web and ios, then exactly the experiment suites present, in order,
#    for all 32 combinations. "." is the iOS package tests and build, which run from the root.
for mask in $(seq 0 31); do
	present=()
	expected="server web ."
	i=0
	for suite in $suites; do
		if (((mask >> i) & 1)); then
			present+=("$suite")
			expected="$expected $(folder "$suite")"
		fi
		i=$((i + 1))
	done
	make_tree ${present[@]+"${present[@]}"}
	if ! run_make check; then
		fail "check with [${present[*]-}] exited non-zero"
		continue
	fi
	got=$(awk '{print $1}' "$LOG" | uniq | tr '\n' ' ' | sed 's/ $//')
	[ "$got" = "$expected" ] || fail "check with [${present[*]-}] ran [$got], expected [$expected]"
done

# 2. Each suite target runs its CI job's commands, in order.
expect_commands() {
	local suite=$1 expected=$2
	make_tree "$suite"
	if ! run_make "$suite"; then
		fail "make $suite exited non-zero"
		return
	fi
	[ "$(cat "$LOG")" = "$expected" ] || fail "make $suite ran the wrong commands"
}
expect_commands scoring "experiments/scoring uv sync --locked
experiments/scoring uv run ruff check .
experiments/scoring uv run ruff format --check .
experiments/scoring uv run pytest -q"
expect_commands measure-lab "experiments/measure-lab make check"
expect_commands evals "experiments/evals uv sync --locked
experiments/evals make test"
expect_commands recon "recon make test"
expect_commands meter-closeup "experiments/meter-closeup make check"

# 2b. The iOS targets. `ios` runs the headless package tests, then the build. `ios-ui` runs CI's
#     UI suite step, skipping the every-state audit unless FULL_UI=1.
ios_build='. xcodebuild -project ios/HouseScan.xcodeproj -scheme HouseScan -configuration Debug -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO build'
ios_ui='. xcodebuild -project ios/HouseScan.xcodeproj -scheme HouseScan -configuration Debug -destination'
audit=HouseScanUITests/ScreenStatesUITests/testEveryStatePassesTheAccessibilityAudit
expect_ios() {
	local expected=$1
	shift
	make_tree
	if ! run_make "$@"; then
		fail "make $* exited non-zero"
		return
	fi
	[ "$(cat "$LOG")" = "$expected" ] || fail "make $* ran the wrong commands"
}
expect_ios ". swift test --package-path ios/HouseScanKit -Xswiftc -warnings-as-errors
$ios_build" ios
expect_ios "$ios_ui platform=iOS Simulator,name=iPhone 17 -only-testing:HouseScanUITests -skip-testing:$audit test" ios-ui
expect_ios "$ios_ui id=SIM-UDID -only-testing:HouseScanUITests test" ios-ui FULL_UI=1 IOS_DESTINATION=id=SIM-UDID
# A destination with spaces and commas must reach xcodebuild as one argument.
for destination in "platform=iOS Simulator,name=iPhone 17" "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5"; do
	make_tree
	run_make ios-ui "IOS_DESTINATION=$destination" || fail "make ios-ui with [$destination] exited non-zero"
	[ "$(cat "$LOG.destination" 2>/dev/null)" = "$destination" ] ||
		fail "make ios-ui split or changed the destination [$destination]"
done

# 2c. `make check` never runs a Simulator test, and a failing package test stops the iOS build.
make_tree $suites
run_make check || fail "check exited non-zero"
grep -q 'xcodebuild .* test$' "$LOG" && fail "check ran the Simulator UI suite"
FAIL_AT=". swift"
make_tree
if run_make check; then
	fail "check passed although the HouseScanKit tests failed"
elif grep -q '^\. xcodebuild' "$LOG"; then
	fail "check built the app after the HouseScanKit tests failed"
fi
FAIL_AT=""

# 2d. The same order holds under make -j. The slowed swift stub would log after a build that
#     wrongly started alongside it.
SLOW_TOOL=swift
make_tree
if ! run_make -j4 ios; then
	fail "make -j4 ios exited non-zero"
elif [ "$(awk '{print $2}' "$LOG" | tr '\n' ' ')" != "swift xcodebuild " ]; then
	fail "make -j4 ios did not run the tests before the build"
fi
FAIL_AT=". swift"
make_tree
if run_make -j4 ios; then
	fail "make -j4 ios passed although the HouseScanKit tests failed"
elif grep -q '^\. xcodebuild' "$LOG"; then
	fail "make -j4 ios built the app although the HouseScanKit tests failed"
fi
FAIL_AT="" SLOW_TOOL=""

# 3. Naming a missing suite fails loudly and runs nothing.
for suite in $suites; do
	make_tree
	if run_make "$suite"; then
		fail "make $suite succeeded without its folder"
	elif [ -s "$LOG" ] || ! grep -q "make $suite: .* is missing" "$work/out"; then
		fail "make $suite without its folder ran commands or gave no reason"
	fi
done

# 4. A failing command inside a present suite fails `make check`, and nothing runs after it.
for FAIL_AT in "experiments/scoring uv" "experiments/measure-lab make" "experiments/evals uv" \
	"experiments/evals make" "recon make" "experiments/meter-closeup make"; do
	make_tree $suites
	if run_make check; then
		fail "check passed although $FAIL_AT failed"
	elif [ "$(tail -n 1 "$LOG" | cut -d' ' -f1-2)" != "$FAIL_AT" ]; then
		fail "check kept going after $FAIL_AT failed"
	fi
done
FAIL_AT=""

if [ "$failures" -ne 0 ]; then
	echo "$failures Makefile dispatch case(s) failed" >&2
	exit 1
fi
echo "Makefile dispatch: all cases pass"
