#!/usr/bin/env bash
set -euo pipefail

# Round-trip and safety tests for private-backup.sh (issue #60). Hermetic:
# a fixture HOME, a fake `chezmoi` on PATH so the runtime gate resolves a
# chosen profile (needed in CI, which has no real chezmoi), and throwaway
# age keys. Never touches the real HOME. Requires age + age-keygen + yq.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"

PB="$SCRIPT_DIR/private-backup.sh"
status=0
pass() { ok "test passed: $*"; }
miss() {
  fail "test failed: $*"
  status=1
}

if ! command -v age >/dev/null 2>&1 || ! command -v age-keygen >/dev/null 2>&1; then
  warn "age/age-keygen not found; skipping private-backup round-trip tests"
  exit 0
fi

fixture_home="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-pb-test.XXXXXX")"
trap 'rm -rf "$fixture_home"' EXIT

mkdir -p "$fixture_home/.ssh" "$fixture_home/fakebin" "$fixture_home/keys" "$fixture_home/out"
# Baseline files declared in .chezmoidata/backup-paths.yaml.
printf 'export SECRET_TOKEN=abc123\n' > "$fixture_home/.zshrc.local"
printf 'export LOGIN_SETTING=fixture\n' > "$fixture_home/.zprofile.local"
chmod 600 "$fixture_home/.zprofile.local"
printf 'Host private\n  User me\n' > "$fixture_home/.ssh/config.local"

# Fake chezmoi: prints a chosen profile so require_secrets_access resolves
# it without a real chezmoi. set_profile() rewrites it.
set_profile() {
  cat > "$fixture_home/fakebin/chezmoi" <<SH
#!/bin/sh
printf '%s\n' '{"profile":"$1"}'
SH
  chmod +x "$fixture_home/fakebin/chezmoi"
}
set_profile personal

age-keygen -o "$fixture_home/keys/id.txt" 2>/dev/null
age-keygen -o "$fixture_home/keys/wrong.txt" 2>/dev/null
recipient="$(age-keygen -y "$fixture_home/keys/id.txt")"

# Run private-backup.sh in the fixture environment.
run() { HOME="$fixture_home" PATH="$fixture_home/fakebin:$PATH" "$PB" "$@"; }

archive="$fixture_home/out/backup.age"

# 1. backup writes an archive and a machine-neutral marker.
if run backup --out "$archive" --recipient "$recipient" --yes >/dev/null 2>&1 && [[ -f "$archive" ]]; then
  pass "backup writes an encrypted archive"
else
  miss "backup did not produce an archive"
fi
marker="$fixture_home/.local/state/dotfiles/private-backup.json"
if [[ -f "$marker" ]]; then
  if grep -Fq "$fixture_home" "$marker"; then
    miss "marker leaks the absolute home path"
  elif [[ "$(yq -p=json -o=tsv '.archive' "$marker")" == "backup.age" ]]; then
    pass "marker is machine-neutral (basename only, no absolute path)"
  else
    miss "marker archive field unexpected"
  fi
else
  miss "marker not written"
fi

# 2. verify (correct identity) passes.
if run verify --in "$archive" --identity "$fixture_home/keys/id.txt" >/dev/null 2>&1; then
  pass "verify accepts a good archive"
else
  miss "verify rejected a good archive"
fi

# 3. verify via --identity-command (the op seam) passes.
if run verify --in "$archive" --identity-command "cat $fixture_home/keys/id.txt" >/dev/null 2>&1; then
  pass "verify works through --identity-command"
else
  miss "verify failed through --identity-command"
fi

# 4. Wrong identity fails closed.
if run verify --in "$archive" --identity "$fixture_home/keys/wrong.txt" >/dev/null 2>&1; then
  miss "verify must reject a wrong identity"
else
  pass "verify rejects a wrong identity"
fi

# 5. A tampered ciphertext fails to decrypt.
cp "$archive" "$fixture_home/out/tampered.age"
# Overwrite the start of the file (the "age-encryption.org/v1" header) so
# the bytes are guaranteed to change and decryption fails deterministically.
printf 'XXXXXXXXXX' | dd of="$fixture_home/out/tampered.age" bs=1 seek=0 count=10 conv=notrunc >/dev/null 2>&1
if run verify --in "$fixture_home/out/tampered.age" --identity "$fixture_home/keys/id.txt" >/dev/null 2>&1; then
  miss "verify must reject a tampered archive"
else
  pass "verify rejects a tampered archive"
fi

# Helper: build an age archive from a hand-crafted staging tree so the
# manifest-integrity paths can be exercised directly.
make_archive() {
  local stage="$1" out="$2"
  tar -cf - -C "$stage" . | age -r "$recipient" -o "$out"
}

# 6. A checksum mismatch (manifest sha does not match the file) is caught.
bad="$fixture_home/stage-badsum"
mkdir -p "$bad/files"
printf 'real content\n' > "$bad/files/.zshrc.local"
TS="2026-01-01T00:00:00Z" yq -n -o=json '{
  "schema_version": 1, "tool": "private-backup.sh", "tool_version": "1",
  "created_at": strenv(TS), "entries": [],
  "files": [{"path": ".zshrc.local", "mode": "600", "size": 13, "sha256": "0000000000000000000000000000000000000000000000000000000000000000"}]
}' > "$bad/manifest.json"
make_archive "$bad" "$fixture_home/out/badsum.age"
# Capture then grep: verify exits non-zero on these negative cases, which
# under `set -o pipefail` would otherwise mask the matched message.
out="$(run verify --in "$fixture_home/out/badsum.age" --identity "$fixture_home/keys/id.txt" 2>&1)" || true
if grep -Fq "checksum mismatch" <<< "$out"; then
  pass "verify detects a checksum mismatch"
else
  miss "verify missed a checksum mismatch"
fi

# 7. An archive file not present in the manifest is caught (sprawl).
extra="$fixture_home/stage-extra"
mkdir -p "$extra/files"
printf 'x\n' > "$extra/files/declared"
printf 'y\n' > "$extra/files/sneaked-in"
sum="$(shasum -a 256 "$extra/files/declared" | awk '{print $1}')"
SUM="$sum" yq -n -o=json '{
  "schema_version": 1, "tool": "private-backup.sh", "tool_version": "1",
  "created_at": "2026-01-01T00:00:00Z", "entries": [],
  "files": [{"path": "declared", "mode": "644", "size": 2, "sha256": strenv(SUM)}]
}' > "$extra/manifest.json"
make_archive "$extra" "$fixture_home/out/extra.age"
out="$(run verify --in "$fixture_home/out/extra.age" --identity "$fixture_home/keys/id.txt" 2>&1)" || true
if grep -Fq "not in manifest" <<< "$out"; then
  pass "verify detects an archive file missing from the manifest"
