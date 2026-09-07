#!/usr/bin/env bash
# Maintenance for the resume-host GitHub Pages repo. Pure bash + jq.
# Runs in GitHub Actions (daily + on demand) and locally via publish.sh.
#
#   scripts/maintain.sh prune             delete applications older than retentionDays
#   scripts/maintain.sh delete <id|TAG> [key]   delete one application (all its
#                                         files), or only one file (key = resume|
#                                         coverLetter|linkedin|prepare)
#   scripts/maintain.sh reconcile         drop manifest refs whose files vanished,
#                                         drop empty entries (run after every change)
#
# Exit 0 = ok. Prints what it removed. Never touches Apply/ or Interview/
# (evergreen general documents) — only per-application entries expire.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
M="$ROOT/manifest.json"
cd "$ROOT"
[ -f "$M" ] || { echo "no manifest.json"; exit 0; }

slug_id() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'; }

remove_entry_files() {   # $1 = id
  jq -r --arg id "$1" '.applications[] | select(.id==$id) | .files[]? // empty' "$M" |
  while IFS= read -r f; do
    [ -n "$f" ] && [ -e "$f" ] && { rm -f -- "$f"; echo "  removed $f"; }
    d="$(dirname -- "$f")"; [ -d "$d" ] && rmdir --ignore-fail-on-non-empty -- "$d" 2>/dev/null || true
  done
  tmp="$(mktemp)"; jq --arg id "$1" 'del(.applications[] | select(.id==$id))' "$M" > "$tmp" && mv "$tmp" "$M"
}

cmd="${1:-reconcile}"
case "$cmd" in
  delete)
    id="$(slug_id "${2:?usage: maintain.sh delete <id|TAG> [key]}")"; key="${3:-}"
    if jq -e --arg id "$id" '.applications[] | select(.id==$id)' "$M" >/dev/null; then
      if [ -n "$key" ]; then
        f="$(jq -r --arg id "$id" --arg k "$key" '.applications[] | select(.id==$id) | .files[$k] // empty' "$M")"
        [ -n "$f" ] || { echo "no file '$key' in $id"; exit 1; }
        echo "deleting $id.$key"; rm -f -- "$f"; echo "  removed $f"
        rmdir --ignore-fail-on-non-empty -- "$(dirname -- "$f")" 2>/dev/null || true
      else
        echo "deleting $id"; remove_entry_files "$id"
      fi
    else
      echo "no application with id '$id'"; exit 1
    fi
    ;;
  prune)
    days="$(jq -r '.retentionDays // 90' "$M")"
    cutoff="$(date -u -d "-${days} days" +%F)"
    echo "pruning applications dated before $cutoff (retention ${days}d)"
    for id in $(jq -r --arg c "$cutoff" '.applications[] | select(.date < $c) | .id' "$M"); do
      echo "expired: $id"; remove_entry_files "$id"
    done
    ;;
  reconcile) ;;
  *) echo "unknown command: $cmd"; exit 1 ;;
esac

# ---- reconcile: drop dangling file refs, then empty entries ----
tmp="$(mktemp)"
jq '.' "$M" > "$tmp"
for id in $(jq -r '.applications[].id' "$tmp"); do
  for key in $(jq -r --arg id "$id" '.applications[] | select(.id==$id) | .files | keys[]' "$tmp"); do
    f="$(jq -r --arg id "$id" --arg k "$key" '.applications[] | select(.id==$id) | .files[$k]' "$tmp")"
    if [ ! -e "$f" ]; then
      echo "  dangling ref dropped: $id.$key -> $f"
      t2="$(mktemp)"; jq --arg id "$id" --arg k "$key" '(.applications[] | select(.id==$id) | .files) |= del(.[$k])' "$tmp" > "$t2" && mv "$t2" "$tmp"
    fi
  done
done
t2="$(mktemp)"
jq '.applications |= map(select((.files | length) > 0))
    | .general |= map(select(.path as $p | ($p | length) > 0))' "$tmp" > "$t2" && mv "$t2" "$tmp"
# general docs: drop refs to missing files
for i in $(jq -r '.general | keys[]' "$tmp"); do
  p="$(jq -r --argjson i "$i" '.general[$i].path' "$tmp")"
  if [ ! -e "$p" ]; then
    echo "  dangling general ref dropped: $p"
    t3="$(mktemp)"; jq --arg p "$p" 'del(.general[] | select(.path==$p))' "$tmp" > "$t3" && mv "$t3" "$tmp"
  fi
done
jq --arg now "$(date -u +%FT%TZ)" '.updated = $now
    | .applications |= sort_by(.date, .company) | .applications |= reverse' "$tmp" > "$M"
rm -f "$tmp"
echo "manifest ok: $(jq '.applications | length' "$M") applications, $(jq '.general | length' "$M") general docs"
