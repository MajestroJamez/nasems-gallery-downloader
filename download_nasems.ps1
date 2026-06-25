<#
  download_nasems.ps1 — native-PowerShell downloader for a "Naše MŠ" (nasems.cz) gallery.

  Recursively downloads all photos from the gallery, mirroring the folder tree into
  .\photos\. Re-runnable (skips files that already exist as non-empty).
  Native PowerShell — no curl.exe / jq / file needed. Works in Windows PowerShell 5.1+.

  Credentials (never hard-code them into a public repo) — any of:
      $env:NASEMS_LOGIN / $env:NASEMS_PASSWORD
      .\download_nasems.ps1 -Login xxx -Password yyy
      .\download_nasems.ps1                      # will prompt interactively

  Run (saving a log):
      powershell -ExecutionPolicy Bypass -File .\download_nasems.ps1 *> download.log
#>
param(
    [string]$Login    = $env:NASEMS_LOGIN,
    [string]$Password = $env:NASEMS_PASSWORD,
    [string]$BaseUrl  = $(if ($env:NASEMS_URL) { $env:NASEMS_URL } else { 'https://nasems.cz' })
)

Set-StrictMode -Off
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not $Login)    { $Login    = Read-Host 'Login' }
if (-not $Password) { $Password = Read-Host 'Password' }

# ---- config ----
$Base    = $BaseUrl.TrimEnd('/')
$Gallery = "$Base/prihlaseno/fotogalerie"

$Root       = Split-Path -Parent $MyInvocation.MyCommand.Path
$OutDir     = Join-Path $Root 'photos'
$TmpDir     = Join-Path $Root '.dltmp'
$BrokenList = Join-Path $Root 'broken_on_server.txt'
$FailList   = Join-Path $Root 'failed_transient.txt'
[void][System.IO.Directory]::CreateDirectory($OutDir)
[void][System.IO.Directory]::CreateDirectory($TmpDir)
[System.IO.File]::WriteAllText($BrokenList, '')
[System.IO.File]::WriteAllText($FailList, '')

$script:session = $null
# tracks how many sibling folders already used a given (case-insensitive) name,
# so duplicates get a _2 / _3 / ... suffix instead of merging into one folder
$script:SeenChild = @{}

