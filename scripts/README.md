# scripts

この directory の script は、dotfiles を host に適用する前後の policy 検証と、catalog に
宣言された運用アクション(手動起動のみ)を担当する。検証系(validate / preflight / doctor /
test-*)は read-only で、host を変更しない。host に書き込むのは明示的に起動した
`install-packages.sh --apply`(catalog 宣言の package install。dry-run 既定)と
`private-backup.sh`(`backup` は確認後に `--out` のアーカイブと state marker を書く。
`restore` は dry-run 既定で `--apply` のときだけ復元する)だけで、いずれも
`chezmoi apply` には結合しない。macOS defaults、secret fetch、
Git remote mutation は行わない。

## 終了コード方針

```text
report-only warning: exit 0
policy violation: exit 1
script/runtime failure: exit 1
CLI usage error: exit 2
```

`[warn]` は現状報告または注意喚起であり、それだけでは失敗扱いにしない。
unknown profile / module / capability や capability enum の不正値は policy violation として fail closed する。
`doctor.sh` / `preflight.sh` は冒頭の policy validation が失敗した場合のみ exit 1 で、それ以外は warning があっても常に exit 0(report-only)。`doctor.sh` の未知 option(`--actions-only` 以外の `-` 始まり)だけは usage error として exit 2 で report を走らせない(#227)。

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
- environmentKind cross-check: kind が禁止する boolean capability が `true`(#43)、または
  enum capability が禁止値(work / client / agent の `npmHardeningMode=off`、#45)だと
  hard fail すること。
- module の `paths:` が home 相対のリテラル path であること(glob / pattern 文字・空白・
  先頭 `~` / `./`・末尾 `/` は fail。`.chezmoiignore` allowlist の `!<path>` 行になるため、#207)。
  同一 path を複数 module が宣言していないこと。
- module の `requires:` の capability が定義済みで、値が schema の型に適合すること。
- `requires:` があるのに `paths:` がない module は fail(条件が何も駆動しないため)。
- package catalog(`.chezmoidata/packages.yaml`)の name/source が有効であること。
- backup path catalog(`.chezmoidata/backup-paths.yaml`)の path が home 相対・glob なし・
  重複なしであること。
- capability registry(#151): 全 capability が `implemented: true|false` を持ち、
  `implemented: false` は doctor.sh が言及していること(source-text の静的 proxy)。

## preflight.sh

導入前の危険検知を行う。既存 home file、既存 Git config(`~/.gitconfig`、`~/.config/git/config`、global identity の設定有無。値は表示しない)、必要 command、project root などを確認する。
副作用は持たない。既存 file や command 不足の warning は report-only として exit 0 のままにする。

```sh
./scripts/preflight.sh personal
```

policy validation が失敗した場合は exit 1。

## doctor.sh

導入後または現状環境の健康診断を行う。chezmoi、Git、Git signing(`enableGitSigning` の SSH 署名 mechanism が managed か、capability true で module inactive の dangling か)、Git identity context(各 context の identity file が存在するか、意図的に未設定か。存在する file は `user.name` / `user.email` の有無だけを見て partial を action 化 — 値は出さない。managed な identity reset が塞げない唯一の状態なので、#202)、Git remote URL(credential らしき userinfo の有無。url と pushurl を見る。URL の値は表示しない)、npm、Corepack、software catalog drift(catalog 宣言 vs 実機の brew/npm/go/mas。declared-missing / undeclared-sprawl / source-mismatch を report-only で表示)、runtime、1Password(`allowSecretsAccess=true` のとき `op` の存在と sign-in。`op whoami` は 5 秒の期限付き・stdin `/dev/null` で回し、応答なしは「未確認」の warn にして doctor を止めない — 未ログインの `op` が対話 unlock 待ちで固まり診断全体が止まっていた、#231)、SSH(`enable1PasswordSSH` の managed `~/.ssh/config` が active か dangling か)、managed-path orphan(managed-by header があるのに現 profile で管理対象でない file。profile 切替の残骸検出。宣言済み **file** path のみ検査し、dir 宣言(gate 配管)の中身には再帰しない — セッションログ等の header 引用を偽 orphan にしない、#174)、managed drift(`chezmoi status` の乖離を report-only で warn。enforce profile では `~/.npmrc` の `_authToken` 行の有無をキー名のみで scan — 値は読まない・出さない — と managed-by header の有無も報告。#148)、AI policy(`enableAiPolicy` / `enableAiTools` の現状。codex-settings が active な profile では Codex 権限面も監視 — managed rules baseline の presence と、**外向き/昇格 probe(push・PR/issue/comment 作成・release・sudo・auth login・clone・curl 等の固定リスト)を `codex execpolicy check` で live rules に評価**し auto-allow を warn(行 grep は blanket prefix・複数行 rule・decision 省略の既定 allow を見逃し、rule 行 echo は任意文字列由来の secret を漏らしうるため不採用 — doctor は rules file を読まず path を codex に渡すだけ・echo するのは自前の probe 文字列のみ。codex CLI 不在時は skip を明示)、`config.toml` の `[projects]` trust は **section header の path と trust_level のみ** scan(MCP env 等の他内容は読まない・#148 と同じキー名限定規律)し、trusted な home root と実在しない path の残骸を warn、#139)、enforceAiSandbox(sandbox ブロックと human-legit write gate の live state)、GitHub injection guard(secret floor は常時 deny、`gateGitHubMcp` の MCP deny の wired 状態、`enableGitHubIsolatedReader` の PreToolUse hook 登録の wired 状態と hook body の presence — body は agent-tools 配布なので存在のみを contents-blind で見る、#137)、quality loop hooks(`enableQualityLoopHooks` の PostToolUse / Stop hook 登録を両 home で wired 状態と body presence で report し、check 宣言 `~/.config/agent-tools/checks.local.json` は **presence のみ**を見る — hook が実行する command を列挙する file なので中身は読まない、#199)、herdr integration(`enableHerdrIntegration` の SessionStart hook 登録を両 home で wired 状態と herdr 配置 body の presence で report し、herdr が PATH にあれば `herdr integration status` の currency(current / outdated / needs repair)も出す — body header を読むだけで server 不要。5 秒の期限付きで実行し exit 0 のときだけ採用、不在・失敗・hang は「未確認」と明示して doctor を止めない(一時ファイル不使用・stdin `/dev/null`・期限到達と中断時は probe の process tree ごと回収。doctor 共通の `bounded_probe` helper で、1Password の `op whoami` と共有、#231)。capability=false は宣言上の状態として報告し、herdr 自身の見え方を module の active / inactive に応じた所有者説明つきで添える、#225)、OpenCode(report-only。`opencode` の presence、`opencode-settings` module が active な profile では managed な permission 床 `~/.config/opencode/opencode.json` の presence — 無ければ apply 手順の action、非 active なら not managed。credential store `~/.local/share/opencode/auth.json` は**存在のみ**で中身も provider 名も読まない、#234)、network tunnels(`allowNetworkTunnels` と tunnel tool の存在)、agent-tools(report-only。`~/src/agent/agent-tools`(既定。`AGENT_TOOLS` env で override 可)の presence を表示し、`enableAgentToolsStatus=true` の opt-in 時のみ status contract(`scripts/status.sh --root <checkout> --json`。root を pin しないと status.sh は cwd を検査して空 repo を偽報告する)を実行して安全な summary を出す。clone / pull / sync はしない)、private-backup(report-only。public baseline の各 target の存在と marker からのバックアップ有無/最終日時を表示。backup 未実行は allowSecretsAccess=true の profile でのみ warn — false の profile は backup 実行自体を拒否する設計なので中立表示(#174)。local 補足は **存在のみ**で中身・件数は出さない。アーカイブや captured file の中身は読まない)、project root の状態を表示する。
副作用は持たない。設定不足や未導入 command の warning は report-only として exit 0 のままにする。
remote URL scan の方針は `docs/supply-chain-git.md`、npm hardening の検査は `docs/supply-chain-npm.md`、Corepack の検査は `docs/supply-chain-corepack.md` に従う。
`npmHardeningMode=enforce` の profile では、期待する npm config 値と現在値の不一致を `[warn]` で報告する(apply 前は不一致が正常)。

```sh
./scripts/doctor.sh personal
./scripts/doctor.sh personal --actions-only   # 末尾の next actions 一覧だけ
```

policy validation が失敗した場合は exit 1。`--actions-only` 以外の `-` 始まりの引数は usage error で exit 2(validator に渡さない)。

**next actions**(#227): 具体的な command / 手順を言える warning は `action`(`lib-policy.sh`)経由で
報告され、inline の `[warn]` 行はそのままに、末尾の `== next actions (N) ==` に理由と手順が番号つきで
まとまる(git hook gates の hooksPath 未設定 / lingering、identity file 不在、managed-path orphan、
managed drift、Codex projects trust の stale / home 全体、herdr integration の body 不在 / outdated / work
機での未導入、agent-tools の dirty / stale)。判断が要る warning(catalog 外 package 等)は warn のまま。
`--actions-only` は `[fail]` と summary 以外を mute するだけで、doctor はファイルを書かない(report-only)。
手順行も key-name-only / secret を出さない規律の対象。

## test-preflight.sh

`preflight.sh` の report-only 契約と apply-impact 警告を fixture HOME で検証する(#150)。
空 home の exit 0 / shell-extra・ssh-1password の replace 警告と override pointer /
非管理 profile の left-as-is / `~/.config` 権限分岐 / config.local の中身非表示 /
policy validation 失敗時のみ非 0、をカバーする。

## test-lib.sh

test-*.sh が共有する fixture helper(source 専用、lib-policy.sh の後に source する)。
`set_capability_all` / `remove_module_all` が fixture の profiles.yaml を yq で構造的に
編集し、対象が存在しなければ fail する(行形式一致の awk 直書きが無言で no-op 化して
テストが vacuous pass する事故の再発防止。#149)。ほかに render/fixture 構築の共有形:
`render_personal_into`(throwaway home への personal apply。root は呼び出し側が mktemp +
cleanup 登録する caller-creates-root 契約 — `$(...)` 内で mktemp する形は cleanup trap から
漏れる、#150)、`make_flipped_source` / `flip_personal_capability`(source copy + personal
限定 capability flip。boolean 専用)、`copy_repo_fixture`(scripts + .chezmoidata の最小
repo copy)。

## test-shell-syntax.sh

CI の bash / zsh syntax check をそのまま取り出し、各入力ファイルへ構文エラーを
順番に挿入して非 0 になることを検証する。先頭ファイルだけの検査や、後続ファイルの
成功で途中の失敗が隠れる退行を防ぐ(#211)。

## test-policy.sh

外部 test framework を使わずに policy validation の fail-closed 挙動を検証する。
一時 directory に data files と scripts をコピーし、fixture を壊して `validate-policy.sh` が失敗することを確認する。

```sh
./scripts/test-policy.sh
```

検証内容:

- `validate-policy.sh --all` が全 profile を検証すること。
- enum capability の許可値を正しく受け入れること。
- unknown profile / module / capability(module の `requires:` 内も)、重複 capability、enum の不正値を拒否すること。
- boolean capability・`requires:`・`implemented:` は YAML boolean の小文字 `true` / `false` だけを受け入れ、
  文字列 / 数値 / null / 大文字綴りを拒否すること(#206)。
- 同一 path を複数 module が宣言したら fail、`requires:` を持つ module は `paths:` 必須。
- software catalog(#53): unknown source / go_install の pkg 欠落 / name 重複 / track_only 不正 / 空 catalog を拒否。
- backup-paths(#60): 絶対 path / `..` / glob / unknown type / 重複 / 空 entry / 空 catalog を拒否。
- environmentKind 制約: work / client / agent で権限付与型 capability の true、sandbox の
  allowSecretsAccess、`npmHardeningMode=off` を hard fail。安全強化型(`enforceAiSandbox` /
  GitHub guard 2 本 / `enableQualityLoopHooks` / `enableHerdrIntegration`)は全 kind で true を許容
  (forbidden 表に入っていないことの pin)。forbidden-enum 表の不正行は fail closed。
- capability registry(#151): `implemented:` 欠落は fail、`implemented: false` は doctor.sh がその名前に
  言及していなければ fail(undisclosed dormant)。
- 単一 dash の option は usage error、非 mikefarah yq / v4 未満は fail closed、空の profiles / schema は fail closed。

## test-gitconfig.sh

`dot_gitconfig` の Git identity 安全境界を検証する。

```sh
./scripts/test-gitconfig.sh
```

検証内容:

- source に `user.useConfigOnly = true` と `transfer.credentialsInUrl = die` が含まれること。
- 全 context(personal / work / client / sandbox / agent)の `includeIf` と include path が定義されていること。
- include の**順序**が exact pin と一致すること(#202: personal の hasconfig 3 本 → personal gitdir →
  非 personal 4 context それぞれで identity reset → context file の隣接 2 段 → mechanism の無条件 include)。
- source に identity 値(`name =` / `email =`、email らしき値)が含まれないこと。
- source に chezmoi のテンプレート構文が含まれないこと(fixture は source を git に直接渡すため)。
- local fixture で、known root 外では commit が identity 未解決を理由に失敗すること。
- local fixture で、`~/src/personal/` 配下では identity file の identity が解決されること。
- credential 入り remote URL が拒否されること。
- credential らしき remote URL(`scheme://user:password@host`)を `git_remotes_with_credentials` が検出すること。
- credential なし・username のみの remote URL は誤検出しないこと。
- identity reset(#202)の matrix: 非 personal 4 context × identity file の状態(absent / empty / name-only /
  email-only / complete)× personal remote(HTTPS / scp 形 / `ssh://` / origin=他 org + upstream=personal の
  multi-remote)で、実 commit の author と committer を検証する。absent / empty / email-only は拒否、name-only は
  context の name + 空 email(personal ではない・可視に壊れている)、complete は context の identity。
  `~/src/` 外の personal fallback は不変。linked worktree は主 repo の `.git` 位置で判定される特性を固定。

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
- `.chezmoiignore` が allowlist の root `**` を持つこと(repo 管理用 file(README、docs、scripts など)は
  宣言されないので apply されない。managed set の pin と未宣言 source の検知は `test-render.sh`、#207)。
- modules.yaml の宣言で `.npmrc` が `npmHardeningMode=enforce` のみ、mise config が `enableRuntimeManagement=true` のみで管理されること。
- template の設定値と `doctor.sh` の enforce 期待値が一致していること。

chezmoi が未導入でも実行できるよう、render はせず静的検査に留める。

## test-doctor.sh

fixture HOME(+ repo copy の capability flip・PATH 先頭の fake command)で doctor の各 section を
検証する。実 home・実 manager・実 codex / herdr には触れない。

```sh
./scripts/test-doctor.sh
```

検証内容(section ごと):

- managed-path orphan: header があり現 profile で管理対象でない file が warning / 管理対象の
  profile では orphan にならない / header 無しは対象外 / dir 宣言の中身に再帰しない(#174)。
- managed drift: fake chezmoi の status 行ごとに warn、空なら ok、失敗は INCOMPLETE(#148)。
- agent-tools: status.sh 実行が opt-in(`enableAgentToolsStatus`)/ opt-in 時は summary + `conflict` を
  warn / contract version 不一致・status.sh 欠如・非ゼロ exit・不正 JSON・不在でも warning のみ /
  `AGENT_TOOLS` override(#71 / #73)。
- private-backup: marker 不在は allowSecretsAccess=true の profile だけ warn(false は中立)、marker
  ありで最終成功時刻 / archive / 件数、不正 marker は unreadable、local 補足は**存在のみ**(#174)。
- git signing / SSH(1Password): capability true + module active は managed、module 除去は dangling。
- GitHub injection guard(#119 / #137): secret floor 常時 deny、`gateGitHubMcp` / `enableGitHubIsolatedReader`
  の wired 状態、hook body の presence(contents-blind)、`enforceAiSandbox` の human-legit gate 開示。
- quality loop hooks(#199): 両 home の登録 + body presence、`checks.local.json` は presence のみ(canary で
  中身を漏らさない)、cap off の not-wired、live file に残置した登録の lingering warn、module 除去の dangling。
- herdr integration(#225): body 不在 / exec bit なし body / dir body / 末尾改行なしの status 応答 /
  outdated・needs repair / status が非ゼロ exit(出力を採用しない)/ hang(期限で process tree ごと回収)/
  probe 稼働中に doctor を SIGTERM(trap で回収・rc 143)/ cap off の module active・inactive 別の表示 /
  module 除去の dangling。fake herdr は ok・fail・hang・interrupt・ok-nonl の mode を持つ。
- 1Password(#231): fake op の signed in(ok 1 行だけ)/ signed out(既存 warn)/ hang(期限で process tree
  ごと回収し「未確認」の warn で次の section へ進む。signed in / out とは断定しない)/ stdin 隔離(doctor の
  stdin に行を流し、fake は自分の stdin が `/dev/null` のときだけ signed in を返す)。fake op は ok・fail・
  hang・stdin の mode を持つ。
- Git identity contexts(#202): identity file の状態(missing / empty / name-only / email-only / complete /
  parse 不能)ごとに、missing と partial は action(手順に file path)、complete は ok、parse 不能は warn。
  値は出力に現れない(canary email で pin)。
- OpenCode(#234): fake opencode を PATH 先頭に置き、personal で床 missing → apply 手順の action / 床 present → ok /
  work → not managed(action なし)。credential store は存在のみ(fake auth.json の provider 名と key を canary にして
  非表示を pin)。
- next actions(#227): summary が最後の section で件数 = 番号行数・inline `[warn]` と同順・各項目に手順行 /
  `--actions-only` が full run の summary と一致し他の行を含まない / 未知 option(`--actions-onyl` / `-h` /
  `-x`)は exit 2 で report を走らせない / 0 件は none / helper 単体の exact pin(複数 step・`%`・先頭 `-`・
  空白 path)/ drift 手順の path が ` M x` でも `~/x` / work 機(module 非 active)で fake herdr が
  not installed・outdated なら `herdr integration install <agent>` の action、current なら info、herdr 不在
  は catalog section への pointer。
- AI policy(#139 / #210): fake `codex execpolicy check` で probe の実効判定(nested allow を誤判定しない)、
  engine 失敗は INCOMPLETE、`config.toml` の projects trust は header + trust_level のみ scan。
- npm(#150): shim だけの npm / 壊れた npm でも doctor を落とさない、enforce の期待値検査は fake npm / node で決定的。
- いずれの場合も doctor が exit 0 を維持すること(report-only)。

## install-packages.sh

software catalog(`.chezmoidata/packages.yaml`)の **未 install entry を install** する(#53 第2段)。
手動起動のみ・`chezmoi apply` 非結合。**dry-run 既定**で、`--apply` を付けたときだけ実 install する。
実 profile を chezmoi config から fail-closed に解決し、source を `installPackages`(brew_formula /
npm_global / go_install)/ `installGuiApps`(brew_cask / mas)で gate する(work / client / agent は
これらが false なので何も install しない)。既 install は skip して**更新しない**(install と update の
分離、[docs/update-policy.md](../docs/update-policy.md))。track-only / manual は対象外。npm / go の
manager が PATH に無ければ skip + warn(runtime は mise の領分)。

```sh
./scripts/install-packages.sh           # dry-run: 何が install されるか表示
./scripts/install-packages.sh --apply   # 未 install entry を実際に install
```

## test-install-packages.sh

`install-packages.sh` の gate と fail-closed 契約を検証する。source→capability の対応、
`profile_installs_source` が personal のみ install を許し work 系は許さないこと、profile 未解決時の
拒否、解決済み work profile の dry-run が 0 件を計画すること(副作用なし)を確認する。

`test-inventory.sh` はこの test から実行する inventory 回帰検証で、単独でも実行できる。fake manager だけを PATH に置き、Go toolchain 自動取得の抑止、GOBIN / GOPATH の PATH 外 executable の再 install 防止、inventory の取得・解析失敗時に install しないこと、doctor の INCOMPLETE / exit 0 と成功 source の検査継続を確認する。実 manager・実 install・実 home は使わない。

## private-backup.sh

private な設定(`.local` 上書き + curated アプリ設定)を **age identity 鍵**で単一アーカイブに
退避し(`backup`)、アーカイブを検証し(`verify`)、検証済みのものだけを復元する(`restore`。
既定 dry-run、`--apply` で実行)。手動起動のみ・`chezmoi apply` 非結合。冒頭で runtime secrets gate
(`require_secrets_access`)を通り、`allowSecretsAccess != true` の profile では実行拒否。

```sh
./scripts/private-backup.sh backup --out PATH [--recipient AGE1... | --recipients-file PATH] \
                            [--local-supplement PATH] [--yes]
./scripts/private-backup.sh verify --in PATH (--identity PATH | --identity-command CMD)
./scripts/private-backup.sh restore --in PATH (--identity PATH | --identity-command CMD) \
                            [--apply] [--skip-existing] [--target-home DIR]
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
- **restore**: verify を通った後のみ復元(整合 NG なら拒否)。**既定 dry-run**(何も書かない)、
  `--apply` で実行。既存ファイルは上書き前に **timestamp 退避 dir**(`~/.local/state/dotfiles/
  restore-backup-<ts>/`)へ move。`--skip-existing` で既存は触らない。**symlink 化した親 dir 経由の
  書き込みを拒否**して HOME 外 escape を防ぐ。`--target-home` で復元先を差し替え可(既定 `$HOME`)。
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
- 拒否 profile(work)では backup が実行拒否し、アーカイブを書かないこと。
- 非コミットの local 補足にある unsafe path(`..` 等)を skip し、baseline は捕捉すること。
- recipient 未指定は usage error(exit 2)になること。
- restore が dry-run では何も書かず、`--apply` で原文どおり復元すること。
- restore の上書きで既存ファイルを timestamp 退避すること。`--skip-existing` で既存を触らないこと。
- restore が **symlink 化した親ディレクトリ経由の書き込みを拒否**し escape しないこと。
- restore が verify 不合格アーカイブ / 拒否 profile では復元を拒否すること。
- local 補足リスト自体が payload として canonical path(`.config/dotfiles/backup-paths.local`)に
  捕捉され、restore が dry-run で計画し `--apply` で内容と mode ごと復元し、復元した home からの
  再 backup が local 対象と補足を 1 回ずつ含むこと(#208。archive 最上位の旧形式 copy は作らない)。
  `--local-supplement` の source path は manifest に載らず、復元先も canonical path であること。
  既存の補足は退避 / `--skip-existing` の規則に従うこと。補足が自身の path を宣言しても entry / file が
  重複しないこと。改竄された補足 payload を verify が拒否すること。
- backup が暗号化前に staging を自己検証すること(#224): 正常 run で self-check の section と
  `verified N file(s)` が出ること。PATH 先頭の fake `cp`(実 cp の後に staging 側の copy だけを改竄)で
  manifest と staging がずれると、`checksum mismatch` で拒否し、`--out` も `.partial` も作らず marker が
  前回のまま・exit 非 0 であること(script に test 用 backdoor は無い)。

## test-secrets-gate.sh

private-backup の runtime gate(issue #60)を検証する。backup / restore は host の
**実 profile** が `allowSecretsAccess=true` のときだけ実行できる。gate は fail-closed で、
profile を解決できない・未知の profile・`true` 以外の値はすべて拒否する。

```sh
./scripts/test-secrets-gate.sh
```

検証内容:

- `profile_allows_secrets_access` が `allowSecretsAccess=true` の profile(personal)だけ許可し、
  `false` の profile(work)と未知 profile を拒否すること(vacuously true にしない)。
- chezmoi が見つからないとき `resolve_runtime_profile` / `require_secrets_access` が fail-closed で
  拒否すること(default profile に倒さない)。
- chezmoi が profile を解決できる環境では、gate の判定が profiles.yaml の
  `allowSecretsAccess` 宣言値(yq 直読みの独立期待値)と一致すること
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
- allowlist 契約(#207): source の複製に未宣言の root file / subtree / 宣言済み directory 配下の
  sibling を置いても、全 profile で managed set が期待値のままで、apply がそれらを作らず、
  home に既にある未管理 file にも触れないこと。
- 宣言忘れの検知(#207): 実 source の全 entry(`.` 始まりと repo 管理 file を除く)を
  `chezmoi target-path` で target に変換し、全 module の宣言 path ∪ 祖先 directory に含まれること。
  未宣言 entry を置いた複製ではこの検査が fail すること(空振り防止)。未使用の chezmoi source
  種別(`run_` 等の属性 prefix、`.chezmoiscripts` 等の special file)は fail すること。
- typo profile が known profile 一覧つきのエラーで fail すること。
- profile 未設定が init 誘導メッセージで fail すること。
- 非対話 init(`--promptString profile=<name>`)が動くこと。
- profile 無回答の init が fail すること(default を持たない)。

chezmoi が必要(CI では version pin して導入する)。

## test-claude-settings.sh

managed `~/.claude/settings.json` の rendered content を検証する。throwaway repo copy で
capability(`enforceAiSandbox` / `gateGitHubMcp`)を flip し、secret floor の無条件 deny
13 件が順序込みで常時出力されること(personal 既定では `gateGitHubMcp` の `mcp__github` を
足して計 14 件。#136 で credential-store 読取 4 件、#234 で OpenCode の `auth.json` を追加)、gate 系 deny/ask ブロックが capability に応じて出る/出ないこと、#93 で
取り込んだ global preference キーの保持、hooks 登録(`enableGitHubIsolatedReader` の PreToolUse / `enableQualityLoopHooks` の
PostToolUse + Stop / `enableHerdrIntegration` の SessionStart。各 capability が自分の event だけを足し、全部 false で `hooks` キーが消えること。#137 / #199 / #225)を exact に確認する。
chezmoi が必要(render job)。

## test-codex-settings.sh

managed `~/.codex/hooks.json` と `~/.codex/rules/default.rules` の rendered content を検証する。hooks 登録は
Claude 側と同じ exact pin(PreToolUse は timeout 10、PostToolUse / Stop は timeout なし、SessionStart は herdr installer と同一形の
`bash '<path>' session` + timeout 10。#181 / #199 / #225)に加え、
top-level key が `{hooks}` だけであること(Codex 0.142.5 の parse 制約 #185)、hook capability が全部 false のとき
apply 済み file が **削除される**こと(template 自己 gate)、rules baseline の exact content と gate の独立性(#139)を
確認する。chezmoi が必要(render job)。

## test-opencode-settings.sh

managed `~/.config/opencode/opencode.json`(OpenCode の permission 床・#234)の rendered content を検証する。
`permission.read` / `permission.bash` の rule map を**順序込みで exact pin**(OpenCode は last-match-wins なので
順序も契約。read = secret floor の deny 6 + `.env` 系、bash = env dump / gh secret / ssh 鍵の deny 7 と外向き・昇格の ask 14)、
`autoupdate: false` / `share: "disabled"` / `instructions` が agent-tools の運用ルール 1 件だけ(絶対 path)であること、
top-level key が `$schema / autoupdate / share / instructions / permission` だけ(provider / model / plugin / mcp / agent を
managed に書かない)、secret / email らしき文字列が無いこと、work では `~/.config/opencode` が render されないことを確認する。
chezmoi が必要(render job)。

## test-git-signing.sh

git-signing module の gating を検証する。`enableGitSigning` の on/off で
`~/.config/git/signing.gitconfig` が管理される/されないこと、signing mechanism
(gpg.format=ssh + op-ssh-sign)が public-safe な骨格のみであることを render で確認する。
chezmoi が必要(render job)。

## test-ssh.sh

ssh-1password module の gating と安全契約を検証する。`enable1PasswordSSH` の on/off gating、
managed `~/.ssh/config` に host 名・秘密鍵・`Host *` への agent 付与・forwarding が混入しない
こと、`Match all` 後の `Include config.local` 構造、`ssh -G` での実挙動(managed-wins と
config.local の解決)を確認する。chezmoi が必要(render job)。

## test-gclone.sh

dot_zshrc の `gclone` helper(#177)をマーカー抽出 + fixture HOME + `zsh -f` で検証する。
実 clone はしない(`-n` の解決のみ)。context 解決の順序(managed の kosako ルール →
local mapping → fail-closed 中断)、URL 3 形式(https / ssh:// / scp)の parse、
path traversal 拒否、既存 dest の非破壊を固定する。zsh が必要(validate job、apt で導入)。

## test-starship.sh

starship.toml の render を検証する。TOML として parse できること(tomllib)、
git-identity context の色分けが runtime 照合で行われ、identity の実値(email 等)が
managed file に混入しないことを確認する。chezmoi が必要(render job)。

## lib-policy.sh

他 script から source される共通 helper。
data file path、profile/module/capability 取得、出力 helper、command availability check、Git remote credential 検出(`git_remotes_with_credentials`。remote 名のみを出力し、URL 値は出力しない)を提供する。ほかに、BSD/GNU をまたぐ octal mode 取得(`file_mode`)、doctor / preflight が共有する policy ゲート(`run_policy_validation`)と標準 project roots 報告(`report_standard_project_roots`)、catalog source → package manager の対応表(`manager_present`。installer と catalog drift 報告の単一 source)を持つ。

policy data(`.chezmoidata/*.yaml`)の読み取りは mikefarah/yq v4 で行う。`require_yq` が yq の存在と variant・版を検査し、満たさなければ fail closed する(`validate-policy.sh` / `test-npmrc.sh` / `test-render.sh` が冒頭で呼ぶ。`doctor.sh` / `preflight.sh` は内部で `validate-policy.sh` を先に実行するため間接的にカバーされる)。profile / module / capability 名は `strenv()` 経由で渡し、yq 式へ展開しない。
