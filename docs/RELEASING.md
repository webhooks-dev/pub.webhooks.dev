# RELEASING — the runbook for `release.yml`

How whk releases get from the private source repo (`app.webhooks.dev`) onto this repo's Releases
page. The workflow itself lives in the private repo (`.github/workflows/release.yml`, per its SPEC
§10); this runbook is public because release provenance should be inspectable by the people
installing the binaries. It names every secret involved — names and where they're created only,
never values.

## The flow

```
git tag v0.1.0 && git push origin v0.1.0          (in app.webhooks.dev, on a green main)
        │
        ▼
release.yml: matrix build of whk, whkd, whk-mcp
  macOS aarch64 ─ codesign + notarize ─ tar
  macOS x86_64  ─ codesign + notarize ─ tar
  Linux x86_64  ─────────────────────── tar
  Linux aarch64 (via cross) ─────────── tar
        │
        ▼
aggregate job: SHA256SUMS + latest.json
        │
        ▼
gh release create on webhooks-dev/pub.webhooks.dev   (PUB_RELEASE_TOKEN)
```

Only the three consumer binaries ship. The cell binaries (`whk-ingest`, `whk-egress`) are **not**
public artifacts — they deploy via the fleet pattern (SPEC §10). The Tauri `app/` bundle joins the
matrix once it has UI to ship, on the macOS legs (it's excluded from the Cargo workspace because
its Linux build needs GTK/WebKit — SPEC §2 D7).

## Cutting a release

1. On `main`, with CI green: bump `[workspace.package] version` in `Cargo.toml` to match the tag
   you're about to push (the workflow should refuse a tag whose version disagrees with the
   manifest — a mismatch here means `whk --version` lies).
2. `git tag v0.1.0 && git push origin v0.1.0`. Tags matching `v*` trigger `release.yml`; nothing
   else does.
3. Watch the run. When it finishes, the release `v0.1.0` on
   `webhooks-dev/pub.webhooks.dev` must have exactly: four `whk-0.1.0-<target>.tar.gz` assets,
   `SHA256SUMS`, and `latest.json`.
4. Smoke-test `install.sh` on at least one macOS and one Linux machine (it exercises the
   `releases/latest` redirect, the checksum gate, and the tarball layout in one shot).

**Fixing a bad release:** ship a new patch tag. Published assets are treated as immutable —
`latest.json` consumers and the installer verify by hash, and mutating assets under an existing
tag breaks anyone mid-download or pinned to it.

## Build matrix