function Log($msg) {
    Write-Host ('{0} {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $msg)
}

# sanitize a folder/file name for the Windows filesystem
function Sanitize($name) {
    $s = [string]$name
    $s = $s -replace '[\\/:*?"<>|]', '-'   # forbidden chars -> -
    $s = $s -replace '[\x00-\x1F]', ''     # control chars
    $s = $s -replace '\s+', ' '            # collapse whitespace
    $s = $s.Trim()
    $s = $s -replace '[ .]+$', ''          # Windows forbids trailing dots/spaces
    if ([string]::IsNullOrEmpty($s)) { $s = '_' }
    return $s
}

function Login {
    Log "Logging in as $Login ..."
    try {
        Invoke-WebRequest -Uri "$Base/" -SessionVariable s -UseBasicParsing -TimeoutSec 60 | Out-Null
        $script:session = $s
        Invoke-WebRequest -Uri "$Base/" -Method Post -WebSession $script:session -UseBasicParsing -TimeoutSec 60 `
            -Body @{ login = $Login; password = $Password } | Out-Null
        Log "  login done"
    } catch {
        Log "  login error: $($_.Exception.Message)"
    }
}

# POST an AJAX action and return the inner HTML (.result), or $null
function Invoke-AjaxResult($body) {
    try {
        $r = Invoke-WebRequest -Uri $Gallery -Method Post -Body $body -WebSession $script:session `
            -UseBasicParsing -TimeoutSec 60
        $j = $r.Content | ConvertFrom-Json
        return [string]$j.result
    } catch {
        return $null
    }
}

# fetch a gallery node; re-login and retry once if the session expired (empty result)
function Fetch-Node($slozka) {
    $body = @{ ajax = 'ajax'; what = 'fotogalerie'; action = 'load_html_fotogalerie_slozka'; slozka = "$slozka" }
    $out = Invoke-AjaxResult $body
    if ([string]::IsNullOrEmpty($out)) {
        Log "  session lost on node $slozka -> re-logging in"
        Login
        $out = Invoke-AjaxResult $body
    }
    return $out
}

# detect image type by magic bytes -> jpg/png/gif/webp or $null
function Get-ImageExt($path) {
    try {
        $fs = [System.IO.File]::OpenRead($path)
        $h = New-Object byte[] 12
        $n = $fs.Read($h, 0, 12)
        $fs.Close()
    } catch { return $null }
    if ($n -ge 3  -and $h[0] -eq 0xFF -and $h[1] -eq 0xD8 -and $h[2] -eq 0xFF) { return 'jpg' }
    if ($n -ge 4  -and $h[0] -eq 0x89 -and $h[1] -eq 0x50 -and $h[2] -eq 0x4E -and $h[3] -eq 0x47) { return 'png' }
    if ($n -ge 4  -and $h[0] -eq 0x47 -and $h[1] -eq 0x49 -and $h[2] -eq 0x46 -and $h[3] -eq 0x38) { return 'gif' }
    if ($n -ge 12 -and $h[0] -eq 0x52 -and $h[1] -eq 0x49 -and $h[2] -eq 0x46 -and $h[3] -eq 0x46 `
                  -and $h[8] -eq 0x57 -and $h[9] -eq 0x45 -and $h[10] -eq 0x42 -and $h[11] -eq 0x50) { return 'webp' }
    return $null
}

function Download-Photo($url, $destdir, $idx) {
    $token = $url.Substring($url.LastIndexOf('/') + 1)
    $base  = '{0:D5}_{1}' -f $idx, $token

    # Skip if this photo is already saved as a NON-EMPTY file. Match by TOKEN at
    # any index (not idx_token): albums can be reordered/extended between runs, so
    # a position-based check would re-download shifted photos and create duplicates.
    $existing = @(Get-ChildItem -LiteralPath $destdir -Filter "*_$token.*" -File -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0) {
        if ($existing[0].Length -gt 0) { return }
        Remove-Item -LiteralPath $existing[0].FullName -Force -ErrorAction SilentlyContinue
    }

    $tmp = Join-Path $TmpDir "$base.part"   # ASCII scratch path; moved into (Unicode) destdir after
    $empties = 0

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        $serverEmpty = $false
        try {
            Invoke-WebRequest -Uri $url -WebSession $script:session -OutFile $tmp `
                -UseBasicParsing -TimeoutSec 90
            if (Test-Path -LiteralPath $tmp) {
                if ((Get-Item -LiteralPath $tmp).Length -eq 0) {
                    $serverEmpty = $true                      # HTTP 200 + 0 bytes
                } else {
                    $ext = Get-ImageExt $tmp
                    if ($ext) {
                        $final = Join-Path $destdir "$base.$ext"
                        [System.IO.File]::Move($tmp, $final)  # .NET handles Unicode dest
                        return
                    }
                    # non-image body (e.g. login page after a redirect) -> session issue
                }
            }
        } catch {
            # connection error / non-2xx -> transient
        }
        if ($serverEmpty) {
            # HTTP 200 + empty body = the image is 0 bytes at the source. This is
            # deterministic, so DON'T re-login/hammer the server; one quick re-check
            # (no login) then record it as broken and move on.
            $empties++
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            if ($empties -ge 2) {
                Log "    SERVER-EMPTY (0 bytes at source, unrecoverable): $url"
                Add-Content -LiteralPath $BrokenList -Value $url -Encoding UTF8
                return
            }
            Start-Sleep -Seconds 1
            continue
        }
        # transient: connection error / non-2xx / non-image body -> re-login + backoff
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Log "    retry $attempt for $token (re-login)"
        Login
        Start-Sleep -Seconds ($attempt * 2)
    }
    Log "    ! failed after retries: $url"
    Add-Content -LiteralPath $FailList -Value $url -Encoding UTF8
}

