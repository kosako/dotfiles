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
sandbox ブロック(`sandbox.enabled` / `allowUnsandboxedCommands` / `network.allowedDomains`)を
出す。enforcement は Claude Code 自身が settings から内部適用する(外側で包む別物
`@anthropic-ai/sandbox-runtime` ではない)。

射程を正確に把握する(過大評価しない):

- **対象は Bash tool の subprocess の fs + network のみ**。`Read` / `Edit` / `Write` /
  `WebFetch`、MCP server、hooks は **sandbox の外**(これらは `permissions` で律する)。
- network は **per-domain の hostname allowlist** で、**TLS 終端しない**(暗号化内容は検査せず、
  hostname だけで allow/deny する。domain fronting 等は素通りしうる)。既定 allowlist は
  public-safe な**空**。
- `allowUnsandboxedCommands: false` で sandbox 外への fallback を塞ぐ(脱出させない)。
  既定は `true` なので、明示的に false にして初めて strict になる。

OS 全体の強制(`@anthropic-ai/sandbox-runtime` / 自作 Seatbelt profile / devcontainer の
network firewall)は **別 tier** で、今の `dotfiles` には入れない(将来の opt-in)。gate・極性・
既定値の正本は [policy-model](policy-model.md) の「Claude Code sandbox」。出典:
code.claude.com/docs/en/sandboxing。Issue #50。

## 禁止事項

- `dotfiles` から AI skills / agents project を暗黙に clone / pull する。
- `dotfiles` から AI tool を暗黙に install する。
- `dotfiles` に skill body を混ぜる。
- `dotfiles` に provider credential を置く。
- `dotfiles` に work / client 固有の AI policy detail を置く。
- AI skills / agents project が `dotfiles` の capability gate を迂回する。
