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

# 8b2. A hardlink header carrying a regular file's mode (#335): bsdtar lists
#      it as "-", so the listing's type pass lets it through and extraction
#      makes a second link; the check on the extracted tree must reject it
#      (GNU tar lists it as "h", and the type pass rejects it first). The
#      archive is written byte by byte (no tar writes this shape), so the
#      case needs python3.
if command -v python3 >/dev/null 2>&1; then
  hl_tar="$fixture_home/out/hardlink-mode.tar"
  python3 - "$hl_tar" <<'PY'
import io
import sys
import tarfile

out = sys.argv[1]
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.USTAR_FORMAT) as tf:
    ti = tarfile.TarInfo("./files")
    ti.type = tarfile.DIRTYPE
    ti.mode = 0o755
    tf.addfile(ti)
    for name, data in (("./manifest.json", b"{}\n"), ("./files/a", b"x\n")):
        ti = tarfile.TarInfo(name)
        ti.size = len(data)
        ti.mode = 0o644
        tf.addfile(ti, io.BytesIO(data))
    ti = tarfile.TarInfo("./files/b")
    ti.type = tarfile.LNKTYPE
    ti.linkname = "./files/a"
    ti.mode = 0o644
    tf.addfile(ti)
data = bytearray(buf.getvalue())
off = 0
patched = 0
while off + 512 <= len(data):
    hdr = bytes(data[off:off + 512])
    if hdr == bytes(512):
        break
    size = int(hdr[124:136].strip(b"\0 ") or b"0", 8)
    if hdr[0:100].rstrip(b"\0") == b"./files/b":
        # Give the hardlink header a regular file's type bits in its mode.
        data[off + 100:off + 108] = b"0100644\0"
        data[off + 148:off + 156] = b" " * 8
        data[off + 148:off + 156] = ("%06o\0 " % sum(data[off:off + 512])).encode()
        patched += 1
    off += 512 + ((size + 511) // 512) * 512
if patched != 1:
    sys.exit("member ./files/b not found")
with open(out, "wb") as f:
    f.write(data)
PY
  age -r "$recipient" -o "$fixture_home/out/hardlink-mode.age" "$hl_tar"
  hl_rc=0
  out="$(run verify --in "$fixture_home/out/hardlink-mode.age" --identity "$fixture_home/keys/id.txt" 2>&1)" || hl_rc=$?
  if [[ "$(tar -tvf "$hl_tar" 2>/dev/null | awk '$NF == "./files/a" && $(NF - 2) == "link" { print substr($1, 1, 1) }')" == "-" ]]; then
    hl_expect="archive extracted a hardlinked member; rejected after extraction, before anything is restored"
  else
    hl_expect="archive has a non-regular member (symlink/hardlink/special); rejected before extraction"
  fi
  if [[ "$hl_rc" -ne 0 ]] && grep -Fq "$hl_expect" <<< "$out" && ! grep -Fq "members validated, extracted" <<< "$out"; then
    pass "verify rejects a hardlink header carrying a regular mode (this tar: $hl_expect)"
  else
    printf '%s\n' "$out" >&2
    miss "verify did not reject a hardlink header carrying a regular mode (expected: $hl_expect; exit $hl_rc)"
  fi
else
  warn "python3 not found; skipping the crafted hardlink-mode archive case"
fi

# 8b2b. An archive that leaves a directory without permissions (mode 000,
#       with a file under it) is rejected — the extracted tree cannot be
#       walked — and the 0700 temp is still removed afterwards, its content
#       included, with no archive-derived name in the output (#335; bsdtar
#       rejects it at the tree check, GNU tar already at extraction). Run
#       with a TMPDIR of its own so a leftover temp shows. Skipped as root
#       (root walks and removes the directory anyway).
if command -v python3 >/dev/null 2>&1 && [[ "$(id -u)" != "0" ]]; then
  locked_tar="$fixture_home/out/locked-dir.tar"
  python3 - "$locked_tar" <<'PY'
import io
import sys
import tarfile

out = sys.argv[1]
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.USTAR_FORMAT) as tf:
    for name, mode in (("./files", 0o755), ("./files/canary-pb-locked", 0o000)):
        ti = tarfile.TarInfo(name)
        ti.type = tarfile.DIRTYPE
        ti.mode = mode
        tf.addfile(ti)
    for name, data in (("./manifest.json", b"{}\n"), ("./files/canary-pb-locked/x", b"secret\n")):
        ti = tarfile.TarInfo(name)
        ti.size = len(data)
        ti.mode = 0o600
        tf.addfile(ti, io.BytesIO(data))
