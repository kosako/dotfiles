# Local Overrides

managed な設定 file と、host 固有の local 上書きの境界規約。
Phase 7 以降の zsh(#15)、VS Code(#16)、SSH(#17)はこの規約に従って実装する。

## 共通原則

- local override file は chezmoi の管理対象にしない。repo にも commit しない。
- secret、会社・クライアント固有の値、host 固有の調整は local override file 側にのみ置く。
- managed file は local override file が存在しなくても壊れないように書く。
- doctor は local override file の存在を report-only で表示してよいが、中身は読まない。
- 命名は managed file に `.local` を付ける(`~/.zshrc.local`、`~/.ssh/config.local`)。
- local override file は git/chezmoi 管理外だが、再セットアップに備えた **暗号化バックアップ**の
  対象にできる(`docs/private-backup.md`、issue #60)。

## zsh: local-wins(末尾 source)

managed な `~/.zshrc` は末尾で local file を source する。

```sh
[ -f "$HOME/.zshrc.local" ] && source "$HOME/.zshrc.local"
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
    IdentityAgent "...op-agent.sock"
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
管理しない」で決着し、`enableVsCodeSettings` を全 profile で `false` にした。capability /
`vscode` module / doctor section / この節の配線は **dormant** に残す。

将来 VS Code を採用するときは、(1) settings template を足し、(2) `.chezmoidata/modules.yaml`
の `vscode` module に `paths`(管理する settings file)と `requires: { enableVsCodeSettings: true }`
を宣言し(`runtime` / `git-signing` module と同じ形)、(3) `enableVsCodeSettings` を反転する。
`.chezmoiignore` の module loop は module の `paths` / `requires` で管理対象を gate するため、
(2) を欠くと template を足しても ignore されたままになる。`enableVsCodeExtensions` は据え置き
=自動 install しない。

採用時の設計メモ: VS Code の settings は JSON 単一 file のため source / Include に相当する
仕組みがなく、managed file に一本化するか機械 merge を導入するかをその時点で決める。

## Claude Code settings: managed-wins(user 設定)

managed な `~/.claude/settings.json` は、dotfiles が書く key(model / plugin / sandbox 等)に
ついて **managed-wins**(source が正)。Claude が動的に足す permission や、`/sandbox` による
per-project の sandbox 調整は **project の `.claude/settings.local.json`**(chezmoi 管理外、
`.chezmoiignore` 済み)に書かれるため、managed な user 設定とは衝突しない。host 固有・機密の
settings は user 級 `~/.claude/settings.local.json`(管理外)に置く。`enforceAiSandbox` で出す
sandbox ブロックの射程は [ai-environment-boundary](ai-environment-boundary.md)、Issue #50。

## GitHub trust list(#119)

GitHub injection 防御(epic #119)の trust 基点の local 値は、managed file に焼かず
**`~/.config/dotfiles/github-trust.local`**(chezmoi 管理外・非コミット)に置く。trust の
基点は `is_self`(自分の login + numeric id)で、collaborator / bot は既定 untrusted(方針は
[ai-policy](ai-policy.md))。egress allowlist の local 値も同じ `~/.config/dotfiles/*.local`
規約に従う(具体ファイル名は egress を per-host 化する Phase 2 / 3 で pin する)。

- 共通原則どおり managed 側は trust list が無くても壊れないように書く(fail closed で
  「自分以外は untrusted」に倒す)。
- **`backup-paths.yaml`(category `ai-tools`)に載せ**、再セットアップに備えた **暗号化
  バックアップ**の対象にする(`docs/private-backup.md`、issue #60)。識別子(login / id)は
  public repo に入れないため、暗号化アーカイブが運ぶ。
- doctor は **存在のみ** contents-blind に report する(private-backup section が
  `baseline present/absent: .config/dotfiles/github-trust.local` として表示し、中身=login /
  id は読まない。injection-guard section にも置き場ポインタを出す)。

## agent-tools の checkout path(#73)

`dotfiles` の `doctor` は agent-tools の presence を既定 path `~/src/agent/agent-tools`
(directory convention)で探す。実体が非標準な checkout(例: `~/dev/agent-tools`)にある
ときは `AGENT_TOOLS` env で override する(override 機構は #71)。local path は managed file に
焼かず、非追跡の `~/.zshrc.local` に置く(zsh は末尾 source = local-wins。local path を
tracked file に入れない public-safety 規約に従う):

```sh
export AGENT_TOOLS="$HOME/dev/agent-tools"
```

- doctor は status 読み取り時に `status.sh --root "$AGENT_TOOLS"` と root を pin する。
  status.sh は既定で **cwd** を検査するため、pin しないと doctor を起動した cwd を誤検査して
  空の repo を偽報告する(#73)。
- 監視層自体を動かすかどうかの opt-in は `enableAgentToolsStatus`(profile capability、tracked)
  で、AGENT_TOOLS(checkout path の解決)とは別レイヤ。capability が off なら presence までで
  status は読まない。
- 共通原則どおり managed 側は AGENT_TOOLS 未設定でも壊れない(既定 path に fallback し、
  不在なら report-only の warn)。

## 決定記録

- 2026-06-13: 本規約を確定(中間レビュー 2026-06-12 の提案に基づく)。zsh = 末尾 source で
  local-wins、SSH = 末尾 Include で managed-wins。
