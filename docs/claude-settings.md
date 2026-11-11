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
| personal・public-safe な `settings.json`(model の既定 / effort / public plugin(第三者の marketplace は tag に固定・`autoUpdate: false`。[update-policy](update-policy.md))/ 通知 / statusLine / tui / workflow 警告抑止 / `switchModelsOnFlag` 等の global preference) | public repo(`dot_claude/modify_settings.json.tmpl`。chezmoi の modify script。下記「apply の仕組み」) | ✅ chezmoi(**personal profile のみ**) |
| permission ブロック(#119): secret floor の無条件 deny 30 件(`~/.ssh` 読取 / credential-store 読取(Codex・OpenCode の `auth.json` を含む・#234)/ env dump / gh secret 系 / gh token の表示と keychain の password の読み出し・dump・export(#315))、1Password の CLI 全体(`op *`)の無条件 ask(#315)、作業を捨てる git の無条件 ask と hook の skip・参照先 note への書き込みの無条件 deny(#304)、`gateGitHubMcp` の `mcp__github` deny、`gateUnusedClaudeMcp` の日常で使わない MCP の deny 21 件(#341。どちらも personal 既定 true で deny は計 56 件)、`allow`(`mcp__pencil` と、merge 済みの branch を片付ける script の 1 本。#505)、`enforceAiSandbox` 連動の human-legit gate | 同上(template が capability で gate して出力) | ✅ chezmoi(内容の回帰は `test-claude-settings.sh` が exact-set で固定) |
| hooks **登録**(#137 / #199 / #225 / #353 / #497 / #505 / #508): `enableGitHubIsolatedReader` 連動で PreToolUse / matcher `Bash` に agent-tools 配布の `personal-safe-gh-hook` を絶対 path で 1 本登録(fail-open steering)。`enableQualityLoopHooks` 連動で PostToolUse / matcher `Edit\|Write` に `personal-fast-edit-check`、matcher なしの Stop に `personal-changed-scope-qa` を登録(品質ループ。repo 単位 opt-in の `~/.config/agent-tools/checks.local.json` が無ければ無言 no-op)。`enableHerdrIntegration` 連動で SessionStart / matcher `^(startup\|resume\|clear\|compact\|fork)$`(herdr 0.9.3 の integration v10 と同じ。#274)に herdr が配置する `~/.claude/hooks/herdr-agent-state.sh` を installer と同一形(`bash '<path>' session`、timeout 10)で 1 本登録(session id の報告。body は `herdr integration install claude` が配置・版管理、#225)。`enableToolCallRecordHook` 連動(#353、agent-tools#454)で SessionStart(matcher なし)と PreToolUse / PostToolUse / PostToolUseFailure / PermissionDenied / PermissionRequest(matcher `*`。PermissionRequest は確認の回数を実測するため。#505、agent-tools#639)に agent-tools 配布の `personal-tool-call-record-hook` を `async: true`・timeout 10 で登録(tool 呼び出しの記録。引数は key だけ・fail-open。既存の entry の後ろに 2 つ目の entry として足す。Claude だけで Codex には出さない)。`enableJaReplyGuardHook` 連動(#497、agent-tools#588)で matcher なしの Stop に agent-tools 配布の `personal-ja-reply-guard` を timeout 10 で登録(最後の答えが英語に逸れたら 1 回だけ止めて日本語で書き直させる。fail-open で、`stop_hook_active` のときは止めない。`personal-changed-scope-qa` の後ろに 2 つ目の entry として足す。Claude だけで Codex には出さない。英語で答えさせたい session は env の `AGENT_TOOLS_JA_GUARD_DISABLE` で止める)。`enableBridgeOneHook` 連動(#508。personal は #510 で on、work は off)で PermissionRequest / matcher `*` に Bridge One の起動用の script `~/.local/share/bridge-one/hook/current/bin/permission-request` を timeout 600 で登録(`async` と `onFailure` は付けない。command は path を single quote で囲み ` 2>/dev/null` を付けた、Bridge One の `tools/hook-deploy/deploy.mjs` が表示するものと同じ文字列。記録 hook の後ろに 2 つ目の entry として足す。ほかの hook と違い決定 (allow / deny) を返しうる: Bridge One の host が答えたときだけ返し、host が動いていない間・起動用の script が無いときは何も出力せず、承認は端末の dialog に戻る。dotfiles が出す PermissionRequest の hook で決定を返しうるのはこれだけで、決定を返す hook を手で足したものとの併存は dotfiles の範囲の外。Claude だけで Codex には出さない。配備は Bridge One の repo が行う)。hooks object は `.chezmoitemplates/agent-hooks-json` で Codex と共有。スクリプト実体は agent-tools(herdr hook は herdr)の責務([config-ownership](config-ownership.md)、capability は [policy-model](policy-model.md)) | 同上(template が capability で gate して出力) | ✅ chezmoi(登録の構造は `test-claude-settings.sh` が exact に固定) |
| telemetry の `env`(#523): `enableClaudeTelemetry` 連動で、Claude Code の OpenTelemetry(metric と event を OTLP/HTTP で送る)の変数を出す。送り先は管理外の local file から apply のときに読む(下記「telemetry」) | 方式は public repo(`dot_claude/modify_settings.json.tmpl`)、送り先は `~/.config/dotfiles/claude-telemetry.local`(非コミット) | ✅ chezmoi(**personal profile のみ**。file が無ければ出さない) |
| 手元だけの key: `/model` で選んだ `model`(template の値は file に無いときの既定だけ)、`modelSettings`(model ごとの effort)、`autoMode`(auto mode の environment。repository 名などを含み public に出さない)、Claude Code が後から足す key | live の `~/.claude/settings.json` | ⚪ 管理外だが apply で消さない(modify script がそのまま残す。#360) |
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
前者は管理外なので衝突しない。後者は managed な `settings.json` を Claude が書き換える。#360 までは
template に無いキーが `chezmoi apply` で消えたが、今は modify script が template の管理しない key を
そのまま残す(下記「apply の仕組み」)。

**方針(issue #93, 案 a「取り込む」)**: Claude が `settings.json` に書く **安定・public-safe な
global preference は managed template に取り込む**。新マシン bootstrap の baseline が忠実になり、
値は PR で変わる。permission 承認は引き続き `settings.local.json`(管理外)に任せる。`settings.json` と
`settings.local.json` の責務境界はこれで固定する。

取り込むのは **安定した** preference だけ。`/model` のように使う人がその場で切り替える値(`model` /
`modelSettings`)や、public に出せない値(`autoMode`)は取り込まず、手元の key として残す(#360)。
Claude が *新しい* key を書いても apply では消えず、`chezmoi status` も `M` を出さない。安定した
public-safe な key なら template に取り込む(取り込みの継続運用)。drift(`M`)が出るのは、managed の
key に Claude が template と違う値を書いたときで、対処は「apply で template の値に戻す」か「その値を
template に取り込む」。`settings.local.json` 行きの permission 承認は対象外。

**project 側の allow の堆積(#334)**: `settings.local.json` は管理外なので、`chezmoi apply` では戻らない。
承認の「次から聞かない」で外向きの操作(push・PR の作成や merge・外部送信など)の allow が溜まると、その
project ではそれらが承認なしに走る(managed の deny / ask は allow に勝つが、外向きの操作の多くは ask に
入れていない)。doctor が標準の project root 直下の repo(work と client では、配置の規約どおり org(client)の
1 段下に置いた repo も。#445)の allow を外向きの probe で評価し、managed の floor と
project 自身の deny / ask が止めないものを warn する(rule の
中身は出さない。一致の規則は [scripts/README](../scripts/README.md) の doctor の AI policy)。対処はその file から
該当の allow を外し、都度承認に戻すこと。

## apply の仕組み(modify script、#360)

`dot_claude/modify_settings.json.tmpl` は chezmoi の modify script で、chezmoi は live の file を stdin に
渡して、script が出力したものを書き戻す。template が描く JSON(managed の JSON)は script の中にある。

- live の file が無い(新しい machine・test の throwaway home)か 0 byte のときは、managed の JSON をそのまま出す
  (render は modify script にする前と byte 単位で同じ)。
- live の file があるときは jq で合成する:
  - managed の JSON の top-level の key は、値が違えば template の値にする(jq の `==` は object の key の
    順を見ないので、意味が同じなら live の byte のまま残る)。
  - ただし `model` は、live に在ればそのまま残す(`/model` の選択)。template の値は file に無いときの既定。
  - capability で出し入れする `sandbox`(`enforceAiSandbox`)、`hooks`(hook の 6 capability)、`env`
    (`enableClaudeTelemetry` と送り先の file。#523)は、template が出さないときは live からも消す。capability で
    出し入れする top-level の key を足すときは、script のこの一覧にも足す(`test-claude-settings.sh` が、capability を
    on にした render と off の render の key の差がこの一覧と同じことを固定する)。template から top-level の key を
    消すときも、live に残したくなければこの一覧に足す。
  - `env` は object 全体を managed にする(`hooks` と同じ)。live の `env` に手で足した変数は apply で消える。host
    固有の環境変数は [local-overrides](local-overrides.md) の経路に置く。
  - それ以外の key(`modelSettings` / `autoMode` / Claude Code が後から足す key)は、位置も値もそのまま残す。
- 合成しても live の file と意味が同じなら、live の byte をそのまま返す(初回の apply が書いた 1 行の配列なども
  整形し直さないので、`chezmoi diff` は空のまま)。変わるときは jq が 2 space の indent で出す(Claude Code が
  書く形と同じ)。
- live の file がちょうど 1 つの JSON の object でない(空白だけ・値が 2 つ以上・配列・壊れた JSON・NUL を含む)ときは、
  apply はその file を書き換えずに止まる。live の file があるときは jq が要る(macOS は `/usr/bin/jq` を同梱)。
- live の file の中身は一時 file に書かず、shell の変数に保って jq には stdin で渡す(#446)。managed の JSON も、
  live の file の前に同じ stdin で渡す(#523。telemetry の送り先は local の値なので、jq の引数に置かない)。jq の
  引数は option と filter だけで、live にしかない値(`autoMode` など)も送り先も process の一覧(`ps`)に出ない。合成と比較は 1 回の jq で行う。script は live の中身を一時 file に置かないので、kill されても live の写しは
  残らない。shell の変数は NUL を持てないので、NUL は `tr` で別の制御文字に置き換えて jq に渡し、上の「壊れた JSON」
  として止める(末尾の NUL も止める。jq は file を直に読むと末尾の NUL を通すが、ここでは通さない)。
  `tr` は `LC_ALL=C` で byte として読む(UTF-8 の locale の BSD の `tr` は、UTF-8 でない byte で止まるため。string の
  中のそうした byte は jq が読み、変わらなければ live の byte のまま返す)。
- ただし chezmoi 自身は、modify script を一時 dir(chezmoi の設定の `scriptTempDir`、既定は `TMPDIR`)に書いてから
  走らせる(書くのは template が描いた script で、live の中身は入らない。telemetry の送り先は入る)。そのため `TMPDIR` が書ける dir でない環境では、
  `scriptTempDir` を書ける dir に向けない限り、`chezmoi diff` / `status` / `apply` も doctor の drift の検査も
  失敗する。この repo の chezmoi の設定は `scriptTempDir` を決めない。doctor はこのとき、`TMPDIR` が書ける dir で
  ないことを action に書き、config / template の error とだけは案内しない。

`chezmoi diff` / `status` も同じ script を走らせて比べる(doctor の drift の検査も `chezmoi status` を使う)。手元の
key を保ったまま apply できるので、#341 / #353 のときのように live の file を手で書き換える必要はない。

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
`mcp__github`(server 全体)の deny を足して計 35 件(下の #304 の 4 件を含む)、`gateUnusedClaudeMcp=true`(personal 既定。#341)で claude.ai の Gmail / Google Calendar / Google Drive / Claude Docs の connector(server 全体)と Notion の書込 tool 17 個の deny を足して計 56 件、`enforceAiSandbox=true` で human-legit gate
(`.env` 読取 / main・master への push の deny、release / branch-protection の ask)を
追加する。`permissions.ask` には、1Password の CLI 全体(`Bash(op *)`)を常時出力する(`op read` / `op item get` /
`op run` などの読み出し系は global option をどこにでも置けるので、subcommand の列挙ではなく program 単位にする。人が private-backup の `--identity-command` などで指示する
場面があるので deny ではなく承認、#315)。`permissions.allow` は `mcp__pencil` と、下の片付けの script の 1 本だけ。

**merge 済みの branch の片付け(#505)**: squash merge の branch は `git branch -d` では消せず、`git branch -D` と
`git push --delete` は下の ask に当たる。直近 30 日で ask に当たった Git の呼び出し 226 回のうち 56% がこの片付けだった。
ask は未 merge の作業を人に確かめるために残し、allow には配備した script だけを置く
(`Bash(~/.claude/agent-tools/scripts/personal-merged-branch-cleanup *)`、agent-tools#640)。script は、個人の repo で、
default branch でなく、tip が merged の PR の head と一致することを確かめ、比較つきで消す。条件の正本は agent-tools の
`docs/merged-branch-cleanup.md`。

- 規則は deny → ask → allow の順に見る。`git branch -D` を直接打てば、今までどおり確認になる。
- Bash の規則は command の文字列に当たるので、`~/` で書く。絶対 path や `$HOME` の形では当たらず、既定の確認になる。
- `&&` などでつないだ command は Claude Code が分けて照合し、つないだ先が allow に無ければ確認になる。
- 手順の守りであって境界ではない。script は agent と同じ OS user が書き換えられる。

**破壊的な git・hook の skip・参照先 note(#304)**: agent-tools#204 が hook を作らずに各 host の permission へ
委ねた項目を、capability に依らず常時出力する(personal)。

- **ask**(人が頼むこともあるので承認): 作業を捨てる git — `reset --hard`、`clean`、`checkout -- <path>` /
  `checkout <...> .`、`-f` / `--force` / `--discard-changes` つきの `checkout` / `switch`、`restore`、`--force` / `-f` /
  `+refspec` の `push`(`--force-with-lease` は一致しない)、`branch -D` / `--force` / `-f`、#334 で足した `push --mirror` /
  `--delete` / `-d` / `:refspec`(remote の branch の削除。rule は `git *push* :**`: 末尾が `:*` だと Claude Code は旧式の
  prefix として読み、その前の `*` を展開しないので一致しない。2.1.293 の実装から確認、test-claude-settings の 4e が混在を弾く。起動時に Claude Code が「この `:*` は wildcard として一致する」と注記するが、それが意図どおり)、`branch -M`、`stash drop` / `clear`、`--force` / `-f` つきの
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
  `~/.zshrc.local` と `~/.zprofile.local`(secret を置く local override。[local-overrides](local-overrides.md)。後者は #381)、
  OpenCode の local 設定 `~/.config/opencode/opencode.local.json`(provider の option、MCP の header)。
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

## telemetry(`enableClaudeTelemetry`、#523)

Claude Code の OpenTelemetry を、managed な `settings.json` の `env` で有効にする。方式は repo で固定し、送り先は repo に
入れない(今は手元の otel backend だが、将来は自分の server へ移すため)。work には配布しない(environmentKind の work /
client / agent で false 必須。[policy-model](policy-model.md))。

送り先は管理外の `~/.config/dotfiles/claude-telemetry.local` に書く。

- 1 行に OTLP/HTTP の base endpoint を 1 つ書く。`#` で始まる行と空行は飛ばし、前後の空白は落とす。
- 手元の otel backend へ送るなら `http://127.0.0.1:4318`。`localhost` は使わない(この Mac の `localhost` は `::1` を先に
  引き、Collector は `127.0.0.1` でしか待ち受けないため)。
- 形は `http(s)://host[:port][/path]`。host は DNS の名前か IPv4 の形で、label は英数字で始まり英数字で終わる。port は
  1 から 65535(先頭に 0 を付けない)。認証情報(`user:pass@`)、query、fragment は書けない。signal ごとの path
  (`/v1/logs` など)も書けない(Claude Code が base endpoint に足すため)。IPv6 の literal も受け付けない。
- 4096 byte 以下の通常の file にする(symlink は、先が通常の file ならよい)。
- 値を変えたら `chezmoi apply` する。apply までは、managed drift の section に `settings.json` の差分として出る。

apply のときの動き:

- file が無い: `env` を出さない(何も送らない)。前の apply で出した `env` も消す。
- 形の正しい file: `env` に下の表の 6 つを出す。値は live の `settings.json` にだけ入る。
- それ以外(値が無い・2 つ以上、形が違う、通常の file でない、大きすぎる、読めない): render が失敗して apply が止まり、
  `settings.json` は書き換わらない。error には file の path が出て、値は出ない。
- 読む file は destination の下(`.chezmoi.destDir`)で、HOME の下ではない。test の使い捨ての destination への render は、
  この machine の file を読まない。

| 変数 | 値 |
| --- | --- |
| `CLAUDE_CODE_ENABLE_TELEMETRY` | `1` |
| `OTEL_METRICS_EXPORTER` / `OTEL_LOGS_EXPORTER` | `otlp` |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/protobuf` |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | file の値 |
| `OTEL_LOG_TOOL_DETAILS` | `1` |

送るもの(Claude Code の docs による。2.1.322 の時点):

- metric(`claude_code.session.count`、`token.usage`、`cost.usage` など)と event(`claude_code.user_prompt`、`tool_result`、
  `api_request` など)。service の名前は `claude-code`(Desktop の Code tab の session は `claude-code-desktop`)。
- `OTEL_LOG_TOOL_DETAILS=1` で、tool の event に Bash の command(切り詰めない)、skill と MCP の名前、tool の入力が入る。
  tool の入力は、値ごとに 512 文字、合わせて約 4K 文字で切られる。tool の出力は自分の server に出してよいと決めたので
  (2026-11-11)、この範囲は出す。
- どの event にも、session の id、account の uuid、`user.email` などの標準の attribute が付く。

送らないもの: prompt の本文(`OTEL_LOG_USER_PROMPTS`)、assistant の応答(`OTEL_LOG_ASSISTANT_RESPONSES`)、tool の出力の
中身(`OTEL_LOG_TOOL_CONTENT`)、API の body(`OTEL_LOG_RAW_API_BODIES`)、trace(beta)。どれも Claude Code の既定で off で、
template は出さない。`env` は object 全体を managed にするので、live に手で足しても apply で消える。

- metric の temporality は Claude Code の既定(delta)のまま。手元の Prometheus は取り込みのときに cumulative に直す
  ([otel-backend](otel-backend.md) の「metric の temporality」)。
- Claude Code は `OTEL_*` の変数を、Bash の tool や hook などの子 process に渡さない(Claude Code の docs)。
- 送り先に認証の header が要るようになったら、秘密は `settings.json` に書かず、Claude Code の `otelHeadersHelper`
  (header を出す script)で渡す。その配線は別の Issue で行う。
- 止めるときは file を消して `chezmoi apply` する。profile ごと止めるなら capability を false にする。
- doctor は file の有無だけを見る(値は読まない)。表示は apply の後の状態で、apply までは前の apply の `env` が残って
  送り続ける(managed drift の section に出る)。

## 後日 / 対象外

- work / client の settings を新マシンで復元する手段は現状無い(#60 の暗号化バックアップは
  work / client では実行を拒否するため、各マシン手設定)。必要になったら #60 とは別の仕組みとして起票する。
- doctor への settings presence/管理状態の report → 対応済み。doctor の managed drift section(#148)が
  `chezmoi status` で、managed な `~/.claude/settings.json` の差分と欠落(未 apply)を report-only で報告する。

関連: [ai-environment-boundary](ai-environment-boundary.md)(責務境界)、
[local-overrides](local-overrides.md)(`.local` の扱い)、#60(暗号化バックアップ)、
#16(VS Code settings は管理しないと決定。配線は #145 で削除済み)。
