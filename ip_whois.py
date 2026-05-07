#!/usr/bin/env python3
"""Fetch WHOIS info for IPs from routing table and output as CSV."""

import re
import csv
import sys
import subprocess
import time
import urllib.request
import urllib.error

from ast import literal_eval
from bs4 import BeautifulSoup

FIELDS = ["inetnum", "netname", "country", "address"]
OUTPUT_FILE = "ip_whois.csv"
PRIVATE_OUTPUT_FILE = "ip_whois_private.csv"
DELAY = 1.0  # seconds between requests to avoid rate limiting
MAX_RETRIES = 3

PRIVATE_PATTERNS = [
    r"^10\.", r"^100\.(6[4-9]|[7-9]\d|1[0-1]\d|12[0-7])\.",
    r"^172\.(1[6-9]|2\d|3[0-1])\.", r"^192\.168\.", r"^198\.18\.",
]


def ip_sort_key(ip):
    """Sort key for proper IP address sorting (numeric octet comparison)."""
    pos = ip.find('/')
    if pos != -1:
        ip = ip[:pos]
    return tuple(int(o) for o in ip.split("."))


def is_private_ip(ip):
    return any(re.match(p, ip) for p in PRIVATE_PATTERNS)


def extract_route_ips(route_output):
    """Extract IPs from ip route output, split into public/private.

    Returns (public_ips, private_routes) where:
      public_ips: sorted list of unique public IP strings
      private_routes: dict mapping route_line -> sorted
        list of private IPs in it
    """
    public_ips = set()
    private_routes = {}

    for line in route_output.strip().splitlines():
        tokens = line.split()
        private_ips = set()
        for token in tokens:
            m = re.match(
                r"^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})"
                r"($|/\d{1,2}$)",
                token,
            )
            if m:
                ip, net = m.groups()
                if is_private_ip(ip):
                    private_ips.add(token)
                else:
                    public_ips.add(token)

        if private_ips:
            private_routes[frozenset(private_ips)] = line

    return sorted(public_ips, key=ip_sort_key), private_routes


def fetch_whois(ip):
    """Fetch WHOIS data from reg.ru for a given IP."""
    url = f"https://www.reg.ru/whois/?dname={ip}"
    for attempt in range(MAX_RETRIES):
        try:
            req = urllib.request.Request(
                url,
                headers={
                    "User-Agent": (
                        "Mozilla/5.0 (X11; Linux x86_64) "
                        "AppleWebKit/537.36"
                    ),
                    "Accept": "text/html,application/xhtml+xml",
                    "Accept-Language": "ru-RU,ru;q=0.9,en-US;q=0.8",
                },
            )
            with urllib.request.urlopen(req, timeout=60) as resp:
                html = resp.read().decode("utf-8", errors="replace")
            if "inetnum" in html:
                return html
            # No inetnum in response - might be rate limited or no data
            return html
        except (urllib.error.URLError, Exception) as e:
            print(
                f"  ERROR (attempt {attempt+1}) "
                f"fetching {ip}: {e}",
                file=sys.stderr,
            )
            if attempt < MAX_RETRIES - 1:
                time.sleep(2 * (attempt + 1))
    return None


def parse_whois_fields_raw(html):
    """Convert WHOIS HTML response to list of {key, value} pairs.

    The WHOIS data is in a <div> with <br/> separators between key-value pairs.
    Some values are wrapped in <a href="...">value</a> tags.
    """
    if not html:
        return []

    with open('html_rsp.txt', 'w') as f:
        f.write(html)

    parsed_html = BeautifulSoup(html, 'html.parser')
    elements = parsed_html.find_all(class_="ds-table__cell-content")
    s_rec = []
    src_text = []
    last_key = ""
    for element in elements:
        for item in element.contents:
            if item.name == "br":
                text = " ".join(src_text)
                src_text = []
                text = text.strip()
                print(f"text={text}")
                if text.startswith('%'):
                    key = '%'
                    value = text[1:]
                elif text.find(':') != -1:
                    key, value = text.split(":", 1)
                    last_key = key
                else:
                    key = last_key
                    value = text
                key = key.strip()
                value = value.strip()
                s_rec.append((key, value))
                continue
            text = item.text
            src_text.append(text)
    return s_rec


def filter_whois_fields(doc):
    recs = {}
    for key, value in doc:
        r = recs.get(key, None)
        if r is None:
            r = recs[key] = [value]
        else:
            r.append(value)
    return {f: "; ".join(recs.get(f)) for f in FIELDS}


def whois(ip):
    html = fetch_whois(ip)
    doc = parse_whois_fields_raw(html)
    with open("reg_cache.txt", "a") as f:
        f.write(f"{doc}\n")
    return filter_whois_fields(doc)


