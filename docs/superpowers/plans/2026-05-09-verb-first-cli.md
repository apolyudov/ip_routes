# Verb-First CLI Restructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure include/exclude commands from kind-first (`include add`) to verb-first (`add include`) with smart defaults for bare commands.

**Architecture:** Replace `cmd_include`/`cmd_exclude` dispatchers with four verb-first dispatchers (`cmd_list`, `cmd_add`, `cmd_del`, `cmd_clear`). Internal functions (`list_file`, `list_add`, `list_remove`, `list_list`, `list_clear`) remain unchanged. `cmd_del` gains auto-detection: if kind is omitted, searches both lists.

**Tech Stack:** Bash, existing `ru-routes.sh` patterns

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `test-include-exclude` | Modify | Update all test calls to new command syntax |
| `ru-routes.sh` | Modify | Replace dispatchers, update parser, update USAGE |
| `README.md` | Modify | Update command documentation |
| `CLAUDE.md` | Modify | Update command reference |

---

### Task 1: Update test script to use verb-first commands (TDD — tests first)

**Files:**
- Modify: `test-include-exclude`

- [ ] **Step 1: Rewrite the test script with new command syntax**

Replace the entire content of `test-include-exclude` with tests using the new verbs:

```bash
#!/bin/bash
set -euo pipefail

# Tests for verb-first include/exclude list management in ru-routes.sh
# Uses an isolated BASE_DIR so no real config is affected.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

pass=0
fail=0

assert_eq() {
    local label=$1 expected=$2 actual=$3
    if [[ "$expected" == "$actual" ]]; then
        (( pass++ )) || true
    else
        (( fail++ )) || true
        echo "FAIL: $label"
        echo "  expected: $expected"
        echo "  actual:   $actual"
    fi
}

assert_file_exists() {
    local label=$1 file=$2
    if [[ -f "$file" ]]; then
        (( pass++ )) || true
    else
        (( fail++ )) || true
        echo "FAIL: $label — file not found: $file"
    fi
}

assert_file_missing() {
    local label=$1 file=$2
    if [[ ! -f "$file" ]]; then
        (( pass++ )) || true
    else
        (( fail++ )) || true
        echo "FAIL: $label — file should not exist: $file"
    fi
}

assert_exit() {
    local label=$1 expected=$2; shift 2
    local actual
    actual=$(BASE_DIR="$TEST_DIR" "$SCRIPT_DIR/ru-routes.sh" "$@" 2>&1) && rc=$? || rc=$?
    if [[ "$rc" -eq "$expected" ]]; then
        (( pass++ )) || true
    else
        (( fail++ )) || true
        echo "FAIL: $label"
        echo "  expected exit: $expected"
        echo "  actual exit:   $rc"
        echo "  output: $actual"
    fi
}

run() { BASE_DIR="$TEST_DIR" "$SCRIPT_DIR/ru-routes.sh" "$@" 2>/dev/null; }
capture() { BASE_DIR="$TEST_DIR" "$SCRIPT_DIR/ru-routes.sh" "$@" 2>&1; }

INC_FILE="$TEST_DIR/user-include.lst"
EXC_FILE="$TEST_DIR/user-exclude.lst"

# ── add ──────────────────────────────────────────────────────────────
echo "=== add ==="

run add include 10.0.0.0/8
assert_file_exists "add creates file" "$INC_FILE"
assert_eq "add writes CIDR" "10.0.0.0/8" "$(cat "$INC_FILE")"

run add include 172.16.0.0/12
assert_eq "add second entry" "2" "$(wc -l < "$INC_FILE")"

run add include 10.0.0.0/8
assert_eq "dedup ignored" "2" "$(wc -l < "$INC_FILE")"

run add exclude 192.168.0.0/16
assert_file_exists "add exclude creates file" "$EXC_FILE"
assert_eq "add exclude entry" "192.168.0.0/16" "$(cat "$EXC_FILE")"

# ── list ─────────────────────────────────────────────────────────────
echo "=== list ==="

out=$(run list include)
assert_eq "list include shows entries" "10.0.0.0/8
172.16.0.0/12" "$out"

out=$(run list exclude)
assert_eq "list exclude shows entries" "192.168.0.0/16" "$out"

out=$(run list)
echo "$out" | grep -q "Include:"
assert_eq "list (bare) shows Include label" "0" "$?"
echo "$out" | grep -q "Exclude:"
assert_eq "list (bare) shows Exclude label" "0" "$?"
echo "$out" | grep -q "10.0.0.0/8"
assert_eq "list (bare) shows include entries" "0" "$?"
echo "$out" | grep -q "192.168.0.0/16"
assert_eq "list (bare) shows exclude entries" "0" "$?"

# ── del (with kind) ──────────────────────────────────────────────────
echo "=== del (with kind) ==="

run del include 10.0.0.0/8
assert_eq "del include leaves one" "1" "$(wc -l < "$INC_FILE")"
assert_eq "remaining entry" "172.16.0.0/12" "$(cat "$INC_FILE")"

# ── del (without kind — auto-detect) ─────────────────────────────────
echo "=== del (auto-detect) ==="

# Add an entry to both lists to test dual-match warning
run add include 10.0.0.0/8
run add exclude 10.0.0.0/8

out=$(capture del 10.0.0.0/8)
echo "$out" | grep -qi "warning"
assert_eq "del dual-match shows warning" "0" "$?"
assert_file_missing "del dual-match removed from include" "$INC_FILE"  # only 172.16.0.0/12 left
grep -qxF "10.0.0.0/8" "$EXC_FILE" 2>/dev/null && echo "FAIL: not removed from exclude" && (( fail++ )) || (( pass++ )) || true

# del with CIDR not in any list
assert_exit "del not found exits 1" 1 del 1.2.3.4/32

# ── list (empty) ─────────────────────────────────────────────────────
echo "=== list (empty) ==="

rm -f "$INC_FILE" "$EXC_FILE"
out=$(run list include)
assert_eq "empty list" "(empty)" "$out"

# ── clear ────────────────────────────────────────────────────────────
echo "=== clear ==="

run add include 10.0.0.0/8
run add exclude 192.168.0.0/16
run clear include
assert_file_missing "clear include" "$INC_FILE"
assert_file_exists "clear include leaves exclude" "$EXC_FILE"

run clear exclude
assert_file_missing "clear exclude" "$EXC_FILE"

# clear (bare) clears both
run add include 10.0.0.0/8
run add exclude 192.168.0.0/16
run clear
assert_file_missing "clear (bare) removes include" "$INC_FILE"
assert_file_missing "clear (bare) removes exclude" "$EXC_FILE"

out=$(run clear 2>&1)
assert_eq "clear idempotent" "0" "$?"

# ── validation ───────────────────────────────────────────────────────
echo "=== validation ==="

assert_exit "invalid CIDR exits 1" 1 add include "not-a-cidr"
assert_exit "missing CIDR exits 1" 1 add include
assert_exit "missing kind exits 1" 1 add
assert_exit "unknown kind exits 1" 1 add bogus 10.0.0.0/8
assert_exit "unknown list kind" 1 list bogus
assert_exit "unknown clear kind" 1 clear bogus

# ── apply_user_overrides ────────────────────────────────────────────
echo "=== apply_user_overrides ==="

SUBNET_FILE="$TEST_DIR/test-subnets.lst"

printf "1.1.1.0/24\n2.2.2.0/24\n3.3.3.0/24\n" > "$SUBNET_FILE"
printf "2.2.2.0/24\n" > "$EXC_FILE"
printf "10.0.0.0/8\n" > "$INC_FILE"

(
    BASE_DIR="$TEST_DIR"
    QUIET=1
    log() { :; }
    err() { echo "ERROR: $@" >&2; }
    source <(sed -n '/^list_file()/,/^cmd_list()/p' "$SCRIPT_DIR/ru-routes.sh" | head -n -1)
    apply_user_overrides "$SUBNET_FILE"
)

actual=$(cat "$SUBNET_FILE")
assert_eq "exclude removes, include adds" "1.1.1.0/24
3.3.3.0/24
10.0.0.0/8" "$actual"

# Test: no override files = no change
rm -f "$INC_FILE" "$EXC_FILE"
printf "1.1.1.0/24\n2.2.2.0/24\n" > "$SUBNET_FILE"

(
    BASE_DIR="$TEST_DIR"
    QUIET=1
    log() { :; }
    err() { echo "ERROR: $@" >&2; }
    source <(sed -n '/^list_file()/,/^cmd_list()/p' "$SCRIPT_DIR/ru-routes.sh" | head -n -1)
    apply_user_overrides "$SUBNET_FILE"
)

actual=$(cat "$SUBNET_FILE")
assert_eq "no overrides = no change" "1.1.1.0/24
2.2.2.0/24" "$actual"

# ── status shows override counts ────────────────────────────────────
echo "=== status override counts ==="

mkdir -p "$TEST_DIR/cache"
cat > "$TEST_DIR/cache/config" <<CONF
IFACE=""
TABLE="ru_routes"
TABLE_ID="200"
PRIORITY="500"
GATEWAY=""
SOURCE_URL="https://example.com"
CACHE_DIR="$TEST_DIR/cache"
CONF

printf "10.0.0.0/8\n172.16.0.0/12\n" > "$INC_FILE"
printf "192.168.0.0/16\n" > "$EXC_FILE"

out=$(BASE_DIR="$TEST_DIR" "$SCRIPT_DIR/ru-routes.sh" status 2>&1)
echo "$out" | grep -q "Include overrides: 2 entries"
assert_eq "status include count" "0" "$?"
echo "$out" | grep -q "Exclude overrides: 1 entries"
assert_eq "status exclude count" "0" "$?"

rm -f "$INC_FILE" "$EXC_FILE"

out=$(BASE_DIR="$TEST_DIR" "$SCRIPT_DIR/ru-routes.sh" status 2>&1)
echo "$out" | grep -q "Include overrides: none"
assert_eq "status include none" "0" "$?"
echo "$out" | grep -q "Exclude overrides: none"
assert_eq "status exclude none" "0" "$?"

# ── Summary ──────────────────────────────────────────────────────────
echo ""
echo "================================"
echo "Passed: $pass"
echo "Failed: $fail"
[[ $fail -eq 0 ]] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit $fail
```

