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

`.chezmoidata/*.yaml`(profiles / modules / capabilities.schema)の読み取りは shell script 側では mikefarah/yq v4 で行う(chezmoi template 側は Go template が読む)。yq が無い・別 variant の場合は `require_yq` が fail closed する。profile / module / capability 名は `strenv()` 経由で渡し、yq 式へ展開しない(injection 防止)。

## Rules

- profile 名だけで副作用を許可しない。
- unknown profile / module / capability は fail closed。
- destructive な操作は work / client でデフォルト無効。
- secret access、network tunnel、AI tools は personal でも明示的に扱う。
- boolean で足りない capability は enum にする。
- `report` は検査のみ、`enforce` / `enable` は実際の適用を意味する。

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