with open(out, "wb") as f:
    f.write(buf.getvalue())
PY
  age -r "$recipient" -o "$fixture_home/out/locked-dir.age" "$locked_tar"
  locked_tmp="$fixture_home/locked-tmp"
  mkdir -p "$locked_tmp"
  locked_rc=0
  out="$(TMPDIR="$locked_tmp" run verify --in "$fixture_home/out/locked-dir.age" --identity "$fixture_home/keys/id.txt" 2>&1)" || locked_rc=$?
  locked_left="$(find "$locked_tmp" -mindepth 1 -maxdepth 1 2>/dev/null)"
  # bsdtar extracts it and the tree check rejects it; GNU tar fails to write
  # under the directory and the extraction itself is rejected. Either way the
  # temp must be gone afterwards.
  if [[ "$locked_rc" -ne 0 && -z "$locked_left" ]] \
    && grep -Eq "could not inspect the extracted archive; rejected before anything is restored|could not extract archive" <<< "$out" \
    && ! grep -Fq "members validated, extracted" <<< "$out" \
    && ! grep -Fq "canary-pb-locked" <<< "$out"; then
    pass "verify rejects an archive that leaves a mode 000 directory, and its temp is still removed"
  else
    printf '%s\nleft: %s\n' "$out" "$locked_left" >&2
    miss "an archive leaving a mode 000 directory was not rejected, or its temp was left behind (exit $locked_rc)"
  fi
  find "$locked_tmp" -type d -exec chmod u+rwx {} \; 2>/dev/null || true
fi

# 8b3. The extracted-tree check itself, on trees tar may leave behind
#      whatever its listing said: a symlink, a fifo and a hardlink are each
#      rejected, a tree of regular files and directories passes, and a
#      directory the check cannot walk is rejected (not read as clean).
#      Extracted from private-backup.sh and run in a subshell.
vt_fns="$(sed -n '/^validate_extracted_tree() {/,/^}/p' "$PB")"
vt_root="$fixture_home/vt"
# vt_case LABEL WANT DIR — WANT is "accepted" (return 0, nothing said) or
# the failure message expected with a non-zero return.
vt_case() {
  local label="$1" want="$2" dir="$3" got rc=0
  got="$(
    fail() { printf '%s\n' "$*"; }
    eval "$vt_fns"
    validate_extracted_tree "$dir"
  )" || rc=$?
  if { [[ "$want" == accepted ]] && [[ "$rc" -eq 0 && -z "$got" ]]; } \
    || { [[ "$want" != accepted ]] && [[ "$rc" -ne 0 && "$got" == *"$want"* ]]; }; then
    pass "extracted-tree check: $label"
  else
    printf '%s\n' "$got" >&2
    miss "extracted-tree check: $label (expected: $want; returned $rc)"
  fi
}
if [[ -z "$vt_fns" ]]; then
  miss "validate_extracted_tree not found in private-backup.sh"
else
  mkdir -p "$vt_root/clean/files/.ssh" "$vt_root/symlink/files" "$vt_root/fifo/files" "$vt_root/hardlink/files"
  printf 'x\n' > "$vt_root/clean/files/.ssh/config"
  printf '{}\n' > "$vt_root/clean/manifest.json"
  ln -s /etc/passwd "$vt_root/symlink/files/evil"
  mkfifo "$vt_root/fifo/files/pipe"
  printf 'x\n' > "$vt_root/hardlink/files/a"
  ln "$vt_root/hardlink/files/a" "$vt_root/hardlink/files/b"
  vt_case "regular files and directories pass" "accepted" "$vt_root/clean"
  vt_case "a symlink is rejected" "archive extracted a non-regular member (symlink/special)" "$vt_root/symlink"
  vt_case "a fifo is rejected" "archive extracted a non-regular member (symlink/special)" "$vt_root/fifo"
  vt_case "a hardlinked file is rejected" "archive extracted a hardlinked member" "$vt_root/hardlink"
  if [[ "$(id -u)" != "0" ]]; then
    mkdir -p "$vt_root/locked/files/sub"
    chmod 000 "$vt_root/locked/files/sub"
    vt_case "a directory it cannot walk is rejected" "could not inspect the extracted archive" "$vt_root/locked"
    chmod 755 "$vt_root/locked/files/sub"
  fi
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

