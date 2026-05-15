#!/usr/bin/env python3
"""Decode Google Authenticator export QR or single otpauth://totp URIs."""

from __future__ import annotations

import argparse
import base64
import json
import sys
from dataclasses import asdict, dataclass
from typing import List, Optional
from urllib.parse import parse_qs, unquote, urlparse

ALGORITHMS = {0: "SHA1", 1: "SHA1", 2: "SHA256", 3: "SHA512", 4: "MD5"}
DIGITS = {0: 6, 1: 6, 2: 8}
OTP_TYPES = {0: "totp", 1: "hotp", 2: "totp"}


@dataclass
class OtpAccount:
    secret_base32: str
    name: str = ""
    issuer: str = ""
    algorithm: str = "SHA1"
    digits: int = 6
    otp_type: str = "totp"
    counter: Optional[int] = None


def read_varint(buf: bytes, i: int) -> tuple[int, int]:
    n = 0
    shift = 0
    while i < len(buf):
        b = buf[i]
        i += 1
        n |= (b & 0x7F) << shift
        if not (b & 0x80):
            return n, i
        shift += 7
    raise ValueError("truncated varint")


def read_delimited(buf: bytes, i: int) -> tuple[bytes, int]:
    length, i = read_varint(buf, i)
    end = i + length
    if end > len(buf):
        raise ValueError("truncated delimited field")
    return buf[i:end], end


def skip_field(buf: bytes, i: int, wire: int) -> int:
    if wire == 0:
        _, i = read_varint(buf, i)
        return i
    if wire == 1:
        return i + 8
    if wire == 2:
        _, i = read_delimited(buf, i)
        return i
    if wire == 5:
        return i + 4
    raise ValueError(f"unsupported wire type {wire}")


def bytes_to_base32(secret: bytes) -> str:
    return base64.b32encode(secret).decode("ascii").rstrip("=")


def parse_otp_parameters(msg: bytes) -> OtpAccount:
    secret: Optional[bytes] = None
    name = ""
    issuer = ""
    algorithm = "SHA1"
    digits = 6
    otp_type = "totp"
    counter: Optional[int] = None
    i = 0
    while i < len(msg):
        tag, i = read_varint(msg, i)
        field, wire = tag >> 3, tag & 7
        if field == 1 and wire == 2:
            secret, i = read_delimited(msg, i)
        elif field == 2 and wire == 2:
            name, i = read_delimited(msg, i)
            name = name.decode("utf-8", errors="replace")
        elif field == 3 and wire == 2:
            issuer, i = read_delimited(msg, i)
            issuer = issuer.decode("utf-8", errors="replace")
        elif field == 4 and wire == 0:
            val, i = read_varint(msg, i)
            algorithm = ALGORITHMS.get(val, "SHA1")
        elif field == 5 and wire == 0:
            val, i = read_varint(msg, i)
            digits = DIGITS.get(val, 6)
        elif field == 6 and wire == 0:
            val, i = read_varint(msg, i)
            otp_type = OTP_TYPES.get(val, "totp")
        elif field == 7 and wire == 0:
            counter, i = read_varint(msg, i)
        else:
            i = skip_field(msg, i, wire)
    if not secret:
        raise ValueError("OtpParameters missing secret")
    return OtpAccount(
        secret_base32=bytes_to_base32(secret),
        name=name,
        issuer=issuer,
        algorithm=algorithm,
        digits=digits,
        otp_type=otp_type,
        counter=counter,
    )


def parse_migration_payload(data: bytes) -> List[OtpAccount]:
    accounts: List[OtpAccount] = []
    i = 0
    while i < len(data):
        tag, i = read_varint(data, i)
        field, wire = tag >> 3, tag & 7
        if field == 1 and wire == 2:
            msg, i = read_delimited(data, i)
            accounts.append(parse_otp_parameters(msg))
        else:
            i = skip_field(data, i, wire)
    if not accounts:
        raise ValueError("no accounts in migration payload")
    return accounts


def parse_totp_uri(uri: str) -> OtpAccount:
    parsed = urlparse(uri.strip())
    if parsed.scheme != "otpauth" or parsed.hostname != "totp":
        raise ValueError("expected otpauth://totp/...")
    label = unquote(parsed.path.lstrip("/"))
    params = parse_qs(parsed.query)
    secret = (params.get("secret") or [""])[0]
    if not secret:
        raise ValueError("missing secret= in URI")
    issuer = (params.get("issuer") or [""])[0]
    if not issuer and ":" in label:
        issuer, label = label.split(":", 1)
    algo = (params.get("algorithm") or ["SHA1"])[0].upper()
    digits = int((params.get("digits") or ["6"])[0])
    return OtpAccount(
        secret_base32=secret.upper().replace(" ", ""),
        name=label,
        issuer=issuer,
        algorithm=algo,
        digits=digits,
        otp_type="totp",
    )


def parse_uri(uri: str) -> List[OtpAccount]:
    uri = uri.strip()
    if uri.startswith("otpauth-migration:"):
        parsed = urlparse(uri)
        raw = parse_qs(parsed.query).get("data")
        if not raw:
            raise ValueError("migration URI missing data=")
        pad = "=" * ((4 - len(raw[0]) % 4) % 4)
        payload = base64.b64decode(raw[0] + pad)
        return parse_migration_payload(payload)
    if uri.startswith("otpauth://"):
        return [parse_totp_uri(uri)]
    raise ValueError("not an otpauth or otpauth-migration URI")


def decode_qr_image(path: str) -> str:
    try:
        from PIL import Image
        from pyzbar.pyzbar import decode as zbar_decode
    except ImportError as e:
        raise SystemExit(
            "Install: pip install pyzbar Pillow  and  sudo apt install libzbar0"
        ) from e
    codes = zbar_decode(Image.open(path))
    if not codes:
        raise ValueError(f"no QR found in {path}")
    return codes[0].data.decode("utf-8", errors="replace")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("image", nargs="?", help="PNG/JPEG with QR code")
    ap.add_argument("--uri", help="otpauth:// or otpauth-migration:// string")
    ap.add_argument("--json", action="store_true", help="JSON output")
    args = ap.parse_args()

    if args.uri:
        uri = args.uri
    elif args.image:
        uri = decode_qr_image(args.image)
    else:
        ap.error("provide IMAGE or --uri")

    accounts = parse_uri(uri)

    if args.json:
        print(json.dumps([asdict(a) for a in accounts], indent=2))
    else:
        for n, acc in enumerate(accounts, 1):
            title = acc.issuer or acc.name or f"account-{n}"
            print(f"=== {title} ===")
            print(f"  name:      {acc.name}")
            print(f"  issuer:    {acc.issuer}")
            print(f"  secret:    {acc.secret_base32}")
            print(f"  algorithm: {acc.algorithm}")
            print(f"  digits:    {acc.digits}")
            print(f"  type:      {acc.otp_type}")
            if acc.counter is not None:
                print(f"  counter:   {acc.counter}")
            print()
        print("Verify: oathtool -b --totp=SHA1 '<secret>'  (match Google Authenticator)")
        print("Store:  pass otp insert <name>  then paste secret when prompted")

    return 0


if __name__ == "__main__":
    sys.exit(main())
