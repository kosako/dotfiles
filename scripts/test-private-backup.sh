#!/usr/bin/env bash
set -euo pipefail

# Round-trip and safety tests for private-backup.sh (issue #60). Hermetic:
# a fixture HOME, a fake `chezmoi` on PATH so the runtime gate resolves a
# chosen profile (needed in CI, which has no real chezmoi), and throwaway
# age keys. Never touches the real HOME. Requires age + age-keygen + yq.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"
# shellcheck source=scripts/test-lib.sh
source "$SCRIPT_DIR/test-lib.sh"

PB="$SCRIPT_DIR/private-backup.sh"
status=0
pass() { ok "test passed: $*"; }
miss() {
  fail "test failed: $*"
  status=1
}

# Without age the suite cannot run. Locally that stays a skip; on CI (CI=true,
# set by GitHub Actions) it is a failure, so a dropped install step or a
# broken PATH cannot turn the whole suite green (#330).
if ! command -v age >/dev/null 2>&1 || ! command -v age-keygen >/dev/null 2>&1; then
  if [[ "${CI:-}" == "true" ]]; then
    fail "age/age-keygen not found on CI; the private-backup tests must run there (the workflow installs a pinned age)"
    exit 1
  fi
  warn "age/age-keygen not found; skipping private-backup round-trip tests"
  exit 0
fi
# The rule above, checked by running this suite again with a PATH that has no
# age (only the system dirs): CI=true must fail, a local run must skip. Done
# only where the system dirs really lack age, so the inner run stops at the
# check. The inner run never re-runs itself (PRIVATE_BACKUP_TEST_INNER), and
# BASH_ENV is dropped so no startup file can put age back on its PATH
# (Codex review, PR #354): the re-run is one level deep whatever happens.
if [[ -z "${PRIVATE_BACKUP_TEST_INNER:-}" ]] && ! PATH=/usr/bin:/bin command -v age >/dev/null 2>&1; then
  age_ci_rc=0
  age_ci_out="$(env -u BASH_ENV CI=true PRIVATE_BACKUP_TEST_INNER=1 PATH=/usr/bin:/bin bash "${BASH_SOURCE[0]}" 2>&1)" || age_ci_rc=$?
  age_local_rc=0
  age_local_out="$(env -u BASH_ENV -u CI PRIVATE_BACKUP_TEST_INNER=1 PATH=/usr/bin:/bin bash "${BASH_SOURCE[0]}" 2>&1)" || age_local_rc=$?
  if [[ "$age_ci_rc" -eq 1 ]] && grep -Fq "[fail] age/age-keygen not found on CI" <<< "$age_ci_out" \
    && [[ "$age_local_rc" -eq 0 ]] && grep -Fq "[warn] age/age-keygen not found; skipping" <<< "$age_local_out"; then
    ok "test passed: without age the suite fails on CI and skips locally"
  else
    printf 'CI run rc=%s\n%s\nlocal run rc=%s\n%s\n' "$age_ci_rc" "$age_ci_out" "$age_local_rc" "$age_local_out" >&2
    fail "test failed: without age the suite must fail on CI (exit 1) and skip locally (exit 0)"
    status=1
  fi
elif [[ -z "${PRIVATE_BACKUP_TEST_INNER:-}" ]]; then
  warn "age is in /usr/bin or /bin here; the no-age check of this suite is skipped"
fi

fixture_home="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-pb-test.XXXXXX")"

# Stop the background cases (the FIFO case, the signal cases) and reap them
# before removing their HOME and staging. A background command can ignore
# INT, and a `set -m` job does not get the suite's signal at all, so the
# suite owns every process it started (#389, #413).
cleanup() {
  stop_child_trees
  # Cases that take a permission away (case 22's mode 000 files, case 39's
  # unsearchable directory) give it back on their normal path only. Modes
  # are opened first, so a run interrupted inside that window still removes
  # the whole fixture (Codex review R2, PR #418; test-doctor does the same).
  chmod -R u+rwX "$fixture_home" 2>/dev/null || true
  rm -rf "$fixture_home" || true
}
trap 'trap "" INT TERM; cleanup' EXIT
trap 'trap "" INT TERM; cleanup; trap - INT; kill -INT $$' INT
trap 'trap "" INT TERM; cleanup; trap - TERM; kill -TERM $$' TERM
[[ -z "${SUITE_INTERRUPT_CUE:-}" ]] || suite_interrupt_inner "$SUITE_INTERRUPT_CUE" "$fixture_home"
# The traps above, checked by interrupting a run of this suite (#413). Run
# once, from the outer run only (an inner run stops at the check above).
if [[ -z "${PRIVATE_BACKUP_TEST_INNER:-}" ]]; then
  if check_suite_interrupt "${BASH_SOURCE[0]}" "$fixture_home" PRIVATE_BACKUP_TEST_INNER=1; then
    pass "a suite interrupted while background cases run stops their whole trees and removes its fixture"
  else
    miss "an interrupted suite left processes behind or kept its fixture"
  fi
fi

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
# run_in HOME_DIR ARGS... — the same, with HOME_DIR as the home.
run_in() {
  local home="$1"
  shift
  HOME="$home" PATH="$fixture_home/fakebin:$PATH" "$PB" "$@"
}
# backup_in HOME_DIR OUT [ARG...] — back up from HOME_DIR to OUT with the
# fixture recipient and --yes, then ARGs. A case's own env (TMPDIR, REAL_*,
# a PATH with its fakes in front) goes before the call; the fixture fakebin
# then comes first on that PATH, which changes nothing: it holds only chezmoi.
backup_in() {
  local home="$1" out="$2"
  shift 2
  run_in "$home" backup --out "$out" --recipient "$recipient" --yes "$@"
}
# seed_home DIR — the two baseline files of a case home (.zshrc.local and
# .ssh/config.local, contents "a" and "b").
seed_home() {
  mkdir -p "$1/.ssh"
  printf 'a\n' > "$1/.zshrc.local"
  printf 'b\n' > "$1/.ssh/config.local"
}
# extract_archive ARCHIVE DIR — decrypt ARCHIVE with the fixture identity and
# unpack it into DIR, modes kept (-p). Called as a plain statement, so a
# failed decrypt or unpack still stops the suite (set -e, pipefail).
extract_archive() { age -d -i "$fixture_home/keys/id.txt" "$1" | tar -xpf - -C "$2"; }
# wait_deadline PID SECONDS — wait for PID, a child of this shell, for up to
# SECONDS; past that, KILL it and its descendants (kill_tree). Sets
# wd_timed_out (1 when it was killed) and wd_rc (its status). Not inside
# $(...): the wait must run in the shell that started PID.
wait_deadline() {
  local deadline=$((SECONDS + $2))
  while kill -0 "$1" 2>/dev/null && [[ "$SECONDS" -lt "$deadline" ]]; do
    sleep 0.2
  done
  wd_timed_out=0
  if kill -0 "$1" 2>/dev/null; then
    wd_timed_out=1
    kill_tree "$1"
  fi
  wd_rc=0
  wait "$1" 2>/dev/null || wd_rc=$?
}

# no_partial OUT — nothing of OUT's partial output is left: neither a run's
# own "OUT.partial.XXXXXX" dir (#398) nor the fixed "OUT.partial" of older
# versions.
no_partial() {
  [[ -z "$(find "$(dirname "$1")" -maxdepth 1 -name "$(basename "$1").partial*" 2>/dev/null)" ]]
}

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
# The path is quoted for the shell that evals the command (a TMPDIR with a
# space would split it otherwise; #330).
if run verify --in "$archive" --identity-command "$(printf 'cat %q' "$fixture_home/keys/id.txt")" >/dev/null 2>&1; then
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

# 4b. An identity command that fails, or prints nothing, is refused before
#     age runs (#330): the op seam's contract, not just age failing on an
#     empty key.
# The third prints a valid key and then fails, so dropping only the exit
# status check is caught too (Codex review, PR #352).
# "Before age runs" is checked on the age calls, not only on the messages
# (Codex review R2, PR #352): a refusal moved after `age -d` would print the
# same text. An age on the front of PATH records each call and runs the real
# one; the control run below proves the record works.
age_spy="$fixture_home/age-spy"
mkdir -p "$age_spy"
cat > "$age_spy/age" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$AGE_CALLS"
exec "$REAL_AGE" "$@"
SH
chmod +x "$age_spy/age"
# age_spy_run ARGS... — run private-backup with the age spy; sets
# age_spy_out, age_spy_rc and age_spy_calls (the number of age calls).
age_spy_run() {
  local calls="$fixture_home/age-calls"
  : > "$calls"
  age_spy_rc=0
  age_spy_out="$(HOME="$fixture_home" AGE_CALLS="$calls" REAL_AGE="$(command -v age)" \
    PATH="$age_spy:$fixture_home/fakebin:$PATH" "$PB" "$@" 2>&1)" || age_spy_rc=$?
  age_spy_calls="$(awk 'END { print NR }' "$calls")"
  return 0
}
age_spy_run verify --in "$archive" --identity "$fixture_home/keys/id.txt"
if [[ "$age_spy_rc" -eq 0 && "$age_spy_calls" -ge 1 ]]; then
  pass "the age spy records the calls of a good verify (control)"
else
  printf '%s\n' "$age_spy_out" >&2
  miss "the age spy recorded no call for a good verify (rc=$age_spy_rc, calls=$age_spy_calls)"
fi
for ic_case in "false" "printf ''" "$(printf 'cat %q; exit 3' "$fixture_home/keys/id.txt")"; do
  age_spy_run verify --in "$archive" --identity-command "$ic_case"
  ic_rc="$age_spy_rc"
  ic_out="$age_spy_out"
  if [[ "$ic_rc" -eq 1 && "$age_spy_calls" -eq 0 ]] && grep -Fxq "[fail] identity command produced no key; refusing" <<< "$ic_out" \
    && ! grep -Fq "could not decrypt archive" <<< "$ic_out" && ! grep -Fq "decrypted to 0700 temp" <<< "$ic_out"; then
    pass "verify refuses an identity command that yields no key (${ic_case%% *} ...)"
  else
    printf '%s\n' "$ic_out" >&2
    miss "verify must refuse an identity command that yields no key (${ic_case%% *} ..., rc=$ic_rc, age calls=$age_spy_calls)"
  fi
done

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
# write_manifest STAGE [PATH...] — write STAGE/manifest.json declaring each
# PATH under STAGE/files with its real sha256, size and mode, so a negative
# case adds only its own defect (yq -i on the result) whatever the umask.
# No PATH gives an empty files list (for cases rejected before extraction).
write_manifest() {
  local stage="$1" rel f sum size mode
  shift
  yq -n -o=json '{
    "schema_version": 1, "tool": "private-backup.sh", "tool_version": "1",
    "created_at": "2026-01-01T00:00:00Z", "entries": [], "files": []
  }' > "$stage/manifest.json"
  for rel in "$@"; do
    f="$stage/files/$rel"
    sum="$(shasum -a 256 < "$f" | awk '{print $1}')"
    size="$(wc -c < "$f" | tr -d ' ')"
    mode="$(file_mode "$f")"
    P="$rel" H="$sum" Z="$size" M="$mode" yq -i -p=json -o=json \
      '.files += [{"path": strenv(P), "mode": strenv(M), "size": (strenv(Z) | tonumber), "sha256": strenv(H)}]' \
      "$stage/manifest.json"
  done
}

# A trailing pipe is part of the path (#390), even when the truncated name
# also exists. Check the manifest, payload, verify and restore independently.
pipe_home="$fixture_home/pipe-home"
pipe_extract="$fixture_home/pipe-extract"
pipe_restore="$fixture_home/pipe-restore"
mkdir -p "$pipe_home/.config/dotfiles" "$pipe_extract" "$pipe_restore"
printf 'wanted content\n' > "$pipe_home/cfg|"
printf 'wrong content\n' > "$pipe_home/cfg"
printf 'backup_paths:\n  - { path: "cfg|", type: file, category: label }\n' \
  > "$pipe_home/.config/dotfiles/backup-paths.local"
if backup_in "$pipe_home" "$pipe_home/pipe.age" >/dev/null 2>&1; then
  extract_archive "$pipe_home/pipe.age" "$pipe_extract"
  pipe_sum="$(shasum -a 256 "$pipe_home/cfg|" | awk '{print $1}')"
  if SUM="$pipe_sum" yq -e -p=json '
    ([.entries[] | select(.path == "cfg|" and .type == "file" and .category == "label" and .origin == "local")] | length) == 1 and
    ([.files[] | select(.path == "cfg|" and .sha256 == strenv(SUM))] | length) == 1 and
    ([.files[] | select(.path == "cfg")] | length) == 0
  ' "$pipe_extract/manifest.json" >/dev/null \
    && cmp -s "$pipe_home/cfg|" "$pipe_extract/files/cfg|" \
    && [[ ! -e "$pipe_extract/files/cfg" ]]; then
    pass "backup preserves a trailing pipe in the manifest and payload"
  else
    miss "backup lost a trailing pipe or captured the truncated path"
  fi
  if run verify --in "$pipe_home/pipe.age" --identity "$fixture_home/keys/id.txt" >/dev/null 2>&1 \
    && run restore --in "$pipe_home/pipe.age" --identity "$fixture_home/keys/id.txt" \
      --target-home "$pipe_restore" --apply >/dev/null 2>&1 \
    && cmp -s "$pipe_home/cfg|" "$pipe_restore/cfg|" && [[ ! -e "$pipe_restore/cfg" ]]; then
    pass "verify and restore preserve a trailing pipe path"
  else
    miss "verify or restore failed to preserve a trailing pipe path"
  fi
else
  miss "backup with a trailing pipe path failed"
fi

