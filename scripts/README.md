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
- module の `paths:` が home 相対であること。同一 path を複数 module が宣言していないこと。
- module の `requires:` の capability が定義済みで、値が schema の型に適合すること。
- `requires:` があるのに `paths:` がない module は fail(条件が何も駆動しないため)。

## preflight.sh

導入前の危険検知を行う。既存 home file、既存 Git config(`~/.gitconfig`、`~/.config/git/config`、global identity の設定有無。値は表示しない)、必要 command、project root などを確認する。
副作用は持たない。既存 file や command 不足の warning は report-only として exit 0 のままにする。

```sh
./scripts/preflight.sh personal
```

policy validation が失敗した場合は exit 1。

## doctor.sh

導入後または現状環境の健康診断を行う。chezmoi、Git、Git identity context(各 context の identity file が存在するか、意図的に未設定か)、Git remote URL(credential らしき userinfo の有無。URL の値は表示しない)、npm、Corepack、runtime、VS Code、1Password、managed-path orphan(managed-by header があるのに現 profile で管理対象でない file。profile 切替の残骸検出)、AI policy(`enableAiPolicy` / `enableAiTools` の現状)、network tunnels(`allowNetworkTunnels` と tunnel tool の存在)、agent-tools(report-only。`~/src/agent/agent-tools` の presence を表示し、`enableAgentToolsStatus=true` の opt-in 時のみ status contract(`scripts/status.sh --json`)を実行して安全な summary を出す。clone / pull / sync はしない)、private-backup(report-only。public baseline の各 target の存在と marker からのバックアップ有無/最終日時を表示。local 補足は **存在のみ**で中身・件数は出さない。アーカイブや captured file の中身は読まない)、project root の状態を表示する。
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

`dot_gitconfig` の Git identity 安全境界を検証する。

```sh
./scripts/test-gitconfig.sh
```

検証内容:

- source に `user.useConfigOnly = true` と `transfer.credentialsInUrl = die` が含まれること。
- 全 context(personal / work / client / sandbox / agent)の `includeIf` と include path が定義されていること。
- source に identity 値(`name =` / `email =`、email らしき値)が含まれないこと。
- source に chezmoi のテンプレート構文が含まれないこと(fixture は source を git に直接渡すため)。
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
- `.chezmoiignore` が module の `paths:` からループ生成されていること。
- `.chezmoiignore` が repo 管理用 file(README、docs、scripts、templates など)を home に apply しないこと。
- modules.yaml の宣言で `.npmrc` が `npmHardeningMode=enforce` のみ、mise config が `enableRuntimeManagement=true` のみで管理されること。
- template の設定値と `doctor.sh` の enforce 期待値が一致していること。

chezmoi が未導入でも実行できるよう、render はせず静的検査に留める。

## test-doctor.sh

fixture HOME で doctor の managed-path orphan 検出を検証する。実 home には触れない。

```sh
./scripts/test-doctor.sh
```

検証内容:

- managed-by header があり現 profile で管理対象でない file が warning になること(profile 切替の残骸)。
- 同じ file でも管理対象の profile では orphan にならないこと。
- header のない file は orphan 扱いしないこと。
- agent-tools の status.sh 実行が opt-in であること(`enableAgentToolsStatus=false` では実行マーカーが作られない)。
- opt-in 時は status を summary し `conflict` を warning にすること。
- contract version 不一致 / status.sh 欠如 / agent-tools 不在でも warning のみで exit 0 になること。
- private-backup section: marker 不在で「no backup recorded」、marker ありで最終成功時刻 /
  archive / 件数を表示すること。local 補足は **存在のみ**で中身(secret らしき行)を漏らさないこと。
- いずれの場合も doctor が exit 0 を維持すること(report-only)。

## private-backup.sh

private な設定(`.local` 上書き + curated アプリ設定)を **age identity 鍵**で単一アーカイブに
退避し(`backup`)、そのアーカイブを検証する(`verify`)。災害復旧用の単方向 backup→restore で、
restore は後続段。手動起動のみ・`chezmoi apply` 非結合。冒頭で runtime secrets gate
(`require_secrets_access`)を通り、`allowSecretsAccess != true` の profile では実行拒否。