else
  miss "verify missed an undeclared archive file"
fi

# 8. A symlink smuggled into the archive is rejected BEFORE extraction
#    (the recipient is public, so a hostile archive can decrypt; tar must
#    not process the symlink and let it escape the 0700 temp).
slink="$fixture_home/stage-symlink"
mkdir -p "$slink/files"
ln -s /etc/passwd "$slink/files/evil"
yq -n -o=json '{
  "schema_version": 1, "tool": "private-backup.sh", "tool_version": "1",
  "created_at": "2026-01-01T00:00:00Z", "entries": [],
  "files": [{"path": "evil", "mode": "777", "size": 0, "sha256": "x"}]
}' > "$slink/manifest.json"
make_archive "$slink" "$fixture_home/out/symlink.age"
out="$(run verify --in "$fixture_home/out/symlink.age" --identity "$fixture_home/keys/id.txt" 2>&1)" || true
if grep -Fq "symlink" <<< "$out" && grep -Fq "before extraction" <<< "$out"; then
  pass "verify rejects a symlink member before extraction"
else
  printf '%s\n' "$out" >&2
  miss "verify did not reject a symlink member before extraction"
fi

# 8b. A disallowed top-level member (not manifest/supplement/files) is
#     rejected before extraction (name pass).
ddir="$fixture_home/stage-disallowed"
mkdir -p "$ddir/files"
printf 'x\n' > "$ddir/files/ok"
printf 'pwn\n' > "$ddir/evil.sh"
yq -n -o=json '{
  "schema_version": 1, "tool": "private-backup.sh", "tool_version": "1",
  "created_at": "2026-01-01T00:00:00Z", "entries": [], "files": []
}' > "$ddir/manifest.json"
make_archive "$ddir" "$fixture_home/out/disallowed.age"
out="$(run verify --in "$fixture_home/out/disallowed.age" --identity "$fixture_home/keys/id.txt" 2>&1)" || true
if grep -Fq "disallowed member name" <<< "$out"; then
  pass "verify rejects a disallowed member name before extraction"
else
  printf '%s\n' "$out" >&2
  miss "verify did not reject a disallowed member name"
fi

# 8c. A mode mismatch (manifest mode != extracted file mode) is caught.
mdir="$fixture_home/stage-mode"
mkdir -p "$mdir/files"
printf 'content\n' > "$mdir/files/.zshrc.local"
chmod 644 "$mdir/files/.zshrc.local"
msum="$(shasum -a 256 "$mdir/files/.zshrc.local" | awk '{print $1}')"
msize="$(wc -c < "$mdir/files/.zshrc.local" | tr -d ' ')"
SUM="$msum" SZ="$msize" yq -n -o=json '{
  "schema_version": 1, "tool": "private-backup.sh", "tool_version": "1",
  "created_at": "2026-01-01T00:00:00Z", "entries": [],
  "files": [{"path": ".zshrc.local", "mode": "600", "size": (strenv(SZ) | tonumber), "sha256": strenv(SUM)}]
}' > "$mdir/manifest.json"
make_archive "$mdir" "$fixture_home/out/mode.age"
out="$(run verify --in "$fixture_home/out/mode.age" --identity "$fixture_home/keys/id.txt" 2>&1)" || true
if grep -Fq "mode mismatch" <<< "$out"; then
  pass "verify detects a mode mismatch"
else
  printf '%s\n' "$out" >&2
  miss "verify missed a mode mismatch"
fi

# 8d. A payload that decrypts but is not a valid tar fails closed (the
#     member listing must reject it before extraction, not swallow tar's
#     error).
printf 'this is not a tar archive\n' | age -r "$recipient" -o "$fixture_home/out/notar.age"
out="$(run verify --in "$fixture_home/out/notar.age" --identity "$fixture_home/keys/id.txt" 2>&1)" || true
if grep -Fq "could not list archive members" <<< "$out"; then
  pass "verify fails closed on a non-tar payload"
else
  printf '%s\n' "$out" >&2
  miss "verify did not fail closed on a non-tar payload"
fi

# 9. Runtime gate: a denied profile refuses to back up.
set_profile work
if run backup --out "$fixture_home/out/denied.age" --recipient "$recipient" --yes >/dev/null 2>&1; then
  miss "backup must refuse under a denied profile"
else
  pass "backup refuses under a denied profile (work)"
fi
[[ -f "$fixture_home/out/denied.age" ]] && miss "denied backup must not write an archive"
set_profile personal

# 10. Defence in depth: an unsafe path in the (unvalidated) local
#     supplement is skipped, not captured.
supp_home="$fixture_home/supp"
mkdir -p "$supp_home/.ssh" "$supp_home/.config/dotfiles"
printf 'a\n' > "$supp_home/.zshrc.local"
printf 'b\n' > "$supp_home/.ssh/config.local"
printf 'backup_paths:\n  - { path: "../escape", type: file }\n' \
  > "$supp_home/.config/dotfiles/backup-paths.local"
supp_out="$(HOME="$supp_home" PATH="$fixture_home/fakebin:$PATH" "$PB" \
  backup --out "$supp_home/s.age" --recipient "$recipient" --yes 2>&1)" || true
if grep -Fq "skip unsafe path" <<< "$supp_out" && [[ -f "$supp_home/s.age" ]]; then
  pass "unsafe supplement path is skipped, baseline still captured"
else
  printf '%s\n' "$supp_out" >&2
  miss "unsafe supplement path was not skipped as expected"
fi

# 11. Missing recipient is a usage error (exit 2), not a silent plaintext.
norec_home="$fixture_home/norec"
mkdir -p "$norec_home/.ssh"
printf 'a\n' > "$norec_home/.zshrc.local"
printf 'b\n' > "$norec_home/.ssh/config.local"
rc=0
HOME="$norec_home" PATH="$fixture_home/fakebin:$PATH" "$PB" \
  backup --out "$norec_home/x.age" --yes >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 2 ]]; then
  pass "missing recipient is a usage error (exit 2)"
else
  miss "missing recipient should exit 2, got $rc"
fi

