#!/usr/bin/env bash
set -euo pipefail

# private-backup.sh — capture curated private config into a single
# age-encrypted archive, and verify such an archive. Disaster recovery
# only (one-way backup -> restore); restore lands in a later stage. See
# docs/private-backup.md and issue #60.
#
# Encryption uses an age identity (X25519). backup encrypts to the public
# recipient (no secret needed to back up); verify/restore decrypt with the
# identity, supplied from 1Password (#51) via --identity-command so the
# secret never touches disk. The whole tar is encrypted, so the archive
# may safely contain secrets that leak into config files.
#
# Manual invocation only — never wired into `chezmoi apply`. Refuses to
# run unless the host's real profile grants allowSecretsAccess.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"

TOOL_NAME="private-backup.sh"
TOOL_VERSION="1"
MANIFEST_SCHEMA_VERSION="1"
DEFAULT_LOCAL_SUPPLEMENT="$HOME/.config/dotfiles/backup-paths.local"
DEFAULT_RECIPIENT_FILE="$HOME/.config/dotfiles/private-backup.recipient"
MARKER_FILE="$HOME/.local/state/dotfiles/private-backup.json"

usage() {
  cat >&2 <<EOF
usage:
  $TOOL_NAME backup --out PATH [--recipient AGE1... | --recipients-file PATH]
                    [--local-supplement PATH] [--yes]
  $TOOL_NAME verify --in PATH (--identity PATH | --identity-command CMD)

backup: resolve the public baseline (.chezmoidata/backup-paths.yaml) plus the
  local supplement, capture the files into a machine-neutral, age-encrypted
  archive at --out, and update the state marker. Recipient defaults to
  $DEFAULT_RECIPIENT_FILE when no flag is given.
verify: decrypt --in into a 0700 temp dir and check it against its manifest
  (checksums, modes, no extra files, safe home-relative paths). Read-only;
  never writes into \$HOME.

Both refuse unless the host profile grants allowSecretsAccess.
EOF
}