```sh
./scripts/private-backup.sh backup --out PATH [--recipient AGE1... | --recipients-file PATH] \
                            [--local-supplement PATH] [--yes]
./scripts/private-backup.sh verify --in PATH (--identity PATH | --identity-command CMD)
```

- **backup**: baseline(`.chezmoidata/backup-paths.yaml`)+ local 補足を解決 → 0700 temp に
  staging → machine-neutral manifest(時刻 / tool version / 各 file の type・mode・sha256。
  絶対 home path・host 名は入れない)生成 → `tar | age -r recipient` を pipe(平文 tar を
  ディスクに残さない)→ `--out` へ書き出し → marker(`~/.local/state/dotfiles/private-backup.json`、
  最終成功時刻 / archive basename / 件数のみ)更新。捕捉 0 件は空アーカイブを書かず fail。
- **verify**: `--identity` / `--identity-command`(op seam)で 0700 temp に**復号**し、
  **展開前に全 tar member を検査**(非正規 member = symlink/hardlink/special を拒否、
  絶対パス・`..`・制御文字・台帳外 member 名を拒否)してから展開。recipient は公開鍵なので
  悪性アーカイブも復号可能 → 展開で HOME 外へ逃げないよう member 検査を前段に置く。展開後は
  manifest と突き合わせ(checksum・mode・余剰ファイル・home-relative・symlink 拒否)。
  HOME には一切書かない read-only。復号物・展開物は trap で確実削除。
  `--identity-command` はユーザー指定の shell コマンド列(`op read op://...` 想定)で、
  quoting のため shell 実行する。アーカイブ由来ではなく呼び出し側が管理するため注入面ではない。
- recipient / identity が解決できなければ fail-closed。仕様は `docs/private-backup.md`。

`age` と mikefarah/yq v4 が必要。

## test-private-backup.sh

`private-backup.sh` の round-trip と安全性を hermetic に検証する(fixture HOME・fake chezmoi で
gate profile を与える・throwaway age 鍵)。実 home には触れない。`age` / `age-keygen` が無い環境
では skip(exit 0)。

```sh
./scripts/test-private-backup.sh
```

検証内容:

- backup がアーカイブと machine-neutral marker(絶対 home path を漏らさない)を書くこと。
- verify が正アーカイブを受理し、wrong identity / 改竄アーカイブを拒否すること。
- `--identity-command`(op seam)経由でも verify できること。
- manifest 不整合(checksum mismatch / 台帳外ファイル / symlink 混入)を検出すること。
- 拒否 profile(work-minimal)では backup が実行拒否し、アーカイブを書かないこと。
- 非コミットの local 補足にある unsafe path(`..` 等)を skip し、baseline は捕捉すること。
- recipient 未指定は usage error(exit 2)になること。

## test-secrets-gate.sh

private-backup の runtime gate(issue #60)を検証する。backup / restore は host の
**実 profile** が `allowSecretsAccess=true` のときだけ実行できる。gate は fail-closed で、
profile を解決できない・未知の profile・`true` 以外の値はすべて拒否する。

```sh
./scripts/test-secrets-gate.sh
```

検証内容:

- `profile_allows_secrets_access` が `allowSecretsAccess=true` の profile(personal)だけ許可し、
  `false` の profile(work-minimal / work-dev)と未知 profile を拒否すること(vacuously true にしない)。
- chezmoi が見つからないとき `resolve_runtime_profile` / `require_secrets_access` が fail-closed で
  拒否すること(default profile に倒さない)。
- chezmoi が profile を解決できる環境では、gate の判定が実 profile の純検査と一致すること
  (より緩くならない。chezmoi 不在の CI では skip)。

実 profile は `chezmoi data` から取得し、CLI 引数では渡さない(呼び出し側が gate を
より緩い profile に誘導できないようにするため)。

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

policy data(`.chezmoidata/*.yaml`)の読み取りは mikefarah/yq v4 で行う。`require_yq` が yq の存在と variant・版を検査し、満たさなければ fail closed する(`validate-policy.sh` / `test-npmrc.sh` / `test-render.sh` が冒頭で呼ぶ。`doctor.sh` / `preflight.sh` は内部で `validate-policy.sh` を先に実行するため間接的にカバーされる)。profile / module / capability 名は `strenv()` 経由で渡し、yq 式へ展開しない。
