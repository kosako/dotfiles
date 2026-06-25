# AI Environment Boundary

この文書は、`dotfiles` repository と、別 project として管理する AI skills / agents repository の責務境界を定義する。

## 基本方針

`dotfiles` は AI 実行環境の control plane として扱う。
AI skills / agents repository は AI が使う実体 asset の置き場として扱う。

```text
dotfiles
  policy / capabilities / directory convention / safety gates

AI skills / agents project
  skills / prompts / AGENTS.md templates / agent definitions / evals

secret store / local private config
  tokens / credentials / private endpoints / organization-specific values
```

AI agent の安全境界は `dotfiles` に置く。AI agent の振る舞いを作る素材は別 project に置く。

## dotfiles が持つもの

- AI agent の権限ポリシー。
- directory convention に基づく read / write / secret access policy。
- `enableAiPolicy` / `enableAiTools` などの capability。
- `doctor` / `preflight` による report-only check。
- AI tool を導入または有効化してよいかを決める gate。
- secret を含まない、profile-independent な policy document。
- 別 AI project を参照するための抽象的な設定項目。
- Claude Code ハーネスの環境設定(`settings.json` の model / permission / plugin / cost posture)を **personal の public-safe な範囲だけ** chezmoi 管理する control plane。これは「skill が使う tool-specific config template」(後述。agent-tools 側の責務)とは別物 ── ハーネスをどう振る舞わせるかは環境ポリシーであり dotfiles に属する。`settings.local.json`(Claude が動的に書く machine 固有値)と skill / instruction の配布物は管理しない。work / client の settings は別系統(暗号化バックアップ / 各マシン手設定)。

`dotfiles` は、AI tools を暗黙に install しない。AI skills / agents project を暗黙に clone / pull / sync しない。

## dotfiles が持たないもの

- 実際の skill body。
- 再利用用の prompt collection。
- 他 project に配布する `AGENTS.md` template。
- agent definition。
- tool-specific workflow。
- eval dataset。
- provider account 固有の設定。
- MCP server の private endpoint。
- 会社・クライアント固有の policy detail。
- token、credential、private key、secret reference の実値。

この repository 自身の `AGENTS.md` は例外ではない。これは `dotfiles` repository を安全に編集するための作業者向けルールなので、この repo に置く。
一方で、他 repository へ展開する `AGENTS.md` template や agent 運用ルールは AI skills / agents project に置く。

## AI skills / agents project が持つもの

- Codex / Claude / other AI tool 向け skills。
- `AGENTS.md` template。
- agent definitions。
- prompt templates。
- reusable workflows。
- skill / agent の README。
- evals、fixtures、golden outputs。
- tool-specific non-secret config templates。
- AI tool ごとの install / setup note。

AI skills / agents project は、`dotfiles` の policy を前提に動く。policy を上書きしない。

## secret store / local private config が持つもの

- API token。
- OAuth credential。
- private key。
- private registry URL。
- organization / client internal URL。
- private MCP endpoint。
- production access detail。

これらは `dotfiles` にも AI skills / agents project にも置かない。

## 連携ルール