| leg | runner | target triple | signed |
|---|---|---|---|
| macOS arm64 | `macos-14` (Apple silicon) | `aarch64-apple-darwin` | Developer ID + notarized |
| macOS x86_64 | `macos-14`, cross-compiling with `--target x86_64-apple-darwin` | `x86_64-apple-darwin` | Developer ID + notarized |
| Linux x86_64 | `ubuntu-latest` | `x86_64-unknown-linux-gnu` | no |
| Linux arm64 | `ubuntu-latest` + [`cross`](https://github.com/cross-rs/cross) (SPEC §10: "aarch64 via cross") | `aarch64-unknown-linux-gnu` | no |

Every leg builds `--release` for exactly `whk`, `whkd`, `whk-mcp` (`cargo build --release
--target <triple> -p whk-cli -p whkd -p whk-mcp`).

Windows has no leg — see the last section.

## Secrets

All of these are **repository secrets on the private source repo**: `app.webhooks.dev` → Settings
→ Secrets and variables → Actions → New repository secret. None of them belong in this repo, in
workflow logs, or in any file. This table is the complete list.

| secret | used for | where it's created |
|---|---|---|
| `APPLE_CERTIFICATE_P12_BASE64` | codesigning | The **Developer ID Application** certificate + private key, exported from Keychain Access as a `.p12`, then base64-encoded (`base64 -i cert.p12`). The certificate itself is issued at developer.apple.com → Certificates → type "Developer ID Application" (requires the paid Apple Developer Program). |
| `APPLE_CERTIFICATE_PASSWORD` | codesigning | The passphrase you chose when exporting the `.p12`. |
| `APPLE_TEAM_ID` | codesigning + notarization | The 10-character team ID, from developer.apple.com → Membership. |
| `APPLE_ID` | notarization | The Apple ID email of the developer account. `notarytool` authenticates as this account. |
| `APPLE_APP_SPECIFIC_PASSWORD` | notarization | Generated at account.apple.com → Sign-In and Security → App-Specific Passwords. `notarytool` cannot use the account password, and must not see it. |
| `PUB_RELEASE_TOKEN` | publishing the release here | A **fine-grained PAT** (github.com → Settings → Developer settings → Fine-grained personal access tokens) restricted to the single repository `webhooks-dev/pub.webhooks.dev`, with repository permission **Contents: Read and write** — that is how fine-grained PATs express releases-write; grant nothing else. |
| `REALTIME_RS_TOKEN` | fetching the private engine | A **fine-grained PAT** restricted to `tizz98/realtime-rs`, permission **Contents: Read-only**. The realtime-rs crates are private git dependencies pinned by rev in the workspace `Cargo.toml`. |

`REALTIME_RS_TOKEN` is needed by **every** build leg before the first `cargo` invocation:

```yaml
- name: Grant read access to the private engine
  env:
    REALTIME_RS_TOKEN: ${{ secrets.REALTIME_RS_TOKEN }}
  run: |
    git config --global \
      url."https://x-access-token:${REALTIME_RS_TOKEN}@github.com/tizz98/".insteadOf \
      "https://github.com/tizz98/"
```

This works because the workspace's `.cargo/config.toml` sets `net.git-fetch-with-cli = true`, so
cargo fetches git dependencies with the git CLI, which honors the `insteadOf` rewrite.

## macOS signing + notarization (what actually happens)

On each macOS leg, after the build:

1. **Ephemeral keychain.** Decode `APPLE_CERTIFICATE_P12_BASE64` to a temp `.p12`, create a
   throwaway keychain with a random password, `security import` the `.p12` into it (unlocked with
   `APPLE_CERTIFICATE_PASSWORD`, `-T /usr/bin/codesign`), and
   `security set-key-partition-list -S apple-tool:,apple:` so codesign can use the key without a
   UI prompt. The keychain is deleted in a cleanup step that runs even on failure.
2. **Codesign** each binary with the hardened runtime and a secure timestamp — both are
   notarization requirements:

   ```sh
   codesign --force --options runtime --timestamp \
     --sign "Developer ID Application: <name> ($APPLE_TEAM_ID)" whk whkd whk-mcp
   ```
3. **Notarize.** Zip the signed binaries (`ditto -c -k`) and submit:

   ```sh
   xcrun notarytool submit whk-notarize.zip \
     --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
     --password "$APPLE_APP_SPECIFIC_PASSWORD" --wait
   ```

   `--wait` blocks until Apple's verdict. On `Invalid`, fetch the reasons with
   `xcrun notarytool log <submission-id>` — the usual causes are a missing hardened runtime or
   timestamp.
4. **No stapling — deliberately.** `stapler staple` works on app bundles, disk images, and
   installer packages, not on flat Mach-O executables, so the notarization ticket cannot travel
   inside these tarballs. Gatekeeper resolves the ticket from Apple's servers on first assessment
   of a quarantined copy. Two consequences worth being honest about: a quarantined binary's first
   run on a fully offline machine can't confirm notarization; and `curl`-fetched files (the
   `install.sh` path) never get the quarantine attribute, so Gatekeeper typically doesn't engage
   there at all. The signature still protects integrity everywhere
   (`codesign --verify --strict`).
5. **Tar** the signed, notarized binaries. Tarring must happen after signing — the signature is
   embedded in each Mach-O, so order matters here only in that you must not sign a copy and ship
   another.

