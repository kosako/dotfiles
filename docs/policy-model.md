# Policy Model

この repository の中心は `profile` ではなく `capabilities`。

## Concepts

```text
profile = ユーザーが選びやすい用途別プリセット
environmentKind = personal / work / client / sandbox / agent
modules = 機能単位。管理対象 path の宣言を持つ
capabilities = 実際に許可される操作・副作用
policy = 何を許可/禁止するかの判断基準
```

## Modules

modules は装飾ラベルではなく、管理対象 path を宣言する単位(2026-06-13 決定。それまでは情報ラベルだった)。

- module は `.chezmoidata/modules.yaml` の `paths:` で home 配下の管理対象を宣言する。
- ある path が chezmoi の管理対象になるのは、profile がその module を列挙し、かつ module の `requires:` にある capability 条件をすべて満たすときだけ。
- それ以外の path は `.chezmoiignore` の生成によって除外される(fail closed)。
- `paths:` を持たない module は現時点では情報ラベル(実装が入る時点で `paths:` を宣言する)。
- `requires:` の capability 名・値は `validate-policy.sh` が schema と突き合わせて検証する。複数 module による同一 path の宣言は fail。

## データ読み取り

`.chezmoidata/*.yaml`(profiles / modules / capabilities.schema / packages / backup-paths)の読み取りは shell script 側では mikefarah/yq v4 で行う(chezmoi template 側は Go template が読む)。yq が無い・別 variant の場合は `require_yq` が fail closed する。profile / module / capability 名は `strenv()` 経由で渡し、yq 式へ展開しない(injection 防止)。

`packages`(`.chezmoidata/packages.yaml`)は software catalog。各 entry の `source`(brew_formula / brew_cask / npm_global / go_install / mas / manual)と canonical id を宣言する。`validate-policy.sh` が source の妥当性・go_install/mas の pkg 必須・name 重複を fail closed で検査する。

実機との drift は `doctor.sh` の `software catalog` section(`report_catalog_drift`)が **report-only**(常に exit 0、欠けている package manager は skip)で報告する。検出は 3 種:

- **未 install**(宣言済みだが入っていない)→ `warn`。
- **台帳外**(undeclared / sprawl: 入っているが catalog に無い)→ `warn`。brew は `brew leaves`(top-level のみ。依存は拾わない)、npm は node 同梱の `npm` / `corepack` を除外(runtime の領分、node/go/uv と同じ扱い)、go は toolchain 同梱の `go` / `gofmt` を除外(GOBIN を `$GOROOT/bin` に向ける mise 等では toolchain 本体が scan dir に同居するため。catalog で宣言・削除できる go_install package ではない)、mas は App Store の無関係アプリが大量に誤検知されるため undeclared は出さない(宣言済み mas entry の presence のみ確認)。
- **source ズレ**(宣言 source の inventory には無いが `command` が PATH 上に在る = 別 source で入っている疑い)→ `info`。manager 横断の名前照合(脆い)はやらず、PATH 上の存在という堅い信号だけを使う。

照合は source ごとの canonical id(`pkg`、無ければ `name`)で行う。

install は `install-packages.sh`(手動起動・`chezmoi apply` 非結合)が担う。catalog の未 install entry を、`installPackages`(brew_formula / npm_global / go_install)と `installGuiApps`(brew_cask / mas)で gate して install する。**dry-run 既定**(`--apply` で実行)、既 install は skip して**更新しない**(install と update の分離、[update-policy](update-policy.md))、track-only / manual は対象外、npm/go の manager 不在時は skip+warn。environmentKind 制約で work / client / agent は gate(installPackages/installGuiApps)が false 必須なので install されない(`environment_kind_forbidden_capabilities`)。sandbox は install 制約の対象外(secret のみ禁止)で、profile が install gate を true にすれば install されうる。

## Rules

- profile 名だけで副作用を許可しない。
- unknown profile / module / capability は fail closed。
- destructive な操作は work / client / agent でデフォルト無効(environmentKind の制約として `validate-policy.sh` が hard fail で強制。下記参照)。
- secret access、network tunnel、AI tools は personal でも明示的に扱う。
- boolean で足りない capability は enum にする。
- `report` は検査のみ、`enforce` / `enable` は実際の適用を意味する。

