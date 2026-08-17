# pub.webhooks.dev

Public distribution for the **whk** consumer surface of webhooks.dev: release binaries and
checksums, nothing else. The source lives in a private repo (`app.webhooks.dev`, built on the
[realtime-rs](https://github.com/tizz98/realtime-rs) engine); this repo exists so releases have a
public home. The tree holds `install.sh`, this README, and the release runbook — the binaries
themselves are on the [Releases](https://github.com/webhooks-dev/pub.webhooks.dev/releases) page.

Each release ships three binaries:

| binary | what it is |
|---|---|
| `whk` | the CLI: `whk listen --forward localhost:3000`, `tail`, `replay`, endpoint management |
| `whkd` | the resident daemon: owns the cell connection, routes, and consumer offsets |
| `whk-mcp` | a stdio MCP server exposing the same surface to coding agents |

The cell-side binaries (`whk-ingest`, `whk-egress`) are **not** published here — they are
server-side deployables, not end-user artifacts.

## Supported platforms

| platform | target triple | artifact |
|---|---|---|
| macOS, Apple silicon | `aarch64-apple-darwin` | tarball; binaries **signed (Developer ID) + notarized** |
| macOS, Intel | `x86_64-apple-darwin` | tarball; binaries **signed (Developer ID) + notarized** |
| Linux, x86_64 | `x86_64-unknown-linux-gnu` | plain tarball |
| Linux, arm64 | `aarch64-unknown-linux-gnu` | plain tarball |
| Windows | — | **not yet.** We have no Windows code-signing identity and won't ship binaries that greet users with SmartScreen warnings. What adding it would take is spelled out in [docs/RELEASING.md](docs/RELEASING.md#windows-why-not-and-what-it-would-take). |

## Install

### One-liner

```sh
curl -fsSL https://raw.githubusercontent.com/webhooks-dev/pub.webhooks.dev/main/install.sh | sh
```

Installs `whk`, `whkd`, and `whk-mcp` to `~/.local/bin` (set `PREFIX=/some/prefix` to install to
`$PREFIX/bin` instead). No sudo. The script downloads the tarball **and** `SHA256SUMS` from the
latest release and verifies the checksum before installing anything — a mismatch is a hard fail.
Re-running is safe and is also how you upgrade.

Prefer to read before you pipe? Same script, two steps:

```sh
curl -fsSL -o install.sh https://raw.githubusercontent.com/webhooks-dev/pub.webhooks.dev/main/install.sh
sh install.sh   # after reading it
```

### Manual download + verify

1. From the [latest release](https://github.com/webhooks-dev/pub.webhooks.dev/releases/latest),
   download the tarball for your platform plus `SHA256SUMS`. Assets are named
   `whk-<version>-<target>.tar.gz`, e.g. `whk-0.1.0-aarch64-apple-darwin.tar.gz`.

2. Verify the checksum — don't skip this:

   ```sh
   # macOS
   grep 'whk-0.1.0-aarch64-apple-darwin.tar.gz' SHA256SUMS | shasum -a 256 -c
   # Linux
   grep 'whk-0.1.0-x86_64-unknown-linux-gnu.tar.gz' SHA256SUMS | sha256sum -c
   ```

   Expect exactly one `OK`. Anything else: delete the file and re-download.

3. Unpack (the three binaries sit at the top level of the tarball) and put them on your `PATH`:

   ```sh
   tar -xzf whk-<version>-<target>.tar.gz
   install -m 0755 whk whkd whk-mcp ~/.local/bin/
   ```

### macOS and Gatekeeper

The macOS binaries are codesigned with a **Developer ID Application** certificate (hardened
runtime, timestamped) and **notarized** by Apple, so Gatekeeper accepts them. Two honest details:

- Notarization tickets can't be stapled to plain command-line executables, so Gatekeeper's first
  assessment of a quarantined copy checks Apple's servers online. Files fetched by `curl` (the
  installer path) don't carry the quarantine attribute in the first place.
- You can check a binary yourself: `codesign --verify --deep --strict whk` and
  `spctl --assess --type execute whk`.

### For scripts and automation

Every release also carries a `latest.json` manifest, fetchable at a stable URL:

```
https://github.com/webhooks-dev/pub.webhooks.dev/releases/latest/download/latest.json
```

```json
{
  "version": "0.1.0",
  "published_at": "2026-08-17T00:00:00Z",
  "targets": {
    "aarch64-apple-darwin": { "url": "https://…/whk-0.1.0-aarch64-apple-darwin.tar.gz", "sha256": "…" }
  }
}
```

One entry per shipped target triple. Verify the `sha256` after download, same as the installer
does.

## Where releases come from

Releases are tag-driven: pushing a `v*` tag in the private source repo runs its `release.yml` — a
matrix build (macOS legs sign + notarize; Linux legs produce plain tarballs), then `SHA256SUMS`
and `latest.json` are generated and everything is published to this repo's Releases with a
fine-grained token. Nothing is uploaded by hand. The full runbook — matrix, secrets (names only,
never values), signing/notarization flow, and limitations — is
[docs/RELEASING.md](docs/RELEASING.md).

## Security

There's no formal security policy yet (this is an MVP). If you find a vulnerability in these
binaries, the installer, or the release pipeline, report it privately to
**dev.tizz98@gmail.com** — please don't open a public issue for it, and don't include webhook
payloads or secrets in the report.
