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

`.chezmoidata/*.yaml`(profiles / modules / capabilities.schema / packages)の読み取りは shell script 側では mikefarah/yq v4 で行う(chezmoi template 側は Go template が読む)。yq が無い・別 variant の場合は `require_yq` が fail closed する。profile / module / capability 名は `strenv()` 経由で渡し、yq 式へ展開しない(injection 防止)。

`packages`(`.chezmoidata/packages.yaml`)は software catalog。各 entry の `source`(brew_formula / brew_cask / npm_global / go_install / mas / manual)と canonical id を宣言する。`validate-policy.sh` が source の妥当性・go_install/mas の pkg 必須・name 重複を fail closed で検査する。実機との drift(未 install / 台帳外 / source ズレ)は `doctor.sh` が report-only で報告する(install action は後続 phase)。

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
| work / client / agent | installPackages, installGuiApps, enableMacOSDefaults, allowSecretsAccess, allowNetworkTunnels, enableAiTools |
| sandbox | allowSecretsAccess |
| personal | (制約なし) |

- 表は `scripts/lib-policy.sh` の `environment_kind_forbidden_capabilities` が持つ。
- `personal` は明示許可前提なので無制約。`agent` は profile がまだ無いが、最小権限を明示するため先行定義してある(agent profile 追加時に即発効)。
- enum capability(`npmHardeningMode` など)への制約は今回の対象外(必要なら別 follow-up)。
- 将来 work 等で禁止 capability を正当に許したくなった場合は、warning で迂回せず、この表自体を見直す。

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
- `work-minimal`: 会社Mac向け最小構成。install 系は無効。
- `work-dev`: 会社Mac向け開発構成。runtime / shell は許可し、install 系は無効。

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