function Recurse($slozka, $parent) {
    $html = Fetch-Node $slozka
    if ([string]::IsNullOrEmpty($html)) { Log "  (empty node $slozka)"; return }

    $m = [regex]::Match($html, '<label>([^<]*)</label>')
    $title = if ($m.Success) { $m.Groups[1].Value } else { "slozka_$slozka" }
    $title = Sanitize $title
    # de-duplicate sibling folders that resolve to the same name (compared
    # case-insensitively, as Windows does): the first keeps the name, the next
    # ones get a _2 / _3 / ... suffix so they no longer merge into one folder.
    $key = $parent + '||' + $title.ToLowerInvariant()
    $n = [int]$script:SeenChild[$key] + 1
    $script:SeenChild[$key] = $n
    if ($n -gt 1) { $title = "${title}_$n" }
    $path = Join-Path $parent $title

    # child folder ids = container divs
    $children = @([regex]::Matches($html, "<div class='container '[^>]*id='(\d+)'") |
                  ForEach-Object { $_.Groups[1].Value })

    if ($children.Count -gt 0) {
        Log "FOLDER: $path  ($title) -> $($children.Count) subfolders"
        foreach ($cid in $children) { Recurse $cid $path }
        return
    }

    # leaf album: full-size lightbox hrefs
    $photos = @([regex]::Matches($html, 'class="lightbox[^"]*"\s+href="(' + [regex]::Escape($Base) + '/fotografie/[^"]+)"') |
                ForEach-Object { $_.Groups[1].Value })
    if ($photos.Count -eq 0) { Log "  (no photos, no subfolders in $path)"; return }

    [void][System.IO.Directory]::CreateDirectory($path)
    Log "ALBUM:  $path  -> $($photos.Count) photos"
    # list the album's already-downloaded (non-empty) photo tokens ONCE, so the
    # skip test below is an in-memory lookup instead of a filesystem scan per photo.
    $have = @{}
    foreach ($fi in (Get-ChildItem -LiteralPath $path -File -ErrorAction SilentlyContinue)) {
        if ($fi.Length -gt 0) {
            $nm = $fi.BaseName                                # idx_token
            $have[$nm.Substring($nm.IndexOf('_') + 1)] = $true
        }
    }
    $idx = 0
    foreach ($u in $photos) {
        $idx++
        $tok = $u.Substring($u.LastIndexOf('/') + 1)
        if ($have.ContainsKey($tok)) { continue }             # already downloaded -> skip
        Download-Photo $u $path $idx
    }
}

function Main {
    Login
    Log "Fetching root gallery ..."
    try {
        $root = (Invoke-WebRequest -Uri $Gallery -WebSession $script:session -UseBasicParsing -TimeoutSec 60).Content
    } catch { $root = '' }
    $rootIds = @([regex]::Matches($root, "<div class='container '[^>]*id='(\d+)'") |
                 ForEach-Object { $_.Groups[1].Value })
    Log "Root folders: $($rootIds.Count)"
    foreach ($id in $rootIds) { Recurse $id $OutDir }

    $nFiles  = @(Get-ChildItem -LiteralPath $OutDir -Recurse -File -ErrorAction SilentlyContinue).Count
    $nBroken = @(Get-Content -LiteralPath $BrokenList -ErrorAction SilentlyContinue | Where-Object { $_ -ne '' }).Count
    $nFail   = @(Get-Content -LiteralPath $FailList   -ErrorAction SilentlyContinue | Where-Object { $_ -ne '' }).Count
    Log "DONE. Photos in: $OutDir"
    Log "Total files: $nFiles"
    Log "Broken on server (0 bytes at source, unrecoverable): $nBroken -> $BrokenList"
    Log "Transient failures (should be retried): $nFail -> $FailList"
}

Main