# 11b. The other recipient sources (#330): the default recipient file (the
#      path the docs recommend) and --recipients-file each produce an archive
#      the matching identity verifies; a missing --recipients-file, and both
#      flags at once, are usage errors (exit 2) that write nothing.
rcpt_home="$fixture_home/rcpt"
mkdir -p "$rcpt_home/.ssh" "$rcpt_home/.config/dotfiles" "$rcpt_home/out"
printf 'a\n' > "$rcpt_home/.zshrc.local"
printf 'b\n' > "$rcpt_home/.ssh/config.local"
printf '%s\n' "$recipient" > "$rcpt_home/recipients.txt"
rcpt_run() { HOME="$rcpt_home" PATH="$fixture_home/fakebin:$PATH" "$PB" "$@"; }
printf '%s\n' "$recipient" > "$rcpt_home/.config/dotfiles/private-backup.recipient"
if rcpt_run backup --out "$rcpt_home/out/default.age" --yes >/dev/null 2>&1 \
  && rcpt_run verify --in "$rcpt_home/out/default.age" --identity "$fixture_home/keys/id.txt" >/dev/null 2>&1; then
  pass "backup without a recipient flag encrypts to the default recipient file"
else
  miss "backup with only the default recipient file did not produce a verifiable archive"
fi
rm "$rcpt_home/.config/dotfiles/private-backup.recipient"
if rcpt_run backup --out "$rcpt_home/out/file.age" --recipients-file "$rcpt_home/recipients.txt" --yes >/dev/null 2>&1 \
  && rcpt_run verify --in "$rcpt_home/out/file.age" --identity "$fixture_home/keys/id.txt" >/dev/null 2>&1; then
  pass "backup --recipients-file encrypts to the listed recipient"
else
  miss "backup --recipients-file did not produce a verifiable archive"
fi
# The two usage errors run in fresh homes (no marker yet), so "writes
# nothing" covers the archive, its .partial and the marker (Codex review,
# PR #351).
for rcpt_err in missing-file both-flags; do
  rcpt_err_home="$fixture_home/rcpt-$rcpt_err"
  mkdir -p "$rcpt_err_home/.ssh"
  printf 'a\n' > "$rcpt_err_home/.zshrc.local"
  printf 'b\n' > "$rcpt_err_home/.ssh/config.local"
  rcpt_rc=0
  case "$rcpt_err" in
    missing-file)
      rcpt_expect="[fail] recipients file not found: $rcpt_err_home/no-such-file"
      rcpt_out="$(HOME="$rcpt_err_home" PATH="$fixture_home/fakebin:$PATH" "$PB" backup --out "$rcpt_err_home/x.age" \
        --recipients-file "$rcpt_err_home/no-such-file" --yes 2>&1)" || rcpt_rc=$?
      ;;
    both-flags)
      rcpt_expect="[fail] use only one of --recipient / --recipients-file"
      rcpt_out="$(HOME="$rcpt_err_home" PATH="$fixture_home/fakebin:$PATH" "$PB" backup --out "$rcpt_err_home/x.age" \
        --recipient "$recipient" --recipients-file "$rcpt_home/recipients.txt" --yes 2>&1)" || rcpt_rc=$?
      ;;
  esac
  if [[ "$rcpt_rc" -eq 2 ]] && grep -Fxq "$rcpt_expect" <<< "$rcpt_out" \
    && [[ ! -e "$rcpt_err_home/x.age" && ! -e "$rcpt_err_home/x.age.partial" && ! -e "$rcpt_err_home/.local/state/dotfiles/private-backup.json" ]]; then
    pass "recipient usage error ($rcpt_err) exits 2 and writes no archive, partial or marker"
  else
    printf '%s\n' "$rcpt_out" >&2
    miss "recipient usage error ($rcpt_err) must exit 2 without writing anything (rc=$rcpt_rc)"
  fi
