# scripts

この directory の script は、dotfiles を host に適用する前後の policy 検証を担当する。
package install、GUI app install、macOS defaults、secret fetch、Git remote mutation は行わない。

## 終了コード方針

```text
report-only warning: exit 0
policy violation: exit 1
script/runtime failure: exit 1
CLI usage error: exit 2
```

`[warn]` は現状報告または注意喚起であり、それだけでは失敗扱いにしない。
unknown profile / module / capability や capability enum の不正値は policy violation として fail closed する。

## validate-policy.sh

`.chezmoidata/profiles.yaml`、`.chezmoidata/modules.yaml`、`.chezmoidata/capabilities.schema.yaml` の整合性を検証する。

```sh
./scripts/validate-policy.sh personal
./scripts/validate-policy.sh --all
./scripts/validate-policy.sh --list-profiles
```

検証内容:

- profile が存在すること。
- `environmentKind` が許可された値であること。
- profile が参照する module が定義済みであること。
- profile が参照する capability が定義済みであること。
- すべての定義済み capability が profile に存在すること。
- boolean capability が `true` または `false` であること。
- enum capability が schema の `values` に含まれること。

## preflight.sh

導入前の危険検知を行う。既存 home file、必要 command、project root などを確認する。
副作用は持たない。既存 file や command 不足の warning は report-only として exit 0 のままにする。

```sh
./scripts/preflight.sh personal
```

policy validation が失敗した場合は exit 1。

## doctor.sh

導入後または現状環境の健康診断を行う。chezmoi、Git、npm、Corepack、runtime、VS Code、1Password、project root の状態を表示する。
副作用は持たない。設定不足や未導入 command の warning は report-only として exit 0 のままにする。

```sh
./scripts/doctor.sh personal
```

policy validation が失敗した場合は exit 1。

## test-policy.sh

外部 test framework を使わずに policy validation の fail-closed 挙動を検証する。
一時 directory に data files と scripts をコピーし、fixture を壊して `validate-policy.sh` が失敗することを確認する。

```sh
./scripts/test-policy.sh
```

検証内容:

- `validate-policy.sh --all` が全 profile を検証すること。
- enum capability の許可値を正しく受け入れること。
- unknown profile を拒否すること。
- unknown module を拒否すること。
- unknown capability を拒否すること。
- capability enum の不正値を拒否すること。

## lib-policy.sh

他 script から source される共通 helper。
data file path、profile/module/capability 取得、出力 helper、command availability check を提供する。
