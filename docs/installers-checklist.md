> **Archived audit (2026-10-07).** Kept for history. Since then CI was fixed and **v0.2.1** shipped as a GitHub Release with AppImage, `.deb`, tar.gz, Setup.exe and zips (tag `v0.2.1` on `fdb57de`). See `docs/ROADMAP.md` for current work.

# Tacx Desktop — real installers checklist (for Tacx Build)

**Audit date:** 2026-10-07 20:26 CEST  
**Repo:** `nielsver/tacx-desktop` (private)  
**Audited SHA:** `bc64814` on `origin/main`  
  (`fix(ci): avoid dpkg-deb|grep -q SIGPIPE…`; packaging landed in `06dbecd`)  
**Prior Welcome→Connect:** `6853f13` (still an ancestor; workouts `0631ab6` already on main)  
**Do not push from audit agent.** Build owns commits / Release trigger / tags.

---

## Status snapshot (what already ships on main)

Almost everything Niels asked for is **already implemented and documented**. Treat this checklist as **verify + polish**, not a greenfield rewrite.

### Linux (Garuda primary)

| Artifact | On main? | Notes |
|----------|----------|--------|
| `tacx-desktop-linux-x64-*.tar.gz` | Yes | Bundle + `FIRST_RUN.txt` + `install.sh` / `uninstall.sh` + icon |
| User `.desktop` launcher (`install.sh`) | Yes | `~/.local/share/applications/com.nielsver.tacx_desktop.desktop` |
| AppImage `Tacx_Desktop-<ver>-x86_64.AppImage` | Yes | `scripts/package_linux_appimage.sh` + Release job |
| `.deb` `tacx-desktop_<ver>_amd64.deb` | Yes | `/opt/tacx-desktop` + `/usr/bin/tacx-desktop` + menu entry |
| BlueZ / Garuda first-run notes | Yes | `packaging/linux/FIRST_RUN.txt` + README Installers section |
| CI smoke | Yes | `scripts/test_linux_install.sh` + `scripts/test_linux_packaging.sh` |

### Windows

