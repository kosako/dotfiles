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
  $TOOL_NAME restore --in PATH (--identity PATH | --identity-command CMD)
                     [--apply] [--skip-existing] [--target-home DIR]

backup: resolve the public baseline (.chezmoidata/backup-paths.yaml) plus the
  local supplement, capture the files into a machine-neutral, age-encrypted
  archive at --out, and update the state marker. Recipient defaults to
  $DEFAULT_RECIPIENT_FILE when no flag is given.
verify: decrypt --in into a 0700 temp dir and check it against its manifest
  (checksums, modes, no extra files, safe home-relative paths). Read-only;
  never writes into \$HOME.
restore: verify --in, then restore its files into \$HOME (or --target-home).
  Dry-run by default; --apply performs it, moving any displaced file into a
  timestamped backup dir first. --skip-existing leaves existing files
  untouched. Refuses to write through a symlinked parent directory.

All refuse unless the host profile grants allowSecretsAccess.
EOF
}

sha256_of() {
  shasum -a 256 < "$1" | awk '{print $1}'
}

# Whether a single tar member NAME is allowed in a private-backup archive.
# Members carry a leading "./"; after stripping it (and any trailing "/"
# on directory entries) only manifest.json, backup-paths.local, the files/
# tree, and the implied directories are permitted. Rejects absolute paths,
# "..", control characters, and anything outside that set. Returns 0/1;
# prints nothing.
member_name_is_allowed() {
  local n="${1#./}"
  n="${n%/}"
  [[ -z "$n" || "$n" == "." ]] && return 0
  case "$n" in
    /* | *..* | *[[:cntrl:]]*) return 1 ;;
  esac
  case "$n" in
    manifest.json | backup-paths.local | files) return 0 ;;
    files/*) backup_path_is_safe "${n#files/}" ;;
    *) return 1 ;;
  esac
}

# Validate every member of a tar BEFORE extracting it. The backup
# recipient is a public key, so anyone holding it can craft an archive
# that decrypts cleanly; tar would otherwise process path traversal,
# absolute paths, and symlink-write-through during extraction, before any
# manifest check runs. Reject the whole archive on (a) any member whose
# type is not a regular file or directory (symlink / hardlink / device /
# fifo), or (b) any disallowed or unsafe member name. Returns 0 if every
# member is safe to extract into an isolated temp.
validate_tar_members() {
  local archive="$1" listdir
  listdir="$(dirname "$archive")"
  local tlist="$listdir/.tlist" vlist="$listdir/.tvlist"
  # Capture the listings to files (not via a process substitution) so a
  # `tar` that fails to even list a corrupt archive fails closed here,
  # rather than its non-zero status being swallowed by the pipe.
  if ! tar -tf "$archive" > "$tlist" 2>/dev/null; then
    fail "could not list archive members; rejected before extraction"
    return 1
  fi
  if ! tar -tvf "$archive" > "$vlist" 2>/dev/null; then
    fail "could not list archive members; rejected before extraction"
    return 1
  fi
  # Type pass: the ls-style first character of `tar -tvf` is portable
  # across BSD (macOS) and GNU tar. Anything but "-" (regular) or "d"
  # (directory) is rejected (symlink "l", hardlink "h", device/fifo).
  local tc
  while IFS= read -r tc; do
    [[ -z "$tc" ]] && continue
    if [[ "$tc" != "-" && "$tc" != "d" ]]; then
      fail "archive has a non-regular member (symlink/hardlink/special); rejected before extraction"
      return 1
    fi
  done < <(awk '{print substr($1,1,1)}' "$vlist")
  # Name pass: reject traversal / absolute / disallowed members. A member
  # name containing a newline is split across lines here, but that cannot
  # cause an escape: the type pass already excludes symlinks, every line
  # fragment is still checked (a "../" fragment is rejected), and any
  # surviving odd name is caught downstream as a file not in the manifest.
  # Backup itself never emits such names (control chars are rejected at
  # capture time).
  local name
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if ! member_name_is_allowed "$name"; then
      fail "archive has a disallowed member name; rejected before extraction"
      return 1
    fi
  done < "$tlist"
  return 0
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
      # special files), preserving the home-relative path layout. NUL
      # delimiting tolerates odd names; each captured path still gets the
      # same safety checks as a declared entry (a control character or a
      # ".." segment would otherwise corrupt the manifest or trip verify).
      local f rel mode size hash
      while IFS= read -r -d '' f; do
        rel="${f#"$HOME"/}"
        if ! backup_path_is_safe "$rel"; then
          warn "skip unsafe captured path under $path"
          skipped=$((skipped + 1))
          continue
        fi
        # Deduplicate against paths already captured (a declared file inside
        # this dir, or an overlapping dir declaration) so the manifest never
        # lists the same file twice; restore would otherwise process it
        # twice and misreport created/displaced counts.
        if grep -Fxq -- "$rel" "$seen_paths"; then
          continue
        fi
        printf '%s\n' "$rel" >> "$seen_paths"
        if [[ ! -r "$f" ]]; then
          warn "skip unreadable file under $path: $rel"
          skipped=$((skipped + 1))
          continue
        fi
        mode="$(file_mode "$f")"
        size="$(wc -c < "$f" | tr -d ' ')"
        hash="$(sha256_of "$f")"
        mkdir -p "$staging/files/$(dirname "$rel")"
        cp -p "$f" "$staging/files/$rel"
        P="$rel" M="$mode" SZ="$size" H="$hash" \
          yq -i -p=json -o=json '.files += [{"path": strenv(P), "mode": strenv(M), "size": (strenv(SZ) | tonumber), "sha256": strenv(H)}]' "$manifest"
        captured=$((captured + 1))
      done < <(find "$target" -type f -print0 2>/dev/null)
    else
      if [[ ! -f "$target" ]]; then
        warn "declared file is not a regular file (skipped): $path"
        skipped=$((skipped + 1))
        continue
      fi
      if [[ ! -r "$target" ]]; then
        warn "unreadable (skipped): $path"
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
    # Both no-TTY and a declined prompt return non-zero: a run that wrote no
    # archive must not exit 0, or unattended runs (cron/CI without --yes)
    # would report success while backups silently never happen.
    if ! read -r reply < /dev/tty 2>/dev/null; then
      printf '\n' >&2
      fail "no TTY for confirmation; pass --yes for unattended runs"
      return 1
    fi
    case "$reply" in
      y | Y | yes | YES) ;;
      *) warn "aborted by user; nothing written"; return 1 ;;
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

# Resolve the identity, decrypt --in to a plaintext tar inside the 0700
# temp, validate every member, and extract into <extract>. Shared by
# verify and restore. Args: in identity identity_command workdir extract.
# Returns 0 on success, 2 on a usage error (missing identity file), 1 on a
# decrypt/extract failure. The --identity-command output is fed through a
# process substitution so the secret key never touches disk; its exit
# status is checked first so a failed `op read` fails closed. The command
# is a user-supplied shell command line (e.g. `op read op://...`), run via
# the shell on purpose so quoting works; the caller controls it (it is not
# archive-derived), so this is not an injection surface. See README.
decrypt_and_extract() {
  local in="$1" identity="$2" identity_command="$3" workdir="$4" extract="$5"
  local identity_material="" cipher_tar="$workdir/archive.tar" decrypt_ok=1

  section "private-backup: decrypt"
  # Decrypt to a plaintext tar inside the 0700 temp (never piped straight
  # into extraction): members must be validated before tar touches the
  # filesystem, so the archive cannot escape the temp via traversal or a
  # symlink. The tar is wiped by the EXIT trap with everything else.
  if [[ -n "$identity" ]]; then
    [[ -f "$identity" ]] || { fail "identity file not found: $identity"; return 2; }
    age -d -i "$identity" -o "$cipher_tar" "$in" 2>/dev/null || decrypt_ok=0
  else
    if ! identity_material="$(eval "$identity_command")" || [[ -z "$identity_material" ]]; then
      fail "identity command produced no key; refusing"
      return 1
    fi
    age -d -i <(printf '%s' "$identity_material") -o "$cipher_tar" "$in" 2>/dev/null || decrypt_ok=0
    identity_material=""
  fi
  if [[ "$decrypt_ok" -ne 1 ]]; then
    fail "could not decrypt archive (wrong identity or corrupt archive)"
    return 1
  fi
  ok "decrypted to 0700 temp"

  validate_tar_members "$cipher_tar" || return 1
  # -p: restore the modes recorded in the archive. Without it bsdtar applies
  # the umask on extraction, so group/other-writable files (664/775) come out
  # as 644/755 and the manifest mode comparison below rejects a good archive.
  if ! tar -xpf "$cipher_tar" -C "$extract" 2>/dev/null; then
    fail "could not extract archive"
    return 1
  fi
  ok "members validated and extracted to 0700 temp"
  return 0
}

# Validate types before emitting TSV: missing/empty fields and embedded
# separators must not make read collapse columns or silently skip entries.
# Every query is checked explicitly because restore calls this under ||,
# where Bash disables errexit throughout the function.
check_manifest() {
  local extract="$1" workdir="$2"
  local manifest="$extract/manifest.json"
  [[ -f "$manifest" ]] || { fail "archive has no manifest.json"; return 1; }
  if ! yq -e -p=json '
    (tag == "!!map") and
    ((.schema_version | tag) == "!!int") and (.schema_version == 1) and
    ((.tool | tag) == "!!str") and (.tool == "private-backup.sh") and
    ((.tool_version | tag) == "!!str") and (.tool_version != "") and
    ((.created_at | tag) == "!!str") and (.created_at != "") and
    ((.entries | tag) == "!!seq") and
    ([.entries[] | ((tag == "!!map") and
      ((.path | tag) == "!!str") and (.path != "") and
      (.path | test("^[^\\x00-\\x1f\\x7f]+$")) and
      ((.type | tag) == "!!str") and
      (.type == "" or .type == "file" or .type == "dir") and
      ((.category | tag) == "!!str") and
      ((.origin | tag) == "!!str") and (.origin == "baseline" or .origin == "local")
    )] | all) and
    ((.files | tag) == "!!seq") and ((.files | length) > 0) and
    ([.files[] | ((tag == "!!map") and
      ((.path | tag) == "!!str") and (.path != "") and
      (.path | test("^[^\\x00-\\x1f\\x7f]+$")) and
      ((.sha256 | tag) == "!!str") and (.sha256 | test("^[0-9a-f]{64}$")) and
      ((.mode | tag) == "!!str") and (.mode | test("^[0-7]{1,4}$")) and
      ((.size | tag) == "!!int") and (.size >= 0)
    )] | all)
  ' "$manifest" >/dev/null 2>&1; then
    fail "invalid manifest schema or file metadata"
    return 1
  fi

  local manifest_paths="$workdir/manifest_paths" rows="$workdir/manifest_rows"
  local entry_paths="$workdir/entry_paths" archive_files="$workdir/archive_files"
  if ! yq -p=json -o=tsv '.entries[].path' "$manifest" > "$entry_paths" \
    || ! yq -p=json -o=tsv '.files[] | [.sha256, .mode, .size, .path]' "$manifest" > "$rows"; then
    fail "could not read manifest entries"
    return 1
  fi
  : > "$manifest_paths" || return 1
  local path sha mode size actual actual_mode actual_size f count=0 status=0
  while IFS= read -r path; do
    if ! backup_path_is_safe "$path"; then
      fail "manifest entry path is unsafe or non-canonical"
      return 1
    fi
  done < "$entry_paths"

  while IFS=$'\t' read -r sha mode size path; do
    if ! backup_path_is_safe "$path"; then
      fail "manifest path is unsafe or non-canonical"
      return 1
    fi
    if grep -Fxq -- "$path" "$manifest_paths"; then
      fail "duplicate manifest path: $path"
      return 1
    fi
    printf '%s\n' "$path" >> "$manifest_paths" || return 1
    count=$((count + 1))
    f="$extract/files/$path"
    if [[ -L "$f" || ! -f "$f" ]]; then
      fail "manifest file missing or not regular: $path"
      status=1
      continue
    fi
    actual="$(sha256_of "$f")" || return 1
    if [[ "$actual" != "$sha" ]]; then
      fail "checksum mismatch: $path"
      status=1
      continue
    fi
    actual_mode="$(file_mode "$f")" || return 1
    if [[ "$actual_mode" != "$mode" ]]; then
      fail "mode mismatch: $path (manifest $mode, archive $actual_mode)"
      status=1
      continue
    fi
    actual_size="$(wc -c < "$f" | tr -d ' ')" || return 1
    if [[ "$actual_size" != "$size" ]]; then
      fail "size mismatch: $path"
      status=1
    fi
  done < "$rows"
  if [[ "$count" -eq 0 ]]; then
    fail "manifest contains no files"
    return 1
  fi

  if ! (cd "$extract/files" && find . -type f -print0) > "$archive_files" 2>/dev/null; then
    fail "could not enumerate archive files"
    return 1
  fi
  local rel
  while IFS= read -r -d '' rel; do
    rel="${rel#./}"
    if ! backup_path_is_safe "$rel" || ! grep -Fxq -- "$rel" "$manifest_paths"; then
      fail "archive file not in manifest or unsafe"
      status=1
    fi
  done < "$archive_files"

  if [[ "$status" -eq 0 ]]; then
    ok "verified $count file(s); manifest and archive agree"
  else
    fail "verification failed"
  fi
  return "$status"
}

# Whether any existing ancestor directory of <base>/<rel> (below <base>)
# is a symlink. Restore refuses such targets so a symlinked parent cannot
# redirect a write outside the intended tree. <base> itself is trusted
# (it is $HOME or an explicit --target-home). Returns 0 if a symlinked
# parent exists.
path_has_symlinked_parent() {
  local rel="$2" cur="$1" comp dir
  dir="$(dirname "$rel")"
  [[ "$dir" == "." ]] && return 1
  local IFS='/' comps=()
  read -ra comps <<< "$dir"
  for comp in "${comps[@]}"; do
    [[ -z "$comp" ]] && continue
    cur="$cur/$comp"
    [[ -L "$cur" ]] && return 0
  done
  return 1
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
  trap 'rm -rf "$workdir"' EXIT
  local extract="$workdir/extract"
  mkdir -p "$extract"

  local rc=0
  decrypt_and_extract "$in" "$identity" "$identity_command" "$workdir" "$extract" || rc=$?
  [[ "$rc" -eq 0 ]] || return "$rc"

  section "private-backup: verify manifest"
  check_manifest "$extract" "$workdir"
}

cmd_restore() {
  local in="" identity="" identity_command="" apply=0 skip_existing=0
  local target_home="$HOME"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --in) in="${2:-}"; shift 2 ;;
      --identity) identity="${2:-}"; shift 2 ;;
      --identity-command) identity_command="${2:-}"; shift 2 ;;
      --apply) apply=1; shift ;;
      --skip-existing) skip_existing=1; shift ;;
      --target-home) target_home="${2:-}"; shift 2 ;;
      *) fail "unknown restore argument: $1"; usage; return 2 ;;
    esac
  done

  if [[ -z "$in" ]]; then
    fail "restore requires --in PATH"
    usage
    return 2
  fi
  if [[ -n "$identity" && -n "$identity_command" ]]; then
    fail "use only one of --identity / --identity-command"
    return 2
  fi
  if [[ -z "$identity" && -z "$identity_command" ]]; then
    fail "restore requires --identity PATH or --identity-command CMD"
    return 2
  fi
  [[ -f "$in" ]] || { fail "archive not found: $in"; return 2; }
  [[ -d "$target_home" ]] || { fail "target home is not a directory: $target_home"; return 2; }

  require_secrets_access || return 1
  require_tools || return 1

  workdir="$(mktemp -d "${TMPDIR:-/tmp}/private-restore.XXXXXX")"
  chmod 700 "$workdir"
  trap 'rm -rf "$workdir"' EXIT
  local extract="$workdir/extract"
  mkdir -p "$extract"

  local rc=0
  decrypt_and_extract "$in" "$identity" "$identity_command" "$workdir" "$extract" || rc=$?
  [[ "$rc" -eq 0 ]] || return "$rc"

  # Never restore from an archive that fails its own integrity check.
  section "private-backup: verify before restore"
  check_manifest "$extract" "$workdir" || {
    fail "archive failed verification; refusing to restore"
    return 1
  }

  local label="dry-run"
  [[ "$apply" -eq 1 ]] && label="apply"
  section "private-backup: restore ($label)"
  if [[ "$apply" -ne 1 ]]; then
    item "dry-run: no files will be written (pass --apply to perform)"
  fi

  # On apply, displaced files move here (repo-external) before being
  # overwritten, so a restore is reversible and never silently destroys
  # content. The backup root's own path must be symlink-free for the same
  # reason payload targets are: a symlinked ~/.local (or state/dotfiles)
  # would otherwise redirect the displaced file outside the target tree.
  # mktemp -d gives a unique dir (no same-second collision) at mode 0700.
  local backup_dir=""
  if [[ "$apply" -eq 1 ]]; then
    if path_has_symlinked_parent "$target_home" ".local/state/dotfiles/x"; then
      fail "refusing: backup state path contains a symlink ($target_home/.local/state/dotfiles)"
      return 1
    fi
    mkdir -p "$target_home/.local/state/dotfiles"
    backup_dir="$(mktemp -d "$target_home/.local/state/dotfiles/restore-backup-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")"
  fi

  local created=0 overwritten=0 skipped=0 status=0 path f target
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    # Defence in depth (the manifest was already validated above).
    if ! backup_path_is_safe "$path"; then
      warn "skip unsafe path: $path"; skipped=$((skipped + 1)); status=1; continue
    fi
    f="$extract/files/$path"
    target="$target_home/$path"
    # Refuse to write through a symlinked parent (escape prevention).
    if path_has_symlinked_parent "$target_home" "$path"; then
      warn "skip (symlinked parent in target path): $path"; skipped=$((skipped + 1)); status=1; continue
    fi

    if [[ -e "$target" || -L "$target" ]]; then
      if [[ "$skip_existing" -eq 1 ]]; then
        item "skip (exists): $path"
        skipped=$((skipped + 1))
        continue
      fi
      if [[ "$apply" -eq 1 ]]; then
        mkdir -p "$(dirname "$backup_dir/$path")"
        if [[ -e "$backup_dir/$path" || -L "$backup_dir/$path" ]]; then
          fail "refusing to overwrite a displaced file: $path"
          return 1
        fi
        # -n preserves a displaced file even if another target aliases it on
        # a case-insensitive filesystem; a skipped move must abort the copy.
        mv -n "$target" "$backup_dir/$path"
        if [[ -e "$target" || -L "$target" ]]; then
          fail "could not displace existing target: $path"
          return 1
        fi
        mkdir -p "$(dirname "$target")"
        cp -p "$f" "$target"
      else
        item "would overwrite (existing backed up first): $path"
      fi
      overwritten=$((overwritten + 1))
    else
      if [[ "$apply" -eq 1 ]]; then
        mkdir -p "$(dirname "$target")"
        cp -p "$f" "$target"
      else
        item "would create: $path"
      fi
      created=$((created + 1))
    fi
  done < "$workdir/manifest_paths"

  if [[ "$apply" -eq 1 ]]; then
    ok "restored: $created created, $overwritten overwritten, $skipped skipped"
    [[ "$overwritten" -gt 0 ]] && item "displaced files saved under: $backup_dir"
  else
    ok "dry-run: $created would be created, $overwritten would be overwritten, $skipped skipped"
  fi
  return "$status"
}

main() {
  local command="${1:-}"
  shift || true
  case "$command" in
    backup) cmd_backup "$@" ;;
    verify) cmd_verify "$@" ;;
    restore) cmd_restore "$@" ;;
    -h | --help | help | "") usage; [[ -z "$command" ]] && return 2 || return 0 ;;
    *) fail "unknown command: $command"; usage; return 2 ;;
  esac
}

main "$@"