# 6. A checksum mismatch (manifest sha does not match the file) is caught.
#    The manifest is written by hand, as before write_manifest: the file
#    also does not have the declared mode "600", and the checksum must be
#    the reason reported (a check that looked at the mode first would not
#    say so).
bad="$fixture_home/stage-badsum"
mkdir -p "$bad/files"
printf 'real content\n' > "$bad/files/.zshrc.local"
TS="2026-01-01T00:00:00Z" yq -n -o=json '{
  "schema_version": 1, "tool": "private-backup.sh", "tool_version": "1",
  "created_at": strenv(TS), "entries": [],
  "files": [{"path": ".zshrc.local", "mode": "600", "size": 13, "sha256": "0000000000000000000000000000000000000000000000000000000000000000"}]
}' > "$bad/manifest.json"
make_archive "$bad" "$fixture_home/out/badsum.age"
# Capture the status separately: each negative case must exit 1 as well as
# report the cause, so a diagnostic alone cannot hide a successful exit.
verify_rc=0
out="$(run verify --in "$fixture_home/out/badsum.age" --identity "$fixture_home/keys/id.txt" 2>&1)" || verify_rc=$?
if [[ "$verify_rc" -eq 1 ]] && grep -Fq "checksum mismatch" <<< "$out"; then
  pass "verify detects a checksum mismatch"
else
  miss "verify missed a checksum mismatch"
fi

# 7. An archive file not present in the manifest is caught (sprawl). The
#    declared file matches its entry, so no mismatch may be reported next to
#    the sprawl (a second defect in the fixture would hide behind it).
extra="$fixture_home/stage-extra"
mkdir -p "$extra/files"
printf 'x\n' > "$extra/files/declared"
printf 'y\n' > "$extra/files/sneaked-in"
write_manifest "$extra" declared
make_archive "$extra" "$fixture_home/out/extra.age"
verify_rc=0
out="$(run verify --in "$fixture_home/out/extra.age" --identity "$fixture_home/keys/id.txt" 2>&1)" || verify_rc=$?
if [[ "$verify_rc" -eq 1 ]] && grep -Fq "not in manifest" <<< "$out" && ! grep -Fq "mismatch:" <<< "$out"; then
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
verify_rc=0
out="$(run verify --in "$fixture_home/out/symlink.age" --identity "$fixture_home/keys/id.txt" 2>&1)" || verify_rc=$?
if [[ "$verify_rc" -eq 1 ]] && grep -Fq "symlink" <<< "$out" && grep -Fq "before extraction" <<< "$out"; then
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
write_manifest "$ddir"
make_archive "$ddir" "$fixture_home/out/disallowed.age"
verify_rc=0
out="$(run verify --in "$fixture_home/out/disallowed.age" --identity "$fixture_home/keys/id.txt" 2>&1)" || verify_rc=$?
if [[ "$verify_rc" -eq 1 ]] && grep -Fq "disallowed member name" <<< "$out"; then
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

# 8b4. The other member shapes the pre-extraction check must refuse (#330):
#      a plain hardlink (both tars list it as "h"), a name that climbs out
#      with "..", and an absolute name. Each is rejected before extraction
#      (nothing is extracted). bsdtar lists the two crafted names as written
#      (the ".." / "/" rules refuse them); GNU tar may strip their leading
#      part when listing, so the remainder is chosen to be no allowed
#      top-level name either, and the check accepts any pre-extraction
#      refusal. The two crafted names need python3 (tar normalizes them when
#      it writes).
# "Before extraction" is checked on what tar was asked to do, not only on the
# message (Codex review, PR #352): a regression that extracted first and
# validated afterwards would print the same refusal. A tar on the front of
# PATH records each call and runs the real one; no call may extract.
tar_spy="$fixture_home/tar-spy"
mkdir -p "$tar_spy"
cat > "$tar_spy/tar" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$TAR_CALLS"
exec "$REAL_TAR" "$@"
SH
chmod +x "$tar_spy/tar"
# spy_verify ARCHIVE — verify ARCHIVE with the spy; sets spy_out, spy_rc and
# spy_extracted (1 when some tar call extracted).
spy_verify() {
  local calls="$fixture_home/tar-calls"
  : > "$calls"
  spy_rc=0
  spy_out="$(HOME="$fixture_home" TAR_CALLS="$calls" REAL_TAR="$(command -v tar)" \
    PATH="$tar_spy:$fixture_home/fakebin:$PATH" "$PB" verify --in "$1" --identity "$fixture_home/keys/id.txt" 2>&1)" || spy_rc=$?
  spy_extracted=0
  grep -Eq '^-?x' "$calls" && spy_extracted=1
  [[ -s "$calls" ]] || spy_extracted=unknown
  return 0
}
hlink="$fixture_home/stage-plain-hardlink"
mkdir -p "$hlink/files"
printf 'x\n' > "$hlink/files/a"
ln "$hlink/files/a" "$hlink/files/b"
printf '{}\n' > "$hlink/manifest.json"
make_archive "$hlink" "$fixture_home/out/plain-hardlink.age"
spy_verify "$fixture_home/out/plain-hardlink.age"
hlink_rc="$spy_rc"
out="$spy_out"
if [[ "$hlink_rc" -ne 0 && "$spy_extracted" == 0 ]] \
  && grep -Fq "archive has a non-regular member (symlink/hardlink/special); rejected before extraction" <<< "$out" \
  && ! grep -Fq "members validated, extracted" <<< "$out"; then
  pass "verify rejects a plain hardlink member before extraction"
else
  printf '%s\n' "$out" >&2
  miss "verify did not reject a plain hardlink member before extraction (exit $hlink_rc, extracted=$spy_extracted)"
fi
if command -v python3 >/dev/null 2>&1; then
  for crafted in "./files/../escaped" "/escaped-absolute"; do
    crafted_tar="$fixture_home/out/crafted-name.tar"
    python3 - "$crafted_tar" "$crafted" <<'PY'
import io
import sys
import tarfile

out, name = sys.argv[1], sys.argv[2]
with tarfile.open(out, mode="w", format=tarfile.USTAR_FORMAT) as tf:
    ti = tarfile.TarInfo("./files")
    ti.type = tarfile.DIRTYPE
    ti.mode = 0o755
    tf.addfile(ti)
    for member, data in (("./manifest.json", b"{}\n"), (name, b"escaped\n")):
        ti = tarfile.TarInfo(member)
        ti.size = len(data)
        ti.mode = 0o644
        tf.addfile(ti, io.BytesIO(data))
PY
    age -r "$recipient" -o "$fixture_home/out/crafted-name.age" "$crafted_tar"
    spy_verify "$fixture_home/out/crafted-name.age"
    crafted_rc="$spy_rc"
    out="$spy_out"
    if [[ "$crafted_rc" -ne 0 && "$spy_extracted" == 0 ]] && grep -Fq "; rejected before extraction" <<< "$out" \
      && ! grep -Fq "members validated, extracted" <<< "$out"; then
      pass "verify rejects a member named $crafted before extraction"
    else
      printf '%s\n' "$out" >&2
      miss "verify did not reject a member named $crafted before extraction (exit $crafted_rc, extracted=$spy_extracted)"
    fi
  done
else
  warn "python3 not found; skipping the crafted traversal / absolute member cases"
fi

# 8c. A mode mismatch (manifest mode != extracted file mode) is caught.
mdir="$fixture_home/stage-mode"
mkdir -p "$mdir/files"
printf 'content\n' > "$mdir/files/.zshrc.local"
chmod 644 "$mdir/files/.zshrc.local"
write_manifest "$mdir" .zshrc.local
yq -i -p=json -o=json '.files[0].mode = "600"' "$mdir/manifest.json"
make_archive "$mdir" "$fixture_home/out/mode.age"
verify_rc=0
out="$(run verify --in "$fixture_home/out/mode.age" --identity "$fixture_home/keys/id.txt" 2>&1)" || verify_rc=$?
if [[ "$verify_rc" -eq 1 ]] && grep -Fq "mode mismatch" <<< "$out"; then
  pass "verify detects a mode mismatch"
else
  printf '%s\n' "$out" >&2
  miss "verify missed a mode mismatch"
fi

# 8d. A payload that decrypts but is not a valid tar fails closed (the
#     member listing must reject it before extraction, not swallow tar's
#     error).
printf 'this is not a tar archive\n' | age -r "$recipient" -o "$fixture_home/out/notar.age"
verify_rc=0
out="$(run verify --in "$fixture_home/out/notar.age" --identity "$fixture_home/keys/id.txt" 2>&1)" || verify_rc=$?
if [[ "$verify_rc" -eq 1 ]] && grep -Fq "could not list archive members" <<< "$out"; then
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

# 9b. environmentKind limits hold at run time, not only in validate-policy
#     (#357): in a repo copy where work sets allowSecretsAccess=true
#     (set_capability_all; the work row forbids it), backup, verify and
#     restore refuse with the environmentKind refusal (exit 1) before
#     anything is read or written: no archive and the marker unchanged
#     (backup), the restore target still empty, and no age call (the spy's
#     record). The copy's validate-policy rejecting the same data shows the
#     fixture is the forbidden combination.
ek_repo="$fixture_home/ek-repo"
ek_target="$fixture_home/ek-target"
mkdir -p "$ek_repo" "$ek_target"
copy_repo_fixture "$ek_repo"
set_capability_all "$ek_repo" allowSecretsAccess true
ek_refusal="[fail] machine profile 'work' sets allowSecretsAccess=true, which environmentKind work forbids; refusing private-backup. Run: ./scripts/validate-policy.sh work"
cp "$marker" "$fixture_home/ek-marker-before"
ek_vrc=0
ek_vout="$("$ek_repo/scripts/validate-policy.sh" work 2>&1)" || ek_vrc=$?
if [[ "$ek_vrc" -eq 1 ]] && grep -Fxq "[fail] environmentKind work forbids allowSecretsAccess=true (profile work)" <<< "$ek_vout"; then
  pass "fixture: validate-policy rejects work with allowSecretsAccess=true"
else
  printf '%s\n' "$ek_vout" >&2
  miss "fixture: validate-policy must reject work with allowSecretsAccess=true (rc=$ek_vrc)"
fi
# The copy's private-backup.sh, through the age spy (PB is set for the call).
PB="$ek_repo/scripts/private-backup.sh" age_spy_run backup --out "$fixture_home/out/ek.age" --recipient "$recipient" --yes
if [[ "$age_spy_rc" -eq 1 && "$age_spy_calls" -eq 0 && ! -e "$fixture_home/out/ek.age" ]] \
  && grep -Fxq "$ek_refusal" <<< "$age_spy_out" && cmp -s "$marker" "$fixture_home/ek-marker-before"; then
  pass "backup refuses a work profile with a forbidden allowSecretsAccess=true (no archive, marker unchanged)"
else
  printf '%s\n' "$age_spy_out" >&2
  miss "backup must refuse a profile that breaks its environmentKind (rc=$age_spy_rc, age calls=$age_spy_calls)"
fi
PB="$ek_repo/scripts/private-backup.sh" age_spy_run verify --in "$archive" --identity "$fixture_home/keys/id.txt"
if [[ "$age_spy_rc" -eq 1 && "$age_spy_calls" -eq 0 ]] && grep -Fxq "$ek_refusal" <<< "$age_spy_out"; then
  pass "verify refuses a work profile with a forbidden allowSecretsAccess=true before decrypting"
else
  printf '%s\n' "$age_spy_out" >&2
  miss "verify must refuse a profile that breaks its environmentKind before decrypting (rc=$age_spy_rc, age calls=$age_spy_calls)"
fi
PB="$ek_repo/scripts/private-backup.sh" age_spy_run restore --in "$archive" --identity "$fixture_home/keys/id.txt" \
  --target-home "$ek_target" --apply
if [[ "$age_spy_rc" -eq 1 && "$age_spy_calls" -eq 0 && -z "$(find "$ek_target" -mindepth 1 -print)" ]] \
  && grep -Fxq "$ek_refusal" <<< "$age_spy_out"; then
  pass "restore --apply refuses a work profile with a forbidden allowSecretsAccess=true and writes nothing"
else
  printf '%s\n' "$age_spy_out" >&2
  miss "restore must refuse a profile that breaks its environmentKind before writing (rc=$age_spy_rc, age calls=$age_spy_calls)"
fi
set_profile personal

# 10. Defence in depth: an unsafe path in the (unvalidated) local
#     supplement is skipped, not captured.
supp_home="$fixture_home/supp"
seed_home "$supp_home"
mkdir -p "$supp_home/.config/dotfiles"
printf 'backup_paths:\n  - { path: "../escape", type: file }\n' \
  > "$supp_home/.config/dotfiles/backup-paths.local"
supp_out="$(backup_in "$supp_home" "$supp_home/s.age" 2>&1)" || true
if grep -Fq "skip unsafe path" <<< "$supp_out" && [[ -f "$supp_home/s.age" ]]; then
  pass "unsafe supplement path is skipped, baseline still captured"
else
  printf '%s\n' "$supp_out" >&2
  miss "unsafe supplement path was not skipped as expected"
fi

# 11. The recipient sources (#330): the default recipient file (the path the
#     docs recommend) and --recipients-file each produce an archive the
#     matching identity verifies; no recipient at all (never a silent
#     plaintext), a missing --recipients-file, and both flags at once are
#     usage errors (exit 2) that write nothing.
rcpt_home="$fixture_home/rcpt"
seed_home "$rcpt_home"
mkdir -p "$rcpt_home/.config/dotfiles" "$rcpt_home/out"
printf '%s\n' "$recipient" > "$rcpt_home/recipients.txt"
printf '%s\n' "$recipient" > "$rcpt_home/.config/dotfiles/private-backup.recipient"
if run_in "$rcpt_home" backup --out "$rcpt_home/out/default.age" --yes >/dev/null 2>&1 \
  && run_in "$rcpt_home" verify --in "$rcpt_home/out/default.age" --identity "$fixture_home/keys/id.txt" >/dev/null 2>&1; then
  pass "backup without a recipient flag encrypts to the default recipient file"
else
  miss "backup with only the default recipient file did not produce a verifiable archive"
