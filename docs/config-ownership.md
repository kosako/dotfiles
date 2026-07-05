# Config Ownership(設定管理の責務分担)

AI エージェント関連の設定は、管理系統が 2 つ(dotfiles = chezmoi、agent-tools =
build / sync)あり、さらにどちらにも属さない unmanaged なファイル(ユーザー手書き・
ローカル)が存在する。「どこを直すのが正本か」が構造化されていないと、hooks 登録の
ようにどちらの管轄でもなく宙に浮く事象が起きる(#137)。この doc は運用時に 1 枚で
引ける早見表とする。境界の詳細定義は
[ai-environment-boundary](ai-environment-boundary.md)。Issue #138。

## 責務分担表

| 資産 | 正本 | 配布 | 変更フロー |
| --- | --- | --- | --- |
| ハーネス環境設定 `~/.claude/settings.json`(model / permissions / hooks **登録** / plugin / statusLine / tui 等の global preference) | dotfiles(`dot_claude/settings.json.tmpl`) | `chezmoi apply` | dotfiles の Issue + PR |
| skill・指示文・hook スクリプト**実体**(`~/.claude/skills/`、`~/.claude/agent-tools/`、`~/.codex` への配布物) | agent-tools | agent-tools の build / sync | agent-tools の Issue + PR |
| 個人の参照先入りファイル(`~/.claude/CLAUDE.md`、各 repo の `.agent-context.local.md`) | ユーザー手書き | なし(unmanaged) | 手動のみ(agent は read-only) |
| マシン固有・動的値(`~/.claude/settings.local.json`、`~/.zshrc.local`、`~/.ssh/config.local` 等の `.local` 系、`~/.config/git/personal.gitconfig`) | ローカル(git / chezmoi 管理外) | なし(一部は暗号化バックアップ #60 が運ぶ) | 直接編集 |
| repo 固有の作業ルール(各 repo の `AGENTS.md`) | 各 repo | — | 各 repo の PR |

補足:

- **hooks は 2 管轄の合流点**(#137): settings.json への hooks **登録**は dotfiles、
  スクリプト**実体**の配備と path の安定は agent-tools。どちらか一方だけでは活性化
  しない。片方を変えるときはもう片方の Issue を確認する。
- `~/.claude/CLAUDE.md`(ユーザー手書き)から参照される `~/.claude/agent-tools/CLAUDE.md`
  は 2 行目の配布物。本体と参照先で正本が異なる。
- `settings.json` / `settings.local.json` の 2 層境界の正本は
  [claude-settings](claude-settings.md)。`.local` 系の勝ち方(local-wins /
  managed-wins)は [local-overrides](local-overrides.md)。

## どこを直すか(判定)

1. ハーネスの振る舞い(model / permission / hooks 登録 / sandbox / plugin /
   statusLine 等の global preference)を変えたい →
   dotfiles の template を変更して PR。live の `~/.claude/settings.json` を直接編集
   しない(managed-wins。`chezmoi apply` で戻る)。
2. skill / 指示文 / hook スクリプトの中身を変えたい → agent-tools。
3. 参照先・個人 context を変えたい → ユーザー手書きファイル(agent は書き換えず、
   必要なら更新をサジェストするに留める)。
4. マシン固有・一時的な調整をしたい → `.local` 系に直接書く。
5. この repo での作業ルールを変えたい → `AGENTS.md`(PR)。

## 管理に乗せてはいけないファイル

ここでの「管理」は chezmoi 管理(= public repo に source を置く)を指す。以下は
将来 module を広げるときも管理対象にしない:

- **認証・トークン類**: 各エージェントの credential / auth ファイル
  (例: `~/.codex/auth.json`。secret の SoR は 1Password、#78)、keychain / keyring が
  持つ値、ライセンストークン。
- **履歴・セッションデータ**: `~/.claude/` 配下の history / projects / sessions /
  shell-snapshots / cache 等、`~/.codex/` の sessions / log。機微(実行コマンド・
  local path・貼られた secret)を含みうるうえ、tool が所有して常時書き換えるため
  managed にすると恒常 drift になる(#93 と同じ構造)。
- **外部ナレッジツールの参照先を含む個人ファイル**: `~/.claude/CLAUDE.md`、
  `.agent-context.local.md`、agent memory。参照先を tracked file に入れない
  public-safety 規約([secrets](secrets.md)、AGENTS.md)による。

暗号化バックアップ(#60、[private-backup](private-backup.md))は別レイヤ: 上記の
うち「新マシンで再現したい、public repo に置けない private / local 設定」は
`.chezmoidata/backup-paths.yaml` で運べる(例: `.codex/config.toml`。アーカイブは
secret を含みうる前提で age 暗号化する)。ただし credential そのものは backup にも
入れない(SoR は 1Password。`auth.json` を意図的に除外している経緯は #78)。

## `.chezmoiignore` への先置きはしない(検討結果)

禁止ファイルの pattern を `.chezmoiignore` に先置きする案(#138)は**採用しない**:

- 本当の被害は「credential・参照先が public repo の履歴に入る」ことで、それは
  **commit 時**に発生する。`.chezmoiignore` が守れるのは apply 層(home への伝播)
  だけで、被害の起きる層を守らない。
- 防波堤は本 doc の明文リスト + PR での public-safety レビュー(人間の責務。
  [claude-settings](claude-settings.md) の規約と同じ)が担う。
- 実際に managed path に隣接して混入しやすい `~/.claude/settings.local.json` は
  既に個別に ignore 済み。それ以上の網羅列挙は実効の薄い宣言を増やすだけで、
  「決定済み不使用の dormant 配線は残さない」基準(#145、
  [policy-model](policy-model.md))とも整合しない。

関連: [ai-environment-boundary](ai-environment-boundary.md)(dotfiles / agent-tools の
境界定義)、[claude-settings](claude-settings.md)(settings.json の 2 層)、
[local-overrides](local-overrides.md)(`.local` の規約)、
[private-backup](private-backup.md)(暗号化バックアップ)、
[secrets](secrets.md)(secret の供給方式)。Issue #138。