- [ ] **Step 2: Run tests to verify they fail against current code**

Run: `./test-include-exclude`
Expected: FAIL (current code uses old `include add` syntax, not `add include`)

- [ ] **Step 3: Verify the test script itself has no syntax errors**

Run: `bash -n test-include-exclude`
Expected: no output (clean parse)

---

### Task 2: Replace command dispatchers

**Files:**
- Modify: `ru-routes.sh` (replace `cmd_include`/`cmd_exclude` at lines 289-311)

- [ ] **Step 1: Replace cmd_include and cmd_exclude with cmd_list, cmd_add, cmd_del, cmd_clear**

Find the block starting with `cmd_include()` and ending with the closing `}` of `cmd_exclude()`. Replace the entire block with:

```bash
cmd_list() {
    local kind="${1:-}"
    case "$kind" in
        include)  list_list include ;;
        exclude)  list_list exclude ;;
        "")       echo "Include:"; list_list include; echo "Exclude:"; list_list exclude ;;
        *)        err "Unknown list kind: $kind (expected include or exclude)"; exit 1 ;;
    esac
}

cmd_add() {
    local kind="${1:-}"
    case "$kind" in
        include|exclude) ;;
        *)  err "Usage: $0 add <include|exclude> <cidr>"; exit 1 ;;
    esac
    shift || true
    [[ $# -lt 1 ]] && { err "Usage: $0 add <include|exclude> <cidr>"; exit 1; }
    list_add "$kind" "$1"
}

cmd_del() {
    local kind=""
    if [[ "${1:-}" == "include" || "${1:-}" == "exclude" ]]; then
        kind="$1"; shift || true
    fi
    [[ $# -lt 1 ]] && { err "Usage: $0 del [include|exclude] <cidr>"; exit 1; }
    local net="$1"
    validate_cidr "$net"

    if [[ -n "$kind" ]]; then
        list_remove "$kind" "$net"
        return
    fi

    local found=0
    local file
    for k in include exclude; do
        file="$(list_file "$k")"
        if [[ -f "$file" ]] && grep -qxF "$net" "$file"; then
            list_remove "$k" "$net"
            (( found++ )) || true
        fi
    done
    if (( found == 0 )); then
        err "$net not found in any list."
        exit 1
    elif (( found > 1 )); then
        log "Warning: $net was found in both lists."
    fi
}

cmd_clear() {
    local kind="${1:-}"
    case "$kind" in
        include)  list_clear include ;;
        exclude)  list_clear exclude ;;
        "")       list_clear include; list_clear exclude ;;
        *)        err "Unknown list kind: $kind (expected include or exclude)"; exit 1 ;;
    esac
}
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n ru-routes.sh`
Expected: no output