fi
rm "$rcpt_home/.config/dotfiles/private-backup.recipient"
if run_in "$rcpt_home" backup --out "$rcpt_home/out/file.age" --recipients-file "$rcpt_home/recipients.txt" --yes >/dev/null 2>&1 \
  && run_in "$rcpt_home" verify --in "$rcpt_home/out/file.age" --identity "$fixture_home/keys/id.txt" >/dev/null 2>&1; then
  pass "backup --recipients-file encrypts to the listed recipient"
else
  miss "backup --recipients-file did not produce a verifiable archive"
fi
# The three usage errors run in fresh homes (no marker yet, no default
# recipient file), so "writes nothing" covers the archive, its .partial and
# the marker (Codex review, PR #351).
for rcpt_err in no-recipient missing-file both-flags; do
  rcpt_err_home="$fixture_home/rcpt-$rcpt_err"
  seed_home "$rcpt_err_home"
  rcpt_rc=0
  case "$rcpt_err" in
    no-recipient)
      rcpt_expect="[fail] no recipient: pass --recipient/--recipients-file or create $rcpt_err_home/.config/dotfiles/private-backup.recipient"
      rcpt_out="$(run_in "$rcpt_err_home" backup --out "$rcpt_err_home/x.age" --yes 2>&1)" || rcpt_rc=$?
      ;;
    missing-file)
      rcpt_expect="[fail] recipients file not found: $rcpt_err_home/no-such-file"
      rcpt_out="$(run_in "$rcpt_err_home" backup --out "$rcpt_err_home/x.age" \
        --recipients-file "$rcpt_err_home/no-such-file" --yes 2>&1)" || rcpt_rc=$?
      ;;
    both-flags)
      rcpt_expect="[fail] use only one of --recipient / --recipients-file"
      rcpt_out="$(run_in "$rcpt_err_home" backup --out "$rcpt_err_home/x.age" \
        --recipient "$recipient" --recipients-file "$rcpt_home/recipients.txt" --yes 2>&1)" || rcpt_rc=$?
      ;;
  esac
  if [[ "$rcpt_rc" -eq 2 ]] && grep -Fxq "$rcpt_expect" <<< "$rcpt_out" \
    && [[ ! -e "$rcpt_err_home/x.age" && ! -e "$rcpt_err_home/.local/state/dotfiles/private-backup.json" ]] \
    && no_partial "$rcpt_err_home/x.age"; then
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
# Nothing at all may appear under the target — no file, and no parent or
# backup directory either (#330: counting files alone let those through).
if grep -Fq "would create" <<< "$out" && [[ -z "$(find "$rdst" -mindepth 1 -print)" ]]; then
  pass "restore dry-run writes nothing"
else
  printf '%s\n' "$out" >&2
  miss "restore dry-run wrote files or did not plan"
fi

# 12b. A dry-run over existing, differing files plans the displacement but
#      makes no backup directory and changes nothing (#330): the target's
#      tree and contents are the same before and after.
rdisp="$fixture_home/restore-dry-displace"
mkdir -p "$rdisp/.ssh"
printf 'local edit\n' > "$rdisp/.zshrc.local"
printf 'local ssh\n' > "$rdisp/.ssh/config.local"
# The state is the path list plus a hash per file, so even a changed final
# newline shows (Codex review, PR #352).
tree_state() { (cd "$1" && find . -mindepth 1 -print | LC_ALL=C sort && find . -type f -exec shasum -a 256 {} + | LC_ALL=C sort); }
rdisp_before="$(tree_state "$rdisp")"
rdisp_rc=0
out="$(run restore --in "$archive" --identity "$fixture_home/keys/id.txt" --target-home "$rdisp" 2>&1)" || rdisp_rc=$?
if [[ "$rdisp_rc" -eq 0 ]] \
  && grep -Fxq "[info] - would overwrite (existing backed up first): .zshrc.local" <<< "$out" \
  && grep -Fxq "[info] - would overwrite (existing backed up first): .ssh/config.local" <<< "$out" \
  && [[ "$(tree_state "$rdisp")" == "$rdisp_before" ]]; then
  pass "restore dry-run over existing files changes nothing and makes no backup directory"
else
  printf '%s\n' "$out" >&2
  miss "restore dry-run over existing files changed the target"
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
write_manifest "$parent_stage" "$parent_path"
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

# 16a. The same refusal for a path whose first component starts with "-"
#      (#397). The parent check took the parent with dirname, which read such
#      a path as an option and failed with no output, so the check found no
#      parent to test and the write went through the symlink. The archive is
#      hand-crafted (anyone with the public key can make one). The control
#      restores the same archive without the symlink, so the case does not
#      pass by refusing every "-" path.
dash_stage="$fixture_home/stage-dash-parent"
dash_path="-cfg/config.local"
dash_archive="$fixture_home/out/dash-parent.age"
mkdir -p "$dash_stage/files/-cfg"
printf 'Host private\n' > "$dash_stage/files/$dash_path"
chmod 600 "$dash_stage/files/$dash_path"
write_manifest "$dash_stage" "$dash_path"
make_archive "$dash_stage" "$dash_archive"
dash_dst="$fixture_home/restore-dash-dst"
dash_escape="$fixture_home/dash-escape-target"
mkdir -p "$dash_dst" "$dash_escape"
ln -s "$dash_escape" "$dash_dst/-cfg"
dash_rc=0
out="$(run restore --in "$dash_archive" --identity "$fixture_home/keys/id.txt" --target-home "$dash_dst" --apply 2>&1)" || dash_rc=$?
if [[ "$dash_rc" -ne 0 ]] && grep -Fq "skip (symlinked parent in target path): $dash_path" <<< "$out" \
  && [[ -z "$(find "$dash_escape" -mindepth 1)" ]]; then
  pass "restore refuses a symlinked parent whose name starts with - (no escape)"
else
  printf '%s\n' "$out" >&2
  miss "restore wrote through a symlinked parent whose name starts with - (exit $dash_rc)"
fi
dash_plain="$fixture_home/restore-dash-plain"
mkdir -p "$dash_plain"
if out="$(run restore --in "$dash_archive" --identity "$fixture_home/keys/id.txt" --target-home "$dash_plain" --apply 2>&1)" \
  && cmp -s "$dash_stage/files/$dash_path" "$dash_plain/$dash_path"; then
  pass "restore writes a path whose first component starts with - when no symlink is in the way"
else
  printf '%s\n' "$out" >&2
  miss "restore failed to write a path whose first component starts with -"
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

# 17. restore --apply refuses an archive that fails verification (a checksum
#     mismatch): exit 1 with the refusal, and the target is left as it was.
r17_before="$(tree_state "$rdst")"
r17_rc=0
out="$(run restore --in "$fixture_home/out/badsum.age" --identity "$fixture_home/keys/id.txt" --target-home "$rdst" --apply 2>&1)" || r17_rc=$?
if [[ "$r17_rc" -eq 1 ]] && grep -Fxq "[fail] archive failed verification; refusing to restore" <<< "$out" \
  && [[ "$(tree_state "$rdst")" == "$r17_before" ]]; then
  pass "restore refuses an archive that fails verification"
else
  printf '%s\n' "$out" >&2
  miss "restore did not refuse a failed-verification archive, or changed the target (rc=$r17_rc)"
fi

# 18. Runtime gate: a denied profile refuses to restore.
set_profile work
if run restore --in "$archive" --identity "$fixture_home/keys/id.txt" --target-home "$rdst" --apply >/dev/null 2>&1; then
  miss "restore must refuse under a denied profile"
else
  pass "restore refuses under a denied profile (work)"
fi
# 18b. verify goes through the same gate (#330): it decrypts, so a denied
#      profile must not be able to read an archive either.
age_spy_run verify --in "$archive" --identity "$fixture_home/keys/id.txt"
verify_rc="$age_spy_rc"
out="$age_spy_out"
if [[ "$verify_rc" -ne 0 && "$age_spy_calls" -eq 0 ]] && grep -Fq "private-backup refuses to run here" <<< "$out" \
  && ! grep -Fq "decrypted to 0700 temp" <<< "$out"; then
  pass "verify refuses under a denied profile (work) before decrypting"
else
  printf '%s\n' "$out" >&2
  miss "verify must refuse under a denied profile (rc=$verify_rc, age calls=$age_spy_calls)"
fi
set_profile personal

# file_mode comes from lib-policy.sh (already sourced): the same helper
# private-backup.sh itself uses, which the test cannot source directly
# (running the script under test executes main).

# 19. A group-writable file (664) round-trips: capture, verify, and restore
#     keep the recorded mode. Regression for the umask bug: extraction
#     without -p turned 664 into 644 and the manifest mode check rejected
#     every archive containing such a file (issue #141). The case also guards
#     the cp -p of the staging and of restore.
gw_home="$fixture_home/gw"
seed_home "$gw_home"
chmod 664 "$gw_home/.zshrc.local"
# backup, verify and restore run under umask 022: losing a -p (tar -xpf in
# decrypt_and_extract, cp -p in stage_file and in restore) shows only when
# the umask masks group write. Under umask 002 a 664 file comes out 664
# even without -p, so the caller's umask must not decide the result.
gw_rc=0
(umask 022; backup_in "$gw_home" "$gw_home/gw.age") >/dev/null 2>&1 || gw_rc=$?
if [[ "$gw_rc" -eq 0 ]] \
  && (umask 022; run_in "$gw_home" verify --in "$gw_home/gw.age" --identity "$fixture_home/keys/id.txt") >/dev/null 2>&1; then
  gw_dst="$fixture_home/gw-restore"
  mkdir -p "$gw_dst"
  if (umask 022; run_in "$gw_home" restore --in "$gw_home/gw.age" --identity "$fixture_home/keys/id.txt" \
    --target-home "$gw_dst" --apply) >/dev/null 2>&1 \
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
seed_home "$ntty_home"
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
seed_home "$dup_home"
mkdir -p "$dup_home/.config/dotfiles" "$dup_home/nest"
printf 'c\n' > "$dup_home/nest/inner"
printf 'backup_paths:\n  - { path: "nest", type: dir }\n  - { path: "nest/inner", type: file }\n' \
  > "$dup_home/.config/dotfiles/backup-paths.local"
if backup_in "$dup_home" "$dup_home/d.age" >/dev/null 2>&1; then
  dup_extract="$fixture_home/dup-extract"
  mkdir -p "$dup_extract"
  extract_archive "$dup_home/d.age" "$dup_extract"
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
#     run mid-archive before). The capture is recorded INCOMPLETE (#398): a
#     file that exists but could not be read is real configuration missing
#     from the archive, unlike an absent optional file.
unr_home="$fixture_home/unr"
seed_home "$unr_home"
mkdir -p "$unr_home/.config/dotfiles" "$unr_home/box"
printf 'locked\n' > "$unr_home/locked"
chmod 000 "$unr_home/locked"
printf 'ok\n' > "$unr_home/box/readable"
printf 'locked\n' > "$unr_home/box/locked-in-dir"
chmod 000 "$unr_home/box/locked-in-dir"
printf 'backup_paths:\n  - { path: "locked", type: file }\n  - { path: "box", type: dir }\n' \
  > "$unr_home/.config/dotfiles/backup-paths.local"
# Mode 000 makes the files unreadable only where permissions bind (not as
# root): there the case would fail on a correct implementation, so it is
# skipped instead (#330; the same guard as test-doctor's OCP-i10).
if [[ ! -r "$unr_home/locked" && ! -r "$unr_home/box/locked-in-dir" ]]; then
  unr_rc=0
  unr_out="$(backup_in "$unr_home" "$unr_home/u.age" 2>&1)" || unr_rc=$?
  if [[ "$unr_rc" -eq 0 && -f "$unr_home/u.age" ]] \
    && grep -Fq "unreadable (skipped): locked" <<< "$unr_out" \
    && grep -Fq "skip unreadable file under box: box/locked-in-dir" <<< "$unr_out" \
    && grep -Fq "capture INCOMPLETE: 2 existing file(s) could not be read;" <<< "$unr_out" \
    && [[ "$(yq -p=json -o=tsv '.capture_incomplete' "$unr_home/.local/state/dotfiles/private-backup.json")" == "true" ]]; then
    pass "unreadable files (declared file and inside a dir) are skipped with a warning, backup still succeeds, and the marker records the capture incomplete"
  else
    printf '%s\n' "$unr_out" >&2
    miss "unreadable files should be skipped without aborting, got rc=$unr_rc"
  fi
else
  warn "mode 000 files are still readable here (root?); unreadable-file case skipped"