| Artifact | On main? | Notes |
|----------|----------|--------|
| Zip of `Release\` | Yes | Portable folder |
| Inno Setup `TacxDesktop-Setup-*.exe` | Yes | Start Menu + uninstaller + optional Desktop icon; `PrivilegesRequired=lowest` |
| First-run text in wizard | Yes | `packaging/windows/windows-first-run.txt` (BLE unpaired tip) |
| CI syntax check of `.iss` | Yes | Header/file presence only (no ISCC on Linux CI) |

### CI / Release wiring

- `.github/workflows/release.yml`: Linux → tar.gz + AppImage + `.deb`; Windows → zip + Setup.exe; macOS `.app` zip unchanged.
- Artifact names: `tacx-desktop-linux-x64`, `tacx-desktop-windows-x64`, `tacx-desktop-macos`.
- Tag `v*` attaches all files via `softprops/action-gh-release`.
- **No GitHub Release objects yet** (`list_releases` empty). End users still need Actions artifacts or a future `v*` tag.
- **Release run #11** on `bc64814` was `workflow_dispatch` / **in_progress** at audit time:  
  https://github.com/nielsver/tacx-desktop/actions/runs/37666604382  
  → **first job to prove AppImage + .deb + Setup.exe artifacts**.

### Explicit non-goals / not present (OK for v1)

- No MSIX / Store packaging  
- No Windows Authenticode signing (SmartScreen will warn)  
- No Linux `.rpm` / AUR PKGBUILD  
- No udev rules (BLE via BlueZ session bus; not USB HID)  
- `garuda_first_run_smoke.sh` still **tar.gz-oriented** (not AppImage)

---

## Recommended path (minimal — Build should follow this order)

1. **Wait for / fix Release #11** (`bc64814`) until Linux + Windows jobs are green.  
   Confirm artifact contents include:
   - `Tacx_Desktop-*-x86_64.AppImage`
   - `tacx-desktop_*_amd64.deb`
   - `tacx-desktop-linux-x64-*.tar.gz`
   - `TacxDesktop-Setup-*.exe`
   - `tacx-desktop-windows-x64-*.zip`
2. **Garuda manual UX** (Niels machine): download AppImage → `chmod +x` → run; BlueZ per `FIRST_RUN.txt`; Welcome→Connect. Optional: keep tar.gz/`install.sh` as fallback.
3. **Windows manual UX**: run Setup.exe → Start Menu launch → wizard shows unpaired-BLE tip → app starts.
4. Only if #11 fails: fix packaging scripts / workflow (do not reinvent; patch in place).
5. When green: optional `v0.2.x` tag so GitHub Releases hosts installers (user-friendly download page).
6. Small polish PRs only after green Release (see backlog below).

**Tools already chosen (keep them):**

- Linux one-click: **AppImage** (`appimagetool`, extract-if-no-FUSE path already in script)  
- Linux system package: **`.deb`** via `dpkg-deb` (secondary on Garuda; fine for Debian/Ubuntu)  
- Windows installer: **Inno Setup 6** via `choco install innosetup` on `windows-latest`  
- Keep portable **tar.gz** / **zip** as power-user fallbacks  

**Do not add** MSIX / WiX / Flatpak / Snap unless Niels asks — AppImage + Inno matches “real installer, user friendly” for Garuda + Windows.

---

## Ordered Build steps

### A. Verify Release #11 (blocking)

- [ ] Poll run 37666604382 until completed.
- [ ] Linux job: all three files uploaded under artifact `tacx-desktop-linux-x64`.
- [ ] Windows job: zip + `TacxDesktop-Setup-*.exe` under `tacx-desktop-windows-x64`.
- [ ] Download AppImage + Setup.exe locally (or ask Niels) and sanity-check sizes (> few MB, not empty).
- [ ] If AppImage step fails (FUSE/network): confirm extract-`appimagetool` fallback still runs; pin a release tag of appimagetool if `continuous` is flaky.
- [ ] If Inno/`choco` fails: retry with pinned Inno version or cache ISCC; keep `.iss` + `package_windows_installer.ps1`.

### B. Garuda end-user path (primary OS)

- [ ] Documented flow already in README — re-read “Installers (end users)” after any doc tweak.
- [ ] Preferred: AppImage in `~/Applications` or `~/Apps`, `chmod +x`, double-click or terminal.
- [ ] BlueZ: `bluez`/`bluez-utils`, `systemctl enable --now bluetooth`, user in `bluetooth` group, never `sudo` the app, trainer **unpaired** in KDE BT.
- [ ] Optional menu entry: either AppImage integration (Plasma) **or** tar.gz + `./install.sh`.
- [ ] Wayland escape hatch: `GDK_BACKEND=x11` (already in FIRST_RUN).
- [ ] Update `scripts/garuda_first_run_smoke.sh` to accept an **AppImage** path (chmod + run / `--appimage-extract-and-run` smoke) while keeping tar.gz support.

### C. Windows end-user path

- [ ] Setup.exe: per-user install (`PrivilegesRequired=lowest`), Start Menu shortcut, uninstaller, optional Desktop icon.
- [ ] Wizard shows `windows-first-run.txt` (unpaired BLE + quit Zwift/etc.).
- [ ] After install, Start Menu → Tacx Desktop launches `tacx_desktop.exe` from `{autopf}\Tacx Desktop` (or user-local equivalent).
- [ ] Keep zip artifact for portable / CI consumers.
- [ ] Backlog (non-blocking): Authenticode signing to reduce SmartScreen; sync Inno `VersionInfoVersion` with tag (today hardcoded `0.2.1.0` in `.iss`).

### D. Docs / UX consistency

- [ ] README Installers section matches actual artifact filenames from Release #11.
- [ ] FIRST_RUN.txt AppImage-first (already); ensure Garuda smoke + any agent messages say AppImage primary, `.deb` secondary.
- [ ] Avoid recommending `debtap` as primary on Garuda — prefer AppImage; mention `.deb` mainly for Debian/Ubuntu.

### E. Ship a user-facing Release (when Niels wants a download page)

- [ ] Tag e.g. `v0.2.1` from green `main` (after #11 + any hotfixes).
- [ ] Confirm GitHub Release assets list AppImage, `.deb`, tar.gz, Setup.exe, zip, macOS zip.
- [ ] Short release notes: Garuda → AppImage; Windows → Setup.exe; BlueZ / unpaired BLE one-liners.

### F. Collision / WIP rules

- [ ] Workouts already on main (`0631ab6`); do not rebase packaging over abandoned local branches.
- [ ] Prefer extending `scripts/package_*` and `release.yml` — do not duplicate parallel packaging trees.
- [ ] Leave audit file `/workspace/tacx-desktop-installers-checklist.md` out of the repo unless Niels wants it committed under `docs/`.

---

## Gap summary (for parent / Build)

| Need | Gap vs `bc64814` | Action |
|------|------------------|--------|
| Real Linux installer | **Mostly done** (AppImage + deb + launcher) | Prove via Release #11; Garuda smoke AppImage |
| Real Windows installer | **Mostly done** (Inno Setup.exe) | Prove via Release #11; manual Start Menu check |
| User-friendly downloads | No published GitHub Release yet | Tag `v*` after green run |
| Signing / SmartScreen | Unsigned Setup.exe | Later backlog |
| udev | None | Not required for BlueZ BLE |

**Bottom line:** Implementation landed in `06dbecd`–`bc64814`. Build’s job now is **green Release artifacts + Garuda/Windows manual UX + optional tag**, not a new packaging stack.