# 12. restore dry-run writes nothing.
rdst="$fixture_home/restore-dst"
mkdir -p "$rdst"
out="$(run restore --in "$archive" --identity "$fixture_home/keys/id.txt" --target-home "$rdst" 2>&1)" || true
if grep -Fq "would create" <<< "$out" && [[ "$(find "$rdst" -type f | wc -l | tr -d ' ')" -eq 0 ]]; then
  pass "restore dry-run writes nothing"
else
  printf '%s\n' "$out" >&2
  miss "restore dry-run wrote files or did not plan"
fi

# 13. restore --apply restores files with the original content.
if run restore --in "$archive" --identity "$fixture_home/keys/id.txt" --target-home "$rdst" --apply >/dev/null 2>&1 \
  && [[ "$(cat "$rdst/.zshrc.local" 2>/dev/null)" == "export SECRET_TOKEN=abc123" ]] \
  && [[ "$(cat "$rdst/.zprofile.local" 2>/dev/null)" == "export LOGIN_SETTING=fixture" ]] \
  && [[ "$(file_mode "$rdst/.zprofile.local")" == "600" ]] \
  && [[ -f "$rdst/.ssh/config.local" ]]; then
  pass "restore --apply restores files with original content"
else
  miss "restore --apply did not restore correctly"
fi

# 14. restore --apply over an existing file backs the old one up first.
printf 'LOCAL EDIT\n' > "$rdst/.zshrc.local"
out="$(run restore --in "$archive" --identity "$fixture_home/keys/id.txt" --target-home "$rdst" --apply 2>&1)" || true
backed_up="$(find "$rdst/.local/state/dotfiles" -name '.zshrc.local' 2>/dev/null | head -n1)"
if [[ "$(cat "$rdst/.zshrc.local")" == "export SECRET_TOKEN=abc123" ]] \
  && [[ -n "$backed_up" && "$(cat "$backed_up")" == "LOCAL EDIT" ]]; then
  pass "restore overwrites and saves the displaced file"
else
  printf '%s\n' "$out" >&2
  miss "restore did not back up the displaced file"
fi

# 15. restore --skip-existing leaves existing files untouched.
printf 'KEEP ME\n' > "$rdst/.zshrc.local"
run restore --in "$archive" --identity "$fixture_home/keys/id.txt" --target-home "$rdst" --apply --skip-existing >/dev/null 2>&1 || true
if [[ "$(cat "$rdst/.zshrc.local")" == "KEEP ME" ]]; then
  pass "restore --skip-existing leaves existing files untouched"
else
  miss "restore --skip-existing overwrote an existing file"
fi

# 16. restore refuses to write through a symlinked parent (escape defence).
sdst="$fixture_home/restore-symlink-dst"
escape="$fixture_home/escape-target"
mkdir -p "$sdst" "$escape"
ln -s "$escape" "$sdst/.ssh"
out="$(run restore --in "$archive" --identity "$fixture_home/keys/id.txt" --target-home "$sdst" --apply 2>&1)" || true
if grep -Fq "symlinked parent" <<< "$out" && [[ ! -e "$escape/config.local" ]]; then
  pass "restore refuses a symlinked parent (no escape)"
else
  printf '%s\n' "$out" >&2
  miss "restore wrote through a symlinked parent"
fi

# 16b. restore refuses when the backup-state path is a symlink (the
#      displaced-file move must not escape via ~/.local -> outside).
bdst="$fixture_home/restore-bdir-dst"
boutside="$fixture_home/bdir-outside"
mkdir -p "$bdst" "$boutside"
printf 'pre-existing\n' > "$bdst/.zshrc.local"   # force the overwrite/backup path
ln -s "$boutside" "$bdst/.local"
out="$(run restore --in "$archive" --identity "$fixture_home/keys/id.txt" --target-home "$bdst" --apply 2>&1)" || true
if grep -Fq "backup state path contains a symlink" <<< "$out" \
  && [[ -z "$(find "$boutside" -type f 2>/dev/null)" ]] \
  && [[ "$(cat "$bdst/.zshrc.local")" == "pre-existing" ]]; then
  pass "restore refuses a symlinked backup-state path (no escape, nothing overwritten)"
else
  printf '%s\n' "$out" >&2
  miss "restore did not refuse a symlinked backup-state path"
fi

# 17. restore refuses an archive that fails verification (corrupt manifest).
out="$(run restore --in "$fixture_home/out/badsum.age" --identity "$fixture_home/keys/id.txt" --target-home "$rdst" --apply 2>&1)" || true
if grep -Fq "refusing to restore" <<< "$out"; then
  pass "restore refuses an archive that fails verification"
else
  printf '%s\n' "$out" >&2
  miss "restore did not refuse a failed-verification archive"
fi

# 18. Runtime gate: a denied profile refuses to restore.
set_profile work
if run restore --in "$archive" --identity "$fixture_home/keys/id.txt" --target-home "$rdst" --apply >/dev/null 2>&1; then
  miss "restore must refuse under a denied profile"
else
  pass "restore refuses under a denied profile (work)"
fi
set_profile personal

# file_mode comes from lib-policy.sh (already sourced): the same helper
# private-backup.sh itself uses, which the test cannot source directly
# (running the script under test executes main).

# 19. A group-writable file (664) round-trips: capture, verify, and restore
#     keep the recorded mode. Regression for the umask bug: extraction
#     without -p turned 664 into 644 and the manifest mode check rejected
#     every archive containing such a file (issue #141).
gw_home="$fixture_home/gw"
mkdir -p "$gw_home/.ssh"
printf 'a\n' > "$gw_home/.zshrc.local"
printf 'b\n' > "$gw_home/.ssh/config.local"
chmod 664 "$gw_home/.zshrc.local"
gw_rc=0
HOME="$gw_home" PATH="$fixture_home/fakebin:$PATH" "$PB" \
  backup --out "$gw_home/gw.age" --recipient "$recipient" --yes >/dev/null 2>&1 || gw_rc=$?
if [[ "$gw_rc" -eq 0 ]] && HOME="$gw_home" PATH="$fixture_home/fakebin:$PATH" "$PB" \
  verify --in "$gw_home/gw.age" --identity "$fixture_home/keys/id.txt" >/dev/null 2>&1; then
  gw_dst="$fixture_home/gw-restore"
  mkdir -p "$gw_dst"
  if HOME="$gw_home" PATH="$fixture_home/fakebin:$PATH" "$PB" \
    restore --in "$gw_home/gw.age" --identity "$fixture_home/keys/id.txt" \
    --target-home "$gw_dst" --apply >/dev/null 2>&1 \
    && [[ "$(file_mode "$gw_dst/.zshrc.local")" == "664" ]]; then
    pass "group-writable file (664) survives backup/verify/restore with its mode"
  else
    miss "restored group-writable file lost its mode (want 664, got $(file_mode "$gw_dst/.zshrc.local" 2>/dev/null))"
  fi