fi
chmod 600 "$unr_home/locked" "$unr_home/box/locked-in-dir" # so the EXIT trap can clean up

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
if backup_in "$alias_home" "$alias_home/a.age" >/dev/null 2>&1 \
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
  if backup_in "$alias_home" "$alias_home/odd.age" >/dev/null 2>&1 \
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
write_manifest "$case_stage" lower LOWER
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
extract_archive "$archive" "$manifest_base"
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
    && "$(cd "$manifest_dst" && find . -mindepth 1 -print)" == "./.zshrc.local" ]]; then
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
seed_home "$sup_home"
mkdir -p "$sup_home/.config/dotfiles" "$sup_home/private" "$sup_dst"
printf 'client secret\n' > "$sup_home/private/extra"
printf 'backup_paths:\n  - { path: "private/extra", type: file }\n' > "$sup_home/$sup_rel"
chmod 600 "$sup_home/$sup_rel"
sup_ok=1
backup_in "$sup_home" "$sup_home/s.age" >/dev/null 2>&1 || sup_ok=0
sup_out="$(run restore --in "$sup_home/s.age" --identity "$fixture_home/keys/id.txt" --target-home "$sup_dst" 2>&1)" || sup_ok=0
if [[ "$sup_ok" -eq 1 ]] && grep -Fq "would create: $sup_rel" <<< "$sup_out" && [[ -z "$(find "$sup_dst" -mindepth 1 -print)" ]]; then
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
if backup_in "$sup_dst" "$sup_dst/again.age" >/dev/null 2>&1; then
  extract_archive "$sup_dst/again.age" "$sup_extract"
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
seed_home "$cus_home"
mkdir -p "$cus_home/lists" "$cus_dst" "$cus_extract"
printf 'note\n' > "$cus_home/lists/note"
printf 'backup_paths:\n  - { path: "lists/note", type: file }\n' > "$cus_list"
if backup_in "$cus_home" "$cus_home/c.age" --local-supplement "$cus_list" >/dev/null 2>&1; then
  extract_archive "$cus_home/c.age" "$cus_extract"
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
seed_home "$ded_home"
mkdir -p "$ded_home/.config/dotfiles" "$ded_extract"
printf 'backup_paths:\n  - { path: "%s", type: file }\n' "$sup_rel" > "$ded_home/$sup_rel"
if backup_in "$ded_home" "$ded_home/d.age" >/dev/null 2>&1; then
  extract_archive "$ded_home/d.age" "$ded_extract"
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
extract_archive "$sup_home/s.age" "$tam_stage"
printf '  - { path: "injected", type: file }\n' >> "$tam_stage/files/$sup_rel"
make_archive "$tam_stage" "$fixture_home/out/tampered-supplement.age"
verify_rc=0
out="$(run verify --in "$fixture_home/out/tampered-supplement.age" --identity "$fixture_home/keys/id.txt" 2>&1)" || verify_rc=$?
if [[ "$verify_rc" -eq 1 ]] && grep -Fq "checksum mismatch: $sup_rel" <<< "$out"; then
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
  empty_out="$(backup_in "$empty_home" "$empty_home/e.age" 2>&1)" || empty_rc=$?
  if [[ "$empty_rc" -ne 0 ]] && grep -Fxq "[fail] no files captured; refusing to write an empty archive" <<< "$empty_out" \
    && [[ ! -e "$empty_home/e.age" && ! -e "$empty_home/.local/state/dotfiles/private-backup.json" ]] \
    && no_partial "$empty_home/e.age"; then
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
seed_home "$kind_home"
mkdir -p "$kind_home/.config/dotfiles" "$kind_home/outside-dir"
printf 'link target content\n' > "$kind_home/outside-file"
printf 'inside the linked dir\n' > "$kind_home/outside-dir/inner"
ln -s outside-file "$kind_home/link-file"
ln -s outside-dir "$kind_home/link-dir"
mkfifo "$kind_home/fifo"
printf 'plain file\n' > "$kind_home/not-a-dir"
printf 'backup_paths:\n  - { path: link-file, type: file }\n  - { path: link-dir, type: dir }\n  - { path: fifo, type: file }\n  - { path: not-a-dir, type: dir }\n' \
  > "$kind_home/.config/dotfiles/backup-paths.local"
# The backup runs under a deadline: a regression that reads the FIFO (no
# regular-file check) blocks for good on a FIFO with no writer and would
# never reach the assertions (Codex review, PR #351). Past the deadline the
# run and everything it started are killed and the case fails.
kind_log="$fixture_home/kind-backup.log"
# A TMPDIR of its own inside the fixture: a KILL skips backup's EXIT trap, and
# the staging it made would otherwise outlive the suite's cleanup (Codex
# review R3, PR #351).
kind_tmp="$fixture_home/kind-tmp"
mkdir -p "$kind_tmp"
TMPDIR="$kind_tmp" backup_in "$kind_home" "$kind_home/k.age" > "$kind_log" 2>&1 &
kind_pid=$!
wait_deadline "$kind_pid" 60
kind_timed_out="$wd_timed_out" kind_rc="$wd_rc"
kind_out="$(cat "$kind_log")"
kind_extract="$fixture_home/kind-extract"
mkdir -p "$kind_extract"
kind_files=""
if [[ "$kind_rc" -eq 0 && -f "$kind_home/k.age" ]]; then
  extract_archive "$kind_home/k.age" "$kind_extract"
  kind_files="$(yq -p=json -o=tsv '.files[].path' "$kind_extract/manifest.json")"
fi
if [[ "$kind_timed_out" -eq 0 && "$kind_rc" -eq 0 && -n "$kind_files" ]] \
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
  printf 'rc=%s timed_out=%s\n%s\nfiles:\n%s\n' "$kind_rc" "$kind_timed_out" "$kind_out" "$kind_files" >&2
  miss "a declared target of the wrong kind was captured or not warned about (or backup hung)"
fi

# 26. backup self-checks its staging with the verify/restore manifest test
#     before encrypting (issue #224): a good run reports it, and a staging
#     that no longer matches the manifest is refused before any output.
sc_home="$fixture_home/sc-home"
seed_home "$sc_home"
sc_out="$(backup_in "$sc_home" "$sc_home/ok.age" 2>&1)" || true
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
sc_out="$(REAL_CP="$real_cp" PATH="$sc_fakebin:$PATH" backup_in "$sc_home" "$sc_home/bad.age" 2>&1)" || sc_rc=$?
if [[ "$sc_rc" -ne 0 ]] && grep -Fq "checksum mismatch" <<< "$sc_out" \
  && grep -Fq "staging failed self-check; no archive written" <<< "$sc_out" \
  && [[ ! -e "$sc_home/bad.age" ]] && no_partial "$sc_home/bad.age" \
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
seed_home "$en_home"
mkdir -p "$en_home/.config/dotfiles" "$en_home/box/deep"
printf 'listed\n' > "$en_home/box/listed"
printf 'unlisted\n' > "$en_home/box/deep/unlisted"
printf 'backup_paths:\n  - { path: "box", type: dir }\n' > "$en_home/.config/dotfiles/backup-paths.local"
# Clean run first: the marker must say capture_incomplete=false. Its skipped
# count (absent optional baseline files) is the baseline for the partial run,
# which must report exactly one more: the directory whose enumeration failed.
en_clean_out="$(backup_in "$en_home" "$en_home/clean.age" 2>&1)" || true
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
en_out="$(REAL_FIND="$real_find" FAKE_FIND_DIR="$en_home/box" PATH="$en_fakebin:$PATH" \
  backup_in "$en_home" "$en_home/partial.age" 2>&1)" || en_rc=$?
en_extract="$fixture_home/en-extract"
mkdir -p "$en_extract"
if [[ "$en_rc" -eq 0 && -f "$en_home/partial.age" ]] \
  && grep -Fq "directory enumeration incomplete (find exit 1; entries under it could not all be listed): box" <<< "$en_out" \
  && grep -Fq "capture INCOMPLETE: enumeration failed for 1 declared director(y/ies)" <<< "$en_out" \
  && grep -Fxq "[warn] skipped entries: $((en_clean_skipped + 1))" <<< "$en_out" \
  && [[ "$(yq -p=json -o=tsv '.capture_incomplete' "$en_home/.local/state/dotfiles/private-backup.json")" == "true" ]]; then
  extract_archive "$en_home/partial.age" "$en_extract"
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

# 27b. Both causes in one run (#398 review): the fake find above fails the
#      directory, and a declared file is unreadable. The warning names both,
#      joined by "and", and the marker records the capture incomplete. Same
#      root guard as 22 (mode 000 does not bind for root).
en2_home="$fixture_home/en2-home"
mkdir -p "$en2_home/.config/dotfiles" "$en2_home/box"
printf 'a\n' > "$en2_home/.zshrc.local"
printf 'listed\n' > "$en2_home/box/listed"
printf 'locked\n' > "$en2_home/locked"
chmod 000 "$en2_home/locked"
printf 'backup_paths:\n  - { path: "box", type: dir }\n  - { path: "locked", type: file }\n' \
  > "$en2_home/.config/dotfiles/backup-paths.local"
if [[ ! -r "$en2_home/locked" ]]; then
  en2_rc=0
  en2_out="$(REAL_FIND="$real_find" FAKE_FIND_DIR="$en2_home/box" PATH="$en_fakebin:$PATH" \
    backup_in "$en2_home" "$en2_home/both.age" 2>&1)" || en2_rc=$?
  if [[ "$en2_rc" -eq 0 && -f "$en2_home/both.age" ]] \
    && grep -Fq "capture INCOMPLETE: enumeration failed for 1 declared director(y/ies) and 1 existing file(s) could not be read;" <<< "$en2_out" \
    && [[ "$(yq -p=json -o=tsv '.capture_incomplete' "$en2_home/.local/state/dotfiles/private-backup.json")" == "true" ]]; then
    pass "a failed enumeration and an unreadable file in one run are both named in the warning, and the marker records the capture incomplete"
  else
    printf '%s\n' "$en2_out" >&2
    miss "a failed enumeration and an unreadable file in one run were not both reported (rc=$en2_rc)"
  fi
else
  warn "mode 000 files are still readable here (root?); combined incomplete case skipped"
fi
chmod 600 "$en2_home/locked" # so the EXIT trap can clean up

# 27c. All three causes in one run (#414): the fake find above fails the
#      directory, a declared file is unreadable, and a declared file sits
#      under a directory without search permission. The warning names all
#      three, joined by "and"; 27b, 22 and 39 have one or two of the causes,
#      so the join before the third shows only here. Same root guard as 22
#      and 39 (mode bits do not bind for root).
en3_home="$fixture_home/en3-home"
mkdir -p "$en3_home/.config/dotfiles" "$en3_home/box" "$en3_home/shut"
printf 'a\n' > "$en3_home/.zshrc.local"
printf 'listed\n' > "$en3_home/box/listed"
printf 'locked\n' > "$en3_home/locked"
chmod 000 "$en3_home/locked"
printf 'config\n' > "$en3_home/shut/config"
chmod 600 "$en3_home/shut"
printf 'backup_paths:\n  - { path: "box", type: dir }\n  - { path: "locked", type: file }\n  - { path: "shut/config", type: file }\n' \
  > "$en3_home/.config/dotfiles/backup-paths.local"
if [[ ! -r "$en3_home/locked" && ! -e "$en3_home/shut/config" ]]; then
  en3_rc=0
  en3_out="$(REAL_FIND="$real_find" FAKE_FIND_DIR="$en3_home/box" PATH="$en_fakebin:$PATH" \
    backup_in "$en3_home" "$en3_home/all.age" 2>&1)" || en3_rc=$?
  if [[ "$en3_rc" -eq 0 && -f "$en3_home/all.age" ]] \
    && grep -Fq "capture INCOMPLETE: enumeration failed for 1 declared director(y/ies) and 1 existing file(s) could not be read and 1 declared path(s) could not be checked (a parent directory is not searchable);" <<< "$en3_out" \
    && [[ "$(yq -p=json -o=tsv '.capture_incomplete' "$en3_home/.local/state/dotfiles/private-backup.json")" == "true" ]]; then
    pass "a failed enumeration, an unreadable file and an unsearchable parent in one run are all named in the warning, and the marker records the capture incomplete"
  else
    printf '%s\n' "$en3_out" >&2
    miss "a failed enumeration, an unreadable file and an unsearchable parent in one run were not all reported (rc=$en3_rc)"
  fi
else
  warn "mode bits do not bind here (root?); three-cause incomplete case skipped"
fi
chmod 600 "$en3_home/locked" # so the EXIT trap can clean up
chmod 700 "$en3_home/shut"

# 28. The local supplement is user input: a structurally invalid entry must
#     not be dropped silently or mangled (issue #246). The shared parser
#     rejects the whole file before any row is used, so backup fails with the
#     message, writes no archive, no partial and no marker. Four shapes: an
#     entry without a path, a "|" in category (would shift fields into the
#     path), a newline inside a path (would split into two rows), and a
#     scalar in place of the list (`backup_paths: false`), which `// []`
#     would have read as "no entries", letting the baseline-only backup
#     succeed silently (Codex review, PR #254). A normal free label still
#     passes, and a "|" INSIDE a path stays allowed (the odd-filename
#     round-trip above already pins that).
# sv_case LABEL BODY — back up from a fresh home whose supplement is BODY.
sv_case() {
  local label="$1" body="$2" rc=0 out home
  home="$fixture_home/sv-$label"
  seed_home "$home"
  mkdir -p "$home/.config/dotfiles"
  printf '%s\n' "$body" > "$home/.config/dotfiles/backup-paths.local"
  out="$(backup_in "$home" "$home/s.age" 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 ]] && grep -Fq "backup-paths entry invalid in $home/.config/dotfiles/backup-paths.local" <<< "$out" \
    && [[ ! -e "$home/s.age" && ! -e "$home/.local/state/dotfiles/private-backup.json" ]] \
    && no_partial "$home/s.age"; then
    pass "invalid supplement ($label) is rejected before capture: no archive, no marker"
  else
    printf '%s\n' "$out" >&2
    miss "invalid supplement ($label) was accepted or mis-reported (rc=$rc)"
  fi
}
sv_case missing-path 'backup_paths:
  - { type: file, category: fixture }'
sv_case pipe-in-category 'backup_paths:
  - { path: only-in-supplement, type: file, category: "shell|override" }'
sv_case newline-in-path 'backup_paths:
  - { path: "one\nfile|other|two", type: file }'
sv_case scalar-list 'backup_paths: false'
# Control: a free-form label without the delimiter is fine and the declared
# file is captured under its own path.
sv_ok="$fixture_home/sv-ok"
seed_home "$sv_ok"
mkdir -p "$sv_ok/.config/dotfiles"
printf 'labelled\n' > "$sv_ok/only-in-supplement"
printf 'backup_paths:\n  - { path: only-in-supplement, type: file, category: "shell/override label" }\n' \
  > "$sv_ok/.config/dotfiles/backup-paths.local"
sv_extract="$fixture_home/sv-extract"
mkdir -p "$sv_extract"
if backup_in "$sv_ok" "$sv_ok/s.age" >/dev/null 2>&1; then
  extract_archive "$sv_ok/s.age" "$sv_extract"
  if [[ "$(yq -p=json -o=tsv '[.files[].path | select(. == "only-in-supplement")] | length' "$sv_extract/manifest.json")" == "1" ]] \
    && [[ "$(yq -p=json -o=tsv '.entries[] | select(.path == "only-in-supplement") | .category' "$sv_extract/manifest.json")" == "shell/override label" ]]; then
    pass "a free-form category label without | is accepted and recorded as declared"
  else
    miss "valid supplement label was not captured / recorded as declared"
  fi
