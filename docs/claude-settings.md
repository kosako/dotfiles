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
| personal・public-safe な `settings.json`(model / effort / public plugin(第三者の marketplace は tag に固定・`autoUpdate: false`。[update-policy](update-policy.md))/ 通知 / statusLine / tui / workflow 警告抑止 等の global preference) | public repo(`dot_claude/settings.json.tmpl`) | ✅ chezmoi(**personal profile のみ**) |
| permission ブロック(#119): secret floor の無条件 deny 30 件(`~/.ssh` 読取 / credential-store 読取(Codex・OpenCode の `auth.json` を含む・#234)/ env dump / gh secret 系 / gh token の表示と keychain の password の読み出し・dump・export(#315))、1Password の CLI 全体(`op *`)の無条件 ask(#315)、作業を捨てる git の無条件 ask と hook の skip・参照先 note への書き込みの無条件 deny(#304)、`gateGitHubMcp` の `mcp__github` deny(personal 既定 true で deny は計 35 件)、`allow: mcp__pencil`、`enforceAiSandbox` 連動の human-legit gate | 同上(template が capability で gate して出力) | ✅ chezmoi(内容の回帰は `test-claude-settings.sh` が exact-set で固定) |
| hooks **登録**(#137 / #199 / #225): `enableGitHubIsolatedReader` 連動で PreToolUse / matcher `Bash` に agent-tools 配布の `personal-safe-gh-hook` を絶対 path で 1 本登録(fail-open steering)。`enableQualityLoopHooks` 連動で PostToolUse / matcher `Edit\|Write` に `personal-fast-edit-check`、matcher なしの Stop に `personal-changed-scope-qa` を登録(品質ループ。repo 単位 opt-in の `~/.config/agent-tools/checks.local.json` が無ければ無言 no-op)。`enableHerdrIntegration` 連動で SessionStart / matcher `^(startup\|resume\|clear\|compact\|fork)$`(herdr 0.9.3 の integration v10 と同じ。#274)に herdr が配置する `~/.claude/hooks/herdr-agent-state.sh` を installer と同一形(`bash '<path>' session`、timeout 10)で 1 本登録(session id の報告。body は `herdr integration install claude` が配置・版管理、#225)。hooks object は `.chezmoitemplates/agent-hooks-json` で Codex と共有。スクリプト実体は agent-tools(herdr hook は herdr)の責務([config-ownership](config-ownership.md)、capability は [policy-model](policy-model.md)) | 同上(template が capability で gate して出力) | ✅ chezmoi(登録の構造は `test-claude-settings.sh` が exact に固定) |
| personal・機密(secret を含む設定など) | project の `.claude/settings.local.json`(project 単位)/ `CLAUDE_CONFIG_DIR` の別 config dir(machine 全体)/ `--settings` や環境変数(session 限定)。user 級 `~/.claude/settings.local.json` は Claude Code が**読まない**ので置き場にしない(#245、[local-overrides](local-overrides.md)) | ❌ 非コミット・管理外 |
| work / client の settings | 各マシン手設定(#60 の暗号化バックアップは `allowSecretsAccess=false` の work / client では実行を拒否するため使えない) | ❌ public repo に生値を置かない |
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

dotfiles が管理するのは user 級の `~/.claude/settings.json` **だけ**。Claude Code が動的に書く
`settings.local.json` は **project の `.claude/settings.local.json`** で、常に管理外(`.chezmoiignore` は
allowlist で、宣言した file 以外は通さない。#207)。user 級の `~/.claude/settings.local.json` は
Claude Code が読まないので、この 2 層には含めない(#245、[local-overrides](local-overrides.md))。

Claude Code は書き先を 2 つに分ける: **動的に承認した permission** は
project の `.claude/settings.local.json`(machine / context 固有・絶対 path を含むので非 public-safe)へ、
**global な preference**(`effortLevel` / `tui` / `skipWorkflowUsageWarning` / 通知 /
`remoteControlAtStartup` / plugin 有効化など)は **`~/.claude/settings.json` 本体**へ書く。
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

`claude-settings` module(`.chezmoidata/modules.yaml`)が `.claude/settings.json` を
宣言し、`personal` profile にのみ登録する。`.chezmoiignore`(allowlist)は活性 module の
宣言 path とその祖先 `.claude` だけを通すので、module を持たない profile(work)では
`.claude` が**ディレクトリごと**管理外になる。`scripts/test-render.sh` が profile 別の
managed set でこの gate を回帰固定している。

## permissions(#119: secret floor / GitHub guard)

`permissions.deny` には capability 非依存の **secret floor**(never-legit な secret 読取
30 件: `Read(~/.ssh/**)` と credential-store 読取 `Read(~/.aws/**)` / `Read(~/.config/gh/**)`
(gh の OAuth token)/ `Read(~/.netrc)` / `Read(~/.codex/auth.json)` /
`Read(~/.local/share/opencode/auth.json)`(#234)、`Bash(cat ~/.ssh/*)` /
`gh secret` / `gh api *secrets*` / `env` / `printenv` 系、gh の token の表示 `gh auth token` /
`gh auth status --show-token|-t|-at`、`auth` の前か直後に option を置いた `gh auth`(`gh -* auth *` /
`gh auth -*`。同じ subcommand に届く置き方なので丸ごと deny)と、keychain の password の読み出し・dump・export(`security
find-generic-password` / `find-internet-password` / `dump-keychain` / `export`。`-q` などの前置 option を
挟む形も)— 後の 2 群は #315 で OpenCode の床に揃え、#334 で Codex の rules の床と doctor の Codex rules の probe にも同じ種類を足した)を常時出力する。**Read 側 deny を
主軸**とする(Read tool はコマンド経由でない読取にも効く。Bash matcher は `head` / `xxd` /
`python open()` 等の等価経路で迂回できる leaky steering なので、path ごとの Bash 列挙は
意図的にしない。#136)。`gateGitHubMcp=true`(personal 既定)で
`mcp__github`(server 全体)の deny を足して計 35 件(下の #304 の 4 件を含む)、`enforceAiSandbox=true` で human-legit gate
(`.env` 読取 / main・master への push の deny、release / branch-protection の ask)を
追加する。`permissions.ask` には、1Password の CLI 全体(`Bash(op *)`)を常時出力する(`op read` / `op item get` /
`op run` などの読み出し系は global option をどこにでも置けるので、subcommand の列挙ではなく program 単位にする。人が private-backup の `--identity-command` などで指示する
場面があるので deny ではなく承認、#315)。`permissions.allow` は `mcp__pencil` のみ。

**破壊的な git・hook の skip・参照先 note(#304)**: agent-tools#204 が hook を作らずに各 host の permission へ
委ねた項目を、capability に依らず常時出力する(personal)。

- **ask**(人が頼むこともあるので承認): 作業を捨てる git — `reset --hard`、`clean`、`checkout -- <path>` /
  `checkout <...> .`、`-f` / `--force` / `--discard-changes` つきの `checkout` / `switch`、`restore`、`--force` / `-f` /
  `+refspec` の `push`(`--force-with-lease` は一致しない)、`branch -D` / `--force` / `-f`、#334 で足した `push --mirror` /
  `--delete` / `-d` / `:refspec`(remote の branch の削除)、`branch -M`、`stash drop` / `clear`、`--force` / `-f` つきの
  `worktree remove`(`worktree add --force` は対象外)。option は**単独の語**として
  照合し(`git *push* -f` と `git *push* -f *`)、subcommand の後ろならどの位置でも、`git -C dir` のような global option が
  前にあっても拾う。`feature-f` のような branch 名の一部には一致しない。2 文字の代表的な束ね(push の `-uf` / `-fu`、
  branch の `-df` / `-fd`、checkout と switch の `-qf` / `-fq`)も拾うが、それ以外の束ねと long option の省略形は
  拾わない(綴りの違いは列挙しない。#315 の教訓)。代わりに、そうした command 名を含む commit message などで確認が
  出ることがある(ask なので害は小さい)。文章に出やすい語(clean / restore)は前後に空白を置く。template は
  (subcommand, option) の組から両方の rule を生成する。
- **hook の skip**: 任意の git の `--no-verify` と `git commit -n`(その短縮形)。pre-commit / commit-msg の gate
  ([git-hook-gates](git-hook-gates.md))を AI tool から飛ばす理由はなく、必要なら人が自分の terminal で実行する。
  glob では option と引数のデータ(`git commit -m "document --no-verify"`、`git grep -e --no-verify`、
  `git commit -m -n`)を区別できないので、**deny** はデータが入りえない位置 — `git commit` / `git push` の直後 — に
  限り、それ以外の置き方(global option の後ろ、後ろや最後の語、束ねた `-nm` / `-an` / `-anm`、引用の中での言及)は
  **ask** にする。
  拾わない形: 他の束ね、long option の省略形、`-c core.hooksPath=...`。
- **deny**: 任意の `.agent-context.local.md` への `Edit`(`Edit(//**/.agent-context.local.md)`)。agent は読むだけの
  user の note。`Edit` の deny は Write・NotebookEdit と、path を名指しする Bash の file command / リダイレクトにも効くが、
  自分で file を開く script には効かない。
- **ask**(#334): secret を含みうると repo 自身が扱っている設定 file の読み取り — `~/.codex/config.toml`(MCP の env)、
  `~/.zshrc.local`、OpenCode の local 設定 `~/.config/opencode/opencode.local.json`(provider の option、MCP の header)。
  doctor は値を出さないが、Codex の設定の調査など正当な理由もありうるので、deny ではなく承認。

日常の git(普通の commit / push、`--force-with-lease`、branch の作成・切替・force なしの rename、merge 済みの `-d`、
`--soft` / mixed の reset、`stash pop` / `list`、`worktree add`(`--force` つきも)、force なしの `worktree remove` など)は止めない。これらの判定は `scripts/test-claude-settings.sh` が、Claude Code の docs の照合規則で git の
command の集合に当てて固定する(rule の文面を固定するもので、harness の挙動の証明ではない)。これらは **steering であって
enforcement boundary ではない**(射程と限界は
[ai-environment-boundary](ai-environment-boundary.md))。deny の内容と順序は
`scripts/test-claude-settings.sh` が exact-set で回帰固定している。

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

- work / client の settings を新マシンで復元する手段は現状無い(#60 の暗号化バックアップは
  work / client では実行を拒否するため、各マシン手設定)。必要になったら #60 とは別の仕組みとして起票する。
- doctor への settings presence/管理状態の report → 対応済み。doctor の managed drift section(#148)が
  `chezmoi status` で、managed な `~/.claude/settings.json` の差分と欠落(未 apply)を report-only で報告する。

関連: [ai-environment-boundary](ai-environment-boundary.md)(責務境界)、
[local-overrides](local-overrides.md)(`.local` の扱い)、#60(暗号化バックアップ)、
#16(VS Code settings は管理しないと決定。配線は #145 で削除済み)。
