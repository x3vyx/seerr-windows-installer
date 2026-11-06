# Seerr Windows Installer (unofficial)

> Fork of [kraikov/seerr-windows-installer](https://github.com/kraikov/seerr-windows-installer)
> that follows Seerr releases on its own. See [Automatic updates](#automatic-updates).

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

Download the latest `Seerr-X.Y.Z-windows-x64-setup.exe` from
[Releases](https://github.com/x3vyx/seerr-windows-installer/releases),
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
├── updater\      # auto-update script, its log and download cache
├── install-service.cmd
└── uninstall-service.cmd

{data dir}\        # default C:\ProgramData\Seerr — selectable at install time
├── db\           # SQLite database
├── logs\         # service stdout/stderr (rotated at 10 MB)
├── backups\      # database + settings from before each update (last 5)
└── settings.json # written by Seerr on first run
```

The chosen data directory is stored under
`HKLM\SOFTWARE\Seerr\DataDir`, so subsequent re-runs of the installer
default to the existing path instead of orphaning your database.

The Windows service is registered as `Seerr` (`sc query Seerr`).

## Automatic updates

Two independent jobs keep an install current.

**GitHub Actions** checks for a new Seerr release every 6 hours. When it finds
one it builds the installer, then tests the real update path on a clean Windows
runner: a forced failure must roll back, and a normal upgrade must keep the
settings and a custom port. The release is only published if that passes.

**The `Seerr Auto Update` scheduled task** runs daily at 04:00 as SYSTEM, or at
the next boot if the PC was off. When there is a newer release it:

1. Downloads the installer and verifies its SHA-256.
2. Stops the service and copies the database and settings to `backups\`.
3. Runs the installer silently and waits for Seerr to report the new version.
4. If Seerr does not come back, restores the backup, reinstalls the previous
   version and skips that release until a newer one appears.

Seerr is down for the whole update, around 9 minutes on a desktop SSD. Most of
that is unpacking the app and Seerr's first start.

Log: `C:\Program Files\Seerr\updater\update.log`

```powershell
# Is an update available? (no admin needed)
powershell -ExecutionPolicy Bypass -File "C:\Program Files\Seerr\updater\Update-Seerr.ps1" -CheckOnly

# Update now (elevated)
Start-ScheduledTask -TaskName "Seerr Auto Update"

# Retry a release that was rolled back (elevated)
powershell -ExecutionPolicy Bypass -File "C:\Program Files\Seerr\updater\Update-Seerr.ps1" -Force
```

If an update was rolled back, Seerr's own sidebar keeps showing that an update
is available.

To turn this off, untick the option in the installer or run
`Disable-ScheduledTask -TaskName "Seerr Auto Update"` from an elevated shell.

To ship a packaging fix for a Seerr version that is already released:

```bash
gh workflow run build.yml -f seerr_ref=v3.5.1 -f revision=2   # releases v3.5.1-r2
```

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

CI does the build on `windows-latest`. Builds run on a schedule, or manually:

```bash
gh workflow run build.yml                                   # latest Seerr release
gh workflow run build.yml -f seerr_ref=v3.5.1 -f publish=false   # build and test only
```

### Build pipeline

1. Clone Seerr at the requested tag.
2. Read the Node version from upstream's `Dockerfile` and the pnpm version from
   its `package.json`, so upstream runtime bumps carry over automatically.
3. `pnpm install --frozen-lockfile` (full deps).
4. `pnpm build` (compiles server + Next.js).
5. Reinstall with `pnpm install --prod --frozen-lockfile` to drop dev deps.
6. Stage `dist/`, `.next/`, `public/`, `node_modules/`, `package.json`,
   `next.config.ts`, `seerr-api.yml` into `dist/app/`.
7. Download the Node win-x64 zip → `dist/node/node.exe`.
8. `choco install nssm` → `dist/service/nssm.exe`.
9. Run Inno Setup (`installer/setup.iss`) → `installer/Output/*.exe`.
10. Run `tests/Test-Upgrade.ps1` on a clean runner.
11. Publish the GitHub Release.

## Roadmap / known limitations

- **No code signing.** SmartScreen/AV flagging is possible. Cert support is
  scaffolded into the workflow — drop in a cert + secret to enable.
- **x64 only.** Win-arm64 prebuilds for `sharp` exist but `sqlite3`/`bcrypt`
  coverage is patchy. Add when stable.
- **No upgrade path from existing Postgres install.** SQLite-only. Migration
  from a Docker/Postgres deployment is a future feature.
- **Upgrades reset custom service settings.** The port is kept, but any other
  variable added with `nssm edit` has to be set again.
- **Auto-update trusts this repo's releases.** The task runs installers from it
  as SYSTEM and the checksum only proves the download is intact, so protect the
  GitHub account that owns the repo with 2FA.
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