else
  miss "backup with a valid free-form category label failed"
fi
# An unknown type (a misspelt `directory`) passes the shared parser, which
# only checks that a type is a plain string. It must be refused while the
# entries are collected, naming the file, the entry and the type, instead of
# stopping the backup at the self-check with "invalid manifest schema"
# (#330). No archive, no marker.
sv_type="$fixture_home/sv-unknown-type"
seed_home "$sv_type"
mkdir -p "$sv_type/.config/dotfiles" "$sv_type/.config/foo"
printf 'backup_paths:\n  - { path: .config/foo, type: directory }\n' > "$sv_type/.config/dotfiles/backup-paths.local"
sv_type_rc=0
sv_type_out="$(backup_in "$sv_type" "$sv_type/s.age" 2>&1)" || sv_type_rc=$?
if [[ "$sv_type_rc" -ne 0 ]] \
  && grep -Fxq "[fail] unknown backup path type in $sv_type/.config/dotfiles/backup-paths.local: .config/foo: directory (known: file, dir)" <<< "$sv_type_out" \
  && ! grep -Fq "invalid manifest schema" <<< "$sv_type_out" \
  && [[ ! -e "$sv_type/s.age" && ! -e "$sv_type/.local/state/dotfiles/private-backup.json" ]] \
  && no_partial "$sv_type/s.age"; then
  pass "an unknown supplement entry type is refused by name before capture: no archive, no marker"
else
  printf '%s\n' "$sv_type_out" >&2
  miss "an unknown supplement entry type was not refused by name (rc=$sv_type_rc)"
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
    out_log="$(REAL_MKTEMP="$real_mktemp" MKTEMP_CALLS="$out_home/mktemp-calls" PATH="$out_fakebin:$PATH" \
      backup_in "$out_home" "$out_path" 2>&1)" || out_rc=$?
    if [[ "$out_rc" -eq 2 ]] && grep -Fq '[fail]' <<< "$out_log" \
      && [[ ! -e "$out_home/mktemp-calls" ]] && no_partial "$out_path" \
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
race_log="$(REAL_MV="$real_mv" RACE_OUT="$race_home/backup.age" \
  REAL_MKTEMP="$real_mktemp" MKTEMP_CALLS="$race_home/mktemp-calls" PATH="$out_fakebin:$PATH" \
  backup_in "$race_home" "$race_home/backup.age" 2>&1)" || race_rc=$?
# mv itself succeeded: the file age wrote ("archive" in the run's partial
# dir since #398) landed inside the directory.
if [[ "$race_rc" -eq 1 && -f "$race_home/backup.age/archive" ]] \
  && grep -Fq '[fail]' <<< "$race_log" \
  && ! grep -Fq 'wrote encrypted archive:' <<< "$race_log" \
  && cmp -s "$marker" "$race_marker"; then
  pass "backup detects a directory appearing at mv time and preserves the marker"
else
  miss "backup reported success or changed the marker after mv into a directory (rc=$race_rc)"
fi

# 32. Every option that takes a value is a usage error (exit 2, with the
#     reason) when the value is missing (#330): `shift 2` past the end used
#     to end the run under set -e with no message at all.
for ov_case in "backup --out" "backup --recipient" "backup --recipients-file" "backup --local-supplement" \
  "verify --in" "verify --identity" "verify --identity-command" \
  "restore --in" "restore --identity" "restore --identity-command" "restore --target-home"; do
  ov_rc=0
  # shellcheck disable=SC2086 # split on purpose: subcommand and option
  ov_out="$(run $ov_case 2>&1)" || ov_rc=$?
  if [[ "$ov_rc" -eq 2 ]] && grep -Fxq "[fail] ${ov_case#* } needs a value" <<< "$ov_out"; then
    pass "$ov_case without a value is a usage error that names the option"
  else
    printf '%s\n' "$ov_out" >&2
    miss "$ov_case without a value must exit 2 and say so (rc=$ov_rc)"
  fi
done
# ...and the next option is not taken as the value: `--out --yes` used to
# write the archive to a file named "--yes" in the current directory (and
# drop the confirmation). Nothing may be written there, and the marker stays.
ov_cwd="$fixture_home/ov-cwd"
mkdir -p "$ov_cwd"
cp "$marker" "$fixture_home/ov-marker-before"
ov_rc=0
ov_out="$(cd "$ov_cwd" && run backup --out --yes --recipient "$recipient" 2>&1)" || ov_rc=$?
if [[ "$ov_rc" -eq 2 ]] && grep -Fxq "[fail] --out needs a value" <<< "$ov_out" \
  && [[ -z "$(find "$ov_cwd" -mindepth 1 -print)" ]] && cmp -s "$marker" "$fixture_home/ov-marker-before"; then
  pass "--out followed by another option is refused; nothing is written and the marker is unchanged"
else
  printf '%s\n' "$ov_out" >&2
  miss "--out --yes must be refused without writing anything (rc=$ov_rc)"
fi
# A value that starts with "-" is refused as well (rm / mv would read it as
# an option); such a path is written as ./-name.
ov_rc=0
ov_out="$(cd "$ov_cwd" && run backup --out -archive.age --recipient "$recipient" --yes 2>&1)" || ov_rc=$?
if [[ "$ov_rc" -eq 2 ]] && grep -Fxq "[fail] --out needs a value" <<< "$ov_out" \
  && [[ -z "$(find "$ov_cwd" -mindepth 1 -print)" ]]; then
  pass "a dash-led --out value is refused without writing anything"
else
  printf '%s\n' "$ov_out" >&2
  miss "a dash-led --out value must be refused (rc=$ov_rc)"
fi
# Written as ./-name, the same archive is accepted, and the marker records
# the name as "-archive.age": the form doctor reads back (#444; test-doctor
# pins that such a marker does not stop doctor).
dash_cwd="$fixture_home/dash-out-cwd"
mkdir -p "$dash_cwd"
dash_rc=0
dash_out="$(cd "$dash_cwd" && run backup --out ./-archive.age --recipient "$recipient" --yes 2>&1)" || dash_rc=$?
if [[ "$dash_rc" -eq 0 && -f "$dash_cwd/-archive.age" ]] \
  && [[ "$(yq -p=json -o=tsv '.archive' "$marker")" == "-archive.age" ]]; then
  pass "--out ./-archive.age writes the archive and the marker records -archive.age"
else
  printf '%s\n' "$dash_out" >&2
  miss "--out ./-archive.age must write the archive and record -archive.age in the marker (rc=$dash_rc)"
fi
# The other argument checks are usage errors too (exit 2, with the reason,
# #468): what each subcommand requires, an unknown argument, both identities
# at once, and a named archive, target home or identity file that is not
# there (decrypt_and_extract's documented 2, which verify and restore pass
# on). The restore runs carry --apply and a target that must stay empty, so
# a check that let the run through would write into it (a dry-run writes
# nothing either way). Labels are short; the argv holds fixture paths,
# passed whole (they may contain spaces, #330).
ue_dst="$fixture_home/ue-dst"
mkdir -p "$ue_dst"
ue_identity_command="$(printf 'cat %q' "$fixture_home/keys/id.txt")"
# ue_case LABEL EXPECT ARGS... — run ARGS; it must exit 2 and print
# "[fail] EXPECT" as a whole line, and nothing may appear under ue_dst
# (emptied again after each run, so one failure does not spill over).
ue_case() {
  local label="$1" expect="$2" ue_rc=0 ue_out
  shift 2
  ue_out="$(run "$@" 2>&1)" || ue_rc=$?
  if [[ "$ue_rc" -eq 2 ]] && grep -Fxq "[fail] $expect" <<< "$ue_out" \
    && [[ -z "$(find "$ue_dst" -mindepth 1 -print)" ]]; then
    pass "$label is a usage error (exit 2) that says why"
  else
    printf '%s\n' "$ue_out" >&2
    miss "$label must exit 2 with \"$expect\" and write nothing (rc=$ue_rc)"
  fi
  rm -rf "$ue_dst"
  mkdir "$ue_dst"
}
ue_case "backup without --out" "backup requires --out PATH" \
  backup --recipient "$recipient" --yes
ue_case "an unknown backup argument" "unknown backup argument: --bogus" \
  backup --out "$fixture_home/out/ue.age" --bogus --recipient "$recipient" --yes
ue_case "verify with both identities" "use only one of --identity / --identity-command" \
  verify --in "$archive" --identity "$fixture_home/keys/id.txt" --identity-command "$ue_identity_command"
ue_case "restore with both identities" "use only one of --identity / --identity-command" \
  restore --in "$archive" --identity "$fixture_home/keys/id.txt" --identity-command "$ue_identity_command" \
  --target-home "$ue_dst" --apply
ue_case "verify without an identity" "verify requires --identity PATH or --identity-command CMD" \
  verify --in "$archive"
ue_case "verify of a missing archive" "archive not found: $fixture_home/out/no-such.age" \
  verify --in "$fixture_home/out/no-such.age" --identity "$fixture_home/keys/id.txt"
ue_case "restore into a missing target home" "target home is not a directory: $fixture_home/no-such-home" \
  restore --in "$archive" --identity "$fixture_home/keys/id.txt" --target-home "$fixture_home/no-such-home" --apply
ue_case "verify with a missing identity file" "identity file not found: $fixture_home/keys/no-such.txt" \
  verify --in "$archive" --identity "$fixture_home/keys/no-such.txt"
ue_case "restore with a missing identity file" "identity file not found: $fixture_home/keys/no-such.txt" \
  restore --in "$archive" --identity "$fixture_home/keys/no-such.txt" --target-home "$ue_dst" --apply

# 33. A run interrupted after its plaintext exists leaves nothing in its
#     temp and ends by the signal (#358): backup (staging + self-check dir),
#     verify and restore (decrypted tar + extracted tree) each get SIGINT —
#     what Ctrl-C sends — and SIGTERM to their process group, in four runs:
#     once (one signal); twice (the second arriving while the cleanup is
#     already removing the temp); every (one more at every removal under
#     the temp, a held key); and rmfail (one signal, the first removal
#     under the temp failing without one). The second signal is what an
#     EXIT trap alone did not survive: it ended the script half-way through
#     that trap and the plaintext stayed (bash 3.2 and 5, INT and TERM
#     alike). With INT / TERM traps whose cleanup still let the signals
#     through (#358 review), the second killed the rm under way and
#     errexit ended backup by an exit, not the signal (bash 3.2), and the
#     every run kept the plaintext (bash 3.2 ended with it left; bash 5
#     re-ran the trap until the deadline); a removal that fails ends the
#     run the same way, by errexit before the signal is re-sent. After one
#     signal bash runs the EXIT trap before dying, so the once run cannot
#     tell an INT / TERM trap from none; it checks the other half of the
#     contract, which every run checks too: the script ends BY the signal
#     (the trap re-raises it after the cleanup), not with an `exit 130`.
#     bash's `wait` reports both as 130, so a python3 wrapper is the run's
#     parent and records how the child ended from waitpid's status (ended
#     by which signal, or exit with which code). Two more runs end normally
#     instead, for the cleanup's contract after a normal end (#358 review):
#     endsig (no signal at the manifest check, then one at every removal
#     under the temp, that is in the EXIT cleanup, a key held as the run
#     ends) and endrmfail (the first removal of that cleanup failing; no
#     signal, so it runs once, under INT). The signals are dropped and a
#     failed removal is only warned about: both end with the run's own
#     status (exit 0), endsig with nothing left, endrmfail with only the
#     temp whose removal failed (named in the warning) left and the
#     removals after it done. An EXIT trap that lets the signals through
#     ends endsig by the signal (the INT / TERM trap runs inside it; the
#     temp is still emptied), a failed removal left to errexit ends
#     endrmfail's backup by exit 1 with the self-check dir left, and a
#     cleanup that stops at the failure leaves that dir too (bash 3.2 and
#     5 alike); of the three, the interrupted runs catch only the errexit
#     one (rmfail's backup). Each run is a background job under `set -m`,
#     so it has a process group of its own to signal, like a foreground
#     job in a terminal (the wrapper ignores the two signals itself, being
#     in that group). The signals are sent from inside the run's own
#     tools, so there is no timing window (as
#     test-doctor's herdr `interrupt` fixture does): a fake yq, at the `-e`
#     manifest check on the temp (the first yq call once the plaintext is
#     complete), snapshots the temp and signals the group, handing its
#     process to `sleep` first so that what the signal kills is a child
#     doing the tool's work, as with the real tool; a fake rm, at the first
#     removal under the temp (the cleanup under way), leaves a marker
#     naming that removal and signals the group again, itself included (a
#     signal a process sends itself lands before kill returns, so there is
#     no wait and no delay), before it removes anything: an rm the signal
#     can kill dies there by it, as the real one would, and one that
#     ignores it (the cleanup ignores INT / TERM) goes on to remove. A
#     marker made beforehand turns that off (once), SIG_EVERY keeps it on
#     for every removal (every, endsig), and SIG_RM_FAIL makes that first
#     removal exit 1 instead (rmfail, endrmfail); SIG_NO_FIRST stops the
#     fake yq at its snapshot (the end runs). Every other call goes to the
#     real tool. A TMPDIR of its own per run, so a leftover shows and a
#     KILL at the deadline (kill_tree) cannot leak into the suite's temp.
#     backup's three list
#     files are made under that TMPDIR too (#372; case 34 pins how), so a
#     cleanup that forgot them shows as a leftover (Codex review R5): the
#     backup runs check that the three were in the temp at the manifest
#     check (the fake yq's snapshot). The
#     python3 wrapper starts the run with the default SIGINT
#     disposition, so the cases run even when the suite itself was started
#     as a background list of a non-interactive shell (`… &`), where SIGINT
#     is ignored at entry and bash cannot reset it. Without python3 the
#     cases are skipped with a warning; on CI (CI=true, set by GitHub
#     Actions) that is a failure instead, as without age (#330): a skip
#     there means the cases did not run, not that they passed.
if ! command -v python3 >/dev/null 2>&1; then
  if [[ "${CI:-}" == "true" ]]; then
    fail "python3 not found on CI; the interrupt cases must run there"
    status=1
  else
    warn "python3 not found; the interrupt cases are skipped"
  fi
