# Local Overrides

managed な設定 file と、host 固有の local 上書きの境界規約。
zsh(#96 で実装・適用済み)と SSH(#17 で実装・適用済み)はこの規約に従って実装した。
VS Code は未使用のため管理しない(#16。将来採用する場合の手順は下記)。

## 共通原則

- local override file は chezmoi の管理対象にしない。repo にも commit しない。
- secret、会社・クライアント固有の値、host 固有の調整は local override file 側にのみ置く。
- managed file は local override file が存在しなくても壊れないように書く。
- doctor は local override file の存在を report-only で表示してよいが、中身は読まない。
- 命名は managed file に `.local` を付ける(`~/.zshrc.local`、`~/.zprofile.local`、`~/.ssh/config.local`)。
  対応する managed file を持たない local 値(trust list・clone context など)は
  `~/.config/dotfiles/<name>.local` に置く(下記)。
- local override file は git/chezmoi 管理外だが、再セットアップに備えた **暗号化バックアップ**の
  対象にできる(`docs/private-backup.md`、issue #60)。

## zsh: local-wins(末尾 source)

managed な `~/.zshrc` はほぼ末尾(widget を包む plugin の zsh-autosuggestions /
zsh-syntax-highlighting の直前)で local file を source する。`~/.zprofile` も末尾で
`~/.zprofile.local` を同じ形で source する。

```sh
[ -r "$HOME/.zshrc.local" ] && source "$HOME/.zshrc.local"
```

zsh は後に評価された設定が勝つため、末尾 source は **local-wins** になる。
shell 設定は利便性の調整が主目的で、host 側の事情(会社の PATH、ツールの hook)が
managed 側の既定値を上書きできる必要があるため、これを意図とする。

## SSH: managed-wins(末尾 Include)

managed な `~/.ssh/config` は末尾に local file を Include する。ただし `Host`/`Match`
ブロックの直後に置くとその section に閉じ込められるため、`Match all` で global に戻してから
Include する。

```text
Host github.com
    IdentityAgent ".../2BUA8C4S2C.com.1password/t/agent.sock"
Match all
Include config.local
```

ssh_config は **first-match-wins** のため、末尾 Include は managed 設定が優先される
**managed-wins** になる。SSH は安全境界(どの host にどの鍵・agent を使うか)であり、
local file が managed の安全設定を上書きできてはならないため、zsh とは逆の勝ち方を意図とする。
`Match all` が無いと Include が直前の Host ブロックに閉じ込められ、local の host が
github.com 接続時しか読まれない(#121)。

local 側は managed が定義していない Host を追加する用途に限る。実装・移行手順は
[ssh](ssh.md)(`ssh-1password` module、`enable1PasswordSSH` gate)。

## VS Code

VS Code は現在この環境で**未使用**(editor は別物)。よって #16 は「VS Code settings を
管理しない」で決着した。当初は capability / `vscode` module / doctor section を dormant で
残したが、**#145 で配線ごと削除**(「決定済み不使用の dormant 宣言は残さない」基準。
基準は [policy-model](policy-model.md) の「dormant capability の扱い(残す基準)」に明文化済み)。

将来 VS Code を採用するときは、git 履歴(#16 / #145)から配線を復元しつつ、
(1) `capabilities.schema.yaml` に `enableVsCodeSettings` を `type: boolean` と `implemented`
付きで再宣言(全 profile への記入と `implemented` の有無が validate で強制される)、
(2) settings template を足し、(3) `.chezmoidata/modules.yaml` に
`vscode` module を `paths` + `requires: { enableVsCodeSettings: true }` 付きで再宣言
(`runtime` / `git-signing` module と同じ形)、(4) doctor section を追加する
(AGENTS.md の「新しい capability は、最低限 `doctor` が読む section を同梱して導入する」規約)。
`.chezmoiignore` の module loop は module の `paths` / `requires` で管理対象を gate するため、
(3) を欠くと template を足しても ignore されたままになる。extensions の自動 install はしない。
テストと docs を含む全手順は [policy-model](policy-model.md) の「capability 追加チェックリスト」に従う。

採用時の設計メモ: VS Code の settings は JSON 単一 file のため source / Include に相当する
仕組みがなく、managed file に一本化するか機械 merge を導入するかをその時点で決める。

## Claude Code settings: managed-wins(user 設定)

managed な `~/.claude/settings.json` は、dotfiles が書く key(model / plugin / sandbox 等)に
ついて **managed-wins**(source が正)。Claude が動的に足す permission や、`/sandbox` による
per-project の sandbox 調整は **project の `.claude/settings.local.json`**(chezmoi 管理外。
`.chezmoiignore` は allowlist で宣言外を通さない、#207)に書かれるため、managed な user
設定とは衝突しない。

host 固有・機密の settings(env / permissions / model 等を、この machine の全 project に効かせたいもの)の
置き場所は、Claude Code が**実際に読む経路**から選ぶ(#245)。user 級の `~/.claude/settings.local.json` は
Claude Code の設定 scope に**存在せず自動では読まれない**(公式の scope は managed → `--settings` →
project local `.claude/settings.local.json` → project `.claude/settings.json` → user `~/.claude/settings.json`。
`settings.local.json` は project scope のみ)。かつてここで案内していたが、置いても効かない。

| 効かせたい範囲 | 経路 | 備考 |
| --- | --- | --- |
| project ごと | その repo の `.claude/settings.local.json` | Claude 自身も動的許可をここに書く(git 除外は自動)。chezmoi 管理外 |
| この machine の全 project(永続) | `CLAUDE_CONFIG_DIR` で config dir ごと別 path に切り替える | `settings.json` / session / plugin も丸ごと別 dir になる。**managed な `~/.claude/settings.json` は読まれなくなる**ので、secret floor の deny や hooks 登録も効かない(上書きではなく置き換え。使うなら別 dir 側に同等の設定を自分で置く)。`~/.zshrc.local` で export する |
| 1 session だけ | `claude --settings <file または JSON>` | managed より弱く project 設定より強い。永続しない |
| 個別の値 | 環境変数(`ANTHROPIC_MODEL` 等) | key ごとに対応が異なる(公式の env-vars 一覧を参照) |

managed template には private 値を入れず、`chezmoi apply` はこれらの経路に触れない(いずれも管理対象外の path)。
`enforceAiSandbox` で出す sandbox ブロックの射程は [ai-environment-boundary](ai-environment-boundary.md)、
Issue #50。

## GitHub trust list(#119)

GitHub injection 防御(epic #119)の trust 基点の local 値は、managed file に焼かず
**`~/.config/dotfiles/github-trust.local`**(chezmoi 管理外・非コミット)に置く。trust の
基点は `is_self`(自分の login + numeric id)で、collaborator / bot は既定 untrusted(方針は
[ai-policy](ai-policy.md))。egress allowlist の local 値も同じ `~/.config/dotfiles/*.local`
規約に従う(具体ファイル名は OS egress firewall を実装する #188(#131 から切り出し)で pin する)。

- 共通原則どおり managed 側は trust list が無くても壊れないように書く(fail closed で
  「自分以外は untrusted」に倒す)。
- **`backup-paths.yaml`(category `ai-tools`)に載せ**、再セットアップに備えた **暗号化
  バックアップ**の対象にする(`docs/private-backup.md`、issue #60)。識別子(login / id)は
  public repo に入れないため、暗号化アーカイブが運ぶ。
- doctor は **存在のみ** contents-blind に report する(private-backup section が
  `baseline present/absent: .config/dotfiles/github-trust.local` として表示し、中身=login /
  id は読まない。injection-guard section にも置き場ポインタを出す)。

## clone context mapping(#177)

`gclone`([directory-convention](directory-convention.md))の owner → context 対応の
local 値は、managed file に焼かず **`~/.config/dotfiles/clone-contexts.local`**
(chezmoi 管理外・非コミット)に置く。会社 org 名を public repo に入れないための seam。

- 行形式: `<owner> <context-path>`(例: `<会社org> work/<会社org>`)。`#` 行はコメント。
- 共通原則どおり managed 側はこの file が無くても壊れない(未マッチは対話確認 or
  fail-closed 中断に倒れる)。
- **`backup-paths.yaml`(category `git`)に載せ**、暗号化バックアップ(#60)の対象にする。

## agent-tools の checkout path(#73)

`dotfiles` の `doctor` は agent-tools の presence を既定 path `~/src/agent/agent-tools`
(directory convention)で探す。実体が directory convention 以外の場所に checkout されて
いるときは `AGENT_TOOLS` env で override する(override 機構は #71)。具体 path は managed
file に焼かず、非追跡の `~/.zshrc.local` に置く(zsh は末尾 source = local-wins。local path を
tracked file に入れない public-safety 規約に従う):

```sh
export AGENT_TOOLS="$HOME/path/to/agent-tools"
```

- doctor は status 読み取り時に `status.sh --root "$AGENT_TOOLS"` と root を pin する。
  #73 当時の status.sh は既定で **cwd** を検査し、pin しないと doctor を起動した cwd を誤検査して
  空の repo を偽報告した。agent-tools#305 以降の既定は script の属する repo(cwd 非依存)だが、
  検査対象を明示するため pin は続ける。
- 監視層自体を動かすかどうかの opt-in は `enableAgentToolsStatus`(profile capability、tracked)
  で、AGENT_TOOLS(checkout path の解決)とは別レイヤ。capability が off なら presence までで
  status は読まない。
- 共通原則どおり managed 側は AGENT_TOOLS 未設定でも壊れない(既定 path に fallback し、
  不在なら report-only の warn)。

## Git global ignore: managed-only(local 無し、#248)

managed な `~/.config/git/ignore`(`git-ignore` module。AI agent の local-only file `.agent-packets/` と
`**/.claude/settings.local.json` を全 repo から除外)には **local override file が無い**。git は global
excludes を **1 file しか読まない**(`core.excludesFile`、未設定なら XDG 既定の `~/.config/git/ignore`)ので、
zsh の末尾 source や SSH の末尾 Include に当たる合成の仕組みが git 側に存在しないため。

- host 固有の除外 pattern は **各 repo の `.git/info/exclude`** に置く(git / chezmoi 管理外)。
- managed 側は `core.excludesFile` を pin しない(明示値は host 自身の設定を黙って上書きする)。host が
  `core.excludesFile` を持つ環境では managed file が読まれないだけで壊れず、doctor がその状態を warn
  する。
- 共通原則どおり doctor / preflight は file の**存在と pattern 行**しか見ない(値を持つ file ではない)。
  詳細は [git-ignore](git-ignore.md)。

## 決定記録

- 2026-06-13: 本規約を確定(中間レビュー 2026-06-12 の提案に基づく)。zsh = 末尾 source で
  local-wins、SSH = 末尾 Include で managed-wins。