done

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

# 14b. New restore parents, including intermediate directories, must be
#      private even when the caller uses umask 022 (issue #282).
parent_stage="$fixture_home/stage-parent-mode"
parent_dst="$fixture_home/restore-parent-mode"
parent_archive="$fixture_home/out/parent-mode.age"
parent_path=".ssh/conf.d/config.local"
mkdir -p "$parent_stage/files/.ssh/conf.d" "$parent_dst"
printf 'Host private\n' > "$parent_stage/files/$parent_path"
chmod 644 "$parent_stage/files/$parent_path"
sum="$(shasum -a 256 "$parent_stage/files/$parent_path" | awk '{print $1}')"
SUM="$sum" P="$parent_path" yq -n -o=json '{
  "schema_version": 1, "tool": "private-backup.sh", "tool_version": "1",
  "created_at": "2026-01-01T00:00:00Z", "entries": [],
  "files": [{"path": strenv(P), "mode": "644", "size": 13, "sha256": strenv(SUM)}]
}' > "$parent_stage/manifest.json"
make_archive "$parent_stage" "$parent_archive"
if out="$(umask 022; run restore --in "$parent_archive" --identity "$fixture_home/keys/id.txt" \
  --target-home "$parent_dst" --apply 2>&1)" \
  && cmp -s "$parent_stage/files/$parent_path" "$parent_dst/$parent_path" \
  && [[ "$(file_mode "$parent_dst/$parent_path")" == "644" ]]; then
  pass "restore creates the nested file with its recorded mode"
else
  printf '%s\n' "$out" >&2
  miss "restore failed to create the nested file with its recorded mode"
fi
for parent in .ssh .ssh/conf.d .local .local/state .local/state/dotfiles; do
  mode="$(file_mode "$parent_dst/$parent" 2>/dev/null)" || mode=missing
  if [[ "$mode" == "700" ]]; then
    pass "new restore parent $parent is 0700"
  else
    miss "new restore parent $parent must be 0700, got $mode"
  fi
done

# 14c. Existing 0755 parents stay unchanged; displaced files get private
#      parents at every level below the unique backup directory.
for parent in .ssh .ssh/conf.d .local .local/state .local/state/dotfiles; do
  chmod 755 "$parent_dst/$parent"
done
printf 'LOCAL EDIT\n' > "$parent_dst/$parent_path"
if out="$(umask 022; run restore --in "$parent_archive" --identity "$fixture_home/keys/id.txt" \
  --target-home "$parent_dst" --apply 2>&1)" \
  && cmp -s "$parent_stage/files/$parent_path" "$parent_dst/$parent_path"; then
  pass "restore overwrites the nested file under existing parents"
else
  printf '%s\n' "$out" >&2
  miss "restore failed to overwrite the nested file under existing parents"
fi
for parent in .ssh .ssh/conf.d .local .local/state .local/state/dotfiles; do
  mode="$(file_mode "$parent_dst/$parent" 2>/dev/null)" || mode=missing
  if [[ "$mode" == "755" ]]; then
    pass "existing restore parent $parent stays 0755"
  else
    miss "existing restore parent $parent must stay 0755, got $mode"
  fi
done
parent_saved="$(find "$parent_dst/.local/state/dotfiles" -name config.local -type f)"
if [[ -f "$parent_saved" && "$(cat "$parent_saved")" == "LOCAL EDIT" ]]; then
  parent_backup="${parent_saved%/"$parent_path"}"
  for parent in "$parent_backup" "$parent_backup/.ssh" "$parent_backup/.ssh/conf.d"; do
    mode="$(file_mode "$parent" 2>/dev/null)" || mode=missing
    if [[ "$mode" == "700" ]]; then
      pass "displaced-file parent ${parent##*/} is 0700"
    else
      miss "displaced-file parent ${parent##*/} must be 0700, got $mode"
    fi
  done
else
  miss "restore did not preserve the displaced nested file"
fi

