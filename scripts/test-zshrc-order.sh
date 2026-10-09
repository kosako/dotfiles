#!/usr/bin/env bash
set -euo pipefail

# dot_zshenv / dot_zshrc の PATH の順序と読込順の test (#333 F39)。managed file を
# そのまま、fixture の HOME・fake の mise・fixture の HOMEBREW_PREFIX を持つ隔離 zsh
# (`zsh -f`、`env -i`) で対話 login shell の起動順 (~/.zshenv → brew shellenv →
# ~/.zshrc) どおりに source し、各時点で `command -v claude` がどこに解決するかと、
# ~/.zshrc の source の順序を order log で確かめる。実 HOME・実 mise・実 brew・
# 実 ~/.zshrc.local には触れない。固定する契約:
#   - ~/.zshenv は ~/.local/bin を mise の shims より前に置く (非対話 shell でも
#     native の claude が shim より勝つ);
#   - ~/.zshrc は `mise activate` の後、~/.zshrc.local の前に ~/.local/bin を再前置する
#     (brew shellenv / mise activate が埋めた native の claude を対話 shell でも勝たせる);
#   - ~/.zshrc.local が PATH に足した entry はそれでも勝つ;
#   - ~/.zshrc.local は mise activate の後に読まれ、その後は widget を wrap する plugin
#     (autosuggestions → syntax-highlighting) だけが続く。
# fake の mise は「activate が PATH の先頭に dir を足す」形だけを模す (実 mise が
# precmd の hook で installs の bin を足す側は hermetic に再現できないので対象外)。
# dot_zprofile は /opt/homebrew の絶対 path を見るので source せず、driver が
# `brew shellenv` の PATH 前置だけを模す。`zsh -n` は構文しか見ないので、この種の
# 順序の退行は検出できない。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-policy.sh
source "$SCRIPT_DIR/lib-policy.sh"

zsh_bin="$(command -v zsh || true)"
[[ -n "$zsh_bin" ]] || { fail "zsh is required for the zshrc order tests"; exit 1; }

status=0
fixture="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-zshrc-order.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
home="$fixture/home"
brew="$fixture/brew"
mise_bin="$fixture/mise-runtime/bin"
local_bin="$fixture/local-bin"
out="$fixture/out"
mkdir -p "$home/.local/bin" "$home/.local/share/mise/shims" "$brew/bin" "$brew/sbin" \
  "$brew/share/zsh-autosuggestions" "$brew/share/zsh-syntax-highlighting" \
  "$mise_bin" "$local_bin" "$fixture/bin" "$out"

# どの claude が勝つかで PATH の順序を判定する: 候補になる dir すべてに同名の空 script を
# 置く。
for dir in "$home/.local/bin" "$home/.local/share/mise/shims" "$brew/bin" "$mise_bin" "$local_bin"; do
  printf '#!/bin/sh\n' > "$dir/claude"
  chmod +x "$dir/claude"
done

# 隔離 zsh の PATH は fixture/bin だけ: fake の mise と、dot_zshrc の compinit が使う
# touch (dump の mtime 更新) / mv (compdump の書き込み) の symlink。
for tool in touch mv; do
  tool_path="$(command -v "$tool" || true)"
  [[ -n "$tool_path" ]] || { fail "required tool not found: $tool"; exit 1; }
  ln -s "$tool_path" "$fixture/bin/$tool"
done

# fake mise: activate の呼び出しを order log に残し、PATH の先頭に runtime の bin を足す
# export 文を出す (zsh 側の eval で展開される)。
cat > "$fixture/bin/mise" <<'SH'
#!/bin/sh
[ "$1" = activate ] || exit 1
printf 'mise\n' >> "$ZSHRC_TEST_OUT/order"
printf '%s\n' 'export PATH="$ZSHRC_TEST_MISE_BIN:$PATH"'
SH
chmod +x "$fixture/bin/mise"

# plugin は order log に印を書くだけの stub。
printf 'print -r -- autosuggestions >> "$ZSHRC_TEST_OUT/order"\n' \
  > "$brew/share/zsh-autosuggestions/zsh-autosuggestions.zsh"
printf 'print -r -- syntax-highlighting >> "$ZSHRC_TEST_OUT/order"\n' \
  > "$brew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"

# ~/.zshrc.local: 読まれた時点の claude の解決先を記録し、自分の PATH entry を前置する。
cat > "$home/.zshrc.local" <<'ZSH'
print -r -- local >> "$ZSHRC_TEST_OUT/order"
command -v claude > "$ZSHRC_TEST_OUT/claude-at-local"
export PATH="$ZSHRC_TEST_LOCAL_BIN:$PATH"
ZSH