else
  miss "verify rejected an archive containing a group-writable file (umask regression)"
fi

# 20. Without --yes and without a TTY, backup must fail (non-zero) instead of
#     reporting success while writing nothing (issue #141: unattended runs
#     would otherwise silently never back up).
ntty_home="$fixture_home/ntty"
mkdir -p "$ntty_home/.ssh"
printf 'a\n' > "$ntty_home/.zshrc.local"
printf 'b\n' > "$ntty_home/.ssh/config.local"
ntty_rc=0
# perl setsid detaches from the controlling terminal so `read < /dev/tty`
# inside the script fails; macOS ships no setsid(1), perl is on both OSes.
ntty_out="$(HOME="$ntty_home" PATH="$fixture_home/fakebin:$PATH" \
  perl -e 'use POSIX (); POSIX::setsid() != -1 or die "setsid: $!"; exec @ARGV or die "exec: $!"' \
  -- "$PB" backup --out "$ntty_home/n.age" --recipient "$recipient" 2>&1 < /dev/null)" || ntty_rc=$?
if [[ "$ntty_rc" -ne 0 && ! -f "$ntty_home/n.age" ]] \
  && grep -Fq "no TTY for confirmation" <<< "$ntty_out"; then
  pass "backup without --yes and without a TTY fails (no silent success)"
else
  printf '%s\n' "$ntty_out" >&2
  miss "non-TTY backup without --yes should fail, got rc=$ntty_rc"
fi

# 21. Overlapping declarations (a dir and a file inside it) capture the file
#     once: the manifest lists no duplicate paths (issue #141).
dup_home="$fixture_home/dup"
mkdir -p "$dup_home/.ssh" "$dup_home/.config/dotfiles" "$dup_home/nest"
printf 'a\n' > "$dup_home/.zshrc.local"
printf 'b\n' > "$dup_home/.ssh/config.local"
printf 'c\n' > "$dup_home/nest/inner"
printf 'backup_paths:\n  - { path: "nest", type: dir }\n  - { path: "nest/inner", type: file }\n' \
  > "$dup_home/.config/dotfiles/backup-paths.local"
if HOME="$dup_home" PATH="$fixture_home/fakebin:$PATH" "$PB" \
  backup --out "$dup_home/d.age" --recipient "$recipient" --yes >/dev/null 2>&1; then
  dup_extract="$fixture_home/dup-extract"
  mkdir -p "$dup_extract"
  age -d -i "$fixture_home/keys/id.txt" "$dup_home/d.age" | tar -xpf - -C "$dup_extract"
  dup_total="$(yq -p=json -o=tsv '.files | length' "$dup_extract/manifest.json")"
  dup_unique="$(yq -p=json -o=tsv '[.files[].path] | unique | length' "$dup_extract/manifest.json")"
  # Exactly once: dedup must not drop the file either (an ordering bug that
  # skipped capture entirely would also show zero duplicates).
  dup_inner="$(yq -p=json -o=tsv '[.files[].path | select(. == "nest/inner")] | length' "$dup_extract/manifest.json")"
  if [[ "$dup_total" == "$dup_unique" && "$dup_inner" == "1" ]]; then
    pass "overlapping dir+file declarations capture the file exactly once"
  else
    miss "manifest should list nest/inner exactly once ($dup_total entries, $dup_unique unique, nest/inner x$dup_inner)"
  fi
else
  miss "backup with overlapping declarations failed"
fi

# 22. An unreadable file is skipped with a warning; the backup still succeeds
#     and captures the readable files (issue #141: set -e aborted the whole
#     run mid-archive before).
unr_home="$fixture_home/unr"
mkdir -p "$unr_home/.ssh" "$unr_home/.config/dotfiles" "$unr_home/box"
printf 'a\n' > "$unr_home/.zshrc.local"
printf 'b\n' > "$unr_home/.ssh/config.local"
printf 'locked\n' > "$unr_home/locked"
chmod 000 "$unr_home/locked"
printf 'ok\n' > "$unr_home/box/readable"
printf 'locked\n' > "$unr_home/box/locked-in-dir"
chmod 000 "$unr_home/box/locked-in-dir"
printf 'backup_paths:\n  - { path: "locked", type: file }\n  - { path: "box", type: dir }\n' \
  > "$unr_home/.config/dotfiles/backup-paths.local"
unr_rc=0
unr_out="$(HOME="$unr_home" PATH="$fixture_home/fakebin:$PATH" "$PB" \
  backup --out "$unr_home/u.age" --recipient "$recipient" --yes 2>&1)" || unr_rc=$?
chmod 600 "$unr_home/locked" "$unr_home/box/locked-in-dir" # so the EXIT trap can clean up
if [[ "$unr_rc" -eq 0 && -f "$unr_home/u.age" ]] \
  && grep -Fq "unreadable (skipped): locked" <<< "$unr_out" \
  && grep -Fq "skip unreadable file under box: box/locked-in-dir" <<< "$unr_out"; then
  pass "unreadable files (declared file and inside a dir) are skipped with a warning, backup still succeeds"
else
  printf '%s\n' "$unr_out" >&2
  miss "unreadable files should be skipped without aborting, got rc=$unr_rc"
fi