---

### Task 3: Update arg parser and dispatch

**Files:**
- Modify: `ru-routes.sh` (arg parser and dispatch at end of file)

- [ ] **Step 1: Update arg parser**

Find the `include|exclude)` case in the `while [[ $# -gt 0 ]]` loop. Replace it with:

```bash
        list|add|del|clear)
            COMMAND="$1"; shift
            KIND="${1:-}"; shift || true
            break
            ;;
```

- [ ] **Step 2: Update dispatch at end of file**

Find the dispatch block:

```bash
if [[ "$COMMAND" == "include" || "$COMMAND" == "exclude" ]]; then
    "cmd_$COMMAND" "$SUBCMD" "$@"
else
    "cmd_$COMMAND"
fi
```

Replace with:

```bash
if [[ "$COMMAND" == "list" || "$COMMAND" == "add" || "$COMMAND" == "del" || "$COMMAND" == "clear" ]]; then
    "cmd_$COMMAND" "$KIND" "$@"
else
    "cmd_$COMMAND"
fi
```

- [ ] **Step 3: Verify syntax**

Run: `bash -n ru-routes.sh`
Expected: no output

- [ ] **Step 4: Run tests**

Run: `./test-include-exclude`
Expected: ALL TESTS PASSED

---

### Task 4: Update USAGE help text