# driver: 対話 login shell の起動順。値は環境変数で渡し、-c 文字列に path を埋めない。
cat > "$fixture/driver.zsh" <<'ZSH'
source "$ZSHRC_TEST_SOURCE/dot_zshenv"
print -r -- "$PATH" > "$ZSHRC_TEST_OUT/path-after-zshenv"
command -v claude > "$ZSHRC_TEST_OUT/claude-after-zshenv"
export PATH="$HOMEBREW_PREFIX/bin:$HOMEBREW_PREFIX/sbin:$PATH"
command -v claude > "$ZSHRC_TEST_OUT/claude-before-zshrc"
source "$ZSHRC_TEST_SOURCE/dot_zshrc"
command -v claude > "$ZSHRC_TEST_OUT/claude-after-zshrc"
print -r -- "$PATH" > "$ZSHRC_TEST_OUT/path-after-zshrc"
ZSH

if ! env -i PATH="$fixture/bin" HOME="$home" HOMEBREW_PREFIX="$brew" \
  ZSHRC_TEST_SOURCE="$DOTFILES_ROOT" ZSHRC_TEST_OUT="$out" \
  ZSHRC_TEST_MISE_BIN="$mise_bin" ZSHRC_TEST_LOCAL_BIN="$local_bin" \
  "$zsh_bin" -f "$fixture/driver.zsh" </dev/null >"$fixture/driver.log" 2>&1; then
  cat "$fixture/driver.log" >&2
  fail "the startup driver (zshenv -> brew shellenv -> zshrc) did not complete"
  exit 1
fi

# read_out NAME -> driver が書いた out/NAME の中身 (無ければ <missing>。判定は一致で
# 行うので、書かれなかった file は fail として見える)。
read_out() { cat "$out/$1" 2>/dev/null || printf '<missing>'; }

# 1. 非対話: ~/.zshenv だけで ~/.local/bin が shims より前。shims が PATH に無いと
#    「shims より前」が空振りで成立するので、先に shims が届いたことを確かめる。
path_after_zshenv="$(read_out path-after-zshenv)"
if [[ ":$path_after_zshenv:" != *":$home/.local/share/mise/shims:"* ]]; then
  fail "test failed: .zshenv did not put the mise shims on PATH (the ~/.local/bin ordering check would be vacuous)"
  status=1
elif [[ "$(read_out claude-after-zshenv)" == "$home/.local/bin/claude" ]]; then
  ok "test passed: .zshenv puts ~/.local/bin ahead of the mise shims"
else
  fail "test failed: .zshenv must put ~/.local/bin ahead of the mise shims (got $(read_out claude-after-zshenv))"
  status=1
fi

# 2. 対照: brew shellenv の前置で ~/.local/bin が埋もれている (fixture が埋もれを再現
#    していなければ、3. の再前置の検査は空振りになる)。
if [[ "$(read_out claude-before-zshrc)" == "$brew/bin/claude" ]]; then
  ok "test passed: brew shellenv buries ~/.local/bin before .zshrc runs (the fixture reproduces the burial)"
else
  fail "test failed: the fixture must bury ~/.local/bin under the brew bin before .zshrc runs (got $(read_out claude-before-zshrc))"
  status=1
fi

# 3. 対話: mise activate の後・~/.zshrc.local の前に ~/.local/bin が再前置されている。
#    fake mise の前置が PATH に届いていなければ、再前置の検査は空振りになる。
path_after_zshrc="$(read_out path-after-zshrc)"
if [[ ":$path_after_zshrc:" != *":$mise_bin:"* ]]; then
  fail "test failed: the fake mise activation did not reach PATH (the re-prepend check would be vacuous)"
  status=1
elif [[ "$(read_out claude-at-local)" == "$home/.local/bin/claude" ]]; then
  ok "test passed: .zshrc re-asserts ~/.local/bin ahead of mise and brew before ~/.zshrc.local runs"
else
  fail "test failed: ~/.local/bin must be ahead of mise and brew when ~/.zshrc.local runs (got $(read_out claude-at-local))"
  status=1
fi

# 4. ~/.zshrc.local が足した PATH entry はそれでも勝つ (再前置は local の override より前)。
if [[ "$(read_out claude-after-zshrc)" == "$local_bin/claude" ]]; then
  ok "test passed: a PATH entry from ~/.zshrc.local still wins"
else
  fail "test failed: a PATH entry from ~/.zshrc.local must win (got $(read_out claude-after-zshrc))"
  status=1
fi

# 5. 読込順: mise activate → ~/.zshrc.local → autosuggestions → syntax-highlighting (最後)。
want_order="$(printf '%s\n' mise local autosuggestions syntax-highlighting)"
if [[ "$(read_out order)" == "$want_order" ]]; then
  ok "test passed: ~/.zshrc.local is sourced after mise activate and only the widget-wrapping plugins follow, syntax-highlighting last"
else
  printf 'order:\n%s\n' "$(read_out order)" >&2
  fail "test failed: source order must be mise, local, autosuggestions, syntax-highlighting"
  status=1
fi

# 診断用: fail があったときだけ driver の出力 (stderr を含む) を見せる。空であることは
# assert しない (zsh の版による compinit の警告で壊れないように)。
if [[ "$status" -ne 0 && -s "$fixture/driver.log" ]]; then
  printf -- '--- driver log ---\n' >&2
  cat "$fixture/driver.log" >&2
fi

if [[ "$status" -eq 0 ]]; then
  ok "zshrc order tests passed"
fi
exit "$status"