# 23. Alias declarations must never make restore displace a target twice.
alias_home="$fixture_home/alias-home"
alias_dst="$fixture_home/alias-dst"
mkdir -p "$alias_home/.config/dotfiles" "$alias_home/.ssh" "$alias_dst"
printf 'restored\n' > "$alias_home/.zshrc.local"
printf 'ssh restored\n' > "$alias_home/.ssh/config.local"
printf 'original\n' > "$alias_dst/.zshrc.local"
cat > "$alias_home/.config/dotfiles/backup-paths.local" <<'YAML'
backup_paths:
  - { path: ./.zshrc.local, type: file }
  - { path: .ssh//config.local, type: file }
  - { path: .ssh/, type: dir }
YAML
if HOME="$alias_home" PATH="$fixture_home/fakebin:$PATH" "$PB" \
  backup --out "$alias_home/a.age" --recipient "$recipient" --yes >/dev/null 2>&1 \
  && run restore --in "$alias_home/a.age" --identity "$fixture_home/keys/id.txt" \
    --target-home "$alias_dst" --apply >/dev/null 2>&1; then
  displaced="$(find "$alias_dst/.local/state/dotfiles" -name .zshrc.local -type f)"
  if [[ -f "$displaced" ]] && [[ "$(cat "$displaced")" == "original" ]] \
    && [[ "$(cat "$alias_dst/.zshrc.local")" == "restored" ]]; then
    pass "alias declarations cannot overwrite the original displaced file"
  else
    miss "alias declarations lost the original displaced file"
  fi
else
  miss "backup/restore failed with a canonical baseline and alias supplement"
fi

# Filename metacharacters must survive hashing and row serialization:
# shasum escapes backslashes, while TSV array output quotes double quotes
# and leading whitespace. All are valid canonical filename characters.
for odd_name in 'space | back\slash' 'double"quote' ' leading-space'; do
  printf 'odd name\n' > "$alias_home/$odd_name"
  P="$odd_name" yq -n '{"backup_paths": [{"path": strenv(P), "type": "file"}]}' \
    > "$alias_home/.config/dotfiles/backup-paths.local"
  if HOME="$alias_home" PATH="$fixture_home/fakebin:$PATH" "$PB" \
    backup --out "$alias_home/odd.age" --recipient "$recipient" --yes >/dev/null 2>&1 \
    && run verify --in "$alias_home/odd.age" --identity "$fixture_home/keys/id.txt" >/dev/null 2>&1 \
    && run restore --in "$alias_home/odd.age" --identity "$fixture_home/keys/id.txt" \
      --target-home "$alias_dst" --apply >/dev/null 2>&1 \
    && cmp -s "$alias_home/$odd_name" "$alias_dst/$odd_name"; then
    pass "canonical filename round-trips exactly: $odd_name"
  else
    miss "canonical filename failed backup/verify/restore: $odd_name"
  fi
done

# Distinct canonical names can still collide on the restore filesystem.
# Preserve the displaced original even when case folding makes the second
# target resolve to the first; case-sensitive filesystems restore both names.
case_stage="$fixture_home/case-stage"
case_dst="$fixture_home/case-dst"
mkdir -p "$case_stage/files" "$case_dst"
printf 'restored\n' > "$case_stage/files/lower"
printf 'restored\n' > "$case_stage/files/LOWER"
printf 'original\n' > "$case_dst/lower"
case_folded=0
[[ -e "$case_dst/LOWER" ]] && case_folded=1
case_hash="$(shasum -a 256 "$case_stage/files/lower" | awk '{print $1}')"
H="$case_hash" M="$(file_mode "$case_stage/files/lower")" yq -n -o=json '{
  "schema_version": 1, "tool": "private-backup.sh", "tool_version": "1",
  "created_at": "2026-01-01T00:00:00Z", "entries": [],
  "files": [
    {"path": "lower", "mode": strenv(M), "size": 9, "sha256": strenv(H)},
    {"path": "LOWER", "mode": strenv(M), "size": 9, "sha256": strenv(H)}
  ]
}' > "$case_stage/manifest.json"
make_archive "$case_stage" "$fixture_home/out/case.age"
case_rc=0
run restore --in "$fixture_home/out/case.age" --identity "$fixture_home/keys/id.txt" \
  --target-home "$case_dst" --apply >/dev/null 2>&1 || case_rc=$?
case_displaced="$(find "$case_dst/.local/state/dotfiles" -name lower -type f)"
if [[ -f "$case_displaced" && "$(cat "$case_displaced")" == "original" ]] \
  && { [[ "$case_folded" -eq 1 && "$case_rc" -ne 0 ]] \
    || [[ "$case_folded" -eq 0 && "$case_rc" -eq 0 && "$(cat "$case_dst/LOWER")" == "restored" ]]; }; then
  pass "case-distinct restore paths preserve the displaced original on this filesystem"
else
  miss "case-distinct restore paths lost the original or returned the wrong status"
fi

# 24. Exercise all three consumers with a valid first payload followed by
#     malformed metadata: no rejected archive may reach target mutations.
manifest_base="$fixture_home/manifest-base"
manifest_stage="$fixture_home/manifest-stage"
manifest_dst="$fixture_home/manifest-dst"
mkdir -p "$manifest_base" "$manifest_stage" "$manifest_dst"
age -d -i "$fixture_home/keys/id.txt" "$archive" | tar -xpf - -C "$manifest_base"
printf 'original\n' > "$manifest_dst/.zshrc.local"

assert_manifest_rejected() {
  local label="$1" bad_archive="$fixture_home/out/manifest-$1.age" rejected=1
  make_archive "$manifest_stage" "$bad_archive"
  if run verify --in "$bad_archive" --identity "$fixture_home/keys/id.txt" >/dev/null 2>&1; then
    rejected=0
  fi
  if run restore --in "$bad_archive" --identity "$fixture_home/keys/id.txt" \
    --target-home "$manifest_dst" >/dev/null 2>&1; then
    rejected=0
  fi
  if run restore --in "$bad_archive" --identity "$fixture_home/keys/id.txt" \
    --target-home "$manifest_dst" --apply >/dev/null 2>&1; then
    rejected=0
  fi
  if [[ "$rejected" -eq 1 && "$(cat "$manifest_dst/.zshrc.local")" == "original" \
    && ! -e "$manifest_dst/.ssh" && ! -e "$manifest_dst/.local" ]]; then
    pass "manifest $label rejected by verify/dry-run/apply before any target write"
  else
    miss "manifest $label was accepted or changed the restore target"
  fi
}

cp -R "$manifest_base/." "$manifest_stage/"
printf '{invalid' > "$manifest_stage/manifest.json"
assert_manifest_rejected malformed-json
while IFS='|' read -r label mutation; do
  yq -p=json -o=json "$mutation" "$manifest_base/manifest.json" > "$manifest_stage/manifest.json"
  assert_manifest_rejected "$label"