else
  sig_home="$fixture_home/sig-home"
  seed_home "$sig_home"
  mkdir -p "$sig_home/target"
  sig_archive="$sig_home/sig.age"
  if ! backup_in "$sig_home" "$sig_archive" >/dev/null 2>&1; then
    miss "the backup the interrupt cases verify and restore could not be made"
  fi
  sig_fakebin="$fixture_home/sigfake"
  mkdir -p "$sig_fakebin"
  real_yq="$(command -v yq)"
  real_rm="$(command -v rm)"
  cat > "$sig_fakebin/yq" <<'SH'
#!/bin/sh
if [ "$1" = -e ]; then
  for arg; do
    case "$arg" in
      "$SIG_TMP"/*)
        find "$SIG_TMP" -type f > "$SIG_SNAPSHOT"
        if [ -z "$SIG_NO_FIRST" ]; then
          (sleep 0.2; kill -"$SIG_NAME" 0) &
          exec sleep 20
        fi
        break
        ;;
    esac
  done
fi
exec "$REAL_YQ" "$@"
SH
  cat > "$sig_fakebin/rm" <<'SH'
#!/bin/sh
if [ ! -e "$SIG_MARKER" ] || [ -n "$SIG_EVERY" ]; then
  for arg; do
    case "$arg" in
      "$SIG_TMP"/*)
        printf '%s\n' "$arg" > "$SIG_MARKER"
        [ -z "$SIG_RM_FAIL" ] || exit 1
        kill -"$SIG_NAME" 0
        break
        ;;
    esac
  done
fi
exec "$REAL_RM" "$@"
SH
  # ended.py ENDED_FILE CMD ARG... — run CMD as a child with the default
  # INT / TERM dispositions (ignoring both itself) and write how it ended
  # to ENDED_FILE: "signal N" or "exit N"; exit as a shell reports it.
  cat > "$sig_fakebin/ended.py" <<'PY'
import os
import signal
import sys

ended, cmd = sys.argv[1], sys.argv[2:]
signal.signal(signal.SIGINT, signal.SIG_IGN)
signal.signal(signal.SIGTERM, signal.SIG_IGN)
pid = os.fork()
if pid == 0:
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
    os.execvp(cmd[0], cmd)
_, st = os.waitpid(pid, 0)
with open(ended, "w") as f:
    if os.WIFSIGNALED(st):
        f.write("signal %d\n" % os.WTERMSIG(st))
        sys.exit(128 + os.WTERMSIG(st))
    f.write("exit %d\n" % os.WEXITSTATUS(st))
    sys.exit(os.WEXITSTATUS(st))
PY
  chmod +x "$sig_fakebin/yq" "$sig_fakebin/rm"
  for sig_name in INT TERM; do
    case "$sig_name" in
      INT) sig_num=2 ;;
      TERM) sig_num=15 ;;
    esac
    for sig_mode in once twice every rmfail endsig endrmfail; do
      # endrmfail sends no signal, so it runs once (under INT).
      [[ "$sig_mode" != endrmfail || "$sig_name" == INT ]] || continue
      for sig_cmd in backup verify restore; do
        case "$sig_cmd" in
          backup)
            sig_args=(backup --out "$sig_home/again.age" --recipient "$recipient" --yes)
            sig_section="self-check manifest" ;;
          verify)
            sig_args=(verify --in "$sig_archive" --identity "$fixture_home/keys/id.txt")
            sig_section="verify manifest" ;;
          restore)
            sig_args=(restore --in "$sig_archive" --identity "$fixture_home/keys/id.txt" --target-home "$sig_home/target")
            sig_section="verify before restore" ;;
        esac
        sig_run="$sig_name-$sig_mode-$sig_cmd"
        sig_tmp="$fixture_home/sig-tmp-$sig_run"
        mkdir -p "$sig_tmp"
        sig_log="$fixture_home/sig-$sig_run.log"
        sig_snapshot="$fixture_home/sig-$sig_run.snapshot"
        sig_marker="$fixture_home/sig-$sig_run.marker"
        sig_ended="$fixture_home/sig-$sig_run.ended"
        # The marker is what makes the fake rm pass its calls through: made
        # beforehand, no second signal is sent. SIG_EVERY overrides it: one
        # more signal at every removal under the temp. SIG_RM_FAIL turns the
        # first removal under the temp into a plain failure (exit 1, nothing
        # removed, no signal). SIG_NO_FIRST lets the run go past the manifest
        # check without a signal, to its normal end and its EXIT cleanup.
        sig_every="" sig_rm_fail="" sig_no_first=""
        case "$sig_mode" in
          once) : > "$sig_marker" ;;
          every) sig_every=1 ;;
          rmfail) sig_rm_fail=1 ;;
          endsig) sig_no_first=1 sig_every=1 ;;
          endrmfail) sig_no_first=1 sig_rm_fail=1 ;;
        esac
        set -m
        HOME="$sig_home" TMPDIR="$sig_tmp" SIG_TMP="$sig_tmp" SIG_SNAPSHOT="$sig_snapshot" SIG_MARKER="$sig_marker" \
          SIG_EVERY="$sig_every" SIG_RM_FAIL="$sig_rm_fail" SIG_NO_FIRST="$sig_no_first" SIG_NAME="$sig_name" \
          REAL_YQ="$real_yq" REAL_RM="$real_rm" \
          PATH="$sig_fakebin:$fixture_home/fakebin:$PATH" \
          python3 "$sig_fakebin/ended.py" "$sig_ended" "$PB" "${sig_args[@]}" > "$sig_log" 2>&1 < /dev/null &
        sig_pid=$!
        set +m
        wait_deadline "$sig_pid" 60
        sig_timed_out="$wd_timed_out" sig_rc="$wd_rc"
        sig_out="$(cat "$sig_log")"
        sig_had="$(cat "$sig_snapshot" 2>/dev/null || true)"
        sig_end="$(cat "$sig_ended" 2>/dev/null || true)"
        sig_left="$(find "$sig_tmp" -mindepth 1 2>/dev/null)"
        # backup's three list files sat directly in the temp at the manifest
        # check (made under TMPDIR, #372), so the leftover check covers them too.
        sig_lists=0 sig_lists_ok=1
        if [[ "$sig_cmd" == backup ]]; then
          while IFS= read -r sig_path; do
            [[ -z "$sig_path" || "${sig_path%/*}" != "$sig_tmp" ]] || sig_lists=$((sig_lists + 1))
          done <<< "$sig_had"
          [[ "$sig_lists" -eq 3 ]] || sig_lists_ok=0
        fi
        # Interrupted (128 + the signal) after the section that checks the
        # plaintext began, with the plaintext in the temp at the first
        # signal, nothing left afterwards, ended by that signal (not by an
        # exit), and, past the once run, the fake rm reached during the
        # cleanup; a failed removal is also named in a warning. The end runs
        # pass the same section with the plaintext in the temp, then end with
        # their own status (exit 0), the fake rm reached in the EXIT cleanup;
        # endrmfail leaves only the temp whose removal failed (the marker
        # names it), named in a warning, every other one removed.
        sig_shape_ok=0
        sig_want_rc=$((128 + sig_num)) sig_want_end="signal $sig_num"
        sig_ends="leaves nothing in its temp and ends by that signal"
        case "$sig_mode" in
          once)
            sig_shape="interrupted by SIG$sig_name after its plaintext existed"
            sig_shape_ok=1 ;;
          twice)
            sig_shape="interrupted twice by SIG$sig_name after its plaintext existed"
            [[ ! -e "$sig_marker" ]] || sig_shape_ok=1 ;;
          every)
            sig_shape="interrupted by SIG$sig_name after its plaintext existed and again at every removal"
            [[ ! -e "$sig_marker" ]] || sig_shape_ok=1 ;;
          rmfail)
            sig_shape="interrupted by SIG$sig_name after its plaintext existed, its first removal failing,"
            if [[ -e "$sig_marker" ]] && grep -Fq "could not remove the temp" <<< "$sig_out"; then
              sig_shape_ok=1
            fi ;;
          endsig)
            sig_shape="ending normally after its plaintext existed, with SIG$sig_name at every removal of its cleanup,"
            sig_want_rc=0 sig_want_end="exit 0"
            sig_ends="leaves nothing in its temp and ends with its own status"
            [[ ! -e "$sig_marker" ]] || sig_shape_ok=1 ;;
          endrmfail)
            sig_shape="ending normally after its plaintext existed, the first removal of its cleanup failing,"
            sig_want_rc=0 sig_want_end="exit 0"
            sig_ends="warns, removes the rest of its temp and ends with its own status"
            sig_failed="$(cat "$sig_marker" 2>/dev/null || true)"
            if [[ -n "$sig_failed" ]] && grep -Fxq "$sig_failed" <<< "$sig_left" \
              && grep -Fq "could not remove the temp $sig_failed" <<< "$sig_out"; then
              sig_shape_ok=1
              # What is left past the failed temp and its contents.
              sig_rest=""
              while IFS= read -r sig_path; do
                [[ -z "$sig_path" || "$sig_path" == "$sig_failed" || "$sig_path" == "$sig_failed"/* ]] \
                  || sig_rest+="$sig_path"$'\n'
              done <<< "$sig_left"
              sig_left="$sig_rest"
            fi ;;
        esac
        if [[ "$sig_timed_out" -eq 0 && "$sig_rc" -eq "$sig_want_rc" && "$sig_end" == "$sig_want_end" ]] \
          && [[ "$sig_shape_ok" -eq 1 && "$sig_lists_ok" -eq 1 && -z "$sig_left" ]] \
          && grep -Fq "private-backup: $sig_section" <<< "$sig_out" \
          && grep -Eq '/files/\.zshrc\.local$' <<< "$sig_had" && grep -Eq '/manifest\.json$' <<< "$sig_had"; then
          pass "$sig_cmd $sig_shape $sig_ends"
        else
          printf 'mode=%s rc=%s timed_out=%s ended=%s marker=%s lists_in_temp=%s\nin the temp at the first signal:\n%s\nleft:\n%s\n%s\n' \
            "$sig_mode" "$sig_rc" "$sig_timed_out" "${sig_end:-unknown}" "$([[ -e "$sig_marker" ]] && echo yes || echo no)" "$sig_lists" \
            "$sig_had" "$sig_left" "$sig_out" >&2
          miss "$sig_cmd $sig_shape: did not reach that point, left its temp behind, or did not end as expected (rc=$sig_rc, ended=${sig_end:-unknown})"
        fi
      done
    done
  done
fi

# 34. backup makes its TMPDIR temps from a template under TMPDIR (#372). BSD
#     mktemp (macOS) without a template ignores TMPDIR and puts the file in
#     the per-user temp dir, so the three list files left the TMPDIR a
#     caller (or a case above) chose, and a KILL left them there. GNU mktemp
#     (CI) honors TMPDIR either way, so where a file landed cannot tell the
#     two apart on every platform; a mktemp first on PATH records each
#     call's last argument instead, and every call must name a template
#     under the run's TMPDIR. The run must also leave that TMPDIR empty.
#     Five calls at least: the three list files, the staging and the
#     self-check dir. Two more hold none of the captured config in clear
#     (the encrypted archive and the marker record) and are made next to the
#     file they are renamed onto, so the rename stays in one file system
#     (#398): the partial-output dir next to --out and the marker temp next
#     to the marker. Those two are allowed by their exact template and must
#     be gone after the run.
tmpl_fakebin="$fixture_home/tmpl-fakebin"
tmpl_home="$fixture_home/tmpl-home"
tmpl_tmp="$fixture_home/tmpl-tmp"
mkdir -p "$tmpl_fakebin" "$tmpl_home" "$tmpl_tmp"
printf 'fixture\n' > "$tmpl_home/.zshrc.local"
cat > "$tmpl_fakebin/mktemp" <<'SH'
#!/bin/sh
last=""
for arg; do last="$arg"; done
printf '%s\n' "$last" >> "$MKTEMP_CALLS"
exec "$REAL_MKTEMP" "$@"
SH
chmod +x "$tmpl_fakebin/mktemp"
tmpl_rc=0
tmpl_out="$(TMPDIR="$tmpl_tmp" REAL_MKTEMP="$real_mktemp" MKTEMP_CALLS="$tmpl_home/mktemp-calls" PATH="$tmpl_fakebin:$PATH" \
  backup_in "$tmpl_home" "$tmpl_home/t.age" 2>&1)" || tmpl_rc=$?
tmpl_calls="$(cat "$tmpl_home/mktemp-calls" 2>/dev/null || true)"
tmpl_count=0 tmpl_bad=""
while IFS= read -r tmpl_call; do
  tmpl_count=$((tmpl_count + 1))
  case "$tmpl_call" in
    "$tmpl_tmp"/*) ;;
    "$tmpl_home/t.age.partial.XXXXXX" | "$tmpl_home/.local/state/dotfiles/private-backup.json.XXXXXX") ;;
    *) tmpl_bad+="${tmpl_call:-(no template)}"$'\n' ;;
  esac
done <<< "$tmpl_calls"
[[ -n "$tmpl_calls" ]] || tmpl_count=0
tmpl_left="$(find "$tmpl_tmp" -mindepth 1 2>/dev/null)"
tmpl_left+="$(find "$tmpl_home" "$tmpl_home/.local/state/dotfiles" -maxdepth 1 \
  \( -name 't.age.partial*' -o -name 'private-backup.json.*' \) 2>/dev/null)"
if [[ "$tmpl_rc" -eq 0 && -f "$tmpl_home/t.age" && "$tmpl_count" -ge 7 && -z "$tmpl_bad" && -z "$tmpl_left" ]]; then
  pass "backup makes its temps under TMPDIR or, for the two rename temps, next to their target, and leaves none behind"
else
  printf 'calls (last argument):\n%s\nneither under TMPDIR nor an allowed rename template:\n%s\nleft behind:\n%s\n%s\n' \
    "$tmpl_calls" "$tmpl_bad" "$tmpl_left" "$tmpl_out" >&2
  miss "backup made a temp outside its TMPDIR and the allowed rename templates, or left one behind (rc=$tmpl_rc, calls=$tmpl_count)"
fi

# 35. Each run writes into its own partial-output dir next to --out (#398).
#     The fixed "$out.partial" was shared by every run with the same --out,
#     so one run removed and re-created the file another run was still
#     encrypting into. A file at that fixed name (another run's, or one left
#     by an older version) must stay as it was, and the run must leave no
#     partial dir behind, when the write succeeds and when age fails (an
#     existing --out is then kept).
pd_home="$fixture_home/partial-dir-home"
mkdir -p "$pd_home"
printf 'fixture\n' > "$pd_home/.zshrc.local"
printf 'another run\n' > "$pd_home/c.age.partial"
pd_rc=0
pd_out="$(backup_in "$pd_home" "$pd_home/c.age" 2>&1)" || pd_rc=$?
pd_left="$(find "$pd_home" -maxdepth 1 -name 'c.age.partial.*' 2>/dev/null)"
if [[ "$pd_rc" -eq 0 && -z "$pd_left" && "$(cat "$pd_home/c.age.partial")" == "another run" ]] \
  && run verify --in "$pd_home/c.age" --identity "$fixture_home/keys/id.txt" >/dev/null 2>&1; then
  pass "backup leaves a file at the fixed .partial name alone and no partial dir behind"
else
  printf '%s\nleft: %s\n' "$pd_out" "$pd_left" >&2
  miss "backup touched the fixed .partial name or left a partial dir (rc=$pd_rc)"
fi
pd_fakebin="$fixture_home/partial-dir-fakebin"
mkdir -p "$pd_fakebin"
cat > "$pd_fakebin/age" <<'SH'
#!/bin/sh
# Fails after writing part of its output, like an age that dies mid-write.
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cat > /dev/null
[ -z "$out" ] || printf 'half-written\n' > "$out"
exit 1
SH
chmod +x "$pd_fakebin/age"
cp "$pd_home/c.age" "$fixture_home/partial-dir-before.age"
pd_rc=0
pd_out="$(PATH="$pd_fakebin:$PATH" backup_in "$pd_home" "$pd_home/c.age" 2>&1)" || pd_rc=$?
pd_left="$(find "$pd_home" -maxdepth 1 -name 'c.age.partial.*' 2>/dev/null)"
if [[ "$pd_rc" -ne 0 && -z "$pd_left" ]] && grep -Fq "failed to create encrypted archive" <<< "$pd_out" \
  && cmp -s "$fixture_home/partial-dir-before.age" "$pd_home/c.age"; then
  pass "a failed archive write removes its partial dir and keeps the existing --out"
else
  printf '%s\nleft: %s\n' "$pd_out" "$pd_left" >&2
  miss "a failed archive write left a partial dir or changed --out (rc=$pd_rc)"
fi

# 36. A failed marker write keeps the last good record and the previous
#     archive (#398). The record went straight into the marker by a
#     redirect, which truncated it before yq ran, and it was made only after
#     --out had been replaced. It is now written to a temp next to the marker
#     before the archive rename. A yq first on PATH fails only the marker's
#     yq -n call; the second run uses the same --out as the first, so a
#     replaced archive shows.
mk_home="$fixture_home/marker-keep-home"
mk_marker="$mk_home/.local/state/dotfiles/private-backup.json"
mk_fakebin="$fixture_home/marker-keep-fakebin"
mkdir -p "$mk_home" "$mk_fakebin"
printf 'fixture\n' > "$mk_home/.zshrc.local"
cat > "$mk_fakebin/yq" <<'SH'
#!/bin/sh
if [ "$1" = "-n" ] && [ -n "${SV:-}" ] && [ -n "${AB:-}" ]; then
  exit 1
fi
exec "$REAL_YQ" "$@"
SH
chmod +x "$mk_fakebin/yq"
mk_rc=0
backup_in "$mk_home" "$mk_home/first.age" >/dev/null 2>&1 || mk_rc=$?
cp "$mk_marker" "$fixture_home/marker-keep-before.json" 2>/dev/null || mk_rc=99
cp "$mk_home/first.age" "$fixture_home/marker-keep-before.age" 2>/dev/null || mk_rc=99
mk_out=""
if [[ "$mk_rc" -eq 0 ]]; then
  mk_out="$(REAL_YQ="$real_yq" PATH="$mk_fakebin:$PATH" backup_in "$mk_home" "$mk_home/first.age" 2>&1)" || mk_rc=$?
fi
mk_left="$(find "$mk_home/.local/state/dotfiles" -maxdepth 1 -name 'private-backup.json.*' 2>/dev/null)"
if [[ "$mk_rc" -ne 0 && "$mk_rc" -ne 99 && -z "$mk_left" ]] \
  && cmp -s "$fixture_home/marker-keep-before.json" "$mk_marker" \
  && cmp -s "$fixture_home/marker-keep-before.age" "$mk_home/first.age" \
  && no_partial "$mk_home/first.age" \
  && ! grep -Fq 'wrote encrypted archive:' <<< "$mk_out"; then
  pass "a failed marker write keeps the last good record and the previous archive, and leaves no temp"
else
  printf '%s\nleft: %s\n' "$mk_out" "$mk_left" >&2
  miss "a failed marker write lost the last record or the previous archive, or left a temp (rc=$mk_rc)"
fi

# 37. A marker path that is a directory is refused before --out is replaced
#     (#398 review): mv would move the record into the directory and report
#     success. The run fails, keeps --out, and leaves nothing in the
#     directory, no marker temp and no partial dir.
md_home="$fixture_home/marker-dir-home"
md_marker="$md_home/.local/state/dotfiles/private-backup.json"
mkdir -p "$md_marker"
printf 'fixture\n' > "$md_home/.zshrc.local"
printf 'previous archive\n' > "$md_home/keep.age"
md_rc=0
md_out="$(backup_in "$md_home" "$md_home/keep.age" 2>&1)" || md_rc=$?
md_left="$(find "$md_home/.local/state/dotfiles" -mindepth 1 ! -path "$md_marker" 2>/dev/null)"
if [[ "$md_rc" -ne 0 && -d "$md_marker" && -z "$(find "$md_marker" -mindepth 1)" && -z "$md_left" ]] \
  && grep -Fq "backup marker path is a directory" <<< "$md_out" \
  && ! grep -Fq 'updated marker:' <<< "$md_out" \
  && [[ "$(cat "$md_home/keep.age")" == "previous archive" ]] && no_partial "$md_home/keep.age"; then
  pass "a marker path that is a directory is refused before --out is replaced, leaving nothing behind"
else
  printf '%s\nleft: %s\n' "$md_out" "$md_left" >&2
  miss "a marker path that is a directory was not refused cleanly (rc=$md_rc)"
fi

# 38. Files under a directory whose name starts with "-" round-trip (#414):
#     stage_file cut the parent with dirname, which read "-cfg/..." as an
#     option and failed, so the cp after it stopped the whole backup. A
#     declared file and a file found under a declared directory, both below
#     such a name, are captured, verified and restored with content and mode.
ld_home="$fixture_home/leading-dash-home"
ld_dst="$fixture_home/leading-dash-dst"
mkdir -p "$ld_home/-cfg" "$ld_home/-box/-sub" "$ld_home/.config/dotfiles" "$ld_dst"
printf 'fixture\n' > "$ld_home/.zshrc.local"
printf 'Host dash\n' > "$ld_home/-cfg/config.local"
printf 'inner\n' > "$ld_home/-box/-sub/inner"
chmod 600 "$ld_home/-cfg/config.local" "$ld_home/-box/-sub/inner"
printf 'backup_paths:\n  - { path: "-cfg/config.local", type: file }\n  - { path: "-box", type: dir }\n' \
  > "$ld_home/.config/dotfiles/backup-paths.local"
ld_rc=0
ld_out="$(backup_in "$ld_home" "$ld_home/d.age" 2>&1)" || ld_rc=$?
if [[ "$ld_rc" -eq 0 ]] \
  && run verify --in "$ld_home/d.age" --identity "$fixture_home/keys/id.txt" >/dev/null 2>&1 \
  && run restore --in "$ld_home/d.age" --identity "$fixture_home/keys/id.txt" --target-home "$ld_dst" --apply >/dev/null 2>&1 \
  && cmp -s "$ld_home/-cfg/config.local" "$ld_dst/-cfg/config.local" \
  && cmp -s "$ld_home/-box/-sub/inner" "$ld_dst/-box/-sub/inner" \
  && [[ "$(file_mode "$ld_dst/-cfg/config.local")" == 600 && "$(file_mode "$ld_dst/-box/-sub/inner")" == 600 ]]; then
  pass "files under a directory whose name starts with - are backed up, verified and restored"
else
  printf '%s\n' "$ld_out" >&2
  miss "a file under a directory whose name starts with - did not round-trip (backup rc=$ld_rc)"
fi

# 39. A declared file under a directory without search permission is not an
#     absent file (#414): [[ -e ]] is false there even though it exists, and
#     backup skipped it as "declared but absent" with the capture complete.
#     It is now recorded incomplete, like an existing unreadable file, also
#     when the way there is a symlink to such a directory (Codex review R1,
#     PR #418). The control declares paths that really are absent: under a
#     searchable directory, under a missing directory, and under a dangling
#     symlink. They are ordinary skips, and the capture stays complete. The
#     run without search permission is skipped where permissions do not bind
#     (root), as in case 22.
ns_home="$fixture_home/unsearchable-home"
mkdir -p "$ns_home/locked-dir/sub" "$ns_home/open-dir" "$ns_home/.config/dotfiles"
printf 'fixture\n' > "$ns_home/.zshrc.local"
printf 'config\n' > "$ns_home/locked-dir/config"
printf 'config\n' > "$ns_home/locked-dir/sub/config"
ln -s locked-dir/sub "$ns_home/link-to-locked"
ln -s nowhere "$ns_home/dangling-link"
ns_marker="$ns_home/.local/state/dotfiles/private-backup.json"
printf 'backup_paths:\n  - { path: "open-dir/missing", type: file }\n  - { path: "no-dir/missing", type: file }\n  - { path: "dangling-link/config", type: file }\n' \
  > "$ns_home/.config/dotfiles/backup-paths.local"
ns_rc=0
ns_out="$(backup_in "$ns_home" "$ns_home/n.age" 2>&1)" || ns_rc=$?
if [[ "$ns_rc" -eq 0 ]] && grep -Fq "declared but absent (skipped): open-dir/missing" <<< "$ns_out" \
  && grep -Fq "declared but absent (skipped): no-dir/missing" <<< "$ns_out" \
  && grep -Fq "declared but absent (skipped): dangling-link/config" <<< "$ns_out" \
  && ! grep -Fq "capture INCOMPLETE" <<< "$ns_out" \
  && [[ "$(yq -p=json -o=tsv '.capture_incomplete' "$ns_marker")" == "false" ]]; then
  pass "control: declared paths that are absent (searchable parent, missing parent, dangling symlink) are ordinary skips (capture complete)"
else
  printf '%s\n' "$ns_out" >&2
  miss "control: a really absent path changed the capture to incomplete or failed the backup (rc=$ns_rc)"
fi
printf 'backup_paths:\n  - { path: "locked-dir/config", type: file }\n  - { path: "link-to-locked/config", type: file }\n' \
  > "$ns_home/.config/dotfiles/backup-paths.local"
chmod 600 "$ns_home/locked-dir"
if [[ ! -e "$ns_home/locked-dir/config" && ! -e "$ns_home/link-to-locked/config" ]]; then
  ns_rc=0
  ns_out="$(backup_in "$ns_home" "$ns_home/n.age" 2>&1)" || ns_rc=$?
  if [[ "$ns_rc" -eq 0 ]] \
    && grep -Fq "cannot tell whether it exists, a parent directory is not searchable (skipped): locked-dir/config" <<< "$ns_out" \
    && grep -Fq "cannot tell whether it exists, a parent directory is not searchable (skipped): link-to-locked/config" <<< "$ns_out" \
    && ! grep -Fq "declared but absent (skipped): locked-dir/config" <<< "$ns_out" \
    && ! grep -Fq "declared but absent (skipped): link-to-locked/config" <<< "$ns_out" \
    && grep -Fq "capture INCOMPLETE: 2 declared path(s) could not be checked (a parent directory is not searchable);" <<< "$ns_out" \
    && [[ "$(yq -p=json -o=tsv '.capture_incomplete' "$ns_marker")" == "true" ]]; then
    pass "declared files under a directory without search permission (directly and through a symlink) are recorded as incomplete, not absent"
  else
    printf '%s\n' "$ns_out" >&2
    miss "a declared file under a directory without search permission was taken as absent (rc=$ns_rc)"
  fi
else
  warn "a directory without search permission is still searchable here (root?); unsearchable-parent case skipped"
fi
chmod 700 "$ns_home/locked-dir" # so the EXIT trap can clean up

# 40. Failures after the archive rename (#414): the docs promise the new
#     archive with the previous marker and a non-zero exit, and no temp left
#     behind. Shims fail the removal of the run's partial dir, fail the
#     marker's rename, or turn the marker path into a directory right before
#     that rename (after the check up front; mv then moves the record into
#     it, and the check after the rename must catch that). Each run starts
#     from a home whose marker and --out come from a good first run, and has
#     a TMPDIR of its own that must be empty afterwards (the staging and the
#     self-check dir hold plaintext; Codex review R1, PR #418).
ar_fakebin="$fixture_home/after-rename-fakebin"
mkdir -p "$ar_fakebin"
real_rmdir="$(command -v rmdir)"
cat > "$ar_fakebin/mv" <<'SH'
#!/bin/sh
for last; do :; done
if [ "$last" = "$AR_MARKER" ]; then
  case "$AR_MODE" in
    marker-mv) exit 1 ;;
    marker-dir) rm -f "$AR_MARKER" && mkdir "$AR_MARKER" || exit 1 ;;
  esac
fi
exec "$REAL_MV" "$@"
SH
cat > "$ar_fakebin/rmdir" <<'SH'
#!/bin/sh
for last; do :; done
case "$AR_MODE:$last" in
  rmdir:*.partial.*) exit 1 ;;
esac
exec "$REAL_RMDIR" "$@"
SH
chmod +x "$ar_fakebin/mv" "$ar_fakebin/rmdir"
for ar_mode in rmdir marker-mv marker-dir; do
  ar_home="$fixture_home/after-rename-$ar_mode"
  ar_marker="$ar_home/.local/state/dotfiles/private-backup.json"
  mkdir -p "$ar_home"
  printf 'fixture\n' > "$ar_home/.zshrc.local"
  ar_rc=0
  backup_in "$ar_home" "$ar_home/a.age" >/dev/null 2>&1 || ar_rc=99
  cp "$ar_home/a.age" "$fixture_home/after-rename-$ar_mode-before.age" 2>/dev/null || ar_rc=99
  cp "$ar_marker" "$fixture_home/after-rename-$ar_mode-before.json" 2>/dev/null || ar_rc=99
  ar_out=""
  ar_tmp="$fixture_home/after-rename-$ar_mode-tmp"
  mkdir -p "$ar_tmp"
  if [[ "$ar_rc" -eq 0 ]]; then
    ar_out="$(TMPDIR="$ar_tmp" AR_MODE="$ar_mode" AR_MARKER="$ar_marker" REAL_MV="$real_mv" REAL_RMDIR="$real_rmdir" \
      PATH="$ar_fakebin:$PATH" backup_in "$ar_home" "$ar_home/a.age" 2>&1)" || ar_rc=$?
  fi
  ar_left="$(find "$ar_home/.local/state/dotfiles" -mindepth 1 ! -path "$ar_marker" 2>/dev/null)"
  ar_state="the new archive and the previous marker"
  if [[ "$ar_mode" == marker-dir ]]; then
    ar_state="the new archive and refuses the marker path that became a directory"
    ar_marker_ok=0
    [[ -d "$ar_marker" && -z "$(find "$ar_marker" -mindepth 1)" ]] \
      && grep -Fq "backup marker path is a directory" <<< "$ar_out" && ar_marker_ok=1
  else
    ar_marker_ok=0
    cmp -s "$fixture_home/after-rename-$ar_mode-before.json" "$ar_marker" && ar_marker_ok=1
  fi
  if [[ "$ar_rc" -ne 0 && "$ar_rc" -ne 99 && "$ar_marker_ok" -eq 1 && -z "$ar_left" ]] \
    && [[ -z "$(find "$ar_tmp" -mindepth 1)" ]] \
    && ! cmp -s "$fixture_home/after-rename-$ar_mode-before.age" "$ar_home/a.age" \
    && run verify --in "$ar_home/a.age" --identity "$fixture_home/keys/id.txt" >/dev/null 2>&1 \
    && no_partial "$ar_home/a.age" \
    && ! grep -Fq 'updated marker:' <<< "$ar_out"; then
    pass "a failure after the archive rename ($ar_mode) leaves $ar_state, exits non-zero and removes its temps (TMPDIR empty)"
  else
    printf '%s\nleft: %s\ntmp: %s\n' "$ar_out" "$ar_left" "$(find "$ar_tmp" -mindepth 1)" >&2
    miss "a failure after the archive rename ($ar_mode) broke the documented state or left a temp (rc=$ar_rc)"
  fi
done

# 41. A local supplement that cannot be checked, or that was named with
#     --local-supplement and is not there, stops the backup before anything
#     is written (#421). [[ -f ]] is false for a supplement under a directory
#     without search permission, and backup went on with "no local
#     supplement", so the private paths it lists were missing from an archive
#     recorded as complete; a mistyped --local-supplement did the same. A
#     symlink that leads to no regular file stops it too, and an inherited
#     CDPATH does not redirect the check of a relative path, nor does
#     "symlink/.." read as text (Codex review, PR #426). Every refusal is observed through a mktemp spy (no call: it
#     stops before the temps) and keeps the marker as it was. The controls
#     back up with the default supplement present, with it absent (the
#     normal state without one) and with an existing named one. The runs
#     without search permission are skipped where permissions do not bind
#     (root), as in case 22.
sx_home="$fixture_home/supplement-check-home"
sx_fakebin="$fixture_home/supplement-check-fakebin"
mkdir -p "$sx_home/.config/dotfiles" "$sx_home/lists" "$sx_home/decoy/lists" "$sx_fakebin" \
  "$sx_home/tree/child" "$sx_home/tree/private" "$sx_home/private"
printf 'fixture\n' > "$sx_home/.zshrc.local"
printf 'config\n' > "$sx_home/private.conf"
printf 'backup_paths:\n  - { path: "private.conf", type: file }\n' > "$sx_home/.config/dotfiles/backup-paths.local"
cp "$sx_home/.config/dotfiles/backup-paths.local" "$sx_home/lists/named.local"
cp "$sx_home/.config/dotfiles/backup-paths.local" "$sx_home/tree/private/list.local"
ln -s tree/child "$sx_home/link-to-child"
sx_default="$sx_home/.config/dotfiles/backup-paths.local"
sx_marker="$sx_home/.local/state/dotfiles/private-backup.json"
sx_real_mktemp="$(command -v mktemp)"
cat > "$sx_fakebin/mktemp" <<'SH'
#!/bin/sh
printf 'called\n' >> "$MKTEMP_CALLS"
exec "$REAL_MKTEMP" "$@"
SH
chmod +x "$sx_fakebin/mktemp"
# sx_backup NAME [ARG...] — back up from sx_home (also the working
# directory) to NAME.age with ARGs and CDPATH=$sx_cdpath (empty unless set);
# the mktemp spy records each call in NAME.mktemp. Sets sx_rc and sx_out,
# and sx_marker_before to the marker right before the run, so each case is
# judged on its own run, not on what an earlier one wrote.
sx_cdpath=""
sx_backup() {
  local name="$1"
  shift
  sx_marker_before="$(cat "$sx_marker" 2>/dev/null || true)"
  sx_rc=0
  sx_out="$(cd "$sx_home" && CDPATH="$sx_cdpath" REAL_MKTEMP="$sx_real_mktemp" \
    MKTEMP_CALLS="$sx_home/$name.mktemp" PATH="$sx_fakebin:$PATH" \
    backup_in "$sx_home" "$sx_home/$name.age" "$@" 2>&1)" || sx_rc=$?
}
# sx_captures_private NAME — the archive NAME.age carries private.conf, the
# file only the supplement declares.
sx_captures_private() {
  [[ "$(age -d -i "$fixture_home/keys/id.txt" "$sx_home/$1.age" 2>/dev/null | tar -xOf - ./manifest.json 2>/dev/null \
    | yq -p=json -o=tsv '[.files[].path | select(. == "private.conf")] | length' 2>/dev/null)" == "1" ]]
}
# sx_refused NAME RC MESSAGE — the last run exited RC with MESSAGE, made no
# temp (no mktemp call), wrote no archive and left the marker as it was.
sx_refused() {
  [[ "$sx_rc" -eq "$2" ]] && grep -Fq -- "$3" <<< "$sx_out" \
    && [[ ! -e "$sx_home/$1.mktemp" && ! -e "$sx_home/$1.age" ]] \
    && [[ -n "$sx_marker_before" && "$(cat "$sx_marker")" == "$sx_marker_before" ]] \
    && ! grep -Fq "no local supplement at" <<< "$sx_out"
}
sx_backup default
if [[ "$sx_rc" -eq 0 ]] && grep -Fq "local supplement present" <<< "$sx_out" && sx_captures_private default; then
  pass "control: the default local supplement is read and what it lists is captured"
else
  printf '%s\n' "$sx_out" >&2
  miss "control: the backup with the default local supplement failed or skipped it (rc=$sx_rc)"
fi
sx_backup named --local-supplement "$sx_home/lists/named.local"
if [[ "$sx_rc" -eq 0 ]] && sx_captures_private named; then
  pass "control: an existing --local-supplement is read"
else
  printf '%s\n' "$sx_out" >&2
  miss "control: the backup with an existing --local-supplement failed (rc=$sx_rc)"
fi
sx_backup missing --local-supplement "$sx_home/lists/mistyped.local"
if sx_refused missing 2 "local supplement not found or not a regular file: $sx_home/lists/mistyped.local"; then
  pass "a --local-supplement that is not there is a usage error (exit 2) before any temp, no archive, marker kept"
else
  printf '%s\n' "$sx_out" >&2
  miss "a missing --local-supplement did not stop the backup with exit 2 before its temps (rc=$sx_rc)"
fi
mv "$sx_default" "$sx_home/lists/default.local"
ln -s nowhere "$sx_home/dangling.local"
sx_backup absent
if [[ "$sx_rc" -eq 0 ]] && grep -Fq "no local supplement at $sx_default" <<< "$sx_out" \
  && [[ "$(yq -p=json -o=tsv '.capture_incomplete' "$sx_marker")" == "false" ]]; then
  pass "control: no supplement at the default location is the normal state (backup goes on, capture complete)"
else
  printf '%s\n' "$sx_out" >&2
  miss "control: an absent default local supplement failed the backup or marked it incomplete (rc=$sx_rc)"
fi
ln -s ../../dangling.local "$sx_default"
sx_backup dangling-default
if sx_refused dangling-default 1 "local supplement is a symlink that leads to no regular file (dangling, or through a directory without search permission): $sx_default"; then
  pass "a dangling symlink at the default supplement location stops the backup (exit 1) before any temp, no archive, marker kept"
else
  printf '%s\n' "$sx_out" >&2
  miss "a dangling symlink at the default supplement location was taken as no supplement (rc=$sx_rc)"
fi
rm -f "$sx_default"
ln -s ../../lists/named.local "$sx_default"
ln -s lists/named.local "$sx_home/link-to-locked.local"
mv "$sx_home/lists/default.local" "$sx_default.real"
chmod 600 "$sx_home/lists" "$sx_home/tree/private"
if [[ ! -e "$sx_home/lists/named.local" ]]; then
  sx_backup locked-link-default
  if sx_refused locked-link-default 1 "local supplement is a symlink that leads to no regular file (dangling, or through a directory without search permission): $sx_default"; then
    pass "a default supplement symlink into a directory without search permission stops the backup (exit 1) before any temp, no archive, marker kept"
  else
    printf '%s\n' "$sx_out" >&2
    miss "a default supplement symlink into a directory without search permission was taken as no supplement (rc=$sx_rc)"
  fi
  sx_backup locked-link-named --local-supplement "$sx_home/link-to-locked.local"
  if sx_refused locked-link-named 1 "local supplement is a symlink that leads to no regular file (dangling, or through a directory without search permission): $sx_home/link-to-locked.local"; then
    pass "a --local-supplement symlink into a directory without search permission stops the backup (exit 1) before any temp, no archive, marker kept"
  else
    printf '%s\n' "$sx_out" >&2
    miss "a --local-supplement symlink into a directory without search permission did not stop the backup with exit 1 (rc=$sx_rc)"
  fi
  sx_backup locked-named --local-supplement "$sx_home/lists/named.local"
  if sx_refused locked-named 1 "cannot tell whether the local supplement exists, a parent directory is not searchable: $sx_home/lists/named.local"; then
    pass "a --local-supplement under a directory without search permission stops the backup (exit 1) before any temp, no archive, marker kept"
  else
    printf '%s\n' "$sx_out" >&2
    miss "a --local-supplement under a directory without search permission did not stop the backup with exit 1 (rc=$sx_rc)"
  fi
  # Relative, with an inherited CDPATH whose same-named directory is
  # searchable: the check must look at ./lists, not at decoy/lists.
  sx_cdpath="$sx_home/decoy"
  sx_backup locked-relative --local-supplement lists/named.local
  sx_cdpath=""
  if sx_refused locked-relative 1 "cannot tell whether the local supplement exists, a parent directory is not searchable: lists/named.local"; then
    pass "a relative --local-supplement under a directory without search permission stops the backup (exit 1) despite a CDPATH with a searchable same-named directory"
  else
    printf '%s\n' "$sx_out" >&2
    miss "a relative --local-supplement was checked through CDPATH (rc=$sx_rc)"
  fi
  # "link-to-child/.." is tree/ for the kernel, so the file is
  # tree/private/list.local (not searchable); a logical cd would take the
  # text and check the searchable private/ instead (Codex review, PR #426).
  sx_backup locked-dotdot --local-supplement "$sx_home/link-to-child/../private/list.local"
  if sx_refused locked-dotdot 1 "cannot tell whether the local supplement exists, a parent directory is not searchable: $sx_home/link-to-child/../private/list.local"; then
    pass "a --local-supplement through a symlink and .. into a directory without search permission stops the backup (exit 1), the parent resolved as for the file"
  else
    printf '%s\n' "$sx_out" >&2
    miss "a --local-supplement through a symlink and .. had its parent resolved as text (rc=$sx_rc)"
  fi
  rm -f "$sx_default"
  mv "$sx_default.real" "$sx_default"
  chmod 600 "$sx_home/.config/dotfiles"
  sx_backup locked-default
  if sx_refused locked-default 1 "cannot tell whether the local supplement exists, a parent directory is not searchable: $sx_default"; then
    pass "a default local supplement under a directory without search permission stops the backup (exit 1) before any temp, no archive, marker kept"
  else
    printf '%s\n' "$sx_out" >&2
    miss "a default local supplement under a directory without search permission was taken as absent (rc=$sx_rc)"
  fi
else
  warn "a directory without search permission is still searchable here (root?); unsearchable-supplement cases skipped"
fi
chmod 700 "$sx_home/.config/dotfiles" "$sx_home/lists" "$sx_home/tree/private" # so the EXIT trap can clean up

if [[ "$status" -eq 0 ]]; then
  ok "private-backup tests passed"
fi
exit "$status"
