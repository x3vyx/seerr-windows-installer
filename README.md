# Seerr Windows Installer (unofficial)

A native Windows installer for [Seerr](https://github.com/seerr-team/seerr) — no
Docker, no PostgreSQL.

- Bundles Node.js 22 LTS, the built Seerr app, and [NSSM](https://nssm.cc/) into
  a single `.exe`.
- Registers Seerr as a Windows service (auto-start on boot, log rotation,
  restart-on-failure).
- Uses **SQLite** as the database (no managed DB needed).
- Lets you pick where the database lives (defaults to `C:\ProgramData\Seerr`,
  remembered across re-installs). Data is preserved when you uninstall.

This repo contains **only the packaging**. Seerr itself is fetched from the
upstream repo at build time.

## Install

Download the latest `Seerr-vX.Y.Z-windows-x64-setup.exe` from
[Releases](https://github.com/kraikov/seerr-windows-installer/releases),
run it, pick a port, click through. The service starts automatically and your
browser opens to the setup wizard.

> **First-run note:** The installer is unsigned. Windows SmartScreen will warn
> on first launch — click "More info" → "Run anyway". (Code signing is on the
> roadmap.)

## What gets installed

```
C:\Program Files\Seerr\
├── app\          # built Seerr (dist, .next, node_modules, public, ...)
├── node\         # node.exe (embedded Node 22 LTS)
├── service\      # nssm.exe
├── install-service.cmd
└── uninstall-service.cmd

{data dir}\        # default C:\ProgramData\Seerr — selectable at install time
├── db\           # SQLite database
├── logs\         # service stdout/stderr (rotated at 10 MB)
└── settings.json # written by Seerr on first run
```

The chosen data directory is stored under
`HKLM\SOFTWARE\Seerr\DataDir`, so subsequent re-runs of the installer
default to the existing path instead of orphaning your database.

The Windows service is registered as `Seerr` (`sc query Seerr`).

## Configuration

Default port is **5055**. You can pick another at install time.

To change the port, data directory, or other env vars after install:

```cmd
nssm edit Seerr
```

(Use the `nssm.exe` shipped at `C:\Program Files\Seerr\service\nssm.exe`, or
install your own.)

Relevant env vars Seerr reads:

| Variable | Default | Notes |
| --- | --- | --- |
| `CONFIG_DIRECTORY` | `C:\ProgramData\Seerr` | DB, logs, settings live here |
| `PORT` | `5055` | HTTP listen port |
| `HOST` | (any) | Bind address |
| `NODE_ENV` | `production` | Don't change |

## Uninstall

Use *Add or Remove Programs*. The data directory at
`C:\ProgramData\Seerr` is **preserved** by default — delete it manually if you
want a clean wipe.

## Building locally

You can't fully build this on macOS/Linux — Windows runners are required for
native deps (`bcrypt`, `sharp`, `sqlite3`).

CI does the build on `windows-latest`. To trigger a build manually:

```bash
gh workflow run build.yml -f seerr_ref=v3.4.1
```

To build and attach the resulting installer to an existing release in one
shot:

```bash
gh release create v3.4.1 --prerelease --notes "..."
gh workflow run build.yml -f seerr_ref=v3.4.1 -f release=v3.4.1
```

### Build pipeline

1. Clone Seerr at the requested tag.
2. `pnpm install --frozen-lockfile` (full deps).
3. `pnpm build` (compiles server + Next.js).
4. Reinstall with `pnpm install --prod --frozen-lockfile` to drop dev deps.
5. Stage `dist/`, `.next/`, `public/`, `node_modules/`, `package.json`,
   `next.config.ts`, `seerr-api.yml` into `dist/app/`.
6. Download Node 22 win-x64 zip → `dist/node/node.exe`.
7. `choco install nssm` → `dist/service/nssm.exe`.
8. Run Inno Setup (`installer/setup.iss`) → `installer/Output/*.exe`.

## Roadmap / known limitations

- **No code signing.** SmartScreen/AV flagging is possible. Cert support is
  scaffolded into the workflow — drop in a cert + secret to enable.
- **x64 only.** Win-arm64 prebuilds for `sharp` exist but `sqlite3`/`bcrypt`
  coverage is patchy. Add when stable.
- **No upgrade path from existing Postgres install.** SQLite-only. Migration
  from a Docker/Postgres deployment is a future feature.
- **Update notifier inside Seerr is enabled.** Rerun the installer with a newer
  version to upgrade.
- **Service runs as `LocalSystem`** (NSSM default). Tightening to a dedicated
  low-privilege account is a follow-up.

## Why a separate repo (not a fork)?

A fork would create permanent merge maintenance against a fast-moving upstream.
This repo treats Seerr as a versioned input — `seerr_ref` in the workflow
pins the upstream tag we package. Any Windows-specific code fixes should be
upstreamed as PRs, not maintained here.

## License

The packaging code in this repo is MIT — see `LICENSE`. Seerr itself is MIT
licensed by the Seerr Team. NSSM is public domain.