# stat mode (octal permission bits) portably across BSD (macOS) and GNU.
file_mode() {
  if [[ "$(uname)" == "Darwin" ]]; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

sha256_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

# Require age and yq up front; both are fail-closed dependencies.
require_tools() {
  local missing=0
  if ! command -v age >/dev/null 2>&1; then
    fail "age not found; install it (brew install age). See docs/private-backup.md"
    missing=1
  fi
  if ! require_yq; then
    missing=1
  fi
  [[ "$missing" -eq 0 ]]
}

# Append the declared paths of a backup-paths file to a staging list as
# "origin|type|category|path" rows. Fails closed on a parse error so a
# broken supplement never silently captures nothing. A missing optional
# file is not an error (returns 0, emits nothing).
collect_declared() {
  local file="$1" origin="$2" out="$3"
  [[ -f "$file" ]] || return 0
  local rows
  if ! rows="$(backup_paths_in "$file")"; then
    fail "could not parse backup paths from $file"
    return 1
  fi
  local type category path
  while IFS='|' read -r type category path; do
    [[ -z "$path" ]] && continue
    printf '%s|%s|%s|%s\n' "$origin" "$type" "$category" "$path" >> "$out"
  done <<< "$rows"
  return 0
}

cmd_backup() {
  local out="" recipient="" recipients_file="" local_supplement="$DEFAULT_LOCAL_SUPPLEMENT"
  local assume_yes=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out) out="${2:-}"; shift 2 ;;
      --recipient) recipient="${2:-}"; shift 2 ;;
      --recipients-file) recipients_file="${2:-}"; shift 2 ;;
      --local-supplement) local_supplement="${2:-}"; shift 2 ;;
      --yes) assume_yes=1; shift ;;
      *) fail "unknown backup argument: $1"; usage; return 2 ;;
    esac
  done

  if [[ -z "$out" ]]; then
    fail "backup requires --out PATH"
    usage
    return 2
  fi

  # Runtime gate first: refuse outright where the profile forbids secrets.
  require_secrets_access || return 1
  require_tools || return 1

  # Resolve the recipient: explicit flag wins, then the recipients file,
  # then the default recipient file. The public key is not secret, but it
  # is not committed to the repo either; absence is a fail-closed usage
  # error (we never silently produce an unencryptable/unaddressed archive).
  local age_recipient_args=()
  if [[ -n "$recipient" && -n "$recipients_file" ]]; then
    fail "use only one of --recipient / --recipients-file"
    return 2
  fi
  if [[ -n "$recipient" ]]; then
    age_recipient_args=(-r "$recipient")
  elif [[ -n "$recipients_file" ]]; then
    [[ -f "$recipients_file" ]] || { fail "recipients file not found: $recipients_file"; return 2; }
    age_recipient_args=(-R "$recipients_file")
  elif [[ -f "$DEFAULT_RECIPIENT_FILE" ]]; then
    age_recipient_args=(-R "$DEFAULT_RECIPIENT_FILE")
  else
    fail "no recipient: pass --recipient/--recipients-file or create $DEFAULT_RECIPIENT_FILE"
    return 2
  fi

  section "private-backup: resolve targets"

  # Script-global (not local) so the deferred EXIT trap can still see them
  # after the function returns; one EXIT trap suffices since the script
  # runs a single subcommand then exits.
  declared="$(mktemp)"
  seen_paths="$(mktemp)"
  staging="$(mktemp -d "${TMPDIR:-/tmp}/private-backup.XXXXXX")"
  chmod 700 "$staging"
  # Clean up the 0700 staging (plaintext config) and temp lists on exit.
  trap 'rm -rf "$staging"; rm -f "$declared" "$seen_paths"' EXIT

  collect_declared "$BACKUP_PATHS_FILE" baseline "$declared" || return 1
  if [[ -f "$local_supplement" ]]; then
    collect_declared "$local_supplement" local "$declared" || return 1
    item "local supplement present (entries not listed)"
  else
    item "no local supplement at $local_supplement"
  fi

  mkdir -p "$staging/files"
  local manifest="$staging/manifest.json"
  TV="$TOOL_VERSION" SV="$MANIFEST_SCHEMA_VERSION" TN="$TOOL_NAME" \
    CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    yq -n -o=json '{
      "schema_version": (strenv(SV) | tonumber),
      "tool": strenv(TN),
      "tool_version": strenv(TV),
      "created_at": strenv(CREATED),
      "entries": [],
      "files": []
    }' > "$manifest"

  local origin type category path target captured=0 skipped=0
  while IFS='|' read -r origin type category path; do
    [[ -z "$path" ]] && continue
    # Defence in depth: the catalog is validated, but the (non-committed)
    # local supplement is not, so re-check every path at runtime.
    if ! backup_path_is_safe "$path"; then
      warn "skip unsafe path (origin=$origin): $path"
      skipped=$((skipped + 1))
      continue
    fi
    case "$path" in
      *[[:cntrl:]]*)
        warn "skip path with control characters (origin=$origin)"
        skipped=$((skipped + 1))
        continue
        ;;
    esac
    if grep -Fxq -- "$path" "$seen_paths"; then
      continue
    fi
    printf '%s\n' "$path" >> "$seen_paths"

    # Record the declared entry (metadata) regardless of capture outcome.
    P="$path" T="$type" C="$category" O="$origin" \
      yq -i -p=json -o=json '.entries += [{"path": strenv(P), "type": strenv(T), "category": strenv(C), "origin": strenv(O)}]' "$manifest"

    target="$HOME/$path"
    if [[ -L "$target" ]]; then
      warn "skip symlink (not captured): $path"
      skipped=$((skipped + 1))
      continue
    fi
    if [[ ! -e "$target" ]]; then
      warn "declared but absent (skipped): $path"
      skipped=$((skipped + 1))
      continue
    fi

    if [[ "$type" == "dir" || ( -z "$type" && -d "$target" ) ]]; then
      if [[ ! -d "$target" ]]; then
        warn "declared dir is not a directory (skipped): $path"
        skipped=$((skipped + 1))
        continue
      fi
      # Capture regular files only (find -type f excludes symlinks and
      # special files), preserving the home-relative path layout.
      while IFS= read -r f; do
        local rel mode size hash
        rel="${f#"$HOME"/}"
        mode="$(file_mode "$f")"
        size="$(wc -c < "$f" | tr -d ' ')"
        hash="$(sha256_of "$f")"
        mkdir -p "$staging/files/$(dirname "$rel")"
        cp -p "$f" "$staging/files/$rel"
        P="$rel" M="$mode" SZ="$size" H="$hash" \
          yq -i -p=json -o=json '.files += [{"path": strenv(P), "mode": strenv(M), "size": (strenv(SZ) | tonumber), "sha256": strenv(H)}]' "$manifest"
        captured=$((captured + 1))
      done < <(find "$target" -type f 2>/dev/null)
    else
      if [[ ! -f "$target" ]]; then
        warn "declared file is not a regular file (skipped): $path"
        skipped=$((skipped + 1))
        continue
      fi
      local mode size hash
      mode="$(file_mode "$target")"
      size="$(wc -c < "$target" | tr -d ' ')"
      hash="$(sha256_of "$target")"
      mkdir -p "$staging/files/$(dirname "$path")"
      cp -p "$target" "$staging/files/$path"
      P="$path" M="$mode" SZ="$size" H="$hash" \
        yq -i -p=json -o=json '.files += [{"path": strenv(P), "mode": strenv(M), "size": (strenv(SZ) | tonumber), "sha256": strenv(H)}]' "$manifest"
      captured=$((captured + 1))
    fi
  done < "$declared"

  if [[ "$captured" -eq 0 ]]; then
    fail "no files captured; refusing to write an empty archive"
    return 1
  fi

  # Bundle the local supplement itself so restore can resolve the same
  # private list. It lives only inside the encrypted archive.
  if [[ -f "$local_supplement" ]]; then
    cp -p "$local_supplement" "$staging/backup-paths.local"
  fi

  section "private-backup: confirm"
  ok "captured files: $captured"
  [[ "$skipped" -gt 0 ]] && warn "skipped entries: $skipped"
  item "destination: $out"
  if [[ "$assume_yes" -ne 1 ]]; then
    printf '[info] - proceed and write the encrypted archive? [y/N] ' >&2
    local reply=""
    read -r reply < /dev/tty || reply=""
    case "$reply" in
      y | Y | yes | YES) ;;
      *) warn "aborted by user; nothing written"; return 0 ;;
    esac
  fi

  section "private-backup: write archive"
  local partial="$out.partial"
  rm -f "$partial"
  # tar the 0700 staging, pipe straight into age so no plaintext tar ever
  # lands on disk; "-C staging ." keeps archive paths relative (no
  # absolute home path in the archive).
  if ! tar -cf - -C "$staging" . | age "${age_recipient_args[@]}" -o "$partial"; then
    rm -f "$partial"
    fail "failed to create encrypted archive"
    return 1
  fi
  mv -f "$partial" "$out"
  ok "wrote encrypted archive: $out"

  # Marker: repo-external, minimal, machine-neutral (basename only; no
  # absolute path, no hostname, no entry contents).
  mkdir -p "$(dirname "$MARKER_FILE")"
  SV="$MANIFEST_SCHEMA_VERSION" TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    AB="$(basename "$out")" FC="$captured" \
    yq -n -o=json '{
      "schema_version": (strenv(SV) | tonumber),
      "last_success": strenv(TS),
      "archive": strenv(AB),
      "file_count": (strenv(FC) | tonumber)
    }' > "$MARKER_FILE"
  ok "updated marker: $MARKER_FILE"
  return 0
}

