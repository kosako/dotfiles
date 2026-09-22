# Git global ignore(`git-ignore` module、#248)

AI agent の **local-only file** を、repo ごとの `.gitignore` に頼らず全 repository から除外するための
managed な global gitignore。agent-tools の packet 規約(`.agent-packets/<issue>.md`、agent-tools#253)が
「第一防衛は global gitignore(dotfiles 側で配る)、repo 側 `.gitignore` は fail-safe」と決めたのを
dotfiles 側で実装したもの。

## 何を除外するか

managed file `~/.config/git/ignore`(source: `private_dot_config/git/ignore`)が持つ pattern は 2 行だけ:

```text
.agent-packets/                    agent packet(Issue 単位の作業状態。private な path / 理由 / 残量を含む)
**/.claude/settings.local.json     Claude Code の project local settings(agent が動的許可を書く。深さ問わず)
```

- `.agent-context.local.md`(repo ごとの user 正本)は**入れない**。従来どおり各 repo の `.gitignore` の
  責務(#248 の受け入れ条件)。
- pattern の追加は `test-git-ignore.sh`(exact pin)と `doctor.sh`(pattern list)の両方を意図して
  更新する。

## 置き場所と core.excludesFile を pin しない理由

- git は global excludes を **1 file だけ**読む。`core.excludesFile` が未設定なら既定の
  `$XDG_CONFIG_HOME/git/ignore`(未設定なら `~/.config/git/ignore`)。managed file はこの**既定の
  場所**に置き、managed な `~/.gitconfig` には `core.excludesFile` を書かない。
- pin しないのは、明示値が host 自身の `core.excludesFile`(たとえば会社 Mac の unmanaged
  `~/.config/git/config` にある値)を**黙って上書き**するため。`~/.gitconfig` は `~/.config/git/config`
  より後に読まれて勝つので、書いた瞬間に host の global ignore が読まれなくなる。既定の場所に置く
  だけなら、host が `core.excludesFile` を持つ環境では managed file が「読まれない」だけで、host の
  設定は壊れない(その状態は doctor が warn する)。
- 1 file しか読まれないので **`.local` は無い**([local-overrides](local-overrides.md) の zsh / SSH と
  違い、managed + local を合成する仕組みが git 側に存在しない)。host 固有の除外 pattern は各 repo の
  `.git/info/exclude` に置く。

## profile

- **personal のみ列挙**。work は非列挙: work 機では agent-tools の packet を書く運用が無く、既存の
  `~/.config/git/ignore` を diff 無しで置換したくないため。採用するときは `preflight` で既存 file の
  有無を確認し、host 固有の pattern を `.git/info/exclude` へ移してから profile に module を列挙する。
- module 列挙だけで gate する(capability は無い。claude-settings / opencode-settings と同型)。
  managed-by header を持つので、profile 切替で非 active になった残置は doctor の managed-path orphan
  scan が拾う(ignore file の残置は無害で、apply でも消えない = `requires` 方式と同じ残置特性)。

## doctor / preflight

- `preflight`(apply 前): module active で `~/.config/git/ignore` が**既にある**と「apply が置換する。
  host 固有 pattern は `.git/info/exclude` へ」の warn(中身は読まない)。`core.excludesFile` が global /
  system のどちらかに設定されていれば「managed file は読まれない」の warn(値は出さない)、明示的に
  空なら「global excludes を読まない」の warn、config が読めなければその旨の warn。非 active profile
  では left-as-is の item。
- `doctor`(apply 後、Git section): managed file の presence、git が**実際に読む** excludes path が
  managed file と一致するか、2 つの pattern 行が残っているか(drift)。excludes path の解決は
  `lib-policy.sh` の `git_excludes_file_setting`(preflight と共有)で、git と同じく **global scope が
  system scope に勝ち**、`GIT_CONFIG_NOSYSTEM` が真なら system を飛ばす(`git config --system` 自体は
  この変数を見ないので自前で飛ばす。system だけに `core.excludesFile` がある host は `--global` だけの
  照会だと「有効」と誤報告される)。**明示的に空**の `core.excludesFile` は「未設定」ではなく「git は
  global excludes を 1 つも読まない」(実測: 既定の file があっても `.agent-packets/x.md` が
  `git status` に出る)ので、既定 path へ倒さず warn する。config が読めない(値なしの key 等)ときは
  「不明」の warn で ok にしない。欠けていれば apply 手順を action に出す。pattern は行の exact 一致で
  見る — `git check-ignore` は repository を要し、doctor は何も作らない。実挙動は test が pin する。

## 検証

`scripts/test-git-ignore.sh`: personal で apply される / work でされない、header と pattern の exact
pin、`enableGitSigning=false` でも残る(allowlist の祖先 dir は活性 module 全体から導出する、#207)、
そして **`.gitignore` を持たない throwaway repo** で `git status` が `.agent-packets/x.md` と
`.claude/settings.local.json`(深さ問わず)を出さず、`keep.md` と `.agent-context.local.md` は出すこと
(空 home の control run で全 file が出ることを先に確認し、`git check-ignore -v` で判定源が managed
file であることまで確認)。git は `git init` を含めて `env -i` の throwaway HOME + `GIT_CONFIG_NOSYSTEM`
+ 空の `--template` で動かし(host の `init.templateDir` が `info/exclude` を仕込めない)、実 home や
実 global / system config には触れない。doctor / preflight の case(`test-doctor.sh` / `test-preflight.sh`)
も同じく `env -i` で、system scope だけの設定は `GIT_CONFIG_SYSTEM` の fixture file で再現する。

## 関連

- agent-tools `docs/agent-packets.md`(packet 規約・public-safety gate が staged packet を止める
  best-effort guardrail)。
- [config-ownership](config-ownership.md)(責務分担表)、[local-overrides](local-overrides.md)
  (`.local` が無い理由)、[git-identity](git-identity.md)(`~/.config/git/` 配下の他 file)。
