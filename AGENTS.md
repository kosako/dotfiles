# AGENTS.md

この repository で作業するエージェント向けの運用ルール。

## 基本方針

- この repo は単なる dotfiles 集ではなく、個人・会社・クライアント・sandbox・AI agent 環境を安全に分けるための環境基盤として扱う。
- 便利さよりも、Git identity、secret、install policy、AI agent 権限が混ざらないことを優先する。
- package install、GUI app install、macOS defaults、secret access、network tunnel、Git remote mutation は暗黙に実行しない。
- `doctor` は副作用なしを維持する。
- `preflight` は導入前の危険検知に限定する。
- 新しい capability は、最低限 `doctor` が読む section を同梱して導入する。宣言だけで何も駆動しない capability(宣言と実装の乖離)を作らない。後続 module 用の placeholder capability も、`doctor` が「未実装」を report する形にする。

## GitHub 運用

Phase 2 以降の作業は、原則として Issue 作成、branch 作成、Pull Request、merge の順で進める。

詳細は `docs/github-workflow.md` に従う。

- Notion は roadmap、設計背景、作業ログ、引き継ぎに使う。
- GitHub Issues は実装単位の scope、done criteria、validation plan に使う。
- GitHub Pull Requests は変更内容、検証結果、残リスク、merge 記録に使う。
- `main` への直接 commit は例外扱いにする。
- script、policy、capability、profile、install、secret、network、AI agent 境界に関わる変更は PR 必須。
- main 直 commit の例外を使った場合は、Notion worklog または follow-up Issue に理由を残す。
- **AI(エージェント)が作る commit は署名しない(`--no-gpg-sign` を付ける)。** personal context は `commit.gpgsign=true` で人間の commit は SSH 署名され GitHub Verified になるが(`docs/git-identity.md`)、AI commit を署名すると op-ssh-sign の Touch ID が必要になり、PR 確認後の自動 merge 等の自動化が止まる。署名は**人間の attest** に限り、AI commit は署名対象外とする。署名 on/off は per-context(personal=署名 / work・client=なし)で per-repo ではなく、AI 非署名は commit 単位の opt-out(repo/context とは別軸)。

## 作業ログ

作業した日は、日単位の作業ログを残す。作業ログは repository には置かず、外部の project notes に保存する。

保存先:

```text
Notion dotfiles project page
```

日付は Asia/Tokyo 基準にする。

### 作業開始時

- 今日の作業ログが Notion にあるか確認する。
- なければ `作業ログ YYYY-MM-DD` として作成する。
- 既にある場合は、最新の内容を読んでから作業する。
- 前日の作業から続く場合は、前回の `Next` / `Open Questions` を確認する。

### 作業終了時

その日のログに以下を追記または更新する。

- `Summary`: 何をしたか。
- `Changes`: 変更した主なファイルや内容。
- `Validation`: 実行した検証。
- `Decisions`: その日に決めたこと。
- `Next`: 次にやること。
- `Open Questions`: 未決事項。

### ログに書かないもの

- secret
- token
- password
- private key
- private registry URL
- 会社・クライアント固有の内部URL
- 会社・クライアント固有の credential 情報

必要な場合は、具体値ではなく抽象化した説明に留める。

### repo に置かないもの

- `worklog/`
- 日次作業ログ
- 長い設計背景
- 試行錯誤
- VM 個別環境のメモ

## コミット前チェック

検証コマンドは `docs/github-workflow.md` の「最低限の validation」に従う。CI(`.github/workflows/validate.yml`)も同じ内容を実行するため、コマンド一覧はそちらを single source of truth とし、ここには重複して書かない。

`doctor` / `preflight` は環境依存の warning が出ることがある。policy violation と report-only warning を混同しない。
