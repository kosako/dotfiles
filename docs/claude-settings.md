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
| personal・public-safe な `settings.json`(model / effort / public plugin / 通知 / statusLine) | public repo(`dot_claude/settings.json.tmpl`) | ✅ chezmoi(**personal profile のみ**) |
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

Claude が動的に足す permission は `settings.local.json` に書かれるため `settings.json` は
安定し、chezmoi の「source が正」モデルと衝突しない。例外は plugin 有効化などで稀に
`settings.json` 自体が書き換わるケースで、その際は手で再 `chezmoi add` する。

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
