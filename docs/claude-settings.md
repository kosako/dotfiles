# Claude Code settings

Claude Code(`~/.claude/`)のハーネス設定の管理規約。dotfiles は **personal の
public-safe な `settings.json` だけ**を control plane として管理する。設計の正本と
論点は issue #75。

ハーネスの環境設定(model / permission / plugin / cost posture)を「どの環境で
どう振る舞わせるか」という環境ポリシーとして dotfiles に置く。これは skill が使う
tool-specific config template(agent-tools 側の責務)とは別物
([ai-environment-boundary](ai-environment-boundary.md))。

## 何を管理し、何を管理しないか

| 対象 | 置き場所 | 管理 |
| --- | --- | --- |
| personal・public-safe な `settings.json`(model / effort / public plugin / 通知 / statusLine / tui / workflow 警告抑止 等の global preference) | public repo(`dot_claude/settings.json.tmpl`) | ✅ chezmoi(**personal profile のみ**) |
| personal・機密(secret を含む設定など) | `~/.claude/settings.local.json` | ❌ 非コミット・管理外 |
| work / client の settings | 暗号化バックアップ(#60)か各マシン手設定 | ❌ public repo に生値を置かない |
| skill / instruction(`skills/`、`agent-tools/CLAUDE.md`) | agent-tools が配布 | ❌ 別 repo の責務 |

## なぜ profile で分けるか

差分の駆動因は **課金モデル**。personal はサブスクなので generous(model / effort を
目一杯)、work は従量課金なので conservative(控えめベース)。

cost posture のような抽象化・共通化はしない。差分が大きく共通化の旨味が薄いので、
profile ごとに独立した settings を持つ。今 dotfiles が管理するのは **personal のみ**で、
work / client は別系統(上表)。

## public-safety

- `settings.json` を public repo に載せるので、commit 前に secret / 社内 path /
  client 固有値が無いか**人間がレビュー**する(機械検査ではなく人間の責務)。
- machine 固有 path(`statusLine` の command 等)は template の
  `{{ .chezmoi.homeDir }}` で相対化し、絶対 path を source に焼かない。

## 2 層(`settings.json` / `settings.local.json`)

Claude Code は `settings.json`(共有)と `settings.local.json`(ローカル)の 2 ファイルを
持つ。dotfiles は **前者だけ**を管理し、後者は常に管理外(`.chezmoiignore` で明示)。

Claude Code は書き先を 2 つに分ける: **動的に承認した permission** は
`settings.local.json`(machine / context 固有・絶対 path を含むので非 public-safe)へ、
**global な preference**(`effortLevel` / `tui` / `skipWorkflowUsageWarning` / 通知 /
`remoteControlAtStartup` / plugin 有効化など)は **`settings.json` 本体**へ書く。
前者は管理外なので衝突しないが、後者は managed な `settings.json` を Claude が
書き換えるため、template に無いキーは `chezmoi apply` で消える(drift)。

**方針(issue #93, 案 a「取り込む」)**: Claude が `settings.json` に書く **安定・public-safe な
global preference は managed template に取り込む**。こうすると `chezmoi apply` がその
キーに対して no-op になり、live が drift しない & 新マシン bootstrap の baseline も忠実に
なる。permission 承認は引き続き `settings.local.json`(管理外)に任せる。`settings.json` と
`settings.local.json` の責務境界はこれで固定する。

この境界は **完全な drift ゼロを保証しない**(構造上の限界)。Claude が将来 *新しい* global
preference キーを `settings.json` に書くと、template に取り込むまでの間は一時的に
`chezmoi status` が `M` を出す。これは想定内で、対処は「その安定 public-safe キーを
template に追記して再 apply する(= 取り込みの継続運用)」。`settings.local.json` 行きの
permission 承認は対象外。

## gate の仕組み

`claude-settings` module(`.chezmoidata/modules.yaml`)が `.claude` /
`.claude/settings.json` を宣言し、`personal` profile にのみ登録する。`.chezmoiignore` の
module loop が、module を持たない profile(work-minimal / work-dev)では `.claude` を
**ディレクトリごと** ignore する。`scripts/test-render.sh` が profile 別の managed set で
この gate を回帰固定している。

## sandbox(`enforceAiSandbox`)

`settings.json` 内の Claude Code native sandbox ブロックは `enforceAiSandbox` capability で
gate する。true のときだけ `sandbox`(`enabled` / `failIfUnavailable: true` /
`allowUnsandboxedCommands: false` / `network.allowedDomains: []`)を出し、false(全 profile の
既定)では出さない。**effective なのは
`claude-settings` module が active な personal だけ**(他 profile で true にしても dangling。
`doctor` が報告)。射程(Bash tool の fs+network のみ・非TLS)・極性・既定の根拠は
[policy-model](policy-model.md)・[ai-environment-boundary](ai-environment-boundary.md)、
Issue #50。content の回帰は `scripts/test-claude-settings.sh`(cap=true で block が出る /
false で出ない)が固定する。

## 後日 / 対象外

- work / client の settings を新マシンで復元したいか次第で、**#60 暗号化バックアップ**に
  含めるか「管理しない(各マシン手設定)」かを決める。今回の personal 実装とは独立。
- doctor への settings presence/管理状態の report(任意・低優先)。

関連: [ai-environment-boundary](ai-environment-boundary.md)(責務境界)、
[local-overrides](local-overrides.md)(`.local` の扱い)、#60(暗号化バックアップ)、
#16(VS Code settings = 類似の tool 設定管理)。
