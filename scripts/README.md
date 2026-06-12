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
`doctor.sh` / `preflight.sh` は冒頭の policy validation が失敗した場合のみ exit 1 で、それ以外は warning があっても常に exit 0(report-only)。

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

導入前の危険検知を行う。既存 home file、既存 Git config(`~/.gitconfig`、`~/.config/git/config`、global identity の設定有無。値は表示しない)、必要 command、project root などを確認する。
副作用は持たない。既存 file や command 不足の warning は report-only として exit 0 のままにする。

```sh
./scripts/preflight.sh personal
```

policy validation が失敗した場合は exit 1。

## doctor.sh

導入後または現状環境の健康診断を行う。chezmoi、Git、Git identity context(各 context の identity file が存在するか、意図的に未設定か)、Git remote URL(credential らしき userinfo の有無。URL の値は表示しない)、npm、Corepack、runtime、VS Code、1Password、project root の状態を表示する。
副作用は持たない。設定不足や未導入 command の warning は report-only として exit 0 のままにする。
remote URL scan の方針は `docs/supply-chain-git.md`、npm hardening の検査は `docs/supply-chain-npm.md`、Corepack の検査は `docs/supply-chain-corepack.md` に従う。
`npmHardeningMode=enforce` の profile では、期待する npm config 値と現在値の不一致を `[warn]` で報告する(apply 前は不一致が正常)。

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

## test-gitconfig.sh

`dot_gitconfig.tmpl` の Git identity 安全境界を検証する。

```sh
./scripts/test-gitconfig.sh
```

検証内容:

- template に `user.useConfigOnly = true` と `transfer.credentialsInUrl = die` が含まれること。
- 全 context(personal / work / client / sandbox / agent)の `includeIf` と include path が定義されていること。
- template に identity 値(`name =` / `email =`、email らしき値)が含まれないこと。
- template に chezmoi のテンプレート構文が含まれないこと(fixture は raw template を git に直接渡すため)。
- local fixture で、known root 外では commit が identity 未解決を理由に失敗すること。
- local fixture で、`~/src/personal/` 配下では identity file の identity が解決されること。
- credential 入り remote URL が拒否されること。
- credential らしき remote URL(`scheme://user:password@host`)を `git_remotes_with_credentials` が検出すること。
- credential なし・username のみの remote URL は誤検出しないこと。

fixture は一時 directory に作り、実際の home や global Git config には触れない。

## test-npmrc.sh

`dot_npmrc.tmpl` と `.chezmoiignore` の npm hardening 設定を静的に検証する。

```sh
./scripts/test-npmrc.sh
```

検証内容:

- template が `npmHardeningMode=enforce` でのみ内容を出力するよう gate されていること。
- 期待する hardening 設定(`ignore-scripts=true` など)が定義されていること。
- token、registry 設定が含まれないこと。
- `.chezmoiignore` が enforce 以外で `.npmrc` を管理対象外にすること。
- `.chezmoiignore` が repo 管理用 file(README、docs、scripts、templates など)を home に apply しないこと。
- `.chezmoiignore` が `enableRuntimeManagement=false` で mise config を管理対象外にすること。
- template の設定値と `doctor.sh` の enforce 期待値が一致していること。

chezmoi が未導入でも実行できるよう、render はせず静的検査に留める。

## test-render.sh

chezmoi で各 profile を throwaway destination に render(apply)し、managed target 一覧を期待値と比較する。実 home には触れない。

```sh
./scripts/test-render.sh
```

検証内容:

- 全 profile が template エラーなしで apply できること。
- 各 profile の managed target 一覧が期待値と一致すること(profile を追加・変更したら期待値の更新が必要)。
- typo profile が known profile 一覧つきのエラーで fail すること。
- profile 未設定が init 誘導メッセージで fail すること。
- 非対話 init(`--promptString profile=<name>`)が動くこと。
- profile 無回答の init が fail すること(default を持たない)。

chezmoi が必要(CI では version pin して導入する)。

## lib-policy.sh

他 script から source される共通 helper。
data file path、profile/module/capability 取得、出力 helper、command availability check、Git remote credential 検出(`git_remotes_with_credentials`。remote 名のみを出力し、URL 値は出力しない)を提供する。
