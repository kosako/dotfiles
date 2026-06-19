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

managed な `~/.ssh/config` は末尾に local file を Include する。

```text
Include config.local
```

ssh_config は **first-match-wins** のため、末尾 Include は managed 設定が優先される
**managed-wins** になる。SSH は安全境界(どの host にどの鍵・agent を使うか)であり、
local file が managed の安全設定を上書きできてはならないため、zsh とは逆の勝ち方を意図とする。

local 側は managed が定義していない Host を追加する用途に限る。

## VS Code

VS Code の settings は JSON 単一 file のため source / Include に相当する仕組みがない。
扱い(managed file に一本化するか、機械 merge を導入するか)は #16 の実装時に決める。

## 決定記録

- 2026-06-13: 本規約を確定(中間レビュー 2026-06-12 の提案に基づく)。zsh = 末尾 source で
  local-wins、SSH = 末尾 Include で managed-wins。
