# dotfiles

Mac用ポータブル開発環境を管理する `chezmoi` repository。

目的は、個人Mac・会社Mac・クライアント環境・sandbox・AI agent 環境で、共通化してよい設定だけを安全に共有すること。

「全部をどこでも同じにする」のではなく、Git identity、secret、install policy、AI agent の権限が混ざらないことを優先する。

## 考え方

基本モデル:

```text
base + modules + profiles + machine + policy + capabilities
```

- `profile`: ユーザーが選びやすい用途別プリセット。
- `environmentKind`: `personal` / `work` / `client` / `sandbox` / `agent` の環境種別。
- `modules`: 使う機能のまとまり。
- `capabilities`: 実際に許可する操作や副作用。
- `policy`: 何を許可し、何を禁止するかの判断基準。

`profile` は権限そのものではない。実際に何を許可するかは `capabilities` で判定する。

## プロジェクトの置き場所

開発 project は以下に置く。

```text
~/src/personal/<repo>
~/src/work/<org>/<repo>
~/src/client/<client>/<repo>
~/src/sandbox/<repo>
~/src/agent/<repo>
```

この階層を Git identity、secret access、install policy、AI agent policy の判定基準にする。

## Profiles

初期 profile はこの3つ。

- `personal`
- `work-minimal`
- `work-dev`

確認:

```sh
./scripts/validate-policy.sh personal
./scripts/preflight.sh personal
./scripts/doctor.sh personal
```

## いまのスコープ

この初期 scaffold では、まだ以下を実行しない。

- package install
- GUI app install
- macOS defaults apply
- `direnv allow`
- secret fetch
- Git remote mutation
- 既存 home 設定の削除や上書き

最初に作るのは policy / profiles / capabilities / preflight / doctor の土台。

## Chezmoi

まず差分を確認する。

```sh
chezmoi diff --source ~/dotfiles
```

適用は差分確認後に行う。

```sh
chezmoi apply --source ~/dotfiles
```

## 安全ルール

- secret は repository に含めない。
- SSH 秘密鍵は repository に含めない。
- 会社名・クライアント名・社内URL・private registry URL は core に入れない。
- unknown profile / module / capability は fail closed にする。
- `doctor` は副作用を持たない。
- `preflight` は導入前の危険検知に限定する。
- npm hardening の方針と `ignore-scripts=true` の逃げ道は [docs/supply-chain-npm.md](docs/supply-chain-npm.md) を参照する。
- Corepack は暗黙に enable しない。方針は [docs/supply-chain-corepack.md](docs/supply-chain-corepack.md) を参照する。

## GitHub Workflow

Phase 2 以降の作業は Issue / Pull Request で管理する。

```text
Notion: roadmap / design background / worklog / handoff
GitHub Issues: implementation scope / done criteria / validation plan
GitHub PRs: change summary / validation result / residual risk / merge record
```

詳細は [docs/github-workflow.md](docs/github-workflow.md) を参照する。

## License

MIT
