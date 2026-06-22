#!/usr/bin/env bash
# Recursively downloads all photos from a "Naše MŠ" (nasems.cz) photo gallery.
# Mirrors the gallery folder tree into ./photos/. Re-runnable (skips files that
# already exist as non-empty).
#
# Credentials (never hard-code them into a public repo):
#   NASEMS_LOGIN=xxx NASEMS_PASSWORD=yyy ./download_nasems.sh
#   ./download_nasems.sh <login> <password>
#   ./download_nasems.sh                      # will prompt interactively
#
# Optional: NASEMS_URL to point at a different host (default https://nasems.cz)
#
# Requires: bash, curl, jq, file (all present in Git Bash / Linux / macOS).
set -uo pipefail

BASE="${NASEMS_URL:-https://nasems.cz}"
GALLERY="$BASE/prihlaseno/fotogalerie"
LOGIN="${NASEMS_LOGIN:-${1:-}}"
PASSWORD="${NASEMS_PASSWORD:-${2:-}}"
[ -z "$LOGIN" ]    && { read -rp  "Login: " LOGIN; }
[ -z "$PASSWORD" ] && { read -rsp "Password: " PASSWORD; echo; }

OUTDIR="$(cd "$(dirname "$0")" && pwd)/photos"
COOKIES="$(dirname "$0")/.cookies.txt"
# ASCII-only scratch dir: native curl.exe cannot write into paths containing
# characters outside the Windows codepage (emoji, e-with-breve, etc.), so we
# download to an ASCII temp file here and let bash mv it into the Unicode folder.
TMPD="$(cd "$(dirname "$0")" && pwd)/.dltmp"
mkdir -p "$OUTDIR" "$TMPD"
# manifests written next to the script
BROKENLIST="$(cd "$(dirname "$0")" && pwd)/broken_on_server.txt"
FAILLIST="$(cd "$(dirname "$0")" && pwd)/failed_transient.txt"
: > "$BROKENLIST"
: > "$FAILLIST"

log(){ printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

# sanitize a folder/file name for the filesystem
sanitize(){
  local s
  # map forbidden chars (\ / : * ? " < > |) to '-', strip control chars, trim.
  # Windows forbids trailing dots and spaces in a path component -> strip them,
  # otherwise native curl.exe cannot write files into the directory.
  s="$(printf '%s' "$1" \
    | tr '\\/:*?"<>|' '----------' \
    | tr -d '\000-\037' \
    | sed 's/[[:space:]]\+/ /g; s/^ *//; s/[ .]*$//')"
  [ -z "$s" ] && s="_"
  printf '%s' "$s"
}

login(){
  log "Logging in as $LOGIN ..."
  curl -s -c "$COOKIES" "$BASE/" -o /dev/null
  local code
  code=$(curl -s -b "$COOKIES" -c "$COOKIES" -o /dev/null -w '%{http_code}' \
    --data-urlencode "login=$LOGIN" --data-urlencode "password=$PASSWORD" "$BASE/")
  # expect 302 redirect to /prihlaseno
  log "  login response: $code"
}

# raw fetch of a gallery node -> inner HTML (may be empty if session expired)
_fetch_raw(){
  local slozka="$1"
  curl -s -b "$COOKIES" \
    --data-urlencode "ajax=ajax" \
    --data-urlencode "what=fotogalerie" \
    --data-urlencode "action=load_html_fotogalerie_slozka" \
    --data-urlencode "slozka=$slozka" \
    "$GALLERY" | jq -r '.result // empty'
}

# fetch a gallery node; re-login and retry once if the session has expired
fetch_node(){
  local slozka="$1" out
  out="$(_fetch_raw "$slozka")"
  if [ -z "$out" ]; then
    log "  session lost on node $slozka -> re-logging in"
    login
    out="$(_fetch_raw "$slozka")"
  fi
  printf '%s' "$out"
}

download_photo(){
  local url="$1" destdir="$2" idx="$3"
  local token="${url##*/}"
  local base
  base="$(printf '%05d_%s' "$idx" "$token")"
  # skip only if already downloaded as a NON-EMPTY file; drop empty/corrupt prior tries
  local existing
  existing="$(ls "$destdir/$base".* 2>/dev/null | head -1)"
  if [ -n "$existing" ]; then
    if [ -s "$existing" ]; then return 0; fi
    rm -f "$existing"
  fi

  # temp file lives in the ASCII scratch dir ($base = idx_token, both ASCII);
  # curl writes here, then bash mv places it into the (possibly Unicode) destdir
  local tmp="$TMPD/$base.part" attempt mime ext code cexit allempty=1
  for attempt in 1 2 3 4 5; do
    rm -f "$tmp"
    code="$(curl -s --max-time 90 -b "$COOKIES" -o "$tmp" -w '%{http_code}' "$url")"
    cexit=$?
    if [ "$cexit" -eq 0 ] && [ "$code" = "200" ] && [ -s "$tmp" ]; then
      mime="$(file -b --mime-type "$tmp" 2>/dev/null)"
      case "$mime" in
        image/jpeg) ext=jpg ;;
        image/png)  ext=png ;;
        image/gif)  ext=gif ;;
        image/webp) ext=webp ;;
        image/*)    ext="${mime##*/}" ;;
        *)  ext="" ;;   # not an image -> treat as failure below
      esac
      if [ -n "$ext" ]; then
        mv -f "$tmp" "$destdir/$base.$ext"
        return 0
      fi
    fi
    # classify the failure. "HTTP 200 with an empty body" = the image is 0 bytes
    # on the server (broken/missing source); anything else is transient/session.
    if ! { [ "$cexit" -eq 0 ] && [ "$code" = "200" ] && [ ! -s "$tmp" ]; }; then
      allempty=0
    fi
    rm -f "$tmp"
    log "    retry $attempt for $token (http=$code curl=$cexit, re-login)"
    login
    sleep $((attempt * 2))
  done
  if [ "$allempty" -eq 1 ]; then
    # every attempt returned 200 + 0 bytes, even right after a fresh login ->
    # the photo is empty on the server and cannot be downloaded by anyone.
    log "    SERVER-EMPTY (0 bytes at source, unrecoverable): $url"
    printf '%s\n' "$url" >> "$BROKENLIST"
  else
    log "    ! failed after retries: $url"
    printf '%s\n' "$url" >> "$FAILLIST"
  fi
  return 1
}