- `dotfiles` は AI skills / agents project の存在を report してよい。
- `dotfiles` は AI skills / agents project の path を表示してよい。
- `dotfiles` は AI skills / agents project を自動更新しない。
- `dotfiles` は AI skills / agents project の secret を読まない。
- `dotfiles` の `doctor` は `~/src/agent/agent-tools`(既定。非標準な checkout 先は `AGENT_TOOLS` env で override 可)の presence を report する。status(`scripts/status.sh --json`、report-only、`contract_version: 2`)の読み取りは別 repo のコード実行になるため、`enableAgentToolsStatus` capability での明示 opt-in 時のみ実行し、安全な summary(`conflict` / `stale` / 失敗 check 等は warning)を出す(Issue #7)。clone / pull / sync は一切しない。
- AI skills / agents project は `dotfiles` の capability を前提条件として参照してよい。
- AI skills / agents project が install、network tunnel、secret access を必要とする場合は、`dotfiles` 側の capability と approval policy に従う。

連携は 2 層に分かれる。混同しない:

- **配布層**(AI skills / agents project → AI tool home): skill / instruction を `~/.claude` / `~/.codex` などへ配置するのは AI skills / agents project 側の責務(build / sync)。`dotfiles` はこの**配布物(skill / instruction)**を作らない。配布の正本は当該 project 側の docs。(例外: ハーネス設定 `~/.claude/settings.json` は配布物ではなく**環境設定**なので、personal の public-safe な範囲だけ `dotfiles` が control plane として管理する。上の「dotfiles が持つもの」参照。)
- **監視層**(`dotfiles` → AI skills / agents project): `dotfiles` の `doctor` が presence と、opt-in 時に status の health を read-only で覗くだけ(上の箇条書き)。書き込み・clone・sync はしない。

監視層の status 読み取りは既定で off(`enableAgentToolsStatus: false`)。実運用で有効化する手順(presence path の整合・opt-in・status の実態確認)は Issue #73 で検討する。

推奨する置き場所:

```text
~/src/agent/<repo>
```

ただし、単なる個人用 prompt library で agent 実行環境と切り離す場合は `~/src/personal/<repo>` でもよい。
work / client 固有の AI asset は `~/src/work/...` または `~/src/client/...` に置き、外部送信や共有の policy を優先する。

## 昇格・分離の判断基準

AI skills / agents project から `dotfiles` に昇格してよいもの:

- profile / capability の安全判定に必要なもの。
- AI project が存在しなくても必要な baseline policy。
- 会社・クライアント固有情報を含まないもの。
- secret を含まないもの。
- 変更頻度が低く、環境基盤として安定しているもの。

`dotfiles` から AI skills / agents project に分離すべきもの:

- prompt や skill の本文。
- tool-specific な使い方。
- agent の振る舞いを直接決める instruction。
- 変更頻度が高い実験的な設定。
- 個人・会社・クライアント文脈に依存するもの。
- それ単体で private context を推測できるもの。

## 初期実装の扱い

現在の `dotfiles` では、AI tools は後続 module とする。
ただし、AI agent の権限ポリシーは初期段階から定義する。

初期状態:

```text
enableAiPolicy: true
enableAiTools: false
```

`enableAiPolicy=true` は policy document と report-only check を有効にする。
`enableAiTools=false` は AI tool install / AI asset sync / agent setup を行わないことを意味する。

## Claude Code sandbox の射程と限界(`enforceAiSandbox`)

`enforceAiSandbox` capability は、managed な `~/.claude/settings.json` に Claude Code の native
sandbox ブロック(`sandbox.enabled` / `failIfUnavailable` / `allowUnsandboxedCommands` /
`network.allowedDomains`)を出す。enforcement は Claude Code 自身が settings から内部適用する
(外側で包む別物 `@anthropic-ai/sandbox-runtime` ではない)。

射程を正確に把握する(過大評価しない):

- **対象は Bash tool の subprocess の fs + network のみ**。`Read` / `Edit` / `Write` /
  `WebFetch`、MCP server、hooks は **sandbox の外**(これらは `permissions` で律する)。
- network は **per-domain の hostname allowlist** で、**TLS 終端しない**(暗号化内容は検査せず、
  hostname だけで allow/deny する。domain fronting 等は素通りしうる)。既定 allowlist は
  public-safe な**空**。
- strict 化は **2 軸**で fallback を塞ぐ(`enforce` の名に合わせ、使えない環境で黙って
  素通りさせない):
  - `allowUnsandboxedCommands: false` — sandbox 内で個々のコマンドを unsandboxed へ
    fallback させない(既定 `true`)。
  - `failIfUnavailable: true` — sandbox 自体が初期化できない(依存不足・未対応 platform)
    ときに、既定の「warning して全コマンドを unsandboxed 実行」を止め、hard fail にする
    (既定 `false`)。これが無いと enforce を名乗っても unavailable 時に静かに無効化される。

OS 全体の強制(`@anthropic-ai/sandbox-runtime` / 自作 Seatbelt profile / devcontainer の
network firewall)は **別 tier** で、今の `dotfiles` には入れない(将来の opt-in)。gate・極性・
既定値の正本は [policy-model](policy-model.md) の「Claude Code sandbox」。出典:
code.claude.com/docs/en/sandboxing。Issue #50。

## GitHub injection 防御の射程と限界(`gateGitHubMcp` / `enableGitHubIsolatedReader`)

AI agent に GitHub の Issue / PR を読ませるときの **runtime / consumption-side prompt
injection** 防御(epic #119)。capability 正本は [policy-model](policy-model.md)。
**設計の正本は private 設計メモ**で、この repo は public-safe な実装面だけを扱う。

Phase 1 は **配管だけ**を land した(既定 false・render は byte-identical)。**Phase 2 で
personal の `gateGitHubMcp` を true** に反転し、github MCP deny を live 化した(render→diff→
実機 dry-run の検証ゲート済み。github MCP は現状未構成なので実質 no-op = defense-in-depth)。
`enforceAiSandbox` / `enableGitHubIsolatedReader` は全 profile false 継続。有効化しても
下記のとおり **enforcement boundary ではない**:

- `gateGitHubMcp`: managed `~/.claude/settings.json` の `permissions.deny` に `mcp__github`
  を足し、GitHub MCP server を丸ごと deny する(`claude-settings` module が active な
  profile のみ実効。dangling は doctor が report)。
- GitHub 由来の deny は **3 tier**(#119 Phase 2 task B。専用 capability は作らない):
  - **(1) never-legit secret floor は無条件**(常時 render)。SSH 秘密鍵読取(`~/.ssh`)・
    全 env dump(`printenv` / `env`)・GitHub Actions secret(`gh secret` / `gh api *secrets*`)は
    誰も Claude に正規に頼まず、deny は Claude の Bash tool にしか効かない(人間のターミナル
    非影響)ので、`enforceAiSandbox` を待たず常時 deny する(personal で今日 live)。
  - **(2)** `gateGitHubMcp`(上記の MCP deny)。
  - **(3) human-legit な write は `enforceAiSandbox` に相乗り**。main / master への直 push と
    `.env` 読取(`cat *.env*` / `Read(//**/.env*)`)を deny、release 操作と branch protection /
    rulesets 変更を ask にする。人間が正規に Claude に頼みうるので常時 ON にはせず、制限
    context(= 下記「制限 context の接続規約」/ Phase 3 [#131])に寄せる。なお main-push deny
    の matcher(`git push * main|master`)は **leaky steering**: ` main` 末尾の explicit 形しか
    拾わず bare `git push` / `git push origin HEAD` / refspec(`HEAD:main`)は抜ける(Claude Code
    の matcher セマンティクスを #119 で裏取り。`*` は空白跨ぎ・末尾 ` main` は word boundary 固定・
    複合コマンドは分割評価)。真の「main 直 push を止める」hard 層は server-side branch protection
    か Phase 3 の隔離 reader であり、matcher を enumeration で広げて塞ぐのは command-string ≠
    enforcement のアンチパターンゆえ **しない**。

**boundary でない理由(過大評価しない)**:

- command-string matcher は **steering であって enforcement ではない**。`$()`・等価な
  read path・別経路の MCP・subagent のギャップ(PreToolUse 不発 [anthropics/claude-code#21460])
  で迂回しうる。
- context-gated な write(他人由来の untrusted が無い clean なときだけ comment / label /
  PR create / push を自律許可)は **Phase 2 の PreToolUse hook** が要るため Phase 1 には
  **無い**(意図的)。
- egress は `enforceAiSandbox` の network allowlist = **hostname best-effort**(TLS 終端せず、
  DNS exfil は素通り。上の sandbox 節)。
- **Phase 1 には trifecta(untrusted 読取 × secret × egress)を構造的に断つ hard 層が無い**。
  hard 層 ── 隔離 reader / network egress sandbox / token の物理分離 ── は Phase 3 [#131]。
  `enableGitHubIsolatedReader` は Phase 3 [#131] の隔離 reader 用に **宣言だけ**してある
  (declared, not enforced。doctor が warn)。

**subagent への適用(deny は継承・親 hook は subagent 不発)**: `permissions.deny` は main session
だけでなく **subagent にも継承される**(Claude Code が subagent に親会話の permission context を
引き継がせる)。よって `mcp__github` deny と secret 床は **subagent からも効く** ── injection で
subagent を spawn して回避する経路は塞がっている。これは **settings.json(親 session)側の
`PreToolUse` hook が subagent の個別 tool call に継承発火しない**([anthropics/claude-code#21460])
のとは別レイヤ:**`permissions.deny`(enforcement)は subagent をカバーするが、親 session 側の
hook(steering)は subagent の tool call には継承発火しない**(subagent 固有の hook は agent
frontmatter で別途定義できるが、それは agent-tools 領分)。一方 `permissions.deny` は session 一律
なので、「main は許可・subagent だけ非付与」(例: untrusted な GitHub を読む subagent からだけ
`WebFetch` を外す)は settings.json では表現できない ── それは agent 定義(agent-tools 領分)/
Phase 3 の隔離 reader の役割になる。

**token 分離の実態(P0-B・best-effort)**: 「untrusted を読む間 `GH_TOKEN` を env から外せば
private-token を hard に切れる」は **この環境では成り立たない**。実機の `gh` は `GH_TOKEN`
未設定でも **keyring 認証**(macOS keychain)で動くため、env を外しても認証は残る = 偽の安心。
真に切るには untrusted-read 用 shell で `GH_CONFIG_DIR` を隔離し、全認証源(keychain / OAuth /
git credential helper / MCP token / curl)を遮断する **session 隔離**が要る = hard 化は Phase 3。
これは runtime / invocation そのものなので dotfiles(control plane)には置かず、**Phase 3 [#131]
への単一 hand-off** とする。acceptance criteria は「隔離 session で `gh` / git の認証済み
private access が失敗することを実機検証する」。dotfiles 側で `GH_CONFIG_DIR` 隔離 shell や
safe-gh wrapper は land しない(env-strip だけの半端な実体は inert = 偽の安心になる)。

**制限 context の接続規約(#119 Phase 2 で確定・実体は agent-tools / Phase 3 [#131])**: tier3 の
human-legit write gate を daily driver 全体に被せず「untrusted な GitHub を読む制限 context」に
だけ効かせる方法は、`permissions.deny` が **session 一律**(「main は許可・制限 context だけ deny」を
1 つの settings 内で表現できない)である以上、**別 session を立てる**ことに帰着する。その別 session の
実体(launcher / 隔離起動)は invocation = agent-tools 領分(Phase 3)に置き、**dotfiles は launcher を
持たない**。接続規約: 制限 context は agent-tools が **`claude --settings <path>` で dotfiles の managed
template を基底に重ねて** 起動する。重ねる中身は **write-gate のみ**(secret floor + `mcp__github`
deny + tier3 の human-legit write deny)で、**`enforceAiSandbox` の egress sandbox ブロックは含めない**
── egress は別 tier(Phase 3 の OS egress firewall)。permission deny(Claude tool)・network egress
(Bash subprocess)・token 隔離(OS / session credential)は同じ file に書けても **同じ enforcement
layer ではない**ので束ねない。deny floor は managed template を single source とし、agent-tools 側で
再発明・drift させない。dotfiles はこの規約を **doc として持つだけ**で、制限 settings file 自体は
render しない(起動主体が dotfiles に無い render は dead-render になる)。

**trust 基点**は `is_self`(login + numeric id)のみ。collaborator / bot は既定 untrusted で、
評価順は is_self → is_bot → association(bot は association=NONE に化けうるため)。read /
write の既定方針は [ai-policy](ai-policy.md)。trust 基点の実値は非コミットの
`~/.config/dotfiles/github-trust.local`(置き場と backup / doctor は
[local-overrides](local-overrides.md))。出典: epic #119。

## 禁止事項

- `dotfiles` から AI skills / agents project を暗黙に clone / pull する。
- `dotfiles` から AI tool を暗黙に install する。
- `dotfiles` に skill body を混ぜる。
- `dotfiles` に provider credential を置く。
- `dotfiles` に work / client 固有の AI policy detail を置く。
- AI skills / agents project が `dotfiles` の capability gate を迂回する。