# 15. restore --skip-existing preserves existing files and restores missing ones.
printf 'KEEP ME\n' > "$rdst/.zshrc.local"
rm "$rdst/.zprofile.local"
if out="$(run restore --in "$archive" --identity "$fixture_home/keys/id.txt" --target-home "$rdst" --apply --skip-existing 2>&1)" \
  && [[ "$(cat "$rdst/.zshrc.local")" == "KEEP ME" ]] \
  && cmp -s "$fixture_home/.zprofile.local" "$rdst/.zprofile.local"; then
  pass "restore --skip-existing preserves existing files and restores missing ones"
else
  printf '%s\n' "$out" >&2
  miss "restore --skip-existing must succeed, preserve existing files and restore missing ones"
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
rm "$cus_dst/lists/note"
if out="$(run restore --in "$cus_home/c.age" --identity "$fixture_home/keys/id.txt" --target-home "$cus_dst" --apply --skip-existing 2>&1)" \
  && [[ "$(cat "$cus_dst/$sup_rel")" == "KEEP LIST" ]] \
  && cmp -s "$cus_home/lists/note" "$cus_dst/lists/note"; then
  pass "restore --skip-existing preserves the supplement and restores missing payload"
else
  printf '%s\n' "$out" >&2
  miss "restore --skip-existing must succeed, preserve the supplement and restore missing payload"
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

# 25b. Nothing to back up is a failure, not an empty archive (#208, #330):
#      with no baseline file and no supplement, and with a supplement whose
#      declared targets are all absent (the list alone is not a backup),
#      backup exits non-zero with the reason and writes no archive, no
#      partial and no marker.
for empty_case in nothing supplement-only; do
  empty_home="$fixture_home/empty-$empty_case"
  mkdir -p "$empty_home"
  if [[ "$empty_case" == supplement-only ]]; then
    mkdir -p "$empty_home/.config/dotfiles"
    printf 'backup_paths:\n  - { path: absent-file, type: file }\n  - { path: absent-dir, type: dir }\n' \
      > "$empty_home/.config/dotfiles/backup-paths.local"
  fi
  empty_rc=0
  empty_out="$(HOME="$empty_home" PATH="$fixture_home/fakebin:$PATH" "$PB" \
    backup --out "$empty_home/e.age" --recipient "$recipient" --yes 2>&1)" || empty_rc=$?
  if [[ "$empty_rc" -ne 0 ]] && grep -Fxq "[fail] no files captured; refusing to write an empty archive" <<< "$empty_out" \
    && [[ ! -e "$empty_home/e.age" && ! -e "$empty_home/e.age.partial" && ! -e "$empty_home/.local/state/dotfiles/private-backup.json" ]]; then
    pass "backup with nothing to capture ($empty_case) fails without an archive or a marker"
  else
    printf '%s\n' "$empty_out" >&2
    miss "backup with nothing to capture ($empty_case) must fail without writing (rc=$empty_rc)"
  fi
done

# 25c. Declared targets of the wrong kind are skipped with a warning and
#      never captured (#330): a symlink to a file and to a directory (the
#      link target, outside the declarations, must not land in the archive
#      under the declared name), a FIFO declared as a file, and a regular
#      file declared as a directory. The backup itself still succeeds.
kind_home="$fixture_home/kind"
mkdir -p "$kind_home/.ssh" "$kind_home/.config/dotfiles" "$kind_home/outside-dir"
printf 'a\n' > "$kind_home/.zshrc.local"
printf 'b\n' > "$kind_home/.ssh/config.local"
printf 'link target content\n' > "$kind_home/outside-file"
printf 'inside the linked dir\n' > "$kind_home/outside-dir/inner"
ln -s outside-file "$kind_home/link-file"
ln -s outside-dir "$kind_home/link-dir"
mkfifo "$kind_home/fifo"
printf 'plain file\n' > "$kind_home/not-a-dir"
printf 'backup_paths:\n  - { path: link-file, type: file }\n  - { path: link-dir, type: dir }\n  - { path: fifo, type: file }\n  - { path: not-a-dir, type: dir }\n' \
  > "$kind_home/.config/dotfiles/backup-paths.local"
