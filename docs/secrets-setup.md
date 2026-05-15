# Secrets setup for VPN automation

Step-by-step guide to prepare **GPG**, **pass**, and **pass-otp** on a fresh Linux system so VPN tools can read LDAP passwords and generate TOTP codes locally. Nothing in this document should contain real secrets.

**Related:** [Multi-VPN automation plan](plans/multi-vpn-automation.md) · future `ga_qr_decode.py` · `pass` entries referenced from `vpn-profiles.yaml`.

---

## 1. Install packages

Debian/Ubuntu:

```bash
sudo apt update
sudo apt install gnupg pass oathtool qrencode zbar-tools libzbar0
```

**pass-otp** is a separate extension (not bundled with `pass`):

```bash
sudo apt install pass-extension-otp
```

If that package is unavailable:

```bash
git clone https://github.com/tadfisher/pass-otp.git
cd pass-otp
make
sudo make install
```

Confirm:

```bash
pass version
pass otp --help
oathtool --version
```

Optional (for decoding Google Authenticator export QR images in-repo):

```bash
pip install pyzbar Pillow
```

---

## 2. Create a GPG key (first time only)

```bash
gpg --full-generate-key
```

Suggested choices:

- Kind: RSA and RSA, **4096** bits, **or** Ed25519 / Curve25519 if offered  
- Expiry: `0` (no expiry) or `2y` — set a calendar reminder to extend  
- Real name / email: your choice (email helps identify the key)

List your key:

```bash
gpg --list-secret-keys --keyid-format=long
```

Example line: `sec   rsa4096/ABCD1234EF567890  …` — the ID after the slash is the **long key ID** for `pass init`.

**Revocation certificate** (do once, store offline encrypted):

```bash
gpg --output revoke.asc --gen-revoke ABCD1234EF567890
```

**Pinentry in terminal/SSH** — if passphrase prompts fail, add to `~/.bashrc`:

```bash
export GPG_TTY=$(tty)
```

Use `gpg-agent` (default on desktop) so you type the GPG passphrase once per session.

---

## 3. Initialize pass

```bash
pass init ABCD1234EF567890
```

Replace with your long key ID from step 2.

Smoke test:

```bash
pass insert test/hello
pass show test/hello
pass rm -r test
```

The password store lives in `~/.password-store/` (directory mode `700`). Entries are GPG-encrypted files.

**Backup:** back up your **GPG private key** and **revocation certificate**. Backing up only `~/.password-store/` without the private key is useless.

---

## 4. Import TOTP from Google Authenticator export

Google Authenticator does not show existing secrets in the UI. Use **Transfer accounts → Export** to get QR code(s).

### 4a. Decode the QR

With `ga_qr_decode.py` (when added to the repo):

```bash
./ga_qr_decode.py ~/Pictures/ga-export.png
```

Or only the URI:

```bash
zbarimg -q --raw ~/Pictures/ga-export.png
./ga_qr_decode.py --uri 'otpauth-migration://offline?data=...'
```

Note the **secret** (base32) and **account** name / **issuer** for the VPN entry.
These will be needed in step 4b.

If you have many accounts, Google may show **multiple** export QR codes — repeat for each image.

### 4b. Store in pass-otp

```bash
pass otp insert -s -i <issuer> -a <account> vpn/sber-totp
```

Paste the base32 secret when prompted and press enter. Note: secret will not be echoed. Repeat for confirmation prompt.

### 4c. Verify against the phone

```bash
pass otp vpn/sber-totp
```

The 6-digit code must match Google Authenticator in the **same 30-second window**.

**Without pass-otp** — store only the base32 string:

```bash
pass insert -m vpn/sber-totp-secret
oathtool -b --totp=SHA1 "$(pass show vpn/sber-totp-secret)"
```

Copy to clipboard (if `xclip` or `wl-copy` installed):

```bash
pass otp -c vpn/sber-totp
```

---

## 5. Store LDAP / VPN password

```bash
pass insert -m vpn/sber-ldap
```

Enter the corporate VPN password (update later with `pass edit vpn/sber-ldap` when IT rotates it).

Keep LDAP and TOTP in **separate** entries.

---

## 6. Recommended naming (for orchestrator)

```
vpn/
  sber-ldap          # pass insert -m
  sber-totp          # pass otp insert
```

Profile YAML will reference:

```yaml
secrets:
  password: pass:vpn/sber-ldap
  totp: pass:vpn/sber-totp
```

---

## 7. Security rules

- Do **not** commit QR screenshots, terminal output from `ga_qr_decode`, or `~/.password-store/`  
- Delete export screenshots after successful `pass otp insert`  
- TOTP secret = full second factor; anyone with secret + LDAP password can connect  
- Avoid cloud QR decoders (e.g. 2fa.live) for production — use local `ga_qr_decode` + `pass`  
- Understand trust model before `pass git init` and pushing to a remote  

---

## 8. Checklist before running VPN automation

- [ ] `gpg --list-secret-keys` shows your key  
- [ ] `pass ls` lists `vpn/...` entries  
- [ ] `pass otp vpn/...` matches phone  
- [ ] GPG agent unlocked in the session where scripts run  
- [ ] LDAP entry updated after password rotation  

---

## Troubleshooting

| Problem | Fix |
|--------|-----|
| `pass otp: unknown command` | Install pass-otp (section 1) |
| `gpg: decryption failed: No secret key` | Wrong key, or `pass init` used different key ID |
| No pinentry popup | `export GPG_TTY=$(tty)`; install `pinentry-gtk2` or `pinentry-curses` |
| `pass otp` ≠ phone | Wrong secret, clock skew (`timedatectl`), or wrong algorithm |
| pyzbar fails | `sudo apt install libzbar0` |

---

## Next steps

1. Complete the checklist above  
2. Copy `vpn-profiles.json.example` → `vpn-profiles.json` and set `pass:` paths / server names  
3. Configure [sudoers for openconnect](sudoers-openconnect.example)  
4. Connect: `./vpn.sh up` (or per-profile)  
5. Verify routing: `./collect.sh`, then `./test-sites` (after Sber/AdGuard profiles are up)  