done <<'CASES'
missing-schema|del(.schema_version)
unknown-schema|.schema_version = 999
string-schema|.schema_version = "1"
wrong-tool-type|.tool = []
wrong-version-type|.tool_version = 1
wrong-date-type|.created_at = 1
missing-entries|del(.entries)
wrong-entries-type|.entries = {}
wrong-entry-type|.entries[0].type = true
wrong-category-type|.entries[0].category = []
wrong-origin|.entries[0].origin = "unknown"
entry-path-type|.entries[0].path = 5
entry-path-control|.entries[0].path = "bad\npath"
missing-files|del(.files)
wrong-files-type|.files = {}
empty-files|.files = []
null-file|.files += [null]
missing-last-path|del(.files[-1].path)
empty-last-path|.files[-1].path = ""
wrong-last-path-type|.files[-1].path = []
path-control|.files[-1].path = "bad\tpath"
missing-hash|del(.files[-1].sha256)
wrong-hash-type|.files[-1].sha256 = []
invalid-hash|.files[-1].sha256 = "bad"
missing-mode|del(.files[-1].mode)
numeric-mode|.files[-1].mode = 644
invalid-mode|.files[-1].mode = "888"
missing-size|del(.files[-1].size)
string-size|.files[-1].size = "5"
negative-size|.files[-1].size = -1
fractional-size|.files[-1].size = 1.5
size-mismatch|.files[-1].size += 1
duplicate|.files += [.files[0]]
path-alias|.files += [.files[0]] | .files[-1].path = "./.zshrc.local"
CASES

# A query process that emits valid rows but fails must not be trusted. These
# failures happen after schema validation, covering both checked row queries.
query_fakebin="$fixture_home/queryfake"
mkdir -p "$query_fakebin"
real_yq="$(command -v yq)"
cat > "$query_fakebin/yq" <<'SH'
#!/bin/sh
"$REAL_YQ" "$@"
rc=$?
for arg in "$@"; do
  if [ "$arg" = "$FAIL_YQ_QUERY" ]; then exit 7; fi
done
exit "$rc"
SH
chmod +x "$query_fakebin/yq"
cp "$manifest_base/manifest.json" "$manifest_stage/manifest.json"
for query in '.entries[].path' '.files[] | [.sha256, .mode, (.size | tostring), .path] | join("\t")'; do
  if [[ "$query" == '.entries[].path' ]]; then label="entry-query-failure"; else label="file-query-failure"; fi
  REAL_YQ="$real_yq" FAIL_YQ_QUERY="$query" PATH="$query_fakebin:$PATH" \
    assert_manifest_rejected "$label"
done

# 25. The local supplement round-trips as payload at its canonical path
#     (issue #208): restore lands it in the target home under the same rules
#     as every other file, and the next backup from that home reads it.
sup_rel=".config/dotfiles/backup-paths.local"
sup_home="$fixture_home/sup-home"
sup_dst="$fixture_home/sup-dst"
mkdir -p "$sup_home/.ssh" "$sup_home/.config/dotfiles" "$sup_home/private" "$sup_dst"
printf 'a\n' > "$sup_home/.zshrc.local"
printf 'b\n' > "$sup_home/.ssh/config.local"
printf 'client secret\n' > "$sup_home/private/extra"
printf 'backup_paths:\n  - { path: "private/extra", type: file }\n' > "$sup_home/$sup_rel"
chmod 600 "$sup_home/$sup_rel"
sup_ok=1
HOME="$sup_home" PATH="$fixture_home/fakebin:$PATH" "$PB" \
  backup --out "$sup_home/s.age" --recipient "$recipient" --yes >/dev/null 2>&1 || sup_ok=0
sup_out="$(run restore --in "$sup_home/s.age" --identity "$fixture_home/keys/id.txt" --target-home "$sup_dst" 2>&1)" || sup_ok=0
if [[ "$sup_ok" -eq 1 ]] && grep -Fq "would create: $sup_rel" <<< "$sup_out" && [[ ! -e "$sup_dst/$sup_rel" ]]; then
  pass "restore dry-run plans the supplement at its canonical path and writes nothing"
else
  printf '%s\n' "$sup_out" >&2
  miss "restore dry-run did not plan the supplement (or wrote it)"
fi
if run restore --in "$sup_home/s.age" --identity "$fixture_home/keys/id.txt" --target-home "$sup_dst" --apply >/dev/null 2>&1 \
  && cmp -s "$sup_home/$sup_rel" "$sup_dst/$sup_rel" \
  && [[ "$(file_mode "$sup_dst/$sup_rel")" == "600" ]] \
  && [[ "$(cat "$sup_dst/private/extra")" == "client secret" ]]; then
  pass "restore --apply lands the supplement at its canonical path with content and mode"
else
  miss "restore --apply did not land the supplement correctly"
fi
# Re-backup from the restored home, with no flag: the local target must still
# be captured, and the supplement must appear exactly once (entry + file),
# with no pre-#208 top-level copy in the archive.
sup_extract="$fixture_home/sup-extract"
mkdir -p "$sup_extract"
if HOME="$sup_dst" PATH="$fixture_home/fakebin:$PATH" "$PB" \
  backup --out "$sup_dst/again.age" --recipient "$recipient" --yes >/dev/null 2>&1; then
  age -d -i "$fixture_home/keys/id.txt" "$sup_dst/again.age" | tar -xpf - -C "$sup_extract"
  sup_files_extra="$(yq -p=json -o=tsv '[.files[].path | select(. == "private/extra")] | length' "$sup_extract/manifest.json")"
  sup_files_list="$(R="$sup_rel" yq -p=json -o=tsv '[.files[].path | select(. == strenv(R))] | length' "$sup_extract/manifest.json")"
  sup_entries_list="$(R="$sup_rel" yq -p=json -o=tsv '[.entries[] | select(.path == strenv(R) and .origin == "supplement")] | length' "$sup_extract/manifest.json")"
  if [[ "$sup_files_extra" == "1" && "$sup_files_list" == "1" && "$sup_entries_list" == "1" ]] \
    && [[ ! -e "$sup_extract/backup-paths.local" ]]; then
    pass "re-backup from the restored home captures the local target and the supplement once (no top-level copy)"
  else
    miss "re-backup manifest unexpected (private/extra x$sup_files_extra, supplement file x$sup_files_list, supplement entry x$sup_entries_list)"
  fi
else
  miss "re-backup from the restored home failed"
fi