# A regression that reads the FIFO (no regular-file check) would block
# forever on a FIFO with no writer and never reach the assertions (Codex
# review, PR #351). While backup runs, a feeder keeps opening and closing
# the FIFO for writing, so every open finds a writer and every read ends in
# EOF (stage_file opens its source several times: cp, wc, shasum). Such a
# regression then captures the FIFO as an empty file and the case fails; a
# correct run never opens it. The feeder stops on a stop file and is reaped.
feed_fifo() { # FIFO STOPFILE
  while [[ ! -e "$2" ]]; do
    exec 9<>"$1"
    sleep 0.2
    exec 9>&-
  done
}
feed_fifo "$kind_home/fifo" "$fixture_home/kind-feeder-stop" &
kind_feeder=$!
kind_rc=0
kind_out="$(HOME="$kind_home" PATH="$fixture_home/fakebin:$PATH" "$PB" \
  backup --out "$kind_home/k.age" --recipient "$recipient" --yes 2>&1)" || kind_rc=$?
: > "$fixture_home/kind-feeder-stop"
wait "$kind_feeder" 2>/dev/null || true
kind_extract="$fixture_home/kind-extract"
mkdir -p "$kind_extract"
kind_files=""
if [[ "$kind_rc" -eq 0 && -f "$kind_home/k.age" ]]; then
  age -d -i "$fixture_home/keys/id.txt" "$kind_home/k.age" | tar -xpf - -C "$kind_extract"
  kind_files="$(yq -p=json -o=tsv '.files[].path' "$kind_extract/manifest.json")"
fi
if [[ "$kind_rc" -eq 0 && -n "$kind_files" ]] \
  && grep -Fxq "[warn] skip symlink (not captured): link-file" <<< "$kind_out" \
  && grep -Fxq "[warn] skip symlink (not captured): link-dir" <<< "$kind_out" \
  && grep -Fxq "[warn] declared file is not a regular file (skipped): fifo" <<< "$kind_out" \
  && grep -Fxq "[warn] declared dir is not a directory (skipped): not-a-dir" <<< "$kind_out" \
  && ! grep -Eq '^(link-file|link-dir|link-dir/.*|fifo|not-a-dir|outside-file|outside-dir/.*)$' <<< "$kind_files" \
  && [[ -z "$(find "$kind_extract/files" \( -name 'link-*' -o -name fifo -o -name not-a-dir -o -name 'outside-*' -o -name inner \) -print)" ]] \
  && ! grep -rqF "link target content" "$kind_extract/files" \
  && ! grep -rqF "inside the linked dir" "$kind_extract/files"; then
  pass "symlinks, a FIFO declared as a file and a file declared as a dir are skipped with warnings and never captured"
else
  printf 'rc=%s\n%s\nfiles:\n%s\n' "$kind_rc" "$kind_out" "$kind_files" >&2
  miss "a declared target of the wrong kind was captured or not warned about"
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

