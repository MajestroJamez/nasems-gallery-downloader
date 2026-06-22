# Naše MŠ gallery downloader

Bulk-downloads **all** photos from a [Naše MŠ](https://nasems.cz) (`nasems.cz`) parent
account photo gallery and saves them to your computer, recreating the original album
folder structure.

Two equivalent implementations are provided — use whichever fits your platform:

| Script | Runtime | Needs |
|---|---|---|
| `download_nasems.ps1` | Windows PowerShell 5.1+ | nothing extra (pure PowerShell) |
| `download_nasems.sh` | Bash | `curl`, `jq`, `file` (built into Git Bash / Linux / macOS) |

> 🇨🇿 Česká verze (výchozí): [README.md](README.md)

---

## What it does

The gallery is not a set of plain links — it is loaded dynamically (AJAX) and is
**nested**: folders contain sub-folders, which eventually contain albums of photos.
The script:

1. **Logs in** with your gallery credentials and keeps the session cookie.
2. **Walks the whole folder tree** recursively (the same AJAX calls the website makes
   when you click a folder).
3. For each album it downloads the **full-size** image (the lightbox link, not the
   thumbnail) and saves it under `photos/<Folder>/<Sub-folder>/<Album>/`.
4. Mirrors the original folder names, cleaning characters that are illegal on the
   filesystem.

The result is a complete local copy of the gallery you can browse, back up, or archive.

## Usage

### PowerShell (Windows)

```powershell
# recommended: pass credentials via environment variables
$env:NASEMS_LOGIN    = 'your-login'
$env:NASEMS_PASSWORD = 'your-password'
powershell -ExecutionPolicy Bypass -File .\download_nasems.ps1 *> download.log

# or pass them as parameters
.\download_nasems.ps1 -Login your-login -Password your-password

# or just run it and let it prompt you
.\download_nasems.ps1
```

### Bash (Git Bash on Windows, Linux, macOS)

```bash
# recommended: environment variables
NASEMS_LOGIN=your-login NASEMS_PASSWORD=your-password ./download_nasems.sh > download.log 2>&1

# or as arguments
./download_nasems.sh your-login your-password

# or just run it and let it prompt you
./download_nasems.sh
```

Photos are written into a `photos/` sub-folder next to the script. Progress is printed
with timestamps; redirect it to a file (as shown) if you want a log.

> **Different kindergarten / host?** Set `NASEMS_URL` (e.g. `NASEMS_URL=https://nasems.cz`).
> The default is `https://nasems.cz`.

## Re-running & resuming

The script is **safe to run again**. It skips every photo already present as a
non-empty file, so an interrupted run (closed window, reboot, lost connection) just
picks up where it left off — no duplicates, no re-downloading.

## Output files

| Path | Meaning |
|---|---|
| `photos/…` | The downloaded gallery, mirroring the album tree |
| `download.log` | Timestamped run log (only if you redirect output) |
| `broken_on_server.txt` | Photos that are **empty on the server** (see below) |
| `failed_transient.txt` | Photos that failed for a temporary reason — re-run to retry |

## Notes & known quirks

- **Robust against drop-outs.** If the session expires or the connection blips, the
  script automatically logs back in and retries each photo a few times.
- **"Broken on server" photos.** Some photos are stored as **0 bytes on the server
  itself** — the server reports `HTTP 200` but sends no image data, for both the
  full-size picture *and* its thumbnail. These cannot be downloaded by any tool or
  browser; they are listed in `broken_on_server.txt` so you can ask the kindergarten
  to re-upload them.
- **Duplicate folder names.** If two sibling folders share the same name (the gallery
  allows it — and Windows additionally treats names case-insensitively, e.g.
  `HRUŠTIČKA` vs `Hruštička`), the first keeps the name and each further one gets a
  `_2`, `_3`, … suffix, so every album ends up in its own separate folder. The
  numbering follows the gallery's own order, so it stays the same on re-runs.
- **Filenames.** Each file is named `NNNNN_<photo-id>.<ext>` (a per-album running
  number plus the gallery's own id), and the type (jpg/png/gif/webp) is detected from
  the file contents.

## Security

The scripts contain **no credentials**. Provide them at run time via environment
variables, parameters, or the interactive prompt. The generated `.cookies.txt`,
`*.log`, `photos/` and manifest files are excluded by `.gitignore` and should not be
committed.

## Disclaimer

For downloading **your own** photos from a gallery **you have legitimate access to**
(e.g. your child's kindergarten). Respect the site's terms of use and the privacy of
other people who may appear in the photos.
