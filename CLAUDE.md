# CLAUDE.md — zbm-server

## Project Overview
Monolithic bash installer script for Ubuntu Server 24.04 with ZFSBootMenu.
Single file: `zbm-ubuntu-server-installer.sh`

## Script Architecture
- **Three modes**: `initial` (runs from live USB), `postreboot` (runs after first boot), `reinstall-zbm` (updates ZFSBootMenu on installed system)
- Steps 1–16 = initial install phase; steps in `postreboot` = Sanoid/snapshot setup + datapool
- Configuration variables are at the top of the script; user is prompted interactively at runtime

## Key Design Decisions
- **Monolithic rpool** — single dataset for everything (root, /home, /var) for easy rollback and clean unmount on shutdown; no zsys, no sub-datasets
- **Partition-based layout** — not whole-disk
- **User is created inside chroot** — `useradd` runs in `/mnt` chroot (Step 10), so the user does NOT exist on the live host system
- **`chown` on /mnt paths must use numeric UID/GID** — resolve from `/mnt/etc/passwd`, not by username, because the host doesn't know the new user

## Branch Structure
| Branch | Purpose |
|--------|---------|
| `main` | Full local repo with all project files |
| `master` | Legacy local branch (unused) |
| `origin/main` | Public GitHub repo — contains only 4 files (see below) |

## GitHub Push Workflow
Only 4 files are published publicly via orphan branch technique:
- `zbm-ubuntu-server-installer.sh`
- `README.md`
- `INSTALLATION-GUIDE.md`
- `QUICK-REFERENCE.md`

```bash
git checkout --orphan public-release
git rm -rf . --quiet
git checkout main -- zbm-ubuntu-server-installer.sh README.md INSTALLATION-GUIDE.md QUICK-REFERENCE.md
git commit -m "vX.Y.Z: description"
git push origin public-release:main --force
git checkout main
git branch -D public-release
```

Remote: `git@github.com:uplansible/zbm-ubuntu-server-installer.git`

## Versioning
Version is in the script header (line 5): `# Ubuntu Server 24.04 ZFSBootMenu Installation Script vX.Y.Z`
Increment patch on every push.

## Current Version
v3.0.35

## Future Work (not yet implemented)
- **Mirror / RAIDZ topologies**: Support multi-disk pools (mirror, raidz1, raidz2, raidz3).
  Requires: disk selection loop for N disks, topology prompt (single/mirror/raidz1/raidz2/raidz3),
  adjusted `zpool create` call to pass multiple vdevs/topology keyword.
  Reference: Sithuk ubuntu-server-zfsbootmenu script, pool creation section (~lines 300–500).
  Note: The current monolithic-dataset approach is compatible — only `zpool create` and disk
  selection need changing, not the dataset layout.