# 28. The local supplement is user input: a structurally invalid entry must
#     not be dropped silently or mangled (issue #246). The shared parser
#     rejects the whole file before any row is used, so backup fails with the
#     message, writes no archive and no marker. Three shapes: an entry
#     without a path, a "|" in category (would shift fields into the path),
#     and a newline inside a path (would split into two rows). A normal free
#     label still passes, and a "|" INSIDE a path stays allowed (the
#     odd-filename round-trip above already pins that).
sv_case() {
  local label="$1" entry="$2" rc=0 out home
  home="$fixture_home/sv-$label"
  mkdir -p "$home/.ssh" "$home/.config/dotfiles"
  printf 'a\n' > "$home/.zshrc.local"
  printf 'b\n' > "$home/.ssh/config.local"
  printf 'backup_paths:\n%s\n' "$entry" > "$home/.config/dotfiles/backup-paths.local"
  out="$(HOME="$home" PATH="$fixture_home/fakebin:$PATH" "$PB" \
    backup --out "$home/s.age" --recipient "$recipient" --yes 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 ]] && grep -Fq "backup-paths entry invalid in $home/.config/dotfiles/backup-paths.local" <<< "$out" \
    && [[ ! -e "$home/s.age" && ! -e "$home/s.age.partial" && ! -e "$home/.local/state/dotfiles/private-backup.json" ]]; then
    pass "invalid supplement ($label) is rejected before capture: no archive, no marker"
  else
    printf '%s\n' "$out" >&2
    miss "invalid supplement ($label) was accepted or mis-reported (rc=$rc)"
  fi
}
sv_case missing-path '  - { type: file, category: fixture }'
sv_case pipe-in-category '  - { path: only-in-supplement, type: file, category: "shell|override" }'
sv_case newline-in-path '  - { path: "one\nfile|other|two", type: file }'
# A scalar in place of the list (`backup_paths: false`): must be rejected
# too — `// []` would have read it as "no entries" and let the baseline-only
# backup succeed silently (Codex review, PR #254).
sv_scalar="$fixture_home/sv-scalar-list"
mkdir -p "$sv_scalar/.ssh" "$sv_scalar/.config/dotfiles"
printf 'a\n' > "$sv_scalar/.zshrc.local"
printf 'b\n' > "$sv_scalar/.ssh/config.local"
printf 'backup_paths: false\n' > "$sv_scalar/.config/dotfiles/backup-paths.local"
sv_scalar_rc=0
sv_scalar_out="$(HOME="$sv_scalar" PATH="$fixture_home/fakebin:$PATH" "$PB" \
  backup --out "$sv_scalar/s.age" --recipient "$recipient" --yes 2>&1)" || sv_scalar_rc=$?
if [[ "$sv_scalar_rc" -ne 0 ]] && grep -Fq "backup-paths entry invalid in $sv_scalar/.config/dotfiles/backup-paths.local" <<< "$sv_scalar_out" \
  && [[ ! -e "$sv_scalar/s.age" && ! -e "$sv_scalar/.local/state/dotfiles/private-backup.json" ]]; then
  pass "invalid supplement (scalar in place of the list) is rejected before capture: no archive, no marker"
else
  printf '%s\n' "$sv_scalar_out" >&2
  miss "a scalar backup_paths in the supplement was accepted (rc=$sv_scalar_rc)"
fi
# Control: a free-form label without the delimiter is fine and the declared
# file is captured under its own path.
sv_ok="$fixture_home/sv-ok"
mkdir -p "$sv_ok/.ssh" "$sv_ok/.config/dotfiles"
printf 'a\n' > "$sv_ok/.zshrc.local"
printf 'b\n' > "$sv_ok/.ssh/config.local"
printf 'labelled\n' > "$sv_ok/only-in-supplement"
printf 'backup_paths:\n  - { path: only-in-supplement, type: file, category: "shell/override label" }\n' \
  > "$sv_ok/.config/dotfiles/backup-paths.local"
sv_extract="$fixture_home/sv-extract"
mkdir -p "$sv_extract"
if HOME="$sv_ok" PATH="$fixture_home/fakebin:$PATH" "$PB" \
  backup --out "$sv_ok/s.age" --recipient "$recipient" --yes >/dev/null 2>&1; then
  age -d -i "$fixture_home/keys/id.txt" "$sv_ok/s.age" | tar -xpf - -C "$sv_extract"
  if [[ "$(yq -p=json -o=tsv '[.files[].path | select(. == "only-in-supplement")] | length' "$sv_extract/manifest.json")" == "1" ]] \
    && [[ "$(yq -p=json -o=tsv '.entries[] | select(.path == "only-in-supplement") | .category' "$sv_extract/manifest.json")" == "shell/override label" ]]; then
    pass "a free-form category label without | is accepted and recorded as declared"
  else
    miss "valid supplement label was not captured / recorded as declared"
  fi
else
  miss "backup with a valid free-form category label failed"
fi

