# Update Policy

広範な自動 upgrade は避ける。

## Rules

- `brew upgrade` は自動実行しない。
- `mise upgrade` は自動実行しない。
- shell plugin update は自動実行しない。
- ツール本体の自己更新(起動時の自動 DL)に任せない。更新は catalog の source で明示的に行う(例: OpenCode は managed 設定で `autoupdate: false`)。例外は下記の claude-code。
- `doctor` は状態を報告するだけにする。
- 更新は明示コマンドとして実行する。

## 例外: claude-code(native installer の自己更新)

claude-code は catalog 外の native installer(`claude.ai/install.sh` → `~/.local/bin`)で
管理し、**バックグラウンドの自己更新を意図的に受け入れている**(#112)。npm 経由の
auto-update が hardened `~/.npmrc`(ignore-scripts=true)と両立しないための採用で、
「npm hardening を維持したまま自動更新も動く」ことを優先した唯一の例外。経緯と詳細は
[supply-chain-npm](supply-chain-npm.md)。

## 取得の方針(install で入る版)

install と update を分けても、install の時点で「どの版が入るか」は source ごとに違う。

### go_install

- `install-packages.sh` は `go install <pkg>@latest` で入れる(その時点の最新の release。tag が無ければ
  default branch の最新 commit)。既に入っている tool は skip するので、`@latest` が効くのは初回の install だけ。
- npm の `min-release-age`([supply-chain-npm](supply-chain-npm.md))に当たる**待ち期間は無い**。Go の既定の
  module proxy と checksum DB は、公開済みの版が後から差し替えられることは検出するが、公開直後の版を避けはしない。
- catalog(`.chezmoidata/packages.yaml`)の schema に版の field は無い。版の固定が要る tool が出たら、catalog に
  版を足す変更として Issue + PR で扱う。
- 更新は人が明示的に行う(`go install <pkg>@<版>`)。

### Claude Code の plugin marketplace

- 第三者の marketplace(managed な `~/.claude/settings.json` の `extraKnownMarketplaces`)は、source の `ref` を
  tag に固定し、`autoUpdate: false` を明示する。Claude Code の marketplace source は `ref`(branch か tag)を
  受け付けるが commit の sha は受け付けないので、固定は tag の単位まで(upstream が tag を付け替えれば、取り直した
  ときに追従する)。
- 第三者の marketplace の auto-update は Claude Code の既定でも off だが、`/plugin` の toggle で on にできる。
  settings の `autoUpdate` は toggle より優先され、toggle を操作すると managed な `settings.json` にも書かれる
  (drift として見える)。
- 更新は template の `ref` を新しい tag に変える PR で行う。apply 後、Claude Code が新しい ref から取り直す。
- 公式の marketplace(`claude-plugins-official`)は Claude Code の既定で auto-update が on。Anthropic 由来で、
  claude-code 本体の自己更新(上記の例外)と同じ扱いとし、固定しない。
- 固定と `autoUpdate: false` は `scripts/test-claude-settings.sh` が全 entry について確認する。

## GitHub Actions(CI)の更新

- CI(`.github/workflows/validate.yml`)の action は commit の SHA で固定し、同じ行の `# vX.Y.Z` に版を書く
  (Dependabot が SHA と一緒に書き換えるのは、同じ行のこの形のコメントだけ)。
- Dependabot の version updates(`.github/dependabot.yml`)が週 1 回、新しい版を PR で知らせる(#433)。minor と patch は
  1 本の PR にまとめ、major は個別の PR にする。security updates もまとめる。公開から 7 日未満の版は version updates に
  出さない(`cooldown`。npm の `min-release-age` と同じ待ち。security updates には効かない)。
- PR は自動では merge しない。人が release notes と差分を確かめてから merge する(Dependabot の PR は AI の trailer を
  持たないので、AI 同士の相互 review には回らない)。
- CI が版と sha256 を固定して取る binary(yq / age / chezmoi / codex。`validate.yml` の `env`)は Dependabot の対象外。
  更新は版と sha256 を変える PR で行う。

## Rationale

勝手に全体を最新版へ上げることは、再現性とサプライチェーン安全性の両方を弱める。

この repository では、install と update を分ける。

- install: 足りないものを入れる。
- update: 既存のものを新しい version に上げる。

update は自動 apply の対象にしない。