def load_reg_cache():
    known = []
    with open('reg_cache.txt', 'r') as f:
        for line in f:
            rec = literal_eval(line)
            row = filter_whois_fields(rec)
            inetnum = row.get("inetnum", "")
            if not inetnum:
                continue
            bounds = parse_inetnum_range(inetnum)
            if bounds:
                known.append((bounds, {f: row.get(f, "") for f in FIELDS}))
    return known


def parse_inetnum_range(inetnum):
    """Parse 'start_ip - end_ip' into (start_tuple, end_tuple) or None."""
    parts = inetnum.split(" - ")
    if len(parts) != 2:
        return None
    try:
        return (ip_sort_key(parts[0].strip()), ip_sort_key(parts[1].strip()))
    except (ValueError, IndexError):
        return None


def load_known_ranges(csv_path):
    """Load known inetnum ranges from an existing CSV file."""
    known = []
    try:
        with open(csv_path, newline="", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            for row in reader:
                inetnum = row.get("inetnum", "")
                if not inetnum:
                    continue
                bounds = parse_inetnum_range(inetnum)
                if bounds:
                    known.append((bounds, {f: row.get(f, "") for f in FIELDS}))
    except FileNotFoundError:
        pass
    return known


def find_matching_range(ip, known_ranges):
    """Return cached fields if ip falls within any known inetnum range."""
    ip_key = ip_sort_key(ip)
    for (start, end), fields in known_ranges:
        if start <= ip_key <= end:
            return fields
    return None


def group_by_route(rows):
    """Group rows sharing the same route (inetnum + other fields).

    IPs that share the same inetnum, netname, country, and address are merged
    into a single row with IPs joined as a comma-separated list.
    Failed lookups (empty inetnum) are kept as individual rows.
    """
    groups = {}
    ungrouped = []

    for row in rows:
        if not row["inetnum"]:
            ungrouped.append(row)
            continue
        key = tuple(row[f] for f in FIELDS)
        groups.setdefault(key, []).append(row["ip"])

    merged = []
    for key, ips in groups.items():
        ips_sorted = sorted(ips, key=ip_sort_key)
        merged.append({"ip": ", ".join(ips_sorted), **dict(zip(FIELDS, key))})

    merged.extend(ungrouped)
    merged.sort(key=lambda r: ip_sort_key(r["ip"].split(", ")[0]))
    return merged


def main():
    # Get routing table
    result = subprocess.run(["ip", "route"], capture_output=True, text=True)
    if result.returncode != 0:
        print(f"Error running ip route: {result.stderr}", file=sys.stderr)
        sys.exit(1)

    public_ips, private_routes = extract_route_ips(result.stdout)
    print(
        f"Found {len(public_ips)} public IPs, "
        f"{len(private_routes)} routes with private IPs"
    )

    # Write private route entries
    private_rows = []
    for ips, route_line in private_routes.items():
        private_rows.append({"ip_net": ", ".join(ips), "route": route_line})
    private_rows.sort(key=lambda r: ip_sort_key(r["ip_net"].split(", ")[0]))

    with open(PRIVATE_OUTPUT_FILE, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(
            f, fieldnames=["ip_net", "route"],
            lineterminator='\n',
        )
        writer.writeheader()
        writer.writerows(private_rows)
    print(
        f"Private routes written to {PRIVATE_OUTPUT_FILE} "
        f"({len(private_rows)} entries)"
    )

    # Look up public IPs
    ips = public_ips

    known_ranges = load_reg_cache()
    if known_ranges:
        print(f"Preloaded {len(known_ranges)} ranges from 'reg_cache.txt'")

    rows = []
    failures = []
    for i, ip in enumerate(ips):
        cached = find_matching_range(ip, known_ranges)
        if cached:
            inetnum_short = cached["inetnum"].split(";")[0][:40]
            print(f"[{i+1}/{len(ips)}] {ip} -> cached: {inetnum_short}")
            rows.append({"ip": ip, **cached})
            continue

        print(f"[{i+1}/{len(ips)}] Looking up {ip}...", end=" ", flush=True)
        fields = whois(ip)
        row = {"ip": ip, **fields}
        rows.append(row)
        inetnum_short = (
            fields["inetnum"].split(";")[0][:40]
            if fields["inetnum"] else "N/A"
        )
        print(f"-> {inetnum_short}")
        if not fields["inetnum"]:
            failures.append(ip)
        else:
            bounds = parse_inetnum_range(fields["inetnum"])
            if bounds:
                known_ranges.append((bounds, fields))
        if i < len(ips) - 1:
            time.sleep(DELAY)

    rows = group_by_route(rows)

    # Write CSV
    with open(OUTPUT_FILE, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(
            f, fieldnames=["ip"] + FIELDS,
            lineterminator='\n',
        )
        writer.writeheader()
        writer.writerows(rows)

    print(f"\nCSV written to {OUTPUT_FILE} ({len(rows)} rows)")
    if failures:
        print(f"Failed to get data for {len(failures)} IPs: {failures}")


if __name__ == "__main__":
    main()