# 29. --out names a file, never a directory (including directory symlinks).
# Check both marker states and observe mktemp calls so cleanup cannot hide
# staging created before the usage error.
out_fakebin="$fixture_home/out-fakebin"
mkdir -p "$out_fakebin"
real_mktemp="$(command -v mktemp)"
cat > "$out_fakebin/mktemp" <<'SH'
#!/bin/sh
printf 'called\n' >> "$MKTEMP_CALLS"
exec "$REAL_MKTEMP" "$@"
SH
chmod +x "$out_fakebin/mktemp"
for out_kind in directory symlink; do
  for marker_state in absent existing; do
    out_home="$fixture_home/out-$out_kind-$marker_state"
    mkdir -p "$out_home/destination"
    printf 'fixture\n' > "$out_home/.zshrc.local"
    out_path="$out_home/destination"
    if [[ "$out_kind" == symlink ]]; then
      ln -s destination "$out_home/link"
      out_path="$out_home/link"
    fi
    out_marker="$out_home/.local/state/dotfiles/private-backup.json"
    if [[ "$marker_state" == existing ]]; then
      mkdir -p "$(dirname "$out_marker")"
      cp "$marker" "$out_marker"
    fi
    out_rc=0
    out_log="$(HOME="$out_home" REAL_MKTEMP="$real_mktemp" MKTEMP_CALLS="$out_home/mktemp-calls" \
      PATH="$out_fakebin:$fixture_home/fakebin:$PATH" "$PB" \
      backup --out "$out_path" --recipient "$recipient" --yes 2>&1)" || out_rc=$?
    if [[ "$out_rc" -eq 2 ]] && grep -Fq '[fail]' <<< "$out_log" \
      && [[ ! -e "$out_home/mktemp-calls" && ! -e "$out_path.partial" ]] \
      && [[ -z "$(find "$out_home/destination" -mindepth 1 -print)" ]]; then
      pass "--out $out_kind ($marker_state marker) is refused before staging without an archive"
    else
      miss "--out $out_kind ($marker_state marker) was not refused before staging (rc=$out_rc)"
    fi
    if { [[ "$marker_state" == absent && ! -e "$out_marker" ]]; } \
      || { [[ "$marker_state" == existing ]] && cmp -s "$marker" "$out_marker"; }; then
      pass "--out $out_kind preserves the $marker_state marker"
    else
      miss "--out $out_kind changed the $marker_state marker"
    fi
  done
done

# 30. An existing regular output file can still be overwritten.
overwrite_archive="$fixture_home/out/overwrite.age"
printf 'old content\n' > "$overwrite_archive"
if run backup --out "$overwrite_archive" --recipient "$recipient" --yes >/dev/null 2>&1 \
  && run verify --in "$overwrite_archive" --identity "$fixture_home/keys/id.txt" >/dev/null 2>&1; then
  pass "backup overwrites an existing regular output file with a valid archive"
else
  miss "backup failed to overwrite an existing regular output file"
fi

# 31. A directory appearing after argument validation must not produce a
# success report or update the marker, even when mv itself succeeds.
real_mv="$(command -v mv)"
cat > "$out_fakebin/mv" <<'SH'
#!/bin/sh
for last; do :; done
if [ "$last" = "$RACE_OUT" ]; then
  mkdir "$RACE_OUT" || exit 1
fi
exec "$REAL_MV" "$@"
SH
chmod +x "$out_fakebin/mv"
race_home="$fixture_home/out-race"
mkdir -p "$race_home/.local/state/dotfiles"
printf 'fixture\n' > "$race_home/.zshrc.local"
race_marker="$race_home/.local/state/dotfiles/private-backup.json"
cp "$marker" "$race_marker"
race_rc=0
race_log="$(HOME="$race_home" REAL_MV="$real_mv" RACE_OUT="$race_home/backup.age" \
  REAL_MKTEMP="$real_mktemp" MKTEMP_CALLS="$race_home/mktemp-calls" \
  PATH="$out_fakebin:$fixture_home/fakebin:$PATH" "$PB" \
  backup --out "$race_home/backup.age" --recipient "$recipient" --yes 2>&1)" || race_rc=$?
if [[ "$race_rc" -eq 1 && -f "$race_home/backup.age/backup.age.partial" ]] \
  && grep -Fq '[fail]' <<< "$race_log" \
  && ! grep -Fq 'wrote encrypted archive:' <<< "$race_log" \
  && cmp -s "$marker" "$race_marker"; then
  pass "backup detects a directory appearing at mv time and preserves the marker"
else
  miss "backup reported success or changed the marker after mv into a directory (rc=$race_rc)"
fi

if [[ "$status" -eq 0 ]]; then
  ok "private-backup tests passed"
fi
exit "$status"
