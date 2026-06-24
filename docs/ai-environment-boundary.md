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
- GitHub 由来の write / secret 操作の deny / ask は **`enforceAiSandbox` に相乗り**する
  (#119 の決定。専用 capability を作らない)。secret 露出(`printenv` / `gh secret` /
  `cat *.env*` / `Read(//**/.env*)` / `~/.ssh`)と main / master への直 push を deny、
  release 操作と branch protection / rulesets 変更を ask にする。

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
  hard 層 ── 隔離 reader / network egress sandbox / token の物理分離 ── は Phase 2 / 3。
  `enableGitHubIsolatedReader` は Phase 3 の隔離 reader 用に **宣言だけ**してある
  (declared, not enforced。doctor が warn)。

**token 分離の実態(P0-B・best-effort)**: 「untrusted を読む間 `GH_TOKEN` を env から外せば
private-token を hard に切れる」は **この環境では成り立たない**。実機の `gh` は `GH_TOKEN`
未設定でも **keyring 認証**(macOS keychain)で動くため、env を外しても認証は残る = 偽の安心。
真に切るには untrusted-read 用 shell で `GH_CONFIG_DIR` を隔離し、全認証源(keychain / OAuth /
git credential helper / MCP token / curl)を遮断する **session 隔離**が要る = hard 化は Phase 2 / 3。

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