## environmentKind の制約

environmentKind は飾りラベルではなく、capability の不変条件を駆動する。`validate-policy.sh` が各 profile を検証するとき、environmentKind が禁止する boolean capability が `true` だと **hard fail**(report-only の warning ではない)する。「work 環境なのに `installPackages=true`」のような矛盾を CI で止めるための invariant(2026-06-14 決定)。

| environmentKind | false 必須の capability |
| --- | --- |
| work / client / agent | installPackages, installGuiApps, allowSecretsAccess, allowNetworkTunnels, enableAiTools |
| sandbox | allowSecretsAccess |
| personal | (制約なし) |

enum capability には**禁止値**の制約を同じ仕組みで当てる(#45、2026-07-07 決定)。boolean の
「false 必須」と違い、enum は特定の 1 値だけを禁止し、残りの選択は profile に委ねる:

| environmentKind | 禁止値 |
| --- | --- |
| work / client / agent | `npmHardeningMode=off`(floor は report。off は install-script 防御の全停止で、制限環境でこれになるのは事故のみ) |
| personal / sandbox | (制約なし) |

- 表は `scripts/lib-policy.sh` の `environment_kind_forbidden_capabilities`(boolean)と
  `environment_kind_forbidden_enum_values`(enum 禁止値)が持つ。
- `personal` は明示許可前提なので無制約。`agent` は profile がまだ無いが、最小権限を明示するため先行定義してある(agent profile 追加時に即発効)。
- **required 値の制約(「work は enforce 必須」)は作らない**(#45 裁定): 会社 Mac の work は
  会社 npm 設定との兼ね合いで report 稼働([supply-chain-npm](supply-chain-npm.md))であり、
  required にすると稼働中のマシンが hard fail する。`corepackMode` も制約対象外
  (off は「意図的非管理」の正当な選択で、security downgrade ではない。doctor が中立報告)。
- 将来 work 等で禁止 capability / 禁止値を正当に許したくなった場合は、warning で迂回せず、この表自体を見直す。

## Claude Code sandbox (`enforceAiSandbox`)

`enforceAiSandbox`(boolean)は、Claude Code の native sandbox を managed な
`~/.claude/settings.json` の `sandbox` ブロックとして出すかを gate する。射程は **Claude Code
の Bash tool の fs + network のみ**(OS 全体ではない。`enforce` はここでは「settings に
sandbox ブロックを出して Claude Code に内部適用させる」意)。射程と限界の正本は
[ai-environment-boundary](ai-environment-boundary.md)。

- **極性が逆**。`environment_kind_forbidden_capabilities` の capability(install / secret /
  network / AI tool 導入)は *権限を付与* するので制限環境で false 必須。sandbox は逆に
  *安全を強化* する(ON ほど agent が締まる)ので **forbidden 表に入れない**。制限環境
  (work / client / agent)でこそ true にしたい capability。
- 効くのは **`claude-settings` module が active な profile だけ**(今は personal)。module を
  持たない profile で true にしても settings には反映されない(dangling)。`doctor` が
  この dangling を report する(AGENTS.md の「capability は doctor section を駆動する」)。
- **既定は全 profile で false**(配線のみ・opt-in)。有効化は allowlist を詰め、push /
  install が壊れないか検証してから cap を反転する別ステップ。
- 将来 agent profile を足すときは「特定 kind で true 必須」(forbidden の逆の不変条件)の
  候補になるが、required 制約は今は作らない(#45 で enum の**禁止値**制約のみ導入し、
  required 方式は不採用とした。上記「environmentKind の制約」)。

## GitHub injection guard (`gateGitHubMcp` / `enableGitHubIsolatedReader`)

GitHub runtime prompt-injection 防御(epic #119)の capability 2 本。射程と限界の正本は
[ai-environment-boundary](ai-environment-boundary.md)。

- **極性は `enforceAiSandbox` と同じ**(安全強化型)。install / secret / network 系と違い
  権限を付与せず agent を締めるので、`environment_kind_forbidden_capabilities` には
  **入れない**(制限環境でこそ true にしたい)。
- `gateGitHubMcp`(boolean): managed `~/.claude/settings.json` の `permissions.deny` に
  `mcp__github` を出して GitHub MCP server を deny する。効くのは `claude-settings` module
  が active な profile だけ(今は personal)。dangling は doctor が report。
- `enableGitHubIsolatedReader`(boolean): **PreToolUse hook 登録**(matcher `Bash`)を出し、
  raw な `gh` 読取を safe-gh 隔離 reader へ誘導する(#137 / #181)。**1 capability が 2 つの
  AI home 両方**に登録を出す — Claude は managed `~/.claude/settings.json` の `hooks`
  (#137、`claude-settings` module)、Codex は user 層の別ファイル `~/.codex/hooks.json`
  (#181、`codex-settings` module。config.toml は codex 所有の live ファイルなので分離)。
  hook body(`personal-safe-gh-hook`)は agent-tools が両 home へ配布し、dotfiles は絶対
  path 参照のみ(登録=dotfiles・実体=agent-tools。path 安定は agent-tools#146 の契約)。
  **steering / fail-open で enforcement ではない**(body 不在・非 2 exit・不正 JSON は
  すべて tool call 続行)。Codex は加えて、登録済みでも一度 `/hooks` trust するまで silent
  skip される inert stage がある(registration ≠ activation)。効くのは対応 module
  (`claude-settings` / `codex-settings`)が active な profile だけ。dangling(module 非
  active / body 不在)は doctor が report。
- GitHub 由来の deny は専用 capability を作らず **3 tier**(#119 Phase 2 task B): never-legit な
  secret 読取(`~/.ssh` と credential-store の `~/.aws` / `~/.config/gh` / `~/.netrc` /
  `~/.codex/auth.json`(#136)/ `printenv` / `env` / `gh secret` / `gh api *secrets*`)は
  **無条件 deny**(`enforceAiSandbox` を待たず常時)。file 系は **Read 側 deny を主軸**とし、
  Bash matcher の path 列挙はしない(等価経路で迂回できる leaky steering。#136)。main / master 直 push と `.env` 読取 deny + release /
  branch-protection ask は **`enforceAiSandbox` に相乗り**(human-legit ゆえ常時 ON にしない)。
- tier3 の main-push deny(`git push * main|master`)は **leaky steering**: ` main` 末尾の explicit
  形しか拾わず bare `git push` / `git push origin HEAD` / refspec(`HEAD:main`)は抜ける(Claude Code
  の matcher セマンティクスを #119 で裏取り)。真の「main 直 push を止める」hard 層は server-side
  branch protection か Phase 3(#131)の隔離 reader。enumeration で matcher を広げて塞ぐのは
  command-string ≠ enforcement のアンチパターンゆえ **しない**。tier3 を `enforceAiSandbox` から
  切り出して常時 ON にする案も、この leak ゆえ「摩擦ゼロだが保護もゼロ」になるため採らない。射程と
  限界・接続規約の正本は [ai-environment-boundary](ai-environment-boundary.md)。
- **状態**: `gateGitHubMcp` は **personal=true**(Phase 2 で github MCP deny を live 化。
  render→diff→実機 dry-run の検証ゲート済み)、work=false(`claude-settings` 非 active)。
  `enableGitHubIsolatedReader` も **personal=true**(#137 で Claude、#181 で Codex の
  PreToolUse hook 登録を live 化。両 home 同一 body)、work=false。github MCP は現状未構成
  なので deny は実質 no-op = 将来 MCP を足したとき先回りで deny する defense-in-depth。

## quality loop hooks(`enableQualityLoopHooks`)

hook 活用計画 Phase 2(agent-tools#203)の品質ループ 2 本を **登録**する capability(#199)。
契約の正本は agent-tools の `docs/quality-loop-hooks.md`、hook body も agent-tools が両 home
へ配布する(登録=dotfiles・実体=agent-tools。`enableGitHubIsolatedReader` と同じ分界)。

- **極性は安全強化型**(true ほど agent が締まる: lint の steer と Stop の 1 回 block)。
  install / secret / network 権限を付与しないので `environment_kind_forbidden_capabilities`
  には**入れない**(`test-policy.sh` が全 kind で true を許容することを pin)。
- **1 capability が 2 つの AI home 両方**に登録を出す — Claude は managed
  `~/.claude/settings.json` の `hooks`、Codex は user 層 `~/.codex/hooks.json`。hooks object は
  `.chezmoitemplates/agent-hooks-json` で両 home 共有(`enableGitHubIsolatedReader` の
  PreToolUse と同居。各 capability は自分の event だけを足し、両方 false で `hooks` キー自体を
  出さない / Codex は file ごと消える)。
  - `PostToolUse` / matcher `Edit|Write` → `personal-fast-edit-check`(steering。失敗要約を
    `additionalContext` で返すだけで block しない・自動 fix しない)。
  - `Stop`(matcher なし。Claude Code は非対応・Codex は無視)→ `personal-changed-scope-qa`
    (best-effort gate。dirty scope に対し宣言 QA が未実行/失敗なら **新しい scope に 1 回だけ**
    exit 2 で block。`stop_hook_active` では block しない。cache で同一 scope は再検査しない)。
  - timeout は両 hook とも未指定(両 harness とも既定 600s)。check の実行時間は宣言側
    (checks.local.json)の責務なので dotfiles で値を発明しない。
- **repo 単位 opt-in**: 宣言の正本はユーザー所有・非 tracked の
  `~/.config/agent-tools/checks.local.json`(repo 実 path をキーに `edit_checks` /
  `qa_checks` を宣言)。宣言が無い repo では両 hook とも**無言 no-op**なので、登録だけ先行
  しても安全(fail-open)。repo 内の宣言 file は読まない(第三者 repo が任意 command を
  宣言できてしまうため)。
- **honest-label**: enforcement boundary ではない(hook 無効化・`--no-verify` 相当の迂回・
  fail-open)。#199 配備時の実測(Claude Code 2.1.258 / codex-cli 0.145.0):
  - Claude Code: PostToolUse の失敗要約は `additionalContext` で届く。Stop は失敗 scope で 1 回
    block(exit 2 + stderr がモデルに届く)、`stop_hook_active` の 2 回目は **Stop の
    additional context として警告が届く**(hook error 扱いではない。2.1.163 で Stop の
    `hookSpecificOutput.additionalContext` が公式対応)。稼働中 session も settings.json の変更を
    file watcher で自動反映。
  - Codex: `apply_patch` の payload に `file_path` が無く(docs)、宣言 edit check は**呼ばれない**
    = fast-edit-check は無言 no-op(agent-tools#203 に報告)。Stop の **block 経路**は動く(理由が
    モデルに届き続行)。**非 block の警告経路**(exit 0 + stdout の
    `hookSpecificOutput{hookEventName:"Stop"}`)は `codex exec --json` に invalid hook output の
    event は出なかったが、警告文がモデルに届くかは未検証(落ちても block にはならない)。
  - Codex は登録後に一度 `/hooks` trust が要る(registration ≠ activation。hook 定義を変えると
    再 trust。未 trust は silent skip)。
- **doctor**: 両 home の登録 + body presence(contents-blind)、`checks.local.json` の presence
  (**中身は読まない** — hook が実行する command を列挙する file なので)、best-effort の
  但し書きを report する。module 非 active / body 不在は dangling / fail-open として warn。
  capability=false でも live の settings.json / hooks.json に登録が残っていれば warn する
  (同一 home で personal → 他 profile に切り替えると module 非 active の managed file は
  prune されず hook が動き続けるため。git-hook-gates の lingering check と同型。残置の
  cleanup path 自体は #201)。
- **状態**: personal=true(#199 で両 home に登録)、work=false(agent-tools 未配備・
  claude-settings / codex-settings も非 active)。

## dormant capability の扱い(残す基準)

宣言だけで実装が無い capability を schema に置いてよいのは、次の**両方**を満たすときだけ
(2026-07-02 監査 + #145 で確定):

1. **owner のある生きた契約**: 実装先が issue で追跡されている接続契約
   (例: かつての `enableGitHubIsolatedReader` → #131 で追跡され #137 で配線済み)か、
   roadmap 上の placeholder(例: `enableAiTools`)であること。
2. **doctor 開示**: doctor がその「未実装 / 未配線」を warn として開示していること
   (AGENTS.md「宣言だけで何も駆動しない capability を作らない」の実体)。

**決定済み不使用・doctor 開示なし・owner なしの dormant は削除する**。schema に残すと
「宣言 = 何かが動く」という読みを裏切り、honest-labeling が信用できなくなる。削除しても
git 履歴から復元できる(削除済みの前例は #16 / #145 を参照)。

この基準は #151 で機械検査に接続した: schema の各 capability は `implemented: true|false`
を必須で持ち(欠落は validate が fail)、`implemented: false` は doctor.sh がその
capability 名に言及していることを validate が静的に検査する(source-text の proxy であって
挙動検査ではないが、「schema と profile に居るのに doctor が一度も触れない」型の穴は塞がる)。

### capability 追加チェックリスト

capability を 1 つ追加するときに触る場所(fail-closed の意図的コスト。validate が大半の
漏れを検出する):

1. `capabilities.schema.yaml` — `type` と `implemented` を宣言。
2. `profiles.yaml` — **全 profile** に値を記入(欠落は validate fail)。
3. 危険な権限なら `lib-policy.sh` の `environment_kind_forbidden_capabilities` と
   本 doc / README の表(3 箇所)+ `test-policy.sh` の cross-check に追加。
   安全強化型(true ほど締まる)は**入れない**(極性は sandbox 節参照)。
4. 実装の配線 — 原則 requires 方式(上の規範)。`implemented: false` で land する場合は
   doctor に未実装/未配線の warn を出す section を追加(AGENTS.md 規約 + #151 検査)。
5. テスト — render 影響があれば `test-render.sh` の期待 managed set、settings 影響が
   あれば `test-claude-settings.sh`、極性は `test-policy.sh`。
6. docs — 対応する docs の節(このファイル・関連 doc)。

## capability → 実装の gating 方式(規範)

capability が実装を gate する方式は **原則 requires 方式**(module の `requires:` で
path ごと管理対象を gate。`runtime` / `git-signing` / `supply-chain-npm` が例)。
ファイル自体は常に管理し**中身だけ**を capability で分岐させたい場合のみ、テンプレート内
分岐を使ってよい(`claude-settings` / `ssh-1password` が例)。その場合は capability true
かつ module inactive の組み合わせを doctor が dangling として警告する section を必ず併設する。

`requires:` の意味論は **boolean / enum の等値のみ**に保つ(不変条件)。module 活性判定は
`.chezmoiignore` の Go template と `lib-policy.sh` の `module_active_for_profile` に
二重実装されており、意味論を拡張すると両方の同時修正が必要になるため。

## Capability Modes

```yaml
npmHardeningMode:
  off: 何もしない
  report: doctor で状態だけ確認する
  enforce: ~/.npmrc を chezmoi で管理する

corepackMode:
  off: 何もしない
  report: doctor で状態だけ確認する
  enable: 明示的に Corepack を有効化する
```

## Initial Profiles

- `personal`: 個人Mac向け。副作用のある capability は明示的に許可する。
- `work`: 会社Mac向け開発構成。runtime / shell は許可し、install 系は無効(#146 で work-minimal / work-dev を統合)。

## Core に入れてよいもの

- 汎用 shell 設定
- 汎用 Git 設定
- 汎用 editor 設定
- doctor / preflight framework
- project template
- policy document
- secret reference の形式

## Core に入れないもの

- 会社名
- クライアント名
- 社内ドメイン
- VPN名
- private registry URL
- 社内GitHub / GitLab URL
- 内部host名
- 実token
- SSH秘密鍵
- 実credential

設定値だけでなく、存在を示すメタデータも情報として扱う。