# recurse(slozka_id, parent_path)
recurse(){
  local slozka="$1" parent="$2"
  local html title path
  html="$(fetch_node "$slozka")"
  if [ -z "$html" ]; then log "  (empty node $slozka)"; return; fi

  # current folder name (from <label> inside podnadpis)
  title="$(printf '%s' "$html" | grep -oE '<label>[^<]*</label>' | head -1 | sed -E 's/<\/?label>//g')"
  title="$(sanitize "${title:-slozka_$slozka}")"
  path="$parent/$title"

  # child folder ids = container divs
  local children
  children="$(printf '%s' "$html" \
    | grep -oE "<div class='container '[^>]*id='[0-9]+'" \
    | grep -oE "id='[0-9]+'" | grep -oE '[0-9]+')"

  if [ -n "$children" ]; then
    log "FOLDER: $path  (${title}) -> $(printf '%s' "$children" | wc -w) subfolders"
    local cid
    while read -r cid; do
      [ -n "$cid" ] && recurse "$cid" "$path"
    done <<< "$children"
    return
  fi

  # leaf album: lightbox full-size hrefs
  local photos n=0 idx=0
  photos="$(printf '%s' "$html" \
    | grep -oE "class=\"lightbox[^\"]*\" href=\"$BASE/fotografie/[^\"]+\"" \
    | grep -oE "$BASE/fotografie/[^\"]+")"
  n="$(printf '%s' "$photos" | grep -c . )"
  if [ "$n" -eq 0 ]; then log "  (no photos, no subfolders in $path)"; return; fi
  mkdir -p "$path"
  log "ALBUM:  $path  -> $n photos"
  local url
  while read -r url; do
    [ -z "$url" ] && continue
    idx=$((idx+1))
    download_photo "$url" "$path" "$idx"
  done <<< "$photos"
}

main(){
  login
  log "Fetching root gallery ..."
  local root_html root_ids
  root_html="$(curl -s -b "$COOKIES" "$GALLERY")"
  root_ids="$(printf '%s' "$root_html" \
    | grep -oE "<div class='container '[^>]*id='[0-9]+'" \
    | grep -oE "id='[0-9]+'" | grep -oE '[0-9]+')"
  log "Root folders: $(printf '%s' "$root_ids" | wc -w)"
  local id
  while read -r id; do
    [ -n "$id" ] && recurse "$id" "$OUTDIR"
  done <<< "$root_ids"
  log "DONE. Photos in: $OUTDIR"
  log "Total files: $(find "$OUTDIR" -type f ! -name '.*' | wc -l)"
  log "Broken on server (0 bytes at source, unrecoverable): $(grep -c . "$BROKENLIST" 2>/dev/null || echo 0) -> $BROKENLIST"
  log "Transient failures (should be retried): $(grep -c . "$FAILLIST" 2>/dev/null || echo 0) -> $FAILLIST"
}

main
