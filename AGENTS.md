# AGENTS.md

この repository で作業するエージェント向けの運用ルール。

## 基本方針

- この repo は単なる dotfiles 集ではなく、個人・会社・クライアント・sandbox・AI agent 環境を安全に分けるための環境基盤として扱う。
- 便利さよりも、Git identity、secret、install policy、AI agent 権限が混ざらないことを優先する。
- package install、GUI app install、macOS defaults、secret access、network tunnel、Git remote mutation は暗黙に実行しない。
- `doctor` は副作用なしを維持する。
- `preflight` は導入前の危険検知に限定する。

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

最低限、変更内容に応じて以下を実行する。

```sh
./scripts/validate-policy.sh personal
./scripts/validate-policy.sh work-minimal
./scripts/validate-policy.sh work-dev
bash -n scripts/lib-policy.sh scripts/validate-policy.sh scripts/preflight.sh scripts/doctor.sh
```

`doctor` / `preflight` は環境依存の warning が出ることがある。policy violation と report-only warning を混同しない。
