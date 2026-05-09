# Verb-First CLI for Include/Exclude Lists

## Problem

Current commands are `include add/remove/list/clear` and `exclude add/remove/list/clear` — kind-first, verb-second. This forces extra typing for common operations and doesn't allow shortcuts like "show me everything" or "remove all."

## Design

Restructure to verb-first commands: `list`, `add`, `del`, `clear`.

### New commands

```
list [include|exclude]              # show entries (both if kind omitted)
add <include|exclude> <cidr>        # add entry
del [include|exclude] <cidr>        # remove entry (searches both lists if kind omitted)
clear [include|exclude]             # clear list(s) (both if kind omitted)
```

### Behavior details

**`list`** (no arg): prints both lists with labels:
```
Include:
10.0.0.0/8
Exclude:
(empty)
```

**`del`** (no kind): searches both lists for the CIDR:
- Found in one list → remove it
- Found in both lists → remove from both, print warning
- Not found → error with exit 1
- `del include <cidr>` / `del exclude <cidr>` — remove from specific list only

**`clear`** (no arg): clears both lists.

### Parser changes

Add `list|add|del|clear` as first-level commands in the arg parser. Capture `KIND` (second positional arg) and remaining `$@` for CIDR.

Inside `cmd_del`, disambiguate: if `$1` is `include`/`exclude`, treat as kind; otherwise treat as CIDR and search both lists.

### What changes

- `cmd_include()` and `cmd_exclude()` → replaced by `cmd_list()`, `cmd_add()`, `cmd_del()`, `cmd_clear()`
- Arg parser: new `list|add|del|clear` cases, dispatch via `"$KIND" "$@"`
- USAGE help text
- README.md, CLAUDE.md

### What stays the same

- Internal functions: `list_file`, `validate_cidr`, `list_add`, `list_remove`, `list_list`, `list_clear`, `apply_user_overrides`
- Storage: `user-include.lst`, `user-exclude.lst`
- `apply_user_overrides` integration in install/update
- `status` output