**Files:**
- Modify: `ru-routes.sh` (USAGE variable)

- [ ] **Step 1: Replace include/exclude lines in USAGE**

Find these lines in the USAGE string:

```
  include add|remove|list|clear [CIDR]  Manage user-include override list
  exclude add|remove|list|clear [CIDR]  Manage user-exclude override list
```

Replace with:

```
  list [include|exclude]               Show override list(s)
  add <include|exclude> <CIDR>         Add network to override list
  del [include|exclude] <CIDR>         Remove network (searches both if kind omitted)
  clear [include|exclude]              Clear override list(s)
```

- [ ] **Step 2: Verify help output**

Run: `./ru-routes.sh --help | grep -A4 "list \[include"`
Expected: shows the 4 new command lines

---

### Task 5: Update documentation

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update README.md**

Find the "User include/exclude lists" section. Replace the command examples:

```markdown
### User include/exclude lists

Manage custom network overrides that are applied on every `install` and `update`:

```bash
./ru-routes.sh add include 10.0.0.0/8        # Force-include a network
./ru-routes.sh del include 10.0.0.0/8        # Remove from include list
./ru-routes.sh list                           # Show all override lists
./ru-routes.sh list include                   # Show include list only
./ru-routes.sh clear                          # Clear all overrides
./ru-routes.sh clear include                  # Clear include list only

./ru-routes.sh add exclude 192.168.0.0/16    # Force-exclude a network
./ru-routes.sh del 10.0.0.0/8                # Remove from whichever list has it
```

Lists are stored in `~/.local/ru-routes/user-include.lst` and `~/.local/ru-routes/user-exclude.lst` (one CIDR per line). During `install` and `update`, excluded networks are removed from the subnet list first, then included networks are appended. The result replaces what goes into the routing table.

`del` without a kind specifier searches both lists: removes from whichever matches, removes from both with a warning if found in both, or errors if not found.
```

- [ ] **Step 2: Update CLAUDE.md**

In the Commands section, find the include/exclude lines:

```
sudo ./ru-routes.sh include add|remove|list|clear [CIDR]   # Manage user-include list (force-add networks)
sudo ./ru-routes.sh exclude add|remove|list|clear [CIDR]   # Manage user-exclude list (force-remove networks)
```

Replace with:

```
sudo ./ru-routes.sh list [include|exclude]               # Show override list(s) (both if omitted)
sudo ./ru-routes.sh add <include|exclude> <CIDR>         # Add network to override list
sudo ./ru-routes.sh del [include|exclude] <CIDR>         # Remove network (searches both if kind omitted)
sudo ./ru-routes.sh clear [include|exclude]              # Clear override list(s) (both if omitted)
```

- [ ] **Step 3: Verify changes**

Run: `grep -c "add include" README.md CLAUDE.md`
Expected: at least 1 match in each

---

### Task 6: Verify and commit

- [ ] **Step 1: Run full test suite**

Run: `./test-include-exclude`
Expected: ALL TESTS PASSED

- [ ] **Step 2: Run syntax check**

Run: `bash -n ru-routes.sh`
Expected: no output

- [ ] **Step 3: Review diff**

Run: `git diff --stat`
Review for: no stray changes, consistent indentation, no debug artifacts

- [ ] **Step 4: Commit**

Single commit per `feature_commit` skill (small refactor, docs + tests + code):

```bash
git add ru-routes.sh test-include-exclude README.md CLAUDE.md docs/superpowers/specs/2026-05-09-verb-first-cli-design.md
git commit -m "refactor: restructure include/exclude CLI to verb-first commands

Commands change from kind-first (include add) to verb-first (add include).
Bare 'list' shows both, bare 'clear' clears both, 'del' without kind
searches both lists automatically.

Old: include add/remove/list/clear, exclude add/remove/list/clear
New: list/add/del/clear with optional include|exclude kind"
```
