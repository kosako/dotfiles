# dotfiles

Mac 用のポータブル開発環境を [chezmoi](https://www.chezmoi.io/) で管理する personal repository。

ねらいは「どこでも同じ設定にする」ことではなく、**個人 / 会社 / クライアント / sandbox / AI agent の環境が、Git identity・secret・install policy・AI agent 権限の面で混ざらないこと**を最優先にすること。便利さよりも、境界を壊さないことを優先する。

> personal project だが repository は public。会社名・クライアント名・内部 URL・secret は core に一切含めない方針で運用している(後述の「安全モデル」)。

## なぜ

複数の環境(個人 Mac・会社 Mac・クライアント案件・実験用・AI agent 用)を扱うと、こういう事故が起きやすい。

- 会社の commit に個人のメールアドレスが乗る(またはその逆)。
- 会社マシンで個人用の package を勝手に入れる、secret に触れる。
- credential 入りの remote URL を push してしまう。
- AI agent が触ってよい範囲が曖昧なまま広がる。

この repository は、これらを**設定の作りからして起きにくく**する。判定の基準は「project をどの directory に置いたか」(`~/src/<context>/`)。

## いま管理しているもの

personal project として段階的に作っている。現時点の実装状況は次のとおり。

| 領域 | 状態 |
| --- | --- |
| Git identity 分離(context 別、fail-closed) | 実装済み・実機適用済み |
| policy / capabilities / profile 検証(fail-closed) | 実装済み |
| environmentKind による capability 制約の強制 | 実装済み |
| supply-chain(git credential scan / npm hardening / Corepack policy) | 実装済み(npm は未適用) |
| project templates / mise runtime | 実装済み(未適用) |
| doctor / preflight(report-only の健康診断) | 実装済み |
| agent-tools との report-only 連携 | 実装済み(opt-in) |
| zsh / VS Code / SSH の管理 | 未着手 |

「実機適用済み」は、現時点でこの author の Mac 上で `~/.gitconfig` が稼働しているという意味。shell・editor・SSH はまだ chezmoi 管理に載せていない。

## 考え方

```text
profile + environmentKind + modules + capabilities + policy
```

- **profile**: 用途別プリセット(`personal` / `work-minimal` / `work-dev`)。選びやすさのための入口で、権限そのものではない。
- **environmentKind**: `personal` / `work` / `client` / `sandbox` / `agent` の環境種別。許可される capability に制約をかける(下記)。
- **modules**: 機能単位。`paths:` で管理対象 file を宣言し、`.chezmoiignore` の生成を駆動する。
- **capabilities**: 実際に許可する操作・副作用(install、secret access、npm hardening mode など)。**何が起きるかは最終的に capabilities が決める**。
- **policy**: 何を許可・禁止するかの判断基準([docs/policy-model.md](docs/policy-model.md))。

### environmentKind は制約を強制する

environmentKind は飾りラベルではない。`validate-policy.sh` が、環境種別が禁止する capability を **hard fail** で検査する(違反した PR は CI で止まる)。

| environmentKind | false 必須の capability |
| --- | --- |
| work / client / agent | installPackages, installGuiApps, enableMacOSDefaults, allowSecretsAccess, allowNetworkTunnels, enableAiTools |
| sandbox | allowSecretsAccess |
| personal | (制約なし) |

つまり「会社 profile なのに package を自動 install する」ような設定は、構造的に作れない。

## ディレクトリ規約

開発 project はここに置く。この階層が Git identity・secret access・install policy・AI agent policy の判定基準になる。

```text
~/src/personal/<repo>
~/src/work/<org>/<repo>
~/src/client/<client>/<repo>
~/src/sandbox/<repo>
~/src/agent/<repo>
```

例えば `~/src/work/...` 配下では work の Git identity が自動で選ばれ、`~/src/` の外では identity が解決されず commit が(意図的に)失敗する。

## Quickstart

### 前提

- [chezmoi](https://www.chezmoi.io/)(home file の apply)
- [mikefarah/yq](https://github.com/mikefarah/yq) v4(policy script が使用)
- macOS

この repository は `~/dotfiles` に置く前提で運用している。

### 導入

```sh
# 1. profile を選んで init(default は無いので明示する)
chezmoi init --source ~/dotfiles --promptString profile=personal

# 2. 何が適用されるかを全て確認する
chezmoi diff --source ~/dotfiles

# 3. 初回は target を絞って適用する(例: gitconfig だけ)
chezmoi apply --source ~/dotfiles ~/.gitconfig
```

Git identity の実値は repository に入れない。使う context の identity file を手で置く。

```sh
mkdir -p ~/.config/git
cat > ~/.config/git/personal.gitconfig <<'EOF'
[user]
	name = Your Name
	email = you@example.com
EOF
```

### 日常

普段はほとんど意識しない。`~/src/<context>/` 配下に project を置いて commit すれば、その context の identity が自動で使われる。状態を確認したいときは次を実行する(どちらも何も変更しない)。

```sh
./scripts/doctor.sh personal    # 導入後の健康診断
./scripts/preflight.sh personal # 新マシン適用前の危険検知
```

## 何が得られるか

- **Git identity が context を跨いで漏れない。** `user.useConfigOnly=true` と `includeIf` により、context 外では identity が解決されず commit が止まる(間違った identity で commit するより安全側に倒れる)。
- **credential 入りの remote URL を Git が拒否する**(`transfer.credentialsInUrl=die`)。加えて既存 remote の credential を doctor が scan する(URL の値は表示しない)。
- **work / client 環境が構造的に lockdown される**(environmentKind の制約強制)。
- **supply-chain hardening。** npm の `ignore-scripts` などの強制、Corepack の暗黙有効化なし、runtime の自動 install なし([docs/supply-chain-npm.md](docs/supply-chain-npm.md) ほか)。
- **fail-closed かつ report-only。** unknown profile・不正データ・依存欠如は黙って進まず止まる。`doctor` / `preflight` は状態を報告するだけで何も変更しない。

## 安全モデル

- secret・SSH 秘密鍵・実 credential は repository に含めない。
- 会社名・クライアント名・社内 URL・private registry URL は core に入れない(public repository 前提)。
- unknown profile / module / capability は fail closed にする。
- `doctor` は副作用を持たない。`preflight` は導入前の危険検知に限定する。
- package install / GUI app install / macOS defaults / secret fetch / network tunnel / Git remote mutation / 既存 home 設定の上書きは、暗黙には実行しない。
- 別 repository(agent-tools)の status 取得は、別 repo のコード実行になるため `enableAgentToolsStatus` での明示 opt-in 時のみ行う([docs/ai-environment-boundary.md](docs/ai-environment-boundary.md))。

## repository の構成

- `scripts/` — policy 検証 / doctor / preflight / テスト([scripts/README.md](scripts/README.md))。
- `.chezmoidata/` — profiles / modules / capabilities schema。
- `docs/` — policy model、Git identity、supply-chain、runtime、AI 境界などの方針。
- `dot_*` / `private_dot_*` — chezmoi が管理する home file の source。

## 開発フロー

変更は Issue → branch → Pull Request → CI → merge で進める([docs/github-workflow.md](docs/github-workflow.md))。CI(`.github/workflows/validate.yml`)が policy 検証・各種テスト・shellcheck・chezmoi render を PR ごとに実行する。roadmap や作業ログは repository の外(Notion)で管理する。

## License

MIT