The Linux legs skip all of this; the tarballs are plain, and the checksums are the integrity
story.

## Artifact layout

A release for tag `v<version>` carries, and `install.sh` depends on, exactly this:

```
whk-<version>-aarch64-apple-darwin.tar.gz
whk-<version>-x86_64-apple-darwin.tar.gz
whk-<version>-x86_64-unknown-linux-gnu.tar.gz
whk-<version>-aarch64-unknown-linux-gnu.tar.gz
SHA256SUMS
latest.json
```

- `<version>` is the tag with the leading `v` stripped: tag `v0.1.0` → asset
  `whk-0.1.0-aarch64-apple-darwin.tar.gz`, `latest.json` `"version": "0.1.0"`.
- Each tarball contains `whk`, `whkd`, `whk-mcp` **at the top level** — no wrapping directory.
  `install.sh` extracts and expects the three files at the root; changing the layout breaks it.
- `SHA256SUMS` is generated by the aggregate job after all legs finish, in `sha256sum` output
  format (`<64-hex>  <filename>`), one line per tarball. Both `sha256sum -c` and
  `shasum -a 256 -c` accept it.
- `latest.json` — the machine-readable pointer, fetchable at the stable URL
  `…/releases/latest/download/latest.json`:

  ```json
  {
    "version": "0.1.0",
    "published_at": "2026-08-17T00:00:00Z",
    "targets": {
      "aarch64-apple-darwin":       { "url": "https://github.com/webhooks-dev/pub.webhooks.dev/releases/download/v0.1.0/whk-0.1.0-aarch64-apple-darwin.tar.gz", "sha256": "<64-hex>" },
      "x86_64-apple-darwin":        { "url": "…", "sha256": "…" },
      "x86_64-unknown-linux-gnu":   { "url": "…", "sha256": "…" },
      "aarch64-unknown-linux-gnu":  { "url": "…", "sha256": "…" }
    }
  }
  ```

  `version`: string, no leading `v`. `published_at`: RFC 3339 UTC. `targets`: one key per shipped
  target triple; each value has `url` (the release-asset download URL) and `sha256` (lowercase
  hex of the tarball, identical to the `SHA256SUMS` line). Consumers must ignore unknown fields;
  additions are non-breaking, and a key only ever means what this schema says.

Publishing is one `gh release create v<version> --repo webhooks-dev/pub.webhooks.dev
--verify-tag=false --title … --notes …` with `GH_TOKEN=$PUB_RELEASE_TOKEN` and the six files as
arguments. The tag exists only in the private repo; here the release itself carries the version.

## Windows: why not, and what it would take

There is no Windows build, and that's a decision, not an oversight (SPEC §2 D5, §10, §11): we
have no Authenticode signing identity, and an unsigned `whk.exe` means SmartScreen "unknown
publisher" interstitials and a steady drip of antivirus false positives — an experience we won't
ship. Adding Windows would take, in order:

1. A code-signing identity — an OV/EV certificate from a CA, or Azure Trusted Signing (the
   cheaper, CI-friendly route), plus its secrets joining the table above.
2. A `windows-latest` matrix leg building `x86_64-pc-windows-msvc` — plus actually porting and
   testing the Unix-assuming parts of the daemon surface (the `whkd` socket is a Unix domain
   socket; `~/.whk` permissions are chmod-based). This is porting work, not just a build flag.
3. A signing step (`signtool` or the Trusted Signing action) and a `.zip` asset
   (`whk-<version>-x86_64-pc-windows-msvc.zip`) joining `SHA256SUMS` and `latest.json`.
4. An install story: `install.sh` stays Unix-only; Windows would get README instructions first,
   winget/scoop manifests when someone commits to maintaining them.

Until someone owns all four, the honest answer stays "not yet" — it's in the README's platform
table so nobody has to discover it by failing.