# The --local-supplement source path is backup-time input only: the list is
# captured at the canonical path, the source path is recorded nowhere, and
# restore lands it at the canonical path regardless.
cus_home="$fixture_home/cus-home"
cus_dst="$fixture_home/cus-dst"
cus_extract="$fixture_home/cus-extract"
cus_list="$cus_home/lists/custom-name.local"
mkdir -p "$cus_home/.ssh" "$cus_home/lists" "$cus_dst" "$cus_extract"
printf 'a\n' > "$cus_home/.zshrc.local"
printf 'b\n' > "$cus_home/.ssh/config.local"
printf 'note\n' > "$cus_home/lists/note"
printf 'backup_paths:\n  - { path: "lists/note", type: file }\n' > "$cus_list"
if HOME="$cus_home" PATH="$fixture_home/fakebin:$PATH" "$PB" \
  backup --out "$cus_home/c.age" --recipient "$recipient" --yes --local-supplement "$cus_list" >/dev/null 2>&1; then
  age -d -i "$fixture_home/keys/id.txt" "$cus_home/c.age" | tar -xpf - -C "$cus_extract"
  if cmp -s "$cus_list" "$cus_extract/files/$sup_rel" \
    && ! grep -Fq "custom-name" "$cus_extract/manifest.json" \
    && [[ "$(yq -p=json -o=tsv '[.files[].path | select(. == "lists/note")] | length' "$cus_extract/manifest.json")" == "1" ]] \
    && run restore --in "$cus_home/c.age" --identity "$fixture_home/keys/id.txt" --target-home "$cus_dst" --apply >/dev/null 2>&1 \
    && cmp -s "$cus_list" "$cus_dst/$sup_rel" && [[ ! -e "$cus_dst/lists/custom-name.local" ]]; then
    pass "--local-supplement source path is not recorded; the list restores to the canonical path"
  else
    miss "--local-supplement list was recorded by source path or restored elsewhere"
  fi
else
  miss "backup with --local-supplement failed"
fi

# An existing supplement in the target home follows the payload rules:
# displaced on --apply, left alone with --skip-existing.
printf 'OLD LIST\n' > "$cus_dst/$sup_rel"
run restore --in "$cus_home/c.age" --identity "$fixture_home/keys/id.txt" --target-home "$cus_dst" --apply >/dev/null 2>&1 || true
cus_displaced="$(find "$cus_dst/.local/state/dotfiles" -path '*/.config/dotfiles/backup-paths.local' -type f 2>/dev/null | head -n1)"
if [[ -n "$cus_displaced" && "$(cat "$cus_displaced")" == "OLD LIST" ]] && cmp -s "$cus_list" "$cus_dst/$sup_rel"; then
  pass "restore displaces an existing supplement before overwriting it"
else
  miss "restore did not displace the existing supplement"
fi
printf 'KEEP LIST\n' > "$cus_dst/$sup_rel"
run restore --in "$cus_home/c.age" --identity "$fixture_home/keys/id.txt" --target-home "$cus_dst" --apply --skip-existing >/dev/null 2>&1 || true
if [[ "$(cat "$cus_dst/$sup_rel")" == "KEEP LIST" ]]; then
  pass "restore --skip-existing leaves an existing supplement untouched"
else
  miss "restore --skip-existing overwrote the existing supplement"
fi

# A supplement that declares its own path is captured once: the canonical
# copy staged first wins, and the declaration is deduplicated.
ded_home="$fixture_home/ded-home"
ded_extract="$fixture_home/ded-extract"
mkdir -p "$ded_home/.ssh" "$ded_home/.config/dotfiles" "$ded_extract"
printf 'a\n' > "$ded_home/.zshrc.local"
printf 'b\n' > "$ded_home/.ssh/config.local"
printf 'backup_paths:\n  - { path: "%s", type: file }\n' "$sup_rel" > "$ded_home/$sup_rel"
if HOME="$ded_home" PATH="$fixture_home/fakebin:$PATH" "$PB" \
  backup --out "$ded_home/d.age" --recipient "$recipient" --yes >/dev/null 2>&1; then
  age -d -i "$fixture_home/keys/id.txt" "$ded_home/d.age" | tar -xpf - -C "$ded_extract"
  ded_files="$(R="$sup_rel" yq -p=json -o=tsv '[.files[].path | select(. == strenv(R))] | length' "$ded_extract/manifest.json")"
  ded_entries="$(R="$sup_rel" yq -p=json -o=tsv '[.entries[] | select(.path == strenv(R))] | length' "$ded_extract/manifest.json")"
  ded_origin="$(R="$sup_rel" yq -p=json -o=tsv '.entries[] | select(.path == strenv(R)) | .origin' "$ded_extract/manifest.json")"
  if [[ "$ded_files" == "1" && "$ded_entries" == "1" && "$ded_origin" == "supplement" ]]; then
    pass "a supplement declaring its own path yields one entry (origin supplement) and one file"
  else
    miss "self-declared supplement duplicated (files x$ded_files, entries x$ded_entries, origin $ded_origin)"
  fi
else
  miss "backup with a self-declaring supplement failed"
fi

# The supplement payload is hashed like every other file: tampering with it
# inside the archive is rejected by verify.
tam_stage="$fixture_home/tam-stage"
mkdir -p "$tam_stage"
age -d -i "$fixture_home/keys/id.txt" "$sup_home/s.age" | tar -xpf - -C "$tam_stage"
printf '  - { path: "injected", type: file }\n' >> "$tam_stage/files/$sup_rel"
make_archive "$tam_stage" "$fixture_home/out/tampered-supplement.age"
out="$(run verify --in "$fixture_home/out/tampered-supplement.age" --identity "$fixture_home/keys/id.txt" 2>&1)" || true
if grep -Fq "checksum mismatch: $sup_rel" <<< "$out"; then
  pass "verify rejects a tampered supplement payload"
else
  printf '%s\n' "$out" >&2
  miss "verify accepted a tampered supplement payload"
fi

# 26. backup self-checks its staging with the verify/restore manifest test
#     before encrypting (issue #224): a good run reports it, and a staging
#     that no longer matches the manifest is refused before any output.
sc_home="$fixture_home/sc-home"
mkdir -p "$sc_home/.ssh"
printf 'a\n' > "$sc_home/.zshrc.local"
printf 'b\n' > "$sc_home/.ssh/config.local"
sc_out="$(HOME="$sc_home" PATH="$fixture_home/fakebin:$PATH" "$PB" \
  backup --out "$sc_home/ok.age" --recipient "$recipient" --yes 2>&1)" || true
if grep -Fq "self-check manifest" <<< "$sc_out" && grep -Eq '^\[ok\] verified [0-9]+ file\(s\)' <<< "$sc_out" \
  && [[ -f "$sc_home/ok.age" ]]; then
  pass "backup self-checks the staging before writing"
else
  printf '%s\n' "$sc_out" >&2
  miss "backup did not report a staging self-check"