cmd_verify() {
  local in="" identity="" identity_command=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --in) in="${2:-}"; shift 2 ;;
      --identity) identity="${2:-}"; shift 2 ;;
      --identity-command) identity_command="${2:-}"; shift 2 ;;
      *) fail "unknown verify argument: $1"; usage; return 2 ;;
    esac
  done

  if [[ -z "$in" ]]; then
    fail "verify requires --in PATH"
    usage
    return 2
  fi
  if [[ -n "$identity" && -n "$identity_command" ]]; then
    fail "use only one of --identity / --identity-command"
    return 2
  fi
  if [[ -z "$identity" && -z "$identity_command" ]]; then
    fail "verify requires --identity PATH or --identity-command CMD"
    return 2
  fi
  [[ -f "$in" ]] || { fail "archive not found: $in"; return 2; }

  require_secrets_access || return 1
  require_tools || return 1

  # Script-global (not local) so the deferred EXIT trap still sees it.
  workdir="$(mktemp -d "${TMPDIR:-/tmp}/private-verify.XXXXXX")"
  chmod 700 "$workdir"
  # Decrypted plaintext only ever lives in this 0700 dir; wipe on exit.
  trap 'rm -rf "$workdir"' EXIT

  local extract="$workdir/extract"
  mkdir -p "$extract"

  section "private-backup: decrypt"
  # Resolve the identity. --identity-command output is fed through a
  # process substitution so the secret key never touches disk; its exit
  # status is checked first so a failed `op read` fails closed.
  local age_identity_args=()
  local identity_material=""
  if [[ -n "$identity" ]]; then
    [[ -f "$identity" ]] || { fail "identity file not found: $identity"; return 2; }
    age_identity_args=(-i "$identity")
  else
    if ! identity_material="$(eval "$identity_command")" || [[ -z "$identity_material" ]]; then
      fail "identity command produced no key; refusing"
      return 1
    fi
  fi

  local decrypt_ok=1
  if [[ -n "$identity" ]]; then
    age -d "${age_identity_args[@]}" "$in" 2>/dev/null | tar -xf - -C "$extract" || decrypt_ok=0
  else
    age -d -i <(printf '%s' "$identity_material") "$in" 2>/dev/null | tar -xf - -C "$extract" || decrypt_ok=0
  fi
  identity_material=""
  if [[ "$decrypt_ok" -ne 1 ]]; then
    fail "could not decrypt/extract archive (wrong identity or corrupt archive)"
    return 1
  fi
  ok "decrypted and extracted to 0700 temp"

  local manifest="$extract/manifest.json"
  [[ -f "$manifest" ]] || { fail "archive has no manifest.json"; return 1; }

  section "private-backup: verify manifest"
  local status=0

  # Each manifest file must exist in the archive with a matching checksum,
  # be a regular file (no symlink/hardlink slipped in), and carry a safe
  # home-relative path. We never write into $HOME — this only inspects the
  # extracted copy. Read sha256+path as TSV in one pass: tab-delimited, so
  # a tab in a path would split it, but tabs (control chars) are rejected
  # below, and the path is the last field so other content stays intact.
  local manifest_paths="$workdir/manifest_paths"
  yq -p=json -o=tsv '.files[].path' "$manifest" > "$manifest_paths"
  local count=0 path sha actual f
  while IFS=$'\t' read -r sha path; do
    [[ -z "$path" ]] && continue
    count=$((count + 1))
    if ! backup_path_is_safe "$path"; then
      fail "manifest path is unsafe: $path"
      status=1
      continue
    fi
    case "$path" in
      *[[:cntrl:]]*) fail "manifest path has control characters"; status=1; continue ;;
    esac
    f="$extract/files/$path"
    if [[ -L "$f" ]]; then
      fail "archived entry is a symlink (rejected): $path"
      status=1
      continue
    fi
    if [[ ! -f "$f" ]]; then
      fail "manifest file missing from archive: $path"
      status=1
      continue
    fi
    actual="$(sha256_of "$f")"
    if [[ "$actual" != "$sha" ]]; then
      fail "checksum mismatch: $path"
      status=1
      continue
    fi
  done < <(yq -p=json -o=tsv '.files[] | [.sha256, .path]' "$manifest")

  # No extra files beyond the manifest's declared files (manifest.json and
  # backup-paths.local live outside files/, so they are not flagged).
  local extra=0 rel
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    if ! grep -Fxq -- "$rel" "$manifest_paths"; then
      fail "archive file not in manifest: $rel"
      extra=$((extra + 1))
      status=1
    fi
  done < <(cd "$extract/files" 2>/dev/null && find . -type f 2>/dev/null | sed 's#^\./##')

  if [[ "$extra" -eq 0 && "$status" -eq 0 ]]; then
    ok "verified $count file(s); manifest and archive agree"
  else
    fail "verification failed"
  fi
  return "$status"
}

main() {
  local command="${1:-}"
  shift || true
  case "$command" in
    backup) cmd_backup "$@" ;;
    verify) cmd_verify "$@" ;;
    -h | --help | help | "") usage; [[ -z "$command" ]] && return 2 || return 0 ;;
    *) fail "unknown command: $command"; usage; return 2 ;;
  esac
}

main "$@"
