#!/usr/bin/env python3
"""Load vpn profiles (JSON; YAML if PyYAML installed) for vpn-orchestrator.sh."""

from __future__ import annotations

import json
import sys
from pathlib import Path


def load(path: Path) -> dict:
    text = path.read_text()
    if path.suffix in (".yaml", ".yml"):
        try:
            import yaml
        except ImportError:
            sys.exit(
                f"{path}: PyYAML required for YAML profiles "
                "(pip install pyyaml) or use vpn-profiles.json"
            )
        data = yaml.safe_load(text)
    else:
        data = json.loads(text)

    if not isinstance(data, dict) or "profiles" not in data:
        raise SystemExit(f"{path}: expected top-level 'profiles' list")
    if not isinstance(data["profiles"], list):
        raise SystemExit(f"{path}: 'profiles' must be a list")
    return data


def main() -> int:
    if len(sys.argv) < 3:
        print(
            "Usage: vpn_profiles_load.py <file> list|get <name>|json",
            file=sys.stderr,
        )
        return 2

    path = Path(sys.argv[1])
    cmd = sys.argv[2]
    data = load(path)
    profiles = data["profiles"]

    if cmd == "list":
        for p in profiles:
            if not isinstance(p, dict) or "name" not in p:
                raise SystemExit("each profile needs a 'name' field")
            print(p["name"])
        return 0

    if cmd == "json":
        print(json.dumps(data, indent=2))
        return 0

    if cmd == "get":
        if len(sys.argv) < 4:
            print("Usage: vpn_profiles_load.py <file> get <name>", file=sys.stderr)
            return 2
        name = sys.argv[3]
        for p in profiles:
            if p.get("name") == name:
                print(json.dumps(p))
                return 0
        raise SystemExit(f"profile not found: {name}")

    raise SystemExit(f"unknown command: {cmd}")


if __name__ == "__main__":
    sys.exit(main())