fi
# Fault injection at the tool boundary, not a backdoor in the script: a
# fake cp copies for real, then corrupts the staged copy under files/ — the
# manifest (hashed from the source) no longer matches the staging, exactly
# the producer/consumer drift the self-check exists to catch.
sc_fakebin="$fixture_home/cpfake"
mkdir -p "$sc_fakebin"
real_cp="$(command -v cp)"
cat > "$sc_fakebin/cp" <<'SH'
#!/bin/sh
"$REAL_CP" "$@"
rc=$?
for last; do :; done
case "$last" in
  */files/*) printf 'x' >> "$last" ;;
esac
exit "$rc"
SH
chmod +x "$sc_fakebin/cp"
sc_rc=0
sc_out="$(HOME="$sc_home" REAL_CP="$real_cp" PATH="$sc_fakebin:$fixture_home/fakebin:$PATH" "$PB" \
  backup --out "$sc_home/bad.age" --recipient "$recipient" --yes 2>&1)" || sc_rc=$?
if [[ "$sc_rc" -ne 0 ]] && grep -Fq "checksum mismatch" <<< "$sc_out" \
  && grep -Fq "staging failed self-check; no archive written" <<< "$sc_out" \
  && [[ ! -e "$sc_home/bad.age" && ! -e "$sc_home/bad.age.partial" ]] \
  && [[ "$(yq -p=json -o=tsv '.archive' "$sc_home/.local/state/dotfiles/private-backup.json")" == "ok.age" ]]; then
  pass "a staging that no longer matches its manifest is refused: no archive, no partial, marker unchanged"
else
  printf '%s\n' "$sc_out" >&2
  miss "self-check did not refuse a corrupted staging (rc=$sc_rc)"
fi

# 27. A declared directory whose enumeration fails part-way (issue #242):
#     find lists what it can and exits non-zero. backup must not report a
#     complete success: the listed files are still captured (continue, like
#     the unreadable-file contract), but the run warns, counts the
#     directory as skipped, and records capture_incomplete=true in the
#     marker; a clean run records false. Fault injection at the tool
#     boundary: a fake find that, for the fixture directory ONLY, prints a
#     partial NUL listing and exits 1 (root-run CI cannot rely on mode 000
#     to make the real find fail); every other invocation (the self-check's
#     `find . -type f`) goes to the real find.
en_home="$fixture_home/en-home"
mkdir -p "$en_home/.ssh" "$en_home/.config/dotfiles" "$en_home/box/deep"
printf 'a\n' > "$en_home/.zshrc.local"
printf 'b\n' > "$en_home/.ssh/config.local"
printf 'listed\n' > "$en_home/box/listed"
printf 'unlisted\n' > "$en_home/box/deep/unlisted"
printf 'backup_paths:\n  - { path: "box", type: dir }\n' > "$en_home/.config/dotfiles/backup-paths.local"
# Clean run first: the marker must say capture_incomplete=false. Its skipped
# count (absent optional baseline files) is the baseline for the partial run,
# which must report exactly one more: the directory whose enumeration failed.
en_clean_out="$(HOME="$en_home" PATH="$fixture_home/fakebin:$PATH" "$PB" \
  backup --out "$en_home/clean.age" --recipient "$recipient" --yes 2>&1)" || true
en_clean_skipped="$(sed -n 's/^\[warn\] skipped entries: \([0-9][0-9]*\)$/\1/p' <<< "$en_clean_out")"
en_clean_skipped="${en_clean_skipped:-0}"
if [[ -f "$en_home/clean.age" ]] \
  && [[ "$(yq -p=json -o=tsv '.capture_incomplete' "$en_home/.local/state/dotfiles/private-backup.json")" == "false" ]]; then
  pass "a clean backup records capture_incomplete=false in the marker"
else
  printf '%s\n' "$en_clean_out" >&2
  miss "clean backup did not record capture_incomplete=false"
fi
en_fakebin="$fixture_home/findfake"
mkdir -p "$en_fakebin"
real_find="$(command -v find)"
cat > "$en_fakebin/find" <<'SH'
#!/bin/sh
if [ "$1" = "$FAKE_FIND_DIR" ]; then
  printf '%s\0' "$FAKE_FIND_DIR/listed"
  exit 1
fi
exec "$REAL_FIND" "$@"
SH
chmod +x "$en_fakebin/find"
en_rc=0
en_out="$(HOME="$en_home" REAL_FIND="$real_find" FAKE_FIND_DIR="$en_home/box" PATH="$en_fakebin:$fixture_home/fakebin:$PATH" "$PB" \
  backup --out "$en_home/partial.age" --recipient "$recipient" --yes 2>&1)" || en_rc=$?
en_extract="$fixture_home/en-extract"
mkdir -p "$en_extract"
if [[ "$en_rc" -eq 0 && -f "$en_home/partial.age" ]] \
  && grep -Fq "directory enumeration incomplete (find exit 1; entries under it could not all be listed): box" <<< "$en_out" \
  && grep -Fq "capture INCOMPLETE: enumeration failed for 1 declared director(y/ies)" <<< "$en_out" \
  && grep -Fxq "[warn] skipped entries: $((en_clean_skipped + 1))" <<< "$en_out" \
  && [[ "$(yq -p=json -o=tsv '.capture_incomplete' "$en_home/.local/state/dotfiles/private-backup.json")" == "true" ]]; then
  age -d -i "$fixture_home/keys/id.txt" "$en_home/partial.age" | tar -xpf - -C "$en_extract"
  if [[ "$(yq -p=json -o=tsv '[.files[].path | select(. == "box/listed")] | length' "$en_extract/manifest.json")" == "1" ]] \
    && [[ "$(yq -p=json -o=tsv '[.files[].path | select(. == "box/deep/unlisted")] | length' "$en_extract/manifest.json")" == "0" ]]; then
    pass "a partial enumeration still captures the listed files, warns, counts the directory as skipped, and marks the marker incomplete"
  else
    miss "partial enumeration archive content unexpected"
  fi
else
  printf '%s\n' "$en_out" >&2
  miss "partial enumeration was not reported as incomplete (rc=$en_rc)"
fi
# verify of that archive still passes: staging/manifest agree — completeness
# of the capture is a different fact, carried by the marker, not the archive.
if run verify --in "$en_home/partial.age" --identity "$fixture_home/keys/id.txt" >/dev/null 2>&1; then
  pass "verify accepts an incomplete-capture archive (integrity, not completeness)"
else
  miss "verify rejected an archive whose staging and manifest agree"
fi

if [[ "$status" -eq 0 ]]; then
  ok "private-backup tests passed"
fi
exit "$status"
