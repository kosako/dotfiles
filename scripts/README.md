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
`doctor.sh` / `preflight.sh` は冒頭の policy validation が失敗した場合のみ exit 1 で、それ以外は warning があっても常に exit 0(report-only)。`doctor.sh` の未知 option(`--actions-only` 以外の `-` 始まり)と、`preflight.sh` の `-` 始まりの引数・2 つ目の引数だけは usage error として exit 2 で report を走らせない(#227 / #309。validate-policy の `-h` / `--all` などに素通しすると、その文字列を profile 名にした report が誤った clean で終わるため)。

## 実行環境の契約(bash 3.2)

`scripts/*.sh` は macOS 標準の `/bin/bash`(3.2)でも動くことを契約にする(#333 F06)。新しい machine では Homebrew の
bash が入る前に preflight が走り、最小の PATH で起動された agent も `#!/usr/bin/env bash` を `/bin/bash` に解決するため。

- bash 4 以降の機能(連想配列、`mapfile` / `readarray`、`${v,,}` / `${v^^}`、`declare -n`、`|&`、`&>>`、`;;&`、負の配列添字、
  `wait -n`、`$EPOCHSECONDS` など)を使わない。
- 3.2 の挙動に合わせる: `set -u` の下で空の配列を `"${a[@]}"` と展開すると unbound variable で落ちる、`read -t` は timeout
  でも 1 を返す、`${v//pat/rep}` の置換の文字列は backslash と引用符を残す、`$!` が未設定だと `set -u` の下ではどう書いても
  error になる。
- macOS の userland(BSD の `mktemp` / `sed` / `stat` / `date`)で動かす。GNU だけの option を使わない。BSD の `mktemp` は
  template が無いと `TMPDIR` を見ないので、template を付ける(#372)。

CI の `bash32` job(macOS の runner)が、`/bin/bash` を PATH の先頭に置いて validate job の test と render job の test
(render group。macOS 用の chezmoi と codex を固定して入れる。#382)を回す。手元で同じことを
するには `docs/github-workflow.md` の「最低限の validation」に従う。

## validate-policy.sh

`.chezmoidata/profiles.yaml`、`.chezmoidata/modules.yaml`、`.chezmoidata/capabilities.schema.yaml` の整合性を検証する。

```sh
./scripts/validate-policy.sh personal
./scripts/validate-policy.sh --all
./scripts/validate-policy.sh --list-profiles
```

検証内容:

- profile・module・capability の名前(`.chezmoidata` の各 map の key)が、制御文字を含まない空でない文字列であること
  (名前は 1 行に 1 つで列挙するので、改行を含む key は 2 つの名前として検証されてしまう。読み取りの失敗も fail、#428。
  空の key は空行として読み飛ばされ、空の名前の module は `paths:` と `requires:` の検査を受けないまま `.chezmoiignore` で
  有効になっていた。#438)。
  `--list-profiles` も profile の名前を検査してから一覧を出す。
- profile が存在すること。
- `environmentKind` が許可された値であること。
- profile の `modules:` が module 名の list であること(省略・null は module なし。文字列・bool・数値・map・
  文字列でない要素・制御文字(改行など)を含む要素・空の要素は fail。型の読み取りと列挙の失敗も fail、
  #412・#422・#438)。profile が参照する module が定義済みであること。
- profile の `capabilities:` が、capability 名(制御文字を含まない空でない文字列)を key に持つ map で、文字列の値も制御文字を
  含まないこと(値は command substitution で読むので末尾の改行が落ち、`"enforce\n"` が `enforce` として通っていた。#428)。
- profile が参照する capability が定義済みであること。
- すべての定義済み capability が profile に存在すること。
- boolean capability が `true` または `false` であること。
- enum capability が schema の `values` に含まれること。
- capability の `type` が boolean / enum のどちらかであること(それ以外は値の検査を飛ばさず fail)。
- environmentKind cross-check: kind が禁止する boolean capability が `true`(#43)、または
  enum capability が禁止値(work / client / agent の `npmHardeningMode=off`、#45)だと
  hard fail すること。boolean の行は、実行時の拒否(install-packages / private-backup)と共有する
  `lib-policy.sh` の `profile_environment_kind_violations` で判定する(#357)。
- module の `paths:` が path の list であること(`modules:` と同じ型の検査、#412。空の path は `.chezmoiignore` に
  `!` だけの行を出し、chezmoi が止まる。#438)。各 path が home 相対の
  リテラル path であること(先頭 `/`・`..` を含む path・glob / pattern 文字・空白・
  先頭 `~` / `./`・末尾 `/` は fail。`.chezmoiignore` allowlist の `!<path>` 行になるため、#207)。
  同一 path を複数 module が宣言していないこと。
- module の `requires:` は map であること。省略・null・空の map は条件なしとし、それ以外の型は fail。
  各 capability が定義済みで、値が schema の型に適合すること。条件の列挙に失敗した場合も fail。
  key と文字列の値は制御文字を含まないこと(条件は 1 行に 1 つで列挙するので、改行を含む値は 2 つの条件として
  検証され、値そのものを比べる `.chezmoiignore` とずれる。#428)。key は空でなく空白を含まず、文字列の値は前後に
  空白を持たないこと(各行は最初の空白で key と値に分かれ、前後の空白は読み取りで落ちるので、
  `"npmHardeningMode enforce": ""`・`"": "npmHardeningMode enforce"`・`"enforce "` が `npmHardeningMode=enforce` として、
  `"": ""` が条件なしとして通り、`.chezmoiignore` では有効にならない。値の途中の空白はそのまま読める。#430。空の key は
  名前の検査(#438)が先に fail にする)。
- `requires:` に条件があるのに `paths:` がない module は fail(条件が何も駆動しないため)。
- package catalog(`.chezmoidata/packages.yaml`)の name/source が有効であること。
- backup path catalog(`.chezmoidata/backup-paths.yaml`)の path が home 相対・glob なし・
  重複なしであること。entry の構造(map・非空 string の `path`・`type` / `category` は `|` と制御文字を
  含まない string)は共有 parser `backup_paths_in` が file 全体を先に検査し、不正なら
  `backup-paths entry invalid` で fail する(#246。local 補足の backup 時読み取りも同じ検査)。
- capability registry(#151): 全 capability が `implemented: true|false` を持ち、
  `implemented: false` は doctor.sh が言及していること(source-text の静的 proxy)。
  `values:` は省略・null か、制御文字を含まない空でない文字列の list であること(map は値を、改行を含む値は 2 つの値を
  許可値として列挙していた。#428。空の値は profile にも `requires:` にも書けない。#438)。

## preflight.sh

導入前の危険検知を行う。確認する内容は次のとおり: system(arch・macOS version・Xcode Command Line Tools)、既存 home file(`~/.gitconfig` / `~/.npmrc`)、shell config の apply impact(`shell-extra` module が active な profile で `~/.zshenv` / `~/.zshrc` / `~/.zprofile` / `~/.config/starship.toml` が既にあれば apply が置換する warn と退避先の案内)、ssh config の apply impact(`ssh-1password` module が active な profile で `~/.ssh/config` が既にあれば apply が置換する warn。`~/.ssh/config.local` は存在のみで中身は読まない)、`~/.config` の権限(0700 でなければ apply が 0700 に変える warn)、既存 Git config(`~/.config/git/config`、context 別 identity file の有無、global identity の設定有無。値は表示しない)、global gitignore(`git-ignore` module が active な profile で `~/.config/git/ignore` が既にあれば apply が置換する warn — git は global excludes を 1 file しか読まないので host 固有 pattern は `.git/info/exclude` へ。`core.excludesFile` が global / system に設定済みなら managed file が読まれない warn、明示的に空なら「global excludes を読まない」warn。値は表示しない、#248)、herdr config の apply impact(`herdr-config` module が active な profile で `~/.config/herdr/config.toml` が既にあれば apply が置換する warn — herdr は config を 1 file しか読まず `.local` が無いので、host 固有の設定は managed file に入れる。中身は読まない、#261)、agent-tools の残量の読み取り口の apply impact(`agent-tools-usage-reader` module が active な profile で `~/.config/agent-tools/usage-reader.json` が既にあれば apply が置換する warn — wrapper は 1 file しか読まず `.local` が無いので diff してから。中身は読まない、#301)、git hook gates の apply impact(`enableGitHookGates=true` の profile で agent-tools deploy の 4 script が揃っているか — 欠けていれば apply は commit gate を武装しない warn — と、global `core.hooksPath` が managed 以外に設定済みかどうか。値は表示しない)、必要 command(catalog に宣言された tool と、catalog 外の前提 git / brew / node / npm / corepack だけ。#259)、Homebrew、dotfiles root の存在と書き込み可否、標準 project root。
副作用は持たない。既存 file や command 不足の warning は report-only として exit 0 のままにする。

```sh
./scripts/preflight.sh personal
```

policy validation が失敗した場合は exit 1。

## doctor.sh

導入後または現状環境の健康診断を行う。section は出力順に次のとおり(最後に next actions の一覧。下記)。

report の行は端末に安全な形で出す(#335)。`lib-policy.sh` の report の helper(`ok` / `info` / `section` / `item` / `warn` /
`fail`)と next actions の一覧が、行全体を共通の `display_safe` に通すので、どこで組み立てた行でも、他の tool や repo の
出力・他人が付けた名前・この checkout の path に含まれる terminal の escape 列や bidi の制御で、表示を崩したり偽装したり
できない。`display_safe` は正しい UTF-8 の文字をそのまま残し、制御文字(C0・DEL・C1)、bidi の override / isolate
(U+202A〜U+202E・U+2066〜U+2069)、UTF-8 として不正な byte を `?` にする(byte 単位で locale に依らない。printable ASCII
だけの行はそのまま通る)。外部由来の値を読む箇所(agent-tools の `status.sh`・usage reader の理由・herdr の状態・git /
chezmoi / corepack / npm の版・npm の設定値・`go env`・`core.excludesFile`、repo の dir と git remote、OpenCode の plugin と
Codex の rules の file 名、backup の marker の欄、Codex の project の key、catalog drift が manager から読む名前と
`npm root -g`)でも明示的に通し、目印にしている(冪等なので二重でも結果は同じ)。文字列の中身(指示文など)は text の
まま出る(読む側は data として扱う)。外部の command の stderr はこの helper を通らないので、doctor が直接呼ぶ command
では捨てる。他の tool の出力を awk / cut / grep で切り出すときも C locale で走らせ、stderr を捨てる(UTF-8 locale では
不正な byte を入力ごと引用した診断を出すため)。next actions の手順に出す path は `shell_quote_safe`(C locale の `printf %q`)で引用する。ASCII だけの引用に
なり、貼り付ければ元の path に戻る(UTF-8 locale の bash 3.2 の `%q` は一部の byte を生のまま残すため)。期限付きの probe
(`bounded_probe`)の終了状態の行は呼び出しごとの nonce を持ち、probe した command が自分で出した行が終了状態として
読まれることはない。

- doctor profile / policy / modules / capabilities: 対象 profile を表示し、policy validation を実行する(失敗時は exit 1)。続けて environmentKind、profile の module、capability の値を列挙する。
- chezmoi: chezmoi の version と source directory。
- Git: `user.useConfigOnly` / `transfer.credentialsInUrl` に加えて、次の 3 つを見る。
  - Git signing: `enableGitSigning` の SSH 署名 mechanism が managed か、capability true で module inactive の dangling か。
  - GitHub の HTTPS の credential helper(#492): `enableGhCredentialHelper` が true で `gh-credential-helper` module が active なら、managed な `~/.config/git/gh-credential.gitconfig` が在り、global の実効値(`--includes` 付き)がその file の helper と一致するか、helper の gh が今も実行できるか(値は出さない。消えていれば `chezmoi apply` の action)。file が無いときは、doctor の PATH に gh があれば action(`chezmoi apply`)、無いか引用の要る path なら warn(system の helper のまま)。capability true で module inactive なら dangling の warn。false のときに file が残っていれば、無条件の include が gh を効かせ続けるので action(module が active なら `chezmoi apply`、別の profile の残りなら手で消す)。
  - global gitignore: `git-ignore` module が active な profile で managed `~/.config/git/ignore` の presence、git が実際に読む excludes path との一致 — `core.excludesFile` は global が system に勝ち、`GIT_CONFIG_NOSYSTEM` なら system を飛ばす。明示的に空なら「global excludes を読まない」、config が読めなければ「不明」で、どちらも ok にしない。無ければ XDG 既定(末尾の `/` はすべて落とし、`-ef` でも同じ file と判定する、#309)— と、`.agent-packets/` と `**/.claude/settings.local.json` の pattern 行の drift。行の exact 一致で見る — `git check-ignore` は repository を要し doctor は何も作らない(#248)。
- git hook gates(report-only): `enableGitHookGates` が true で module が active なら、modules.yaml が宣言する shim(`~/.config/git-hook-gates/hooks/` の 23 本。#361)がすべて実行可能に置かれているか(欠けたものを 1 本ずつ warn し、そろっていれば 1 行の ok)、global `core.hooksPath`(`--includes` 付きで読む)が managed shim directory を指すか(別の値なら値は出さずに warn)、agent-tools deploy 4 本(dispatcher + gate 3 本)が揃っているかを report する。配線済みなのに deploy が欠けていれば commit が fail-closed で止まる旨を warn し、`core.hooksPath` が未設定なら action。capability true で module inactive なら dangling として warn。capability=false で宣言されたどれかの shim / hooksPath が残っていれば action(lingering)。git-hook-gates module が active な profile では apply で除去する手順、module が非 active な profile(profile 切替後の残置。#201)では apply が触れないので、残っている file を `rm -i` で消す手順と、`core.hooksPath` が managed shim directory を指さなくなったかの確認(まだ指すなら表示された設定元の行を消す)を出す(managed file が無く `core.hooksPath` だけが残るときは設定元を探す手順。#258)。repo-local `core.hooksPath` で外れ、`--no-verify` は prepare-commit-msg の identity の検査を除いて gate を飛ばし、`git am` と apply backend の rebase ではどの gate も走らない best-effort である旨も表示する(#196 / #239 / #431。詳細は `docs/git-hook-gates.md`)。
- Git identity contexts: `git-profile` module が active な profile では、managed な identity reset `~/.config/git-profile/identity-reset.gitconfig` の presence を見る — 中身は見ない。無ければ、context file の無い非 personal repo で personal pattern に一致する remote が personal identity を継承して commit 拒否にならないので、`mkdir -p ~/.config` → `chezmoi apply`(dir と file)を action にする(#241)。各 context の identity file が存在するか、意図的に未設定かも見る。存在する file は `user.name` / `user.email` の有無だけを見て partial を action 化し、値の無い key(`=` なし。git が identity 全体を拒否する)は別の action、git が parse できない file は warn — 値は出さない。partial は managed な identity reset が塞げない唯一の状態なので doctor が主な検出手段になる(#202)。
- Git remote URLs: credential らしき userinfo の有無。url と pushurl を見る。URL の値は表示しない。root を開けない(root 自身や親 dir の permission denied、symlink loop など。存在しないと確かめられた root だけ skip する)、repo の探索(find。root 自身が symlink なら link 先を辿る)や remote 設定の読み取り(`git config`)に失敗した root / repo は名指しで INCOMPLETE として warn し、clean の ok は出さない。`scanned repositories` は読めた repo だけを数える(#359)。
- npm hardening / Corepack: 検査内容は下記の docs に従う。
- software catalog(report-only): catalog 宣言 vs 実機の brew/npm/go/mas。declared-missing / undeclared-sprawl / source-mismatch を report-only で表示。
- runtime and shell: mise(`enableRuntimeManagement`)・direnv(`enableDirenv`)・zsh・starship の有無。mise を管理する profile では `go install` の行き先(`go env GOBIN`、空なら GOPATH の先頭の `bin`)が `~/go/bin` かを確かめ、違えば action(mise config の apply と、古い GOBIN を持たない新しい shell。installer は同じ行き先で導入済みを判定するので、usage reader の installer の案内より前に出る。#305)、PATH に `~/go/bin` が無ければ info。
- 1Password: `allowSecretsAccess=true` のとき `op` の存在と sign-in。`op whoami` は 5 秒の期限付き・stdin `/dev/null` で回し、応答なしは「未確認」の warn にして doctor を止めない — 未ログインの `op` が対話 unlock 待ちで固まり診断全体が止まっていた(#231)。
- SSH (1Password agent): `enable1PasswordSSH` の managed `~/.ssh/config` が active か dangling か。
- private-backup(report-only): public baseline の各 target の存在と、marker からのバックアップ有無・最終日時と、捕捉が完全かどうか(`capture: complete`。#242 以前の marker は `unknown`)を表示する。`capture_incomplete=true` なら warn とし、読めない entry を直してから再 backup する手順を next actions に出す(#242)。backup 未実行は allowSecretsAccess=true の profile でのみ warn — false の profile は backup 実行自体を拒否する設計なので中立表示(#174)。local 補足は **存在のみ**で中身・件数は出さない。アーカイブや captured file の中身は読まない。
- managed-path orphans: managed-by header があるのに現 profile で管理対象でない file。profile 切替の残骸検出。宣言済み **file** path のみ検査し、その祖先の directory(allowlist が親として通すだけ、#207)の下には再帰しない — セッションログ等の header 引用を偽 orphan にしない(#174)。
- managed drift(report-only): `chezmoi status` の乖離を report-only で warn。`chezmoi status` が失敗したとき、chezmoi の config が無ければ未初期化の item、あれば config / template の error(apply も壊れている)として `chezmoi status` を示す action(#309)。config があり `TMPDIR`(空なら `/tmp`)が書ける dir でないときは、chezmoi が modify script をそこに書いてから走らせるので、`TMPDIR`(か `scriptTempDir`)も原因に挙げる action にする(#446。dir の mode を見るだけで何も書かない)。enforce profile では `~/.npmrc` の `_authToken` 行の有無をキー名のみで scan — 値は読まない・出さない — と managed-by header の有無も報告(#148)。
- AI policy: `enableAiPolicy` / `enableAiTools` の現状。codex-settings が active な profile では Codex 権限面も監視 — managed rules baseline の presence と、**外向き/昇格 probe(push・PR/issue/comment 作成・release・sudo・auth login・clone・curl 等)と、認証情報の表示・secret の読み出しの probe(gh token の表示・env の一覧・keychain の password・1Password の CLI。#334)の固定リストを `codex execpolicy check` で live rules に評価**し auto-allow を warn。probe には Codex が読む rules dir の `*.rules` をすべて渡し(Codex は `default.rules` だけでなく通常 file の `*.rules` を全部読む。symlink と `default.rules.bak.<日付>` は読まない)、baseline 以外の rules file は管理外として名前だけ warn する(#316。見るのは user layer だけで、trusted な project の `.codex/rules/` は対象外)(行 grep は blanket prefix・複数行 rule・decision 省略の既定 allow を見逃し、rule 行 echo は任意文字列由来の secret を漏らしうるため不採用 — doctor は rules file を読まず path を codex に渡すだけ・echo するのは自前の probe 文字列のみ。codex CLI 不在時は skip を明示)、`config.toml` の `[projects]` trust は yq の TOML parser で読み、`trust_level = "trusted"` の project の **key(path)だけ**を取り出す(設定値は出さない・yq の error も捨てる、#148 と同じキー名限定規律)。trusted な home root と実在しない path の残骸を warn(#139)。正当な書き方は TOML の意味どおりに数え、TOML として読めない・projects が文字列や配列・trusted な key が空か制御文字を含む、のときは INCOMPLETE(0 件とは言わない、#292 / #309)。claude-settings が active な profile では Claude の project 級の allow の堆積も監視する(#334): 承認の「次から聞かない」で project の `.claude/settings.local.json` に溜まる allow rule(と `.claude/settings.json` の allow)を、標準の project root(`~/src/{personal,work,client,sandbox,agent}`)直下の repo と、work と client では配置の規約どおり org(client)の 1 段下に置いた repo(`~/src/work/<org>/<repo>`・`~/src/client/<client>/<repo>`。#445)と、HOME の下にあるときのこの repo について読み(work と client の直下の dir は、規約の外に置いた repo として読み、org として 1 段下も一覧する。その dir 自身の `.claude` と `.git` は repo として読まない。同じ dir は 1 回だけ。`.` で始まる名前の repo も含む。検索・一覧できない root と、一覧できない work と client の直下の dir は空ではなく読めない扱い)、外向きの probe(Codex と同じ 30 本。secret の読み出しは floor の deny が allow に勝つので含めない)に Claude Code(2.1.293)の分類どおりに当てる。rule は JSON の文字列ごとに読む(NUL 区切り。改行を含む rule も 1 つの rule のまま)。読むのは 1 回(`yq eval-all`)で、JSON の文書がちょうど 1 つで、同じ object の中で key が重ならないこと(yq は最初の、`JSON.parse` は最後の値を採るため)を求め、評価が最後まで成功したときだけ yq が出す終端の印が無ければ読めなかった扱いにする。中身は先に `\(` `\)` `\\` を戻し、末尾が `:*` で前が空でなく行末の文字(改行・CR・U+2028・U+2029)を含まなければ旧式の prefix(引数なしにも一致、空白の連続は 1 つ、prefix の中の `*` は展開されないのでその rule は一致しない)、`*` を含めば wildcard(前後を JavaScript の `trim()` と同じ文字の集合で locale に依らず落とし(NBSP・BOM などを含む)、rule と command の両方で空白と tab の連続を 1 つの空白に読む。`*` は空白を含む任意の文字列、`\*` は文字の `*`、`/**/` は 0 個以上の dir、唯一の wildcard が末尾の ` *` なら引数なしにも一致)、それ以外は書かれたとおりの完全一致。`Bash` / `Bash()` / `Bash(*)` は全部に一致し、閉じ括弧が escape された rule は Claude Code と同じく無効として飛ばす。live の `~/.claude/settings.json` と、その project 自身の 2 つの file の deny / ask が止める probe は除き(どの file にあっても deny / ask は allow に勝つ)、残りを file ごとに action(先頭 5 本の名前と残りの件数。rule は token を含みうるので出さない)。JSON として読めない file(permissions が object でない、list が配列でないものを含む)と、確かめた不在でないもの(`.claude` が権限などで開けない、設定の path が通常の file でない。cd の errno で見分ける)は item で、1 つでもあれば ok にしない(読めた file に問題が無くても「clean ではない」と item で言う)。live の floor が読めないときも item。clone の中の clone のような深い checkout は見ない(読むのは root の直下までで、work と client では直下の dir の 1 段下まで。そのため規約の外に work と client の直下に置いた repo では、その中の 1 段下の dir も repo として読む)。
- OpenCode(report-only): `opencode` の presence、`opencode-settings` module が active な profile では managed な permission 床 `~/.config/opencode/opencode.json` の presence — 無ければ apply 手順の action、非 active なら not managed。credential store `~/.local/share/opencode/auth.json` は**存在のみ**で中身も provider 名も読まない(#234)。agent-tools の plugin(`plugins/personal-*.js`)は静的に、global の plugins dir にあるかと、`personal-agent-tools` の init(OpenCode の既存の log の目印の行で「確認できた / 未確認(理由つき)」。いちばん新しい目印の build_id が配置中の marker と一致するときだけ確認できた。過去の起動の証拠で、直近の起動の成功ではない。log の行は出さない。#311)と、二重読込(`.ts` / `.mjs` の併置・単数形 `plugin/` dir・OpenCode が読む設定 — managed の床と `OPENCODE_CONFIG` の指す file — の `plugin` 欄に同じ名前。読まれていない `opencode.local.json` だけなら注記)を報告する — OpenCode は起動しない(`opencode debug config` でさえ DB に書き込むため)、設定ファイルは `plugin` 欄だけを読み表示しない。`opencode.local.json` があるのに `OPENCODE_CONFIG` が未設定 / 別 file を指す場合も報告する(未設定のときは `~/.zshrc.local` に `OPENCODE_CONFIG` という文字列があるかだけを見て、あれば非対話 shell 由来として中立表示。中身は表示しない。#263)。この section の末尾に enforceAiSandbox(sandbox ブロックと human-legit write gate の live state)の行も出る。
- Claude MCP exposure(report-only): `gateUnusedClaudeMcp` の deny(claude.ai の Gmail / Google Calendar / Google Drive / Claude Docs の connector と、利用の無いかまれな Notion の書込 tool)の wired 状態。live の file は読まない(#341)。
- tool call record hook(report-only): `enableToolCallRecordHook` の登録(SessionStart と PreToolUse / PostToolUse / PostToolUseFailure / PermissionDenied に `personal-tool-call-record-hook`)の wired 状態。live の file は読まない(#353)。
- GitHub injection guard(report-only): secret floor は managed settings.json の常時 deny 宣言として報告(live の状態は managed drift を参照)、`gateGitHubMcp` の MCP deny の wired 状態、`enableGitHubIsolatedReader` の PreToolUse hook 登録の wired 状態と hook body の presence — body は agent-tools 配布なので存在のみを contents-blind で見る(#137)。`enableGitHubIsolatedReader=false` でも live の `~/.claude/settings.json` / `~/.codex/hooks.json` に登録が残っていれば、file ごとに action にする(下の quality loop hooks と同じ検査。#201)。
- quality loop hooks(report-only): `enableQualityLoopHooks` の PostToolUse / Stop hook 登録を両 home で wired 状態と body presence で report し、check 宣言 `~/.config/agent-tools/checks.local.json` は **presence のみ**を見る — hook が実行する command を列挙する file なので中身は読まない(#199)。capability=false でも live の `~/.claude/settings.json` / `~/.codex/hooks.json` に登録が残っていれば(apply 前の flip、または profile 切替の残置)、file ごとに action にする(`--actions-only` にも出る)。body の path (品質ループは PostToolUse と Stop の 2 本のどちらか) を固定文字列で探すだけで、中身は出さない。その profile が file を管理していれば(settings module が active)`chezmoi apply` を、管理していなければ hook の項目か file を手で消す手順(file を消したら herdr の登録を入れ直す)を出す。在るのに通常の file でない(FIFO なら読むと止まる)、または読めない file は、登録を確かめられないので warn にし、not-wired の ok は出さない(#200 / #201)。親の dir を辿れず在るかを確かめられない file も同じ(不在とするのは、親に入れてそこに file が無いときと、親が無い・dir でないと cd の errno で確かめたときだけ。#439)。
- herdr integration(report-only): `enableHerdrIntegration` の SessionStart hook 登録を両 home で wired 状態と herdr 配置 body の presence で report し、herdr が PATH にあれば `herdr integration status` の currency(current / outdated / needs repair)も出す — body header を読むだけで server 不要。5 秒の期限付きで実行し exit 0 のときだけ採用、不在・失敗・hang は「未確認」と明示して doctor を止めない(一時ファイル不使用・stdin `/dev/null`・期限到達と中断時は probe の process tree ごと回収。各 process を止めてから子を辿る `kill_tree`(`lib-policy.sh`)で、辿っている間に増える子も残さない、#423。doctor 共通の `bounded_probe` helper で、1Password の `op whoami` と共有、#231)。capability=false は宣言上の状態として報告し、herdr 自身の見え方を module の active / inactive に応じた所有者説明つきで添える(#225)。OpenCode が入っていれば、herdr から見た OpenCode integration の状態も中立に表示する(plugin は herdr の installer が置き、dotfiles に登録の役割は無い。#263)。
- herdr config(report-only): `herdr-config` module が active な profile で managed `~/.config/herdr/config.toml` の presence(無ければ `mkdir -p ~/.config` → `chezmoi apply` の action)、doctor を実行した環境の `HERDR_CONFIG_PATH` / `XDG_CONFIG_HOME` が別の file を指していないか(herdr は設定されていれば空でも採用する。同じ綴りか、両方あれば `-ef` で同じ file と判定。presence とは独立に warn し、欠損時の action は読み先がずれていれば「既定値で動く」と断定しない。ずれていれば検証もしない)、herdr が PATH にあれば `herdr config check` の結果(`bounded_probe` の期限付き。exit 0 なら ok、それ以外は action — parse error のとき herdr は黙って全部既定値で動くため。答えが無ければ「未確認」)。herdr の出力は表示しない。module 非 active は not managed(#261)。
- Codex review / worker profiles(report-only): `codexReviewEffort` / `codexWorkerEffort` が配る
  `~/.codex/agent-tools-{review,worker}.config.toml` の **presence のみ**(中身は config 値なので出さない)。
  codex-settings が active な profile では、値があるのに file が無い / `off` なのに file が残る(agent-tools は読み続ける)を
  apply 手順つきの action にし、非 active な profile では手置き・他 profile の残置を中立に表示して `off` 以外の値を
  dangling として warn する。`CODEX_HOME` が `~/.codex` 以外を指すと agent-tools はそちらを読むので warn(#264)。
- agent-tools usage reader(report-only): `agent-tools-usage-reader` module が active な profile で managed
  `~/.config/agent-tools/usage-reader.json` を確認する(読み取り口は実行しない。読み取り口は cache を書くことがあるため)。
  doctor を実行した環境の絶対 path の `XDG_CONFIG_HOME` が別の場所を指せば warn(相対・空は wrapper と同じく無視)、
  無ければ `mkdir -p ~/.config` → `chezmoi apply` の action、指す先の無い symlink なら無いときと同じ扱いの action
  (wrapper は exit 3 = 読み取り口なしにする)、regular file でなければ action。regular file なら、契約に合うかは
  wrapper が判定する(#303): `enableAgentToolsStatus=true` の opt-in の下でだけ、配備済みの
  `~/.claude/agent-tools/scripts/personal-usage-reader` の `--help` の 1 行目に `[--check]` があることを確かめてから
  `--check` を `XDG_CONFIG_HOME` を外して(= managed file に対して)`bounded_probe` で呼ぶ。exit 0 → ok、
  exit 2 → wrapper の理由の 1 行(`display_safe` を通す)を添えた action(手順は `chezmoi apply` と、理由が実行ファイルなら
  tacho の導入 `install-packages.sh`。読み先がずれていれば「ずれを直すまで効かない」と書く)、exit 3(有無の確認の
  後に消えた)→ 無いときと同じ手順の action、それ以外の exit・期限切れ → 未確認の warn。opt-in なし → 未確認の item、wrapper の未配備・`--check` 非対応の旧版 → 未確認で
  agent-tools の sync を示す action、`--help` が失敗する(起動できない wrapper もありうる)→ 未確認の warn。設定の値は表示しない。非 active な profile では手置きの file を中立に表示する(#301)。
- agent-tools(report-only): `~/src/agent/agent-tools`(既定。`AGENT_TOOLS` env で override 可)の presence を表示し(不在は `enableAgentToolsStatus=true` の profile だけ warn。false の profile — agent-tools を配備しない work — では想定どおりの状態として中立表示。#258)、`enableAgentToolsStatus=true` の opt-in 時のみ status contract(`scripts/status.sh --root <checkout> --json`。root は常に明示的に pin する — #73 当時の status.sh は `--root` 省略時に cwd を検査して空 repo を偽報告した。agent-tools#305 以降の既定は script 自身の repo)を実行して安全な summary を出す。sync targets は tool ごとの件数(claude-code / codex / opencode)と、conflict / stale / deployed_but_inactive がどの tool の行かも出す(#263)。clone / pull / sync はしない。
- network tunnels: `allowNetworkTunnels` と tunnel tool の存在。
- project roots: project root の状態。

副作用は持たない。設定不足や未導入 command の warning は report-only として exit 0 のままにする。
remote URL scan の方針は [docs/supply-chain-git.md](../docs/supply-chain-git.md)、npm hardening の検査は [docs/supply-chain-npm.md](../docs/supply-chain-npm.md)、Corepack の検査は [docs/supply-chain-corepack.md](../docs/supply-chain-corepack.md) に従う。
`npmHardeningMode=enforce` の profile では、期待する npm config 値と現在値の不一致を `[warn]` で報告する(apply 前は不一致が正常)。

```sh
./scripts/doctor.sh personal
./scripts/doctor.sh personal --actions-only   # 末尾の next actions 一覧だけ
```

policy validation が失敗した場合は exit 1。`--actions-only` 以外の `-` 始まりの引数は usage error で exit 2(validator に渡さない)。

**next actions**(#227): 具体的な command / 手順を言える warning は `action`(`lib-policy.sh`)経由で
報告され、inline の `[warn]` 行はそのままに、末尾の `== next actions (N) ==` に理由と手順が番号つきで
まとまる(global gitignore の欠損 / pattern drift、git hook gates の hooksPath 未設定 / lingering、safe-gh と品質ループの hook 登録の残置(#201)、
identity reset の欠損、identity file の不在 / partial / 値の無い key、private-backup の不完全な捕捉、
managed-path orphan、managed drift、Codex projects trust の stale / home 全体、OpenCode の permission 床の
欠損、herdr integration の body 不在 / outdated / work 機での未導入、herdr config の欠損 / `herdr config check` の不合格、残量の読み取り口の設定の欠損 / `--check` の不合格 / wrapper の未配備・旧版、agent-tools の dirty / stale)。
判断が要る warning(catalog 外 package 等)は warn のまま。
`--actions-only` は `[fail]` と summary 以外を mute するだけで、doctor はファイルを書かない(report-only)。
手順行も key-name-only / secret を出さない規律の対象。

## test-preflight.sh

`preflight.sh` の report-only 契約と apply-impact 警告を fixture HOME で検証する(#150)。
空 home の exit 0(`~/.config` も無いときは apply が 0700 で作るという item を出す)/ 空 home に対する run(report・引数の拒否・policy validation の失敗)が
その home に何も書かないこと(report-only)/ shell-extra・ssh-1password の replace 警告と override pointer /
非管理 profile の left-as-is / `~/.config` 権限分岐 / config.local の中身非表示 /
`-` 始まりの引数(`-h` / `--all` / `--list-profiles` など)と 2 つ目の引数を exit 2 で拒否し report を走らせない(#309)/
git-ignore の apply impact(既存 `~/.config/git/ignore` の置換 warn と `.git/info/exclude` への pointer、
`core.excludesFile` が別の file を指す・明示的な空値のときの warn、managed path または同じ file の別名なら ok
(設定値は出さない)、work の left-as-is、不在時の ok。
`env -i` で hermetic に回す、#248)/
herdr config の apply impact(既存 `~/.config/herdr/config.toml` の置換 warn、work の left-as-is、不在時の ok、#261)/
agent-tools の残量の読み取り口の apply impact(既存 `~/.config/agent-tools/usage-reader.json` の置換 warn、work の left-as-is、不在時の ok、#301)/
policy validation 失敗時のみ非 0 / commands 節が確認する tool がすべて catalog(name / pkg / bin)か
catalog 外の前提(git / brew / node / npm / corepack)であること(catalog から外れた tool が毎回 warn しない、#259)/
git hook gates の deploy 4 本の readiness(完全な deploy は script ごとと武装と hooksPath が ok。hooksPath は `~/.gitconfig` に直接書いた形と、
apply が配線する形(`~/.gitconfig` の `[include]` が読む `hooks.gitconfig` に書く。読むには `--includes` が要る、#196)の両方で確かめる。identity gate が欠けた旧 deploy は
その script と「武装しない」の warn、script の path が directory でも不完全とする、#307 / #392)/ global の identity・hooksPath・excludesFile、usage-reader.json、herdr config の
値を出さないこと(それぞれの warn は出し、canary は出ない、#307)、をカバーする。

## test-lib.sh

test-*.sh が共有する fixture helper(source 専用、lib-policy.sh の後に source する)。
`set_capability_all` / `remove_module_all` が fixture の profiles.yaml を yq で構造的に
編集し、対象が存在しなければ fail する(行形式一致の awk 直書きが無言で no-op 化して
テストが vacuous pass する事故の再発防止。#149)。ほかに render/fixture 構築の共有形:
`render_profile_into` / `render_personal_into`(throwaway home への profile の apply。後者は personal 固定の形。root は呼び出し側が mktemp +
cleanup 登録する caller-creates-root 契約 — `$(...)` 内で mktemp する形は cleanup trap から
漏れる、#150。呼び出し側が先に置いた ROOT/home の file はそのまま残し、作り直さない。chezmoi の home directory は
`HOME` に従うので、別の home で render するときは `HOME=... render_profile_into ...` と呼ぶ)、`make_flipped_source` / `flip_personal_capability`(source copy + personal
限定 capability flip。boolean 専用。personal が宣言していない capability は fail する、#332)、`copy_repo_fixture`(scripts + .chezmoidata の最小
repo copy)、`strict_json_object`(file がちょうど 1 つの JSON の object であることを jq で確かめる。yq の JSON の reader は
object の先頭・末尾の comma、member の間の comma の抜け、複数の document、空の file を受け付けるので、JSON の妥当性の
検査はこちらで行い、中身は yq で読む、#478)。

CI で飛ばしてはいけない case の gate(#484): `ci_gate PROBE...` は、PROBE(1 つの command と引数)が通れば `run`、
通らなければ CI(`CI=true`)では `fail`、それ以外では `skip` を出す。CI での skip は case が走らなかったことなので、
導入の step が消えたり PATH が壊れたりしても green にしない(#330)。PROBE の出力は捨て、stdin は `/dev/null` にする。
1 つの gate には 1 つの道具を渡す(`command -v a b` はどちらかがあれば通る)。`fail` を case の失敗にし、`skip` を報告する
のは呼び出し側(test-codex-settings.sh の codex は item、test-private-backup.sh と test-starship.sh の python3 は warn)。
gate 自体は test-policy.sh が 1 回だけ確かめる。

case の行と stub の helper(#485。5 つの suite の写しをまとめた): `pass MESSAGE...` / `miss MESSAGE...` は、case ごとに
`[ok] test passed: ...` / `[fail] test failed: ...` を出し、`miss` は読み込む側の suite の `status` を 1 にする。全部の case を
報告してから集めた status で終わる suite(test-gclone・test-install-packages・test-preflight・test-private-backup・
test-secrets-gate)が使い、最初の失敗で止まる suite(test-policy など)は使わない。`write_fake_chezmoi DIR PAYLOAD RC` は、
何を聞かれても PAYLOAD(`chezmoi data` の答え)と改行を出して RC で終わる `DIR/chezmoi` を作る。PAYLOAD は single quote で
引用して書くので、quote を含んでも壊れない。`write_call_recorders DIR LOG RC NAME...` は、NAME ごとに、`NAME 引数` を LOG に
足して RC で終わる `DIR/NAME` を作る。LOG は先に作らないので、「呼ばれなかった」は LOG が無いことで確かめられる。どちらも RC は
数字だけを受け付ける。subcommand ごとに答える stub(doctor の chezmoi や manager)は、それぞれの suite に残す。4 つとも
test-policy.sh が確かめる。

report の照合の helper(#483): `expect_report OUTPUT EXPECT... [! ABSENT...]` は、手元にある出力を照合する。各 EXPECT が
exact な行として(先頭が `~` なら部分一致で)あり、`!` のあとの文字列がどこにも無いことを確かめる(2 つ目からの `!` は区切り
だけ)。外れたときは出力と、外れた期待ごとの 1 行(`expected line:` / `expected text:` / `unexpected:`)を stderr に出し、1 を
返す。command の実行と ok / fail の報告は呼び出し側が持つ(test-doctor.sh の `doctor_expect`・`hg_expect`・`cx_expect`・`op_expect`)。

process の後始末の helper(#413): `kill_tree`(PID と子孫を KILL。各 process を SIGSTOP で止め、ps で止まったことを確かめてから子を
列挙するので、辿っている間に新しい子を作れない。確かめられなければ warn して続ける。doctor の期限付き probe の後始末と共有するので
`lib-policy.sh` に置く、#423。停止の待ちと warn は test-doctor.sh の KT が確かめる、#440)、`stop_child_trees`(この shell が起動して回収していない
process を子孫ごと KILL して回収する。suite の cleanup が、登録した PID ではなく全部の子を止めるので、中断の signal が届かない
background の case(`set -m` の job や、INT を無視する非対話 shell の background job)の登録漏れが起きない)。
`check_suite_interrupt` / `suite_interrupt_inner` は、suite を `SUITE_INTERRUPT_CUE` 付きで起動し直し、trap を張った直後に
background の case と同じ形の process の木を 2 つ起動させてから TERM を送る。1 つは `set -m` の job、もう 1 つは素の background job で、
最初の子が終わると新しい子を起動する wrapper(辿っている間に増える木)。run の PATH の先頭の `pgrep` の shim が、wrapper の子を決まった
順で返し、2 つ目の子の列挙の前に「wrapper が止まった」か「新しい子が記録された」まで待つので、止めずに辿る cleanup は timing に依らず
新しい子を残す。`sleep` はすべて check ごとに一意の時間で起動し、記録されなかった process も `pgrep -f` で見つける。木の前に、内側の
run の fixture に、中身のある権限の無い dir を置く(権限を外す case の途中で中断されたときの形。後始末が先に mode を戻さないと
`rm -rf` では消えない。#440)。中の file が見えないこと(mode が効くこと)を確かめてから cue に記録し、root では mode が効かないので
その部分は skip する。異なる 5 つの process が TERM の前に生きていて、suite が TERM で終わり、権限の無い dir が記録され(root を除く)、
check の process がどれも残らず、fixture が消えることを確かめる。check の一時 dir と内側の run の fixture(TMPDIR)は呼び出し側の
fixture の下に作るので、呼び出し側の suite が check の途中で中断されても残らない(test-private-backup.sh / test-doctor.sh の冒頭で使う)。

Git の fixture の helper(#389。2 つの suite の写しを #482 でまとめた): `fixture_git_env HOME GLOBAL_CONFIG [NAME=VALUE...] -- CMD...` は、呼び出し側の環境を PATH の
ほかは引き継がずに(`env -i`)CMD を走らせる。HOME は fixture の home、XDG_CONFIG_HOME はその `.config`、`LC_ALL=C`、system の config は切り、
global の config は GLOBAL_CONFIG にして、`--` の前の NAME=VALUE を足す(pair でない語や CMD が無いときは fail する)。suite を
hook が走らせると GIT_DIR などが export されていて、fixture の git が親の repo を指すため。`check_git_env_isolation RUN_GIT DIR` は、
suite の run_git がその環境を落とすことの自己検査。無関係な repo の GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE / GIT_CONFIG_* を
export した下で、init / add / commit / checkout / config が fixture の repo に入り、無関係な repo の HEAD・refs・index・config が
byte 単位で変わらないことを確かめる。check は渡した wrapper だけを守るので、test-gitconfig.sh と test-git-hook-gates.sh が
それぞれ自分の run_git で呼ぶ。

## test-shell-syntax.sh

CI の bash / zsh syntax check をそのまま取り出し、各入力ファイルへ構文エラーを
順番に挿入して非 0 になることを検証する。先頭ファイルだけの検査や、後続ファイルの
成功で途中の失敗が隠れる退行を防ぐ(#211)。
bash32 job の bash 3.2 の syntax check(`bash syntax check (bash 3.2)`)も同じ形で取り出して検証し、job 名や step 名が変わったら「missing CI syntax step」で fail closed する。
CI の suite の配線も確かめる: validate job の step が呼ぶ suite と bash32 job の render 以外の group の suite、render job の step が呼ぶ
suite と bash32 の render group の suite、両 job の和と `docs/github-workflow.md` の「最低限の validation」の最初の一覧、両 job の和と
`scripts/test-*.sh`(source 専用の `test-lib.sh` と、`test-install-packages.sh` から呼ばれる `test-inventory.sh` を除く)が、
それぞれ同じ集合であること(job ごとに比べるので、両 job で走る `test-npmrc.sh` を片方から落としても検出する。どれかの一覧が空なら
fail)、bash32 の `test-doctor.sh` の part が 1 から `doctor_parts` まで 1 回ずつあること、`test-install-packages.sh` が
`test-inventory.sh` を呼んでいること、bash32 job の step が `if: matrix.group == '<group>'` で名指す group がすべて matrix に
あること(bash 3.2 の syntax check と validate-policy は others group でだけ走るので、group の名前が変わると黙ってどこでも
走らなくなる。名指す step が 1 つも無ければ fail)。

## test-zshrc-compinit.sh

`dot_zshrc` の compinit の block(`autoload -Uz compinit` から fzf-tab の節の前まで)を managed file から
抽出し、fixture の HOME を持つ隔離 zsh(`zsh -f`)で日次キャッシュの選び分けを検証する(#329)。実 home の
`~/.zcompdump` には触れない。dump が無いとき・24h より古いときは遅い経路(`compinit -u`)を通り、その後の
dump が 24h 以内の扱いになること(compinit は補完 file の数と zsh の版が変わらない限り既存の dump を書き直さない
ので、mtime を進めないと以後のすべての shell が遅い経路を通り続ける)、24h 以内の dump は速い経路
(`compinit -C`)で手を付けないことを確かめる。CI の `zsh -n` は構文しか見ないので、この種の退行を検出できない。

## test-zshrc-order.sh

`dot_zshenv` と `dot_zshrc` を丸ごと、fixture の HOME・fake の mise・fixture の HOMEBREW_PREFIX(stub の brew bin と
plugin)を持つ隔離 zsh(`zsh -f`、`env -i`)で対話 login shell の起動順(`~/.zshenv` → `brew shellenv` → `~/.zshrc`)
どおりに source し、PATH の順序と読込順を固定する(#333)。実 HOME・実 mise・実 brew・実 `~/.zshrc.local` には触れない。
判定は最終 PATH の文字列ではなく「どの `claude` が勝つか」(`command -v claude` の解決先)と order log で行う。

- 非対話(`~/.zshenv` のみ): `~/.local/bin` が mise の shims より前(shims が PATH に届いていることを先に確かめ、
  shims 不在での空振りを防ぐ)。
- 対話: `brew shellenv` の前置で `~/.local/bin` が埋もれる対照を確かめたうえで、`~/.zshrc` が `mise activate` の後・
  `~/.zshrc.local` の前に `~/.local/bin` を再前置すること(fake mise の前置が PATH に届いていることを先に確かめる)。
- `~/.zshrc.local` が足した PATH entry はそれでも勝つこと。
- 読込順が mise activate → `~/.zshrc.local` → zsh-autosuggestions → zsh-syntax-highlighting(最後)であること。
- `~/.zshrc.local` が managed の keybinding(Ctrl-O)より後に読まれ、local の付け替えが source 完了後も残ること
  (local が読まれた時点で managed の Ctrl-O が bind 済みであることを先に確かめ、空振りを防ぐ。PATH の検査と
  order log だけでは、source を PATH 再前置の直後へ動かす退行を捕まえられない)。

fake の mise は「activate が PATH の先頭に dir を足す」形だけを模す(precmd の hook で installs の bin を足す側は対象外)。
`dot_zprofile` は `/opt/homebrew` の絶対 path を見るので、上の driver は source せず `brew shellenv` の PATH 前置だけを模す。
`dot_zprofile` 自体は別の driver で、`/opt/homebrew` を fixture の相対 path に置き換えた copy を source して確かめる(#384):
fake の brew の shellenv を読んだ後に `~/.zprofile.local` を読み、local が変数でも PATH でも勝つこと。`~/.zprofile.local` を
置かない対照では brew の値が残ること(local が値を変えていることと、brew の行に届いていることを確かめる)。
`~/.zprofile.local` のある HOME では、`dot_zprofile` が前置し直す `~/.local/bin` と mise の shims にも同名の probe を置き、
local の dir の方に解決すること(#413。前置し直しの行を `~/.zprofile.local` の後へ動かすと fail する)。

## test-ai-clip.sh

`dot_zshrc` の Ctrl-O helper(`_ai_clip_strip_ansi` / `_ai_clip_copy` / `_ai_clip_run`)を
managed file から抽出し、fixture の TMPDIR と fake `pbcopy` を持つ隔離 zsh(`zsh -f`、`env -i`)で
振る舞いを検証する(#243)。実 clipboard・実 home・network には触れない。

- 平文出力の一時 file(`ai-clip.*`)が、正常終了・非 0 終了・**SIGINT による中断**のいずれでも残らないこと
  (`always` block。末尾の `rm` だけでは Ctrl-C で残っていた)。中断は 2 経路で検証する: shell 自身への
  `kill -INT $$`(対話 zsh `-i`。非対話 zsh は SIGINT で即死し always に到達しないため)と、pseudo-terminal
  (`script(1)`、BSD / util-linux 両対応)経由で外部コマンド(`sleep`)実行中に送る**本物の Ctrl-C**。どちらも
  到達 marker で「中断前まで実行・中断後は未実行」を確認し、旧実装(末尾 `rm`)が file を残すことを対照として
  assert する(空振り防止)。
- コマンド自身の exit status が返り、clipboard 失敗(`pbcopy` 不在・OSC 52 未 opt-in)は stderr の警告のみで
  status を変えないこと。どちらも status 1 と 1 以外(3 / 5)で確かめ、失敗を全部 1 にする wrapper を通さない。
- コマンドは現在の shell で実行され `cd` / `export` が残ること。
- コピー内容が「`$ コマンド`」+ 出力 +「`[exit status: N]`」であること。
- コマンドが wrapper の内部の変数名に代入しても壊れないこと(#280): 正常終了と非 0 の終了では、既存の file が無事で
  一時 file が消え、表示 / copy / status が正しく、代入が current shell に残ること。SIGINT と pty の Ctrl-C による
  中断では、既存の file が無事で一時 file が消えること。
- `mktemp` が失敗したら status 1 で、コマンドを実行も copy もしないこと(#280)。
- Ctrl-O の widget(`_ai_clip_accept_line`)を抜き出し、zle と `print -s` を stub にした隔離 zsh で、空白で始まらない行は
  そのまま履歴に保存され、BUFFER が空白で始まる wrapper の呼び出しになり、それを eval すると元の行が 1 つの引数として
  展開されずに渡ること(行の中の command substitution は実行されない)、空白で始まる行は保存されないこと、空の行は
  accept するだけであること(#307)。
- pbcopy が無く `AI_CLIPBOARD_OSC52=1` のとき、copy が OSC 52(`ESC ] 52 ; c ; <base64> BEL`)として端末に届くこと
  (`script(1)` の typescript で確かめる、#307)。

## test-policy.sh

外部 test framework を使わずに policy validation の fail-closed 挙動を検証する。
一時 directory に data files と scripts をコピーし、fixture を壊して `validate-policy.sh` が失敗することを確認する。

```sh
./scripts/test-policy.sh
```

検証内容:

- `validate-policy.sh --all` が全 profile を検証すること。
- `validate-policy.sh --all` が一時 file を作らないこと(#329。後始末の途中に 2 つ目の signal が届くと、trap の後始末が
  終わらずに file が残りうるため。#358): 呼ばれると marker を残して失敗する `mktemp` を PATH の先頭に置き、空の directory を `TMPDIR` にしても
  通り、marker も `TMPDIR` の中身も残らないこと。
- enum capability の許可値を正しく受け入れること。
- unknown profile / module / capability(module の `requires:` 内も)、重複 capability / module、enum の不正値、
  environmentKind の欠落 / 未知の値、schema が宣言する capability の欠落を拒否すること。
- boolean capability・`requires:` 内の boolean 条件値・`implemented:` は YAML boolean の小文字 `true` / `false` だけを受け入れ、
  文字列 / 数値 / null / 大文字綴りを拒否すること(#206)。
- `requires:` 自体の boolean / 文字列 / 数値 / 配列は exit 1 で拒否し、module 名と map が必要な旨を表示すること。
  省略・null・空の map は条件なしとして許容。不正な型や列挙失敗時には runtime の active 判定も失敗すること(#391)。
- 同一 path を複数 module が宣言したら fail、`requires:` に条件を持つ module は `paths:` 必須。
- module の `paths:` の各 path(#207): 先頭 `/` の絶対 path と `..` を含む path は、home 相対でないとして拒否すること。
  どちらも 1 回の実行で、文言と module の検査の fail を pin する。pattern 文字・空白・先頭 `~`・末尾 `/` は、リテラルで
  ないとして拒否すること。
- capability の `type:` が boolean / enum のどちらでもない(schema の typo)と、module の `requires:` の検査と profile の
  検査の両方で fail すること。`requires:` に使われる capability で、1 回の実行で両方を pin する。
- profile の `modules:` と module の `paths:` の型(#412): 文字列・bool・数値・map と、文字列でない要素を含む list を
  拒否すること(`requires:` の無い module の `paths:` でも)。型の読み取りと、型が正しいあとの列挙のどちらに失敗しても、空の list と扱わずに fail すること
  (失敗させる読み取りは 1 case に 1 つ)。
- 要素の中の制御文字(#422): 列挙は要素ごとに 1 行を出すので、改行を含む 1 要素が 2 つの名前に分かれ、どちらも検証を通って
  いた(`.chezmoiignore` は要素そのものを `has` で比べるので、どちらも有効にならない)。正しい 2 要素を改行で 1 要素に
  つないだ modules と paths、tab を含む module 名、C1 の制御文字(U+009B)を含む path を拒否し、非 ASCII の名前は型の検査を
  通すこと(制御文字は Unicode の Cc。ASCII の `[[:cntrl:]]` は C1 を通していた)。
- 名前・条件・許可値の中の制御文字(#428): 正しい名前や値を改行でつないだ module の `requires:` の値と key、enum の
  `values:`、module・capability・profile の名前(`--list-profiles` も)を拒否し、C1 を含む `requires:` の値、tab を含む
  `values:` の要素と profile の capability 名、末尾に改行や C1 を持つ profile の capability の値、map の `values:`、
  list の `capabilities:` を拒否すること。非 ASCII の key と
  値は通し、文字列でない key は拒否すること。各読み取りの失敗も fail にすること。
- `requires:` の空白(#430): 値の前後の空白、key の前後の空白、空白を含む key に空の値の組み合わせ
  (`"npmHardeningMode enforce": ""`)を拒否し、値の途中の空白・文字列でない値・無い map は空白の検査を通すこと。
  読み取りの失敗も fail にすること。空の key は次の項目。
- 空の名前・要素・key(#438): 空行として読み飛ばされ、どれも通っていた。`paths: ["**"]` の空の名前の module を profile に
  足した fixture(名前が `zz` の対照は path の検査で fail)、空の path(単独と、正しい path との組み合わせ)、profile の
  `modules:` の空の要素、空の profile 名(`--list-profiles` も)、空の capability 名、profile の `capabilities:` の空の key、
  enum の `values:` の空の値、`requires:` の空の key(`"": "npmHardeningMode enforce"` と `"": ""`)を拒否すること。
  `yaml_read_safe_entries` は単独でも空の key を拒否すること。
- software catalog(#53): unknown source / go_install の pkg 欠落 / name 重複 / track_only 不正 / 空 catalog を拒否。
- backup-paths(#60 / #246): 絶対 path / `..` / glob / unknown type / 重複 / 空 entry / 空 catalog に加え、
  共有 parser の構造検査として category の `|`・path 内の改行・非 string の type・list の代わりの scalar
  (`backup_paths: false`)を拒否。
- environmentKind 制約: work / client / agent で権限付与型 capability の true、sandbox の
  allowSecretsAccess、`npmHardeningMode=off` を hard fail。`npmHardeningMode=off` は、禁止の boolean がすべて false の
  work の profile を各 kind に付け替えて enum の行だけの違反にし、exit code まで pin する。personal を各 kind に付け替えた
  fixture でも、boolean の行と同時に enum の行が報告されること。権限を与えない capability と値(安全強化型の
  `enforceAiSandbox` / GitHub guard 2 本 / `gateUnusedClaudeMcp`、agent の hook を足すだけの `enableQualityLoopHooks` /
  `enableHerdrIntegration` / `enableToolCallRecordHook` の true、`npmHardeningMode=enforce`、`codexReviewEffort` /
  `codexWorkerEffort` の `xhigh`)は、fixture の定義済み profile(personal / work)で許容されること(forbidden 表に
  入っていないことの、その 2 つの kind での pin。case ごとに別の fixture の `--all` で確かめる。ほかの kind の forbidden
  表への追加は、この case では見ない)。forbidden-enum 表の不正行(schema に無い値・`=` の無い行)は fail closed。
- capability registry(#151): `implemented:` 欠落は fail、`implemented: false` は doctor.sh がその名前に
  言及していなければ fail(undisclosed dormant)。
- 単一 dash の option は usage error、非 mikefarah yq / v4 未満は fail closed、空の profiles / schema は fail closed。
  yq の version の文字列は他の tool の出力なので、端末の escape を `?` にして表示し、fake の yq のどの case でも生の ESC を
  出さないこと(#335)。
- software catalog drift(`report_catalog_drift`): fake の brew / npm / go(と yq・coreutils)だけを置いた PATH で、
  drift なし・catalog 外の brew leaf / go binary・未 install の宣言・source 不一致(info)・Go toolchain 自身の
  binary を sprawl にしないこと・manager 不在時の skip を検証し、いずれも exit 0(report-only)であること。
- report の書き込みと signal(#378): 満杯の pipe への書き込みが塞がっている最中に子が終わっても(bash 3.2 の SIGCHLD は
  SA_RESTART なしで、builtin の printf が EINTR で失敗し set -e で止まっていた)、`item` / `warn` の 3000 行(stdio の
  buffer より長い行を含む)が 1 回ずつ順に届き、script が最後まで走ること。どの段も時計ではなく合図で進める。素の builtin
  で書く対照が bash 3.2 では途中で止まることも確かめる(再現しない fixture で空振りしないため。bash 4+ では報告だけ)。
  fd が閉じていれば `report_write` は失敗のままであること。
- bash 3.2 だけで(bash 4+ では skip): 書き込みが塞がっている最中に script へ送った TERM で trap が 3 秒以内に走り、
  `report_write_stop` が書き手を残さず、書きかけの行が届かず、その後に書き進めないこと。trap の `report_write_stop` の
  最中に 2 回目の signal(pgrep の shim から HUP)が来ても書き手が終わること。signal で終わるのは期待どおりなので、
  bash 3.2 が pipeline を回収するときに出す `Terminated: 15` / `Hangup: 1` は表示しない。
- doctor / preflight / validate-policy / install-packages / private-backup の EXIT trap(doctor と private-backup は
  INT / TERM の trap も)が `report_write_stop` を呼ぶこと(静的検査)。

## test-gitconfig.sh

`dot_gitconfig` の Git identity 安全境界を検証する。

```sh
./scripts/test-gitconfig.sh
```

検証内容:

- source に `user.useConfigOnly = true` と `transfer.credentialsInUrl = die` が含まれること。
- 全 context(personal / work / client / sandbox / agent)の `includeIf`・include path(identity reset・signing・
  gh の credential helper・git-hook-gates の include も含む)と、その**順序**が exact pin と一致すること(#202: personal の hasconfig 3 本 →
  personal gitdir → 非 personal 4 context それぞれで identity reset → context file の隣接 2 段 → mechanism の無条件
  include)。header は行頭、path の行は comment でないことまで見る(comment にした行は存在の grep なら通ってしまう)。
- hasconfig の rule が public な personal の 3 pattern だけであること(comment の行も含めて、ほかの org の URL を書かない)。
- source に identity 値(`name =` / `email =`、email らしき値)が含まれないこと。
- source に chezmoi のテンプレート構文が含まれないこと(fixture は source を git に直接渡すため)。
- local fixture で、known root 外では commit が identity 未解決を理由に失敗すること。
- local fixture で、`~/src/personal/` 配下では identity file の identity が解決されること。
- credential 入り remote URL が、接続の前に `fatal:` の行で拒否されること(#413。git は warn でも die でも同じ
  「uses plaintext credentials」を出し、warn は接続に進んで別の理由で失敗するので、exit status と文言だけでは区別できない)。
  対照として、`-c transfer.credentialsInUrl=warn` では同じ文言が `fatal:` なしで出ること。どちらも閉じた localhost の port に
  向けるので、warn に退行しても名前解決をせず、machine の外へ出ない。
- 全 context(personal / work / client / sandbox / agent と root の外)で、managed な include(identity reset・signing)を
  置いた状態の `transfer.credentialsInUrl` の実効値が `die` であること(#413。後から読む include の上書きを見る)。
  template の git-hook-gates の include は、source がこの key を書かないことを確かめる。
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
- template が `min-release-age-exclude`(7 日の待ちから外す package)を設定しないこと(#443)。
- template の設定値と `doctor.sh` の enforce 期待値が一致していること。`min-release-age=7` は、古い npm の形(`before` が
  約 7 日前の cutoff)を見る `npm_before_within_age_window` の呼び出しの引数が 7 日・±12h(`7 43200`)に固定されていることを
  確かめる(窓の幅は doctor の run では見分けられないため)。今の npm の形(`min-release-age` が 7 で `before` が null、かつ
  `npm config list` のどの source にも `before` が無い)と `min-release-age-exclude` の件数の検査は、`test-doctor.sh` が doctor を
  走らせて挙動で固定する(#443)。ただしその run は今の npm の形の age を 1 と 7 にしか置かないので、age の項だけはここで静的に
  固定する: `npm min-release-age=7 honored (before unset)` を出す branch の条件(直前の if / elif の文。行の継続は 1 行に
  つなぐ)が、age を `"$npm_age" == "7"` の形でだけ比べ、`||` を持たないこと(`-ge 5` のように緩めた条件は 1 と 7 の run を
  通ってしまう)。また、その run の fake npm は stderr に何も書かず、知らない引数を無視するので、doctor が
  `"$(npm config list --json 2>/dev/null)"` をそのまま読むこと(npm の stderr を捨て、引数を足さない。comment の行は数えない)も
  ここで静的に固定する。

静的検査は chezmoi 無しで実行できる(CI の validate job)。chezmoi がある環境では加えて personal を
throwaway destination に実 render し、生成された `~/.npmrc` の内容(hardening 値・token / registry の
不在)も検査する(#150。CI では render job が担い、chezmoi の無い validate job は skip を warn する)。

## test-doctor.sh

fixture HOME(+ repo copy の capability flip・PATH 先頭の fake command)で doctor の各 section を
検証する。実 home には触れない。op / herdr / codex / opencode / gh と、package manager の brew / npm は、冒頭で PATH の先頭に
置く stub が受け、実機の tool は起動しない(#306、#458。gh は #492 の doctor が PATH の上の有無だけを見るので、host の gh で
結果が変わらないように置く)。stub は PATH 上に在り、実行すると記録して exit 1 になる(在るが
使えない側の分岐。たとえば op は「not found」ではなく「サインインしていない」、software catalog と npm hardening は warn に
なる)。brew と npm を stub にするのは、本物が fixture の HOME に書く(brew は新しい HOME ごとに formula の API を取って cache
に書き、npm は log を書く)うえ、doctor の 1 回を倍近く遅くするため。fake が要る section(npm の NPM・DS など)は、その前に
自分の fake を置く。

```sh
./scripts/test-doctor.sh
TEST_DOCTOR_PART=2 ./scripts/test-doctor.sh   # part 2 だけ(共通の setup と、その part の case)
```

case は、続いた範囲ごとに 3 つの part(part 1: 冒頭の orphan の check から herdr integration の手前まで、
part 2: herdr integration から AI policy の手前まで、part 3: AI policy から最後まで)に分かれる(#456)。CI の macOS の
bash32 job は、part ごとの group(doctor-1〜3)で並列に回す。`TEST_DOCTOR_PART` が空か未設定なら全部の part を回し、
1〜3 以外の値は case を 1 つも走らせずに exit 2 で止まる(打ち間違いで何も確かめずに通らないため)。part を
またいで使う helper・fixture の HOME・host の stub は、part 1 の前の共通の setup に置く。

検証内容(section ごと):

- suite 自身が中断されたとき(TERM)、background の case(HI-d3 の doctor、QL-f5 の doctor と OCP-i10 の init の reporter の FIFO の run)の process の木を残さず、
  fixture を消すこと(#413。test-lib.sh の `check_suite_interrupt`。cleanup は全部の子を止めてから fixture を消す)。fixture に
  権限の無い dir が在っても消すこと(権限を外す case の途中の中断。cleanup は先に mode を戻す。root では skip。#440)。
- managed-path orphan: header があり現 profile で管理対象でない file が warning / 管理対象の
  profile では orphan にならない / header 無しは対象外 / 宣言した file の祖先の directory の下に再帰しない(#174 / #207)。
- managed drift: fake chezmoi の status 行ごとに warn、空なら ok、`chezmoi status` の失敗は、chezmoi の config が無ければ
  「not initialized」の item で skip、あれば `chezmoi status` を示す action(#309)、config があり `TMPDIR` が dir でなければ
  `TMPDIR` を挙げる action(#446。いずれも exit 0)/ enforce の `~/.npmrc` は `_authToken` 行を件数だけで warn(値は出さない。
  行が無ければ ok)し、line 1 の managed-by header は ok、欠落は warn(#148)。
- agent-tools: status.sh 実行が opt-in(`enableAgentToolsStatus`)/ opt-in 時は summary + `conflict` を
  warn / contract version 不一致・status.sh 欠如・非ゼロ exit・不正 JSON・不在でも warning のみ(不正 JSON は
  contract_version unknown として field を解釈しないことを、contract version 不一致と同じ sentinel の不在で pin、#332)/
  `AGENT_TOOLS` override(#71 / #73)。
- private-backup: marker 不在は allowSecretsAccess=true の profile だけ warn(false は中立)、marker
  ありで最終成功時刻 / archive / 件数、不正 marker は unreadable、local 補足は**存在のみ**(#174)。marker の
  `capture_incomplete` が false なら `capture: complete`、true なら再 backup 手順の action、field の無い旧 marker
  なら unknown になること(#242)。marker の archive が `-` で始まる名前(`--out ./-archive.age` が記録する形)でも
  名前をそのまま出し、exit 0 で next actions まで進むこと(#444。basename が option と読んで doctor が exit 1 で止まって
  いた。`backup.age` の case が対照)。directory を含む値(手で書き換えた marker)は最後の要素だけを出して directory を
  出さないこと。`/` で終わる値は名前が残らないので unknown になること。
- global gitignore(#248): managed file を git が読んでいれば ok / 不在は `mkdir -p` → `chezmoi apply` の action /
  `core.excludesFile`(global、または system だけの設定)や `XDG_CONFIG_HOME` で別の file に振り替わっていれば
  warn(`GIT_CONFIG_NOSYSTEM=1` なら system の値は無視。`XDG_CONFIG_HOME` が `~/.config` への symlink なら同じ file として
  ok。`~/.config//` のような末尾の `/` は全部落として managed の path になること。file がある間は `-ef` がこの綴りも同じ file と
  見るので、doctor の run ではなく `git_default_excludes_file` を直接確かめる。#309)/ 明示的な空値は「global excludes を読まない」warn /
  config が読めなければ「不明」の warn / pattern 行の欠落は drift の action / work は not managed。どの run も
  `env -i` で hermetic。
- git signing / SSH(1Password): capability true + module active は managed、module 除去は dangling。
- GitHub injection guard(#119 / #137): secret floor の常時 deny 宣言と managed drift への案内(旧 active 文言は出さない)、`gateGitHubMcp` / `enableGitHubIsolatedReader`
  の wired 状態、hook body の presence(contents-blind)、`enforceAiSandbox` の human-legit gate 開示。claude-settings を外した
  run(QL-e)で `gateGitHubMcp` / `gateUnusedClaudeMcp` / `enableToolCallRecordHook` / `enableGitHubIsolatedReader`(Claude 側)が
  dangling になり、claude-settings が非 active なら secret floor・human-legit gate・main-push の注記を出さないこと。
- quality loop hooks(#199): 両 home の登録 + body presence、`checks.local.json` は presence のみ(canary で
  中身を漏らさない)、cap off の not-wired、live file に残置した登録の lingering warn、module 除去の dangling。
  profile 切替の残置(#201): 両 hook の capability が off で claude-settings が非 active のとき、両 file に残った
  safe-gh と quality-loop の登録が file × capability ごとに action になり、管理していない Claude 側は手で消す、
  管理している Codex 側は apply と案内すること(canary で中身を漏らさない)、`--actions-only` にも手順つきで出ること、
  PostToolUse の fast-edit-check だけが残っても品質ループの残置になること、読めない file(root では skip)と FIFO
  (期限つきで実行し、止まれば kill して fail)は未確認の warn になり ok が出ないこと、検索できない ~/.claude や loop する symlink の ~/.codex の下の file は在るかを確かめられないので未確認の warn になり、残置の action も ok も出ないこと(root では skip)、親が無い・dir でないときは不在と確かめて両方の not-wired が出ること(#439)、file が無ければ両方の not-wired が出ること。
- herdr integration(#225): body 不在 / exec bit なし body / dir body / 末尾改行なしの status 応答 /
  outdated・needs repair / status が非ゼロ exit(出力を採用しない)/ hang(期限で process tree ごと回収)/
  probe 稼働中に doctor を SIGTERM(trap で回収・rc 143)/ cap off の module active・inactive 別の表示 /
  module 除去の dangling。fake herdr は ok・fail・hang・interrupt・ok-nonl の mode を持つ。
- herdr config(#261): PATH 先頭の fake herdr で `herdr config check` の exit を決め、`__rc=0` などの行を出してから
  失敗しても終了状態として読まれないこと(#335)、present + exit 0 → ok /
  exit 1 → action(stdout に何も出さない失敗も同じ。probe は stderr を捨てるので、診断を stderr に出す check はこの形で届く。
  「答えが無い」は期限内に終わらない check だけ)/ missing → `mkdir -p` → `chezmoi apply` の連続 2 step の action / `HERDR_CONFIG_PATH`(別 file・
  空値)と `XDG_CONFIG_HOME`(別 dir・空値)の振り替え → warn で、present なら検証しない(fake は exit 1 を返すので、
  走れば action が出る)、missing なら redirect warn と「既定値」と断定しない missing action の両方 /
  `XDG_CONFIG_HOME=~/.config/`(末尾 `/`)と `~/.config` への symlink(`-ef`、#307)は同じ file 扱い / work → not managed。どの run も
  `env -i` で hermetic。
- agent-tools の残量の読み取り口(#301 / #303): fixture の HOME に fake の wrapper(`--help` と `--check` の exit・
  1 行目・理由を control file で決める)を置き、missing → `mkdir -p` → `chezmoi apply` の連続 2 step の action /
  `--check` exit 0 → ok(JSON でない file でも wrapper が受ければ ok = doctor は形を自分で判定しない)/ exit 2 →
  wrapper の名前の接頭辞を外した理由つきの action と apply → install の連続 2 step(理由の ESC・CR は除く。理由が
  無ければ括弧なし)/ exit 3 → `mkdir -p` → `chezmoi apply` の連続 2 step の
  欠損の action / 契約の外の exit(1)→ 未確認の warn / `--help` に `[--check]` が無い旧版 → 未確認と sync の action /
  `--help` が失敗する(exit 127)→ 旧版とは断定しない未確認の warn。どちらも `--check` は呼ばない / wrapper が実行できない・無い → 未配備の action / opt-in なし(opt-out の
  repo の写し)→ 未確認の item で wrapper を一度も呼ばない / regular file でない → action / 指す先の無い symlink →
  「読み取り口なし」の action(wrapper は exit 3 にするので失敗とは書かない)。どちらも `--check` は呼ばない / 絶対
  path の `XDG_CONFIG_HOME` が別の場所 → redirect warn(missing でも `--check` の不合格でも「ずれを直すまで効かない」の
  action で、wrapper の失敗とは断定しない)、相対の `XDG_CONFIG_HOME` と `~/.config/`(末尾 `/`)と `~/.config` への
  symlink(`-ef`、#307)は同じ file 扱い / work → 手置きは中立の item、無ければ ok(読み先がずれていれば、どちらも
  「wrapper が読む」「読み取り口なし」と断定せず、ずれた先を示す)。設定の canary が出力に出ないこと。fixture の
  reader は実行されると、wrapper は `--help` / `--check` 以外で呼ばれるか `--check` が `XDG_CONFIG_HOME` を見ると
  marker を残し、全 run の後に marker が無いこと。どの run も `env -i` で hermetic。
- 1Password(#231): fake op の signed in(ok 1 行だけ。doctor の stdin に行を流し、fake は自分の stdin が
  `/dev/null` でないと印を残す — 印が無いこと = stdin 隔離)/ signed out(既存 warn)。fake op は ok・fail の mode を
  持つ。応答の無い `op whoami`(期限で回収し「未確認」の warn だけを出して次の section へ進む。signed in / out とは
  断定しない)は次の respawn の case が見る。期限の時点で既に動いている孫の回収は、共有の `bounded_probe` の側で
  HI-d2 / HI-d3 が見る。
- 1Password の respawn(#423): fake op は、自分の子の列挙が取られるまで待ってから次の command(一意の
  `sleep 3000.<数字>`)を起動する。PATH 先頭の `pgrep` の shim が fake op の子の本物の列挙を取り、取った印を置いてから、
  「fake op が止まった」か「次の command が起動した」まで答えを返さない。次の command は列挙より前には起動できず、列挙は
  起動の後にしか返らないので、動いている process の子を先に殺す後始末(以前の `kill_process_tree`)は timing に依らず次の
  command を残して落ちる。shim の待ちが「止まった」で終わり(timeout は fail)、doctor の後に次の command が残らず、
  「未確認」の warn だけが出て(signed in / out は出ない)次の section へ進み、`kill_tree:` の warn が無いこと。落ちたときは
  fake op の木も止める(後始末が fake op に届かないと、印を待って回り続けるため)。
- kill_tree の停止の待ち(KT、#440): `kill_tree` を単独の bash で、PATH 先頭の `ps` と `pgrep` の shim の下で走らせる。対象は
  一意の `sleep 3000.<数字>` の子を 2 つ持つ `sh`。shim は対象についての問い合わせだけを順に記録し、`ps` は対象についてだけ
  答えを差し替える(子の `sleep` についての問い合わせは記録せず本物に渡す)。停止が遅れて見える(20 回は止まっていない `S` と
  答え、その後は本物の状態)とき、子の列挙は `ps` が停止を示した後になり、warn が出ないこと / process が在るのに `ps` が失敗し
  続けるとき、消えたとは扱わずに問い合わせを続け(20 回以上)、「状態を読めない」warn を出し、木を全部 KILL すること / `S` と
  答え続けるとき、20 回以上問い合わせてから「止まらない」warn を出し、木を全部 KILL すること。どれも 0 で返ること。20 回(約 0.4
  秒)は待ちの上限(約 5 秒)より十分短く、上限そのものは固定しないが、待ちを数回で切ると 3 つとも落ちる。OP-e と中断の check
  の `pgrep` の shim は、止まるまで列挙を返さないので、kill_tree の側の待ちを外しても通る(順序だけを見る)。待ちと warn は
  この case が見る。
- Git identity contexts(#202 / #241): identity file の状態(missing / empty / name-only / email-only / complete /
  parse 不能 / 明示的な空値 / 値の無い key(`=` なし))ごとに、missing と partial は action(手順に file path)、
  complete は ok、parse 不能は warn、値の無い key は「git が identity 全体を拒否する」別の action になること
  (4 万行の file の末尾にあっても検出する)。managed な identity reset の presence も見て、無ければ `mkdir -p` →
  `chezmoi apply` の連続 2 step の action になること(空白を含む home でも `%q` で一致)。その場合、非 personal
  context の文言は「remote が personal pattern に一致する repo で personal identity を継承」に変わる(継承するのは
  未指定の key だけで、明示的な空値は空のまま)。personal は fallback そのものなので、reset が無くても空の ident の文言の
  まま。値は出力に現れない(canary の email / name で pin)。doctor は毎回すべての context を報告するので、状態は 4 回の
  run の各 context に振り分ける(1 回の run に複数の context の状態が載るので、loop の回の間で状態が漏れても落ちる)。
- OpenCode(#234): fake opencode を PATH 先頭に置き、personal で床 missing → apply 手順の action / 床 present → ok /
  work → not managed(action なし)。credential store は存在のみ(fake auth.json の provider 名と key を canary にして
  非表示を pin)。
- OpenCode の plugin(#263): 静的な検査だけで、PATH 先頭の fake opencode が一度も起動されないこと(実行の記録で pin)。
  plugin の発見・二重読込・`OPENCODE_CONFIG` の状態・herdr から見た OpenCode を report し、config の canary を出さないこと。
  init の目印(#311): doctor を通す e2e の 3 run(既定の log と、doctor の `XDG_DATA_HOME` の下の log の一致 → ok、相対 path の
  `XDG_DATA_HOME` はそのまま reporter に届いて「未確認」。init の行は 1 run に 1 行)の他は、doctor.sh から取り出した reporter の
  関数を単体で走らせ、出力の全体が期待の 1 行に一致すること。
  fixture の log で、quoted の一致 → ok、1 行目がこの plugin の marker でない(marker なし・
  build_id を含むだけの comment・別の plugin 名・別の target)・log なし・FIFO の log(期限 30 秒の単体の run で、超えたら
  process tree を回収して fail)・行なし・不一致(両方の build_id を表示)・`unknown`・v=1 の形でない(v=2・余分な
  token・65 桁・大文字)・囲まれていない message や message の途中(`"` つきの引用を含む)や別の plugin 名の行(目印と
  みなさない)・読めない log → それぞれの理由の「未確認」。本物の目印の後に目印を引用しただけの行があっても
  「確認できた」のまま。いちばん新しい行だけを見ること(古い
  一致 + 新しい不一致、その逆)、`XDG_DATA_HOME` の絶対 path / 空 / 相対の扱い。log の行に canary を入れ、行が
  出力に出ないこと。
- Codex review / worker profile(#264 / #299): personal で file 欠損 → apply の action / present → ok(fixture の canary で
  中身の非表示を pin)/ capability が off なのに file が残る → action / work では手置き・欠損を中立に表示し、off 以外の値を
  dangling として warn / `CODEX_HOME` が `~/.codex` 以外(末尾 `/` は同じ扱い)→ warn。
- Git の節(#307): global の `user.useConfigOnly=true` / `transfer.credentialsInUrl=die` でなければ warn、そうなら ok(ok の側は
  次の INCOMPLETE の case の run で見るので、root では skip)。remote URL の scan が `~/src` の personal / work / client /
  sandbox / agent のすべてを巡り、credential らしい userinfo の remote を URL を出さずに warn すること(canary で pin)。
- remote URL scan の INCOMPLETE(#359): `.git/config` が読めない repo、配下に開けない dir がある root、root 自身が開けないとき、
  親 dir(`~/src`)を通過できず root を存在しないと確かめられないとき、それぞれを名指しで warn し(URL は canary で非表示を
  pin)、読めた repo の flag と件数はそのまま、`scanned repositories` は読めた repo だけを数え、clean の ok を出さず exit 0。
  root が symlink のときは link 先を辿り、その配下の flag と読めない config の INCOMPLETE が出ること(辿らなければ
  clean の ok になる)。root では skip。
- git hook gates の readiness(#307): module が active な profile で、配線 + deploy 4 本 → 全部 ok / 配線 + identity gate の
  欠けた旧 deploy、または実行 bit の無い gate → commit が止まる warn / 配線なし + dispatcher だけ → 両方が不完全の warn。
  deploy script や shim の path が directory なら完了 / 配線済みと数えない(#392)。shim が 1 本欠けても、directory や
  実行 bit の無い shim でも、その shim を名指しで warn し、そろった ok を出さない。global `core.hooksPath` は `~` の形でも
  絶対 path の形でも managed と数え、別の場所を指せば値を出さずに warn する(canary で pin)。doctor の一覧が短くなれば落ちる。
- git hook gates の残置(#258): `enableGitHookGates=false` で配管が残るとき、module が active な personal では apply の
  action、非 active な work では実在する file だけを名指しした `rm -i` の手順と core.hooksPath の確認 / 何も無ければ
  not wired で action なし。
- next actions(#227): summary が最後の section で件数 = 番号行数・inline `[warn]` と同順・各項目に手順行 /
  `--actions-only` が full run の summary と一致し他の行を含まない / 未知 option(`--actions-onyl` / `-h` /
  `-x`)は exit 2 で report を走らせない / 0 件は none / helper 単体の exact pin(複数 step・`%`・先頭 `-`・
  空白 path)/ drift 手順の path が ` M x` でも `~/x` / work 機(module 非 active)で fake herdr が
  not installed・outdated なら `herdr integration install <agent>` の action、current なら info、herdr 不在
  は catalog section への pointer。
- go install target(#305): fake `go` の `go env GOBIN` / `GOPATH` で、既定の GOPATH・GOBIN の明示が ok、別の dir が action(`--actions-only` に mise config の apply と、継承した GOBIN / GOPATH を外す `exec env -u GOBIN -u GOPATH zsh -l` の手順が出る。その形で継承値が消えることも確認)、
  `go env` の失敗は「確かめられない」の warn(ok を出さない)、PATH に `~/go/bin` が無ければ info(`go env` が
  失敗したときも出す)、末尾 slash の HOME でも一致。
- network tunnels(#333): PATH を fake dir + system dir の写し(`/usr/bin` と `/bin` の全 entry への symlink から tunnel tool の
  名前だけを除いた dir。host に入っている tunnel tool はどの run にも届かない)に固定し、fake の tailscale が在れば
  work(`allowNetworkTunnels=false`)では warn・personal(true)では中立の item、無ければ `no tunnel tools found`。fake は
  呼び出しを記録し、doctor が tool を実行しないこと(記録の不在)も pin。
- AI policy(#139 / #210): fake `codex execpolicy check` で probe の実効判定(nested allow を誤判定しない)、
  engine 失敗は INCOMPLETE、probe に渡す rules file の集合が Codex の読む集合と一致すること(隠し file を含み、symlink・dir・
  `.bak`・bare の `.rules` を含まない)と管理外 file の名前の warn(制御文字などは `display_safe` で `?` に置換)、通常の file の `default.rules` は
  管理された baseline の ok と、clean の ok の「read-only baseline holding」、symlink の `default.rules` は baseline 無効として warn、読めない rules dir は INCOMPLETE(#316)、`config.toml` の projects trust は yq の TOML parser で読み、trusted な project の key だけを
  取り出す(値は出さない、#309)。正当な書き方(`[projects]` table・inline table・dotted / quote / escape を含む key・
  複数行文字列)は TOML の意味どおりに数え、TOML として読めない・projects が文字列や配列・trusted な key が空か制御文字を含む、
  のときだけ INCOMPLETE(0 件とは言わない)。whole-home と stale の trust は action の手順の行まで確かめる。trust の書き方の case と、
  codex の結果の形の case は、doctor.sh から取り出した監視の関数を `set -euo pipefail` の別の bash で走らせて確かめ(exit 0 も含めて)、
  personal の report への配線・probe の集合の pin・engine の失敗は doctor 全体の run で確かめる。
- Claude の project 級の allow(#334): 専用の fixture HOME で、`:*` が引数なしに一致、floor の deny / ask と project 自身の ask が allow に勝つ、
  `Bash` 単体(先頭 5 本と残りの件数)、rule の途中の `*`、regex の文字は文字どおり(`sudo.*` は `sudo -v` に一致しない)、
  旧式の `:*` の前の `*` は展開されない(`gh *:*` は何にも一致しない)、`/**/` は 0 個以上の dir、旧式の prefix は空白の連続を
  1 つに詰める、wildcard でも rule と command の空白と tab の連続を 1 つに読む、同じ file の deny も allow に勝つ、改行を含む rule は 1 つのまま(floor の複数行の ask が `Bash` 単体に読めない、
  allow の末尾の改行は落とす)、JSON でない file は item(中身を出さない)、深い checkout は読まない、work と client では
  org(client)の 1 段下の repo を読み(#445。直下の repo も対照として読む。`.` で始まる名前の repo も読む)、
  repo でもある org の dir(自身の `.git` と `.claude` を持つ)もその下の repo も、symlink で 2 回辿る org の下の repo も 1 回だけ読み、その repo より深い checkout は読まない、file の中の canary を出さない。
  floor が止める allow だけなら ok(読んだ file の数)、読めない file があれば ok を出さず「clean ではない」の item、HOME の下の
  標準の root と work の org の下に置いたこの repo の写しは 1 回だけ読む、標準の root の外(`~/dotfiles`)の写しも `//` を含む HOME で読む、floor の file が無ければ全部 warn、floor が読めなければ(JSON の文書が 2 つ、key が重なる、`~/.claude` が開けない floor を含む)not checked、開けない `.claude`・通常の file でない設定の path・一覧できない project root(`~/src` が開けない場合を含む)と一覧できない work と client の org の dir は読めない扱いで、読めなかった数に数える(直下の repo の `.claude` と `.git` は repo として読まないので、開けなくても item は `.claude` の 1 つだけ。root では chmod の case を飛ばす)、`.` で始まる名前の repo も読む、work は
  not watched。probe が届かない形(`\*`・`\\`・`\(`・`^`・`]`・`Bash()`・escape された閉じ括弧・改行や U+2028 を含む `:*`・NBSP や BOM の
  trim)は、doctor.sh から matcher を取り出して一致と不一致の対で、`LC_ALL=C` と継承した locale の両方で確かめる。reader も取り出し、
  途中で止まる stub の yq では読めなかった扱いになること、完走すれば rule を 1 つずつ持つことを確かめる。
- display_safe(#335): report の helper と next actions の一覧が行全体を `display_safe` に通すことを、lib-policy.sh を別の bash で
  読み込んで直接確かめる(DS-S)。名前に escape を含む checkout で data file が欠けたときの policy 検証の失敗が、exit 1 のまま
  path を `?` で出すことも確かめる(DS-3)。remote の URL・npm の版・herdr の出力に不正な byte と escape を入れ、継承した locale で
  走らせても report に生の byte が出ないことを確かめる(DS-4)。helper を lib-policy.sh から取り出し、正しい UTF-8(日本語・NBSP・絵文字・U+10000 と U+10FFFF)を残し、
  C0・DEL・C1・bidi の制御・不正な UTF-8(途中で切れた列・2〜4 byte の overlong・surrogate・U+10FFFF 超)を `?` にすることを、
  `LC_ALL=C` と継承した locale の両方で、case ごとに `set -euo pipefail` の別の bash で(exit 0 も含めて)確かめる。
  `shell_quote_safe` の結果が ASCII だけで、貼り付けると元の値に戻ることも確かめる。DS-2 は bidi の文字と日本語を含む
  repo 名の Claude の設定 file が、warn と next actions の手順の両方で ASCII だけの引用で出ることを継承した locale で確かめる。専用の HOME で 1 回 doctor を走らせ(C locale。macOS の UTF-8 locale では
  bidi の文字も `[[:cntrl:]]` に当たり、go の行き先の検査が先に弾くため)、status.sh・herdr・npm・git・chezmoi・corepack・go・
  brew の出力、repo の dir 名、OpenCode の plugin の file 名(config の `plugin` 欄にも載るものを含む)、backup の marker、Codex の
  project の key、`core.excludesFile`、go の実行ファイル名、doctor を置いた checkout の dir 名、git の stderr に escape・BEL・C1・RLO・不正な byte を仕込み、それぞれが `?` で出る
  ことと、report のどこにも生の byte が無いことを確かめる。usage reader の理由は UR-3b、Codex の rules の file 名は AI policy の
  case で固定する。
- npm(#150): shim だけの npm / 壊れた npm でも doctor を落とさない、enforce の期待値検査は fake npm / node で決定的。
  7 日の待ちは、今の npm の形(`min-release-age=7`・`before` が null で `npm config list` に無い)と古い npm の形
  (`before` が約 7 日前で `min-release-age` が null か 7)を ok に、日数違い・窓の外の `before`・約 7 日前の `before` の横の
  別の日数・読めない `before`・source が明示的に `null` にした `before`・読めない `npm config list`・11.10 より古い npm の
  `min-release-age=7` を warn にする。listing の行の途中の `before = `(別の key の値)と、`long=true` の source があるときに
  npm が並べる既定値の `before = null`(doctor は `--long=false` で読む)は、設定された `before` と扱わない。source の `json=true` があっても(doctor は `--json=false` で読む)、設定された `before` を見落とさない。
  `min-release-age-exclude` は fake の `npm config list --json` の値を doctor の node script で数え(この呼び出しだけ PATH の
  実際の node で走らせるので、node が無いと test は失敗する)、項目は数だけを出して warn にする(名前は出さない。
  `undefined`・`null` という名前の項目は 1 項目、CR・NBSP・tab だけの項目は空、key が無ければ空と数える。list でない値・
  JSON として読めない listing・npm の error の object・失敗する count・読めない listing は warn で exit 0。#443)。7 日の待ちと
  exclude の数は fake の別の応答を読むので、1 回の run でそれぞれの状態を 1 つずつ確かめる。
- Corepack(#150): `corepackMode=off` なら intentionally unmanaged、report なら fake corepack の version 行を表示すること。
- いずれの場合も doctor が exit 0 を維持すること(report-only)。

## install-packages.sh

software catalog(`.chezmoidata/packages.yaml`)の **未 install entry を install** する(#53 第2段)。
手動起動のみ・`chezmoi apply` 非結合。**dry-run 既定**で、`--apply` を付けたときだけ実 install する。
実 profile を chezmoi config から fail-closed に解決し、source を `installPackages`(brew_formula /
npm_global / go_install)/ `installGuiApps`(brew_cask / mas)で gate する(work / client / agent は
これらが false なので何も install しない。environmentKind が禁じる capability を true にした profile は、
validate-policy を経ずに起動されても冒頭で拒否し、manager を probe せずに exit 1。#357)。既 install は skip して**更新しない**(install と update の
分離、[docs/update-policy.md](../docs/update-policy.md))。track-only / manual は対象外。npm / go の
manager が PATH に無ければ skip + warn(runtime は mise の領分)。

```sh
./scripts/install-packages.sh           # dry-run: 何が install されるか表示
./scripts/install-packages.sh --apply   # 未 install entry を実際に install
```

## test-install-packages.sh

`install-packages.sh` の gate と fail-closed 契約を検証する。source→capability の対応、
`profile_installs_source` が personal のみ install を許し work 系は許さないこと、profile 未解決 / 未定義時の
拒否(exit 1 と診断文言)、解決済み work profile の dry-run が全 entry を not granted で skip して 0 件を
計画し、manager を一切呼ばないこと(呼び出しを記録する fake manager を PATH に前置。gate を通る entry が
0 件なら fail)を確認する。installer の run には空の fixture HOME を渡し、実 home の設定を読ませない。

`test-inventory.sh` はこの test から実行する inventory 回帰検証で、単独でも実行できる。fake manager だけを PATH に置き、Go toolchain 自動取得の抑止、GOBIN / GOPATH の PATH 外 executable の再 install 防止、PATH 上にだけある Go の copy は導入済みとみなさず Go の bin dir に入れること(#305)、inventory の取得・解析失敗時に install しないこと、doctor の INCOMPLETE / exit 0 と成功 source の検査継続、track-only / manual entry の skip、manager 不在 source の skip + warn、install 失敗の集計と exit 1(#333)を確認する。成功するはずの run が非 0 で終わったときは、その出力と step 名・exit code を出して止まり、`test-install-packages.sh` も fail の行を出す。実 manager・実 install・実 home は使わない。

## private-backup.sh

private な設定(`.local` 上書き + curated アプリ設定)を **age identity 鍵**で単一アーカイブに
退避し(`backup`)、アーカイブを検証し(`verify`)、検証済みのものだけを復元する(`restore`。
既定 dry-run、`--apply` で実行)。手動起動のみ・`chezmoi apply` 非結合。冒頭で runtime secrets gate
(`require_secrets_access`)を通り、`allowSecretsAccess != true` の profile では実行拒否。
environmentKind が禁じる capability を true にした profile も、その違反として拒否する(#357)。

```sh
./scripts/private-backup.sh backup --out PATH [--recipient AGE1... | --recipients-file PATH] \
                            [--local-supplement PATH] [--yes]
./scripts/private-backup.sh verify --in PATH (--identity PATH | --identity-command CMD)
./scripts/private-backup.sh restore --in PATH (--identity PATH | --identity-command CMD) \
                            [--apply] [--skip-existing] [--target-home DIR]
```

- **backup**: baseline(`.chezmoidata/backup-paths.yaml`)+ local 補足を解決(既定の場所に無い補足は補足なし。
  `--local-supplement` の path に無ければ exit 2、在るかを確かめられなければ exit 1 で、どちらも何も書かない。#421)→ 0700 temp に
  staging(補足リスト自体も canonical path `.config/dotfiles/backup-paths.local` の payload として
  先に stage、#208)→ machine-neutral manifest(時刻 / tool version / 各 file の type・mode・sha256。
  絶対 home path・host 名は入れない)生成 → **self-check**(verify / restore と同じ `check_manifest`
  を staging に当てる。不合格なら `--out` も `.partial` も書かず marker も更新せず exit 非 0、#224)
  → 確認 → `tar | age -r recipient` を pipe(平文 tar をディスクに残さない)→ `--out` へ書き出し(`--out` は file の
  path。既存の directory(directory への symlink を含む)は書き込みの前に拒否し、mv の後にも regular file であることを
  確かめる、#298)→
  marker(`~/.local/state/dotfiles/private-backup.json`、最終成功時刻 / archive basename / 件数 /
  `capture_incomplete` のみ。#242)更新。捕捉 0 件(補足リストだけも含む)は空アーカイブを書かず fail。
- **verify**: `--identity` / `--identity-command`(op seam)で 0700 temp に**復号**し、
  **展開前に全 tar member を検査**(一覧で非正規と分かる member = symlink/hardlink/special を拒否、
  絶対パス・`..`・制御文字・台帳外 member 名を拒否)してから展開。recipient は公開鍵なので
  悪性アーカイブも復号可能 → 展開で HOME 外へ逃げないよう member 検査を前段に置く。展開の直後にも
  0700 temp の中の実体を確かめ、展開後に残る通常の file と dir 以外と、link 数が 2 以上の file を拒否する(一覧の
  表示に依らない 2 回目の種別の検査で、保証するのは最後の tree の状態。bsdtar は通常の file の mode を持つ hardlink の
  header を `-` と一覧する。#335)。展開後は
  manifest と突き合わせ(checksum・mode・余剰ファイル・home-relative・symlink 拒否)。
  HOME には一切書かない read-only。復号物・展開物の temp は終了時に削除を試み、消しきれなければ temp の path を
  出して手での削除を求める(restore の temp も同じ。#335)。
  `--identity-command` はユーザー指定の shell コマンド列(`op read op://...` 想定)で、
  quoting のため shell 実行する。アーカイブ由来ではなく呼び出し側が管理するため注入面ではない。
- **restore**: verify を通った後のみ復元(整合 NG なら拒否)。**既定 dry-run**(何も書かない)、
  `--apply` で実行。既存ファイルは上書き前に **timestamp 退避 dir**(復元先 home 配下の
  `.local/state/dotfiles/restore-backup-<UTC ts>.<ランダム>/`。既定は `~` 配下、`--target-home` 指定時はその dir 配下)
  へ move。`--skip-existing` で既存は触らない。復元先と退避先に新しく作る親 directory は 0700(既存の directory の
  mode は変えない、#295)。**symlink 化した親 dir 経由の
  書き込みを拒否**して HOME 外 escape を防ぐ。`--target-home` で復元先を差し替え可(既定 `$HOME`)。
- recipient / identity が解決できなければ fail-closed。仕様は `docs/private-backup.md`。

`age` と mikefarah/yq v4 が必要。

## test-private-backup.sh

`private-backup.sh` の round-trip と安全性を hermetic に検証する(fixture HOME・fake chezmoi で
gate profile を与える・throwaway age 鍵)。実 home には触れない。`age` / `age-keygen` が無い環境
では、手元は skip(exit 0)、CI(`CI=true`)では fail(exit 1。workflow の age の導入が消えても green に
ならないように、#330)。この規則自体も、age の無い PATH で suite を走らせ直して確かめる。

```sh
./scripts/test-private-backup.sh
```

検証内容:

- suite 自身が中断されたとき(TERM)、background の case の process の木を残さず、fixture を消すこと(#413。test-lib.sh の
  `check_suite_interrupt`。cleanup は登録した PID ではなく全部の子を止める)。fixture に権限の無い dir が在っても消すこと
  (case 22・39 のような権限を外す case の途中の中断。cleanup は先に mode を戻す。root では skip。#440)。
- backup がアーカイブと machine-neutral marker(絶対 home path を漏らさない)を書くこと。
- `-` で始まる `--out` の値は拒否し(#330)、`./-archive.age` と書けば archive を書いて、marker の archive が
  `-archive.age` になること(doctor が読む形。#444)。
- verify が正アーカイブを受理し、wrong identity / 改竄アーカイブを拒否すること。
- `--identity-command`(op seam)経由でも verify できること。
- manifest 不整合(checksum mismatch / 台帳外ファイル / symlink 混入)を検出すること。case の manifest は手書きで、
  元の宣言の mode(checksum の case は `600`、台帳外ファイルの case は `644`)をそのまま持つ。file の mode は umask で
  決まるので、umask によっては case 自身の不整合の隣に mode の食い違いも乗る(台帳外ファイルの case は umask 002 で
  mode mismatch も出て、その隣でも台帳外を報告すること)。checksum の case は umask 022 / 002 で sha と mode の両方が
  食い違う状態を保ち、報告する理由が checksum であること(mode を先に見る検査では理由が変わる)。
- 通常の file の mode を持たせた hardlink の header(python3 で byte 単位に作る。無ければ手元は skip、CI では fail。#484)を verify が拒否すること
  (bsdtar では展開後の検査で、GNU tar では展開前の一覧の検査で)。展開後の検査を private-backup.sh から取り出し、
  symlink・fifo・hardlink を拒否し、通常の file と dir の tree を通し、辿れない dir を拒否することを、戻り値と message の両方で直接
  確かめる。mode 000 の dir(中に file)を残す archive を verify が拒否し、その後に temp が中身ごと消え、archive 由来の名前が
  出ないことも確かめる(root では飛ばす。#335。python3 が無いときは hardlink の case と同じ扱い)。
- 拒否 profile(work)では backup が実行拒否し、アーカイブを書かないこと。
- environmentKind の実行時の拒否(#357): work に `allowSecretsAccess=true` を入れた repo の copy(copy の
  validate-policy が同じ data を拒否することも確かめる)では、backup / verify / restore `--apply` が
  environmentKind の拒否行で exit 1 になり、age を呼ばず、archive を書かず、marker も restore 先も変えないこと。
- 非コミットの local 補足にある unsafe path(`..` 等)を skip し、baseline は捕捉すること。
- local 補足リストの構造不正(#246): path の無い entry・category の `|`・path 内の改行・list の代わりの scalar
  (`backup_paths: false`)があれば、`backup-paths entry invalid` で backup ごと fail し、archive も partial も
  marker も書かないこと(個々の unsafe path を skip する上の扱いとは別)。`|` を含まない自由な category label は通り、
  宣言どおり manifest に記録されること。
- recipient の指定(#330): 既定の recipient file と `--recipients-file` はそれぞれ verify の通る archive を作り、
  recipient の未指定(平文にはしない)・存在しない `--recipients-file`・2 つの flag の同時指定は usage error(exit 2)で、
  理由の行を出し、archive も partial も marker も書かないこと。
- ほかの引数の検査も usage error(exit 2)で理由の行を出すこと(#468): backup の `--out` の欠落と未知の引数、
  verify / restore の identity の二重指定、verify の identity の欠落、存在しない archive・restore 先・identity file
  (decrypt_and_extract の 2 を verify / restore がそのまま返す)。restore の run は `--apply` で、空の restore 先に
  何も書かないことも確かめる。
- restore が dry-run では何も書かず、`--apply` で原文どおり復元すること。
- restore の上書きで既存ファイルを timestamp 退避すること。`--skip-existing` で既存を触らないこと。
- restore が **symlink 化した親ディレクトリ経由の書き込みを拒否**し escape しないこと。
- restore が復元先と退避先に新しく作る親 directory が 0700 であること(#295)。
- `--out` は file の path で、既存の directory と directory への symlink を書き込みの前に拒否し、引数の検査の後に
  directory が現れる競合(fake の `mv`)でも成功を表示しないこと。既存の regular file は上書きできること(#298)。
- restore が verify 不合格アーカイブ / 拒否 profile では復元を拒否すること(verify 不合格の `--apply` は exit 1 で、
  restore 先を変えない)。
- group 書き込みの file(664)が backup → verify → restore で mode を保つこと(#141)。展開の `-p` や `cp -p` が
  落ちたことが見えるように、3 つとも umask 022 で走らせる(umask 002 では `-p` が無くても 664 のまま)。
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
- directory 列挙の途中失敗を無警告の成功にしないこと(#242): PATH 先頭の fake `find`(fixture の directory
  にだけ部分 NUL 一覧を出して exit 1、他は実 find に委譲)で、列挙できた file は捕捉しつつ
  `directory enumeration incomplete` と `capture INCOMPLETE` を warn し、skip 1 件を計上し、marker の
  `capture_incomplete` が true になること。正常 run では false。その archive の verify は通ること
  (整合と完全性は別)。列挙の失敗・読めない file・検索できない directory の下の宣言が同じ run で重なれば、
  warn はそれらを and でつないで全部を名指しすること(2 つの run と 3 つの run。#398 review・#414)。
- 平文ができた後の中断で temp に何も残らず、同じ signal で終わること(#358): backup / verify / restore を `set -m` の
  background job(自分の process group)にし、SIGINT / SIGTERM それぞれで 4 種の run を回す: once(1 回)/ twice(後始末の
  途中にもう 1 回)/ every(temp 配下の削除のたびにもう 1 回 = key の押しっぱなし)/ rmfail(1 回。temp 配下の最初の削除が
  signal なしに失敗する)。正常終了の後始末も 2 種の run で確かめる(#358 review): endsig(manifest 検査では送らずに正常
  終了まで進め、EXIT の後始末の temp 配下の削除のたびに 1 回)/ endrmfail(その後始末の temp 配下の最初の削除が signal
  なしに失敗する。signal を使わないので INT の回だけ)。signal は run の中から送る(timing の窓を作らない): PATH 先頭の
  fake `yq`(temp への manifest 検査 = 平文が揃った時点で中身を記録してから group へ。正常終了の run は記録だけ)と fake
  `rm`(temp 配下の削除 = 後始末の途中で自分を含む group へ送り、自分に届いてから本物の rm に渡す。自分に送った
  signal は kill が戻る前に届くので、待たない。signal で死ぬ rm はそこで死に、無視する rm は削除を続ける)。
  backup の一覧 file 3 つも専用 TMPDIR の下に作られる(#372。作り方は下の bullet)ので、
  消し忘れは残留の検査に映る(Codex review R5)。backup の run は、その 3 つが manifest 検査の時点で専用 TMPDIR にあったことも確かめる。
  中断の run は、終了後に専用 TMPDIR が空で、rc が 130 / 143 で、python3 の wrapper を親に
  して記録した waitpid の終了状態が `exit 130` ではなく signal であること。rmfail は失敗した削除の warn も確かめる。正常
  終了の run は、rc 0 で終了状態が `exit 0` であること(signal は捨て、削除の失敗は warn だけで終了状態を変えない)。endsig
  は TMPDIR が空、endrmfail は失敗した temp だけが残り(warn がその path を名指しする)、後続の削除は済んでいること。
  変異での検出(bash 3.2 / 5 とも): main の版(EXIT trap だけで、後始末の間も INT / TERM を通す)は twice / every / rmfail
  の 18 case と endsig の 6 case、endrmfail の backup が fail(once は bash が EXIT trap を走らせてから死ぬので区別できない)。
  INT / TERM の trap だけを外す(EXIT の trap は無視を保つ)と rmfail の 6 case が fail。再送を exit に替えた実装は中断の
  24 case すべてが fail。後始末の間も INT / TERM を通す実装(3 つの trap とも)は every と endsig の 12 case が平文を残して
  fail(bash 3.2 は signal で終わり、bash 5 は signal のたびに trap をやり直して期限で kill される)。EXIT の trap だけが
  通す実装は endsig の 6 case が signal で終わって fail(temp は INT / TERM の trap が空にする)。削除の失敗を errexit に
  任せる実装は rmfail と endrmfail の backup の 3 case が exit 1 で終わって fail。失敗した削除で後始末をやめる実装は
  endrmfail の backup だけが self-check の dir を残して fail(中断の run は EXIT の trap が後始末をもう一度回すので通る)。
  `remove_workdir` が残りを warn しない実装は rmfail と endrmfail の verify / restore の 6 case が fail。一覧 file の削除を
  外す実装は backup の 11 case(endrmfail を含む)が一覧 file を残して fail(一覧 file が TMPDIR の外にあった #372 の前は macOS
  で通っていた)。一覧 file を専用 TMPDIR の外に作る実装は同じ 11 case が「3 つが TMPDIR に無い」で fail。通す実装と
  errexit を併せた形(#358 review の前)では every / endsig の 12 case と rmfail / endrmfail の backup の 3 case が fail し、
  bash 3.2 では加えて twice の SIGINT の backup が exit で終わって fail する(bash 5 の twice は通る)。wrapper が SIGINT を既定に
  戻すので、非対話 shell の background list(`… &`)として suite を起動しても走る。python3 が無ければ手元は warn して
  skip、CI(`CI=true`)では fail(age が無いときと同じ形。#330)。
- backup の temp の置き場所(#372・#398): 一覧 file 3 つ・staging・self-check の dir は TMPDIR の下の template から作ること。
  BSD の mktemp(macOS)は template が無いと TMPDIR を見ずに user ごとの temp dir に作るので、一覧 file 3 つが呼び出し側の
  決めた TMPDIR の外に出て、KILL ではそこに残っていた。GNU の mktemp(CI)は template が無くても TMPDIR に従うので、file の
  できた場所ではどちらの platform でも区別できない。PATH 先頭の `mktemp` が呼び出しごとの最後の引数を記録し、どの呼び出しも
  run の TMPDIR の下の template を名指しすることを確かめる。例外は捕捉した設定の中身を平文で持たない 2 つ(暗号化した
  archive と、日時や件数を書く marker の記録)で、rename で置き換える先と同じ file system に置くため、`--out` の隣の
  archive の dir(`<out>.partial.XXXXXX`)と marker の隣の一時 file を、その正確な template でだけ許す。呼び出しは 7 回以上
  (TMPDIR の下の 5 つと隣の 2 つ)で、run の後に TMPDIR が空で、隣の 2 つも残らないこと。
- 名前が `-` で始まる directory の下の file(宣言した file と、宣言した directory の配下)を backup → verify → restore で
  往復できること(#414。staging の親を dirname で切ると option と読まれて backup ごと止まっていた)。
- 検索の権限が無い directory の下の宣言(直接と、そこへの symlink の経由)を「不在」と扱わず、`capture INCOMPLETE` と marker の
  `capture_incomplete: true` にすること(#414)。対照として、本当に無い宣言(検索できる directory の下・無い directory の下・
  dangling な symlink の下)は通常の skip で、捕捉は complete のまま。
  権限の効かない root では飛ばす。
- archive の rename の後の失敗(#414): PATH 先頭の fake `rmdir` / `mv` で、partial dir の削除の失敗・marker の rename の失敗・
  rename の直前に marker の path が directory に変わる場合を作り、新しい archive が残り(verify が通る)、前回の marker が
  残る(directory に変わった場合は拒否して中を空にする)、exit 非 0 で、一時の file と dir が残らない(run ごとの TMPDIR が空)ことを確かめる。
- local 補足を確かめられないとき(#421): 検索の権限が無い directory の下の補足(既定の場所と `--local-supplement`、
  相対 path は検索できる同名の directory を持つ `CDPATH` を継承させても)と、regular file に辿り着かない補足の symlink
  (dangling、検索できない directory の中への link。既定の場所と `--local-supplement`)は exit 1、`--local-supplement` の
  path に file が無ければ exit 2 で、どれも `mktemp` を呼ばず(PATH 先頭の spy で観測)、archive を書かず、marker も
  変えないこと(以前は「no local supplement」で続け、補足だけが宣言する file が欠けた archive を complete と記録していた)。対照として、
  既定の補足と在る `--local-supplement` は読まれて補足の宣言する file が archive に入り、既定の場所に補足が無いときは
  補足なしで続けて complete のまま。権限の効かない root では検索の権限の case を飛ばす。

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
- environmentKind の実行時の拒否(#357): repo の copy の gate が、work に `allowSecretsAccess=true` を入れた
  data・YAML の alias で personal の map を流用した work・sandbox に付け替えた personal・未知の kind を、
  validate-policy を経ずに environmentKind の拒否行で拒否し、`profile_allows_secrets_access` も許可しないこと。
  未改変の copy の gate が personal を許可すること(control)、alias と sandbox の copy では copy の validate-policy も
  同じ data を同じ行で拒否すること(静的な検査と gate が alias を同じに読む。sandbox の行は test-policy.sh が部分一致でしか
  見ないため。work の data の同じ検査は test-private-backup.sh の 9b が同じ fixture で持つ)、`set_environment_kind`(test-lib.sh)が
  未定義の profile と environmentKind の無い profile で fail して file を変えないことも確かめる。
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
- 各 profile の managed target 一覧が期待値と一致すること(profile を追加・変更したら期待値の更新が必要)。apply が
  home に書いた entry がすべて managed target 一覧に含まれること(work では `~/.config/opencode` が作られない、など。
  空に render される managed target は書かれないので、一致ではなく包含を見る)。
- render した mise config が `go.set_gobin = false`(GOBIN を設定させない)で、`.zshenv` が `~/go/bin` を PATH の末尾に足すこと(#305)。
- render した mise config が `not_found_auto_install = false` で、shim が無い runtime を勝手に install しないこと(#333)。
- allowlist 契約(#207): source の複製に未宣言の root file / subtree / 宣言済み directory 配下の
  sibling を置いても、全 profile で managed set が期待値のままで、apply がそれらを作らず、
  home に既にある未管理 file にも触れないこと。
- 宣言忘れの検知(#207): 実 source の全 entry(`.` 始まりと repo 管理 file を除く)を
  `chezmoi target-path` で target に変換し、全 module の宣言 path ∪ 祖先 directory に含まれること。
  未宣言 entry を置いた複製ではこの検査が fail すること(空振り防止)。未使用の chezmoi source
  種別(`run_` 等の属性 prefix、`.chezmoiscripts` 等の special file)は fail すること。例外は path で名指しした
  `dot_claude/modify_settings.json.tmpl`(#360)だけで、ほかの `modify_` の file は fail すること。
- typo profile が known profile 一覧つきのエラーで fail すること。
- profile 未設定が init 誘導メッセージで fail すること。
- 非対話 init(`--promptString profile=<name>`)が動くこと。
- profile 無回答の init が fail すること(default を持たない)。`--promptDefaults` を付けて default のある prompt には
  default で答えさせ、閉じた stdin で profile の prompt(`promptStringOnce`)が失敗することを見る(flag なしでは default の
  有無に関係なく EOF で失敗するので、default の復活を捕まえられない)。
- README Quickstart の最小 Git apply(#241): README に `mkdir -p ~/.config` と
  `chezmoi apply --source ~/dotfiles ~/.gitconfig ~/.config/git-profile ~/.config/git-profile/identity-reset.gitconfig`
  の 2 行が exact にあること。その 3 target だけを apply すると `~/.gitconfig` と identity reset の 2 file だけが
  配備されること。
- typed boolean guard(#206): validate-policy を通さずに chezmoi を直接使う場合も、profile の capability・module の
  `requires:`・schema の `implemented:` に文字列 `"true"` / `"false"`・数値・null・配列・map を置くと、apply が
  型エラーで fail して hook 登録(`~/.claude/settings.json` / `~/.codex/hooks.json`)を作らないこと。両 template の
  execute-template も同じ型エラーで fail すること。
- typed enum guard(#264): 同じく chezmoi を直接使う場合も、enum capability(`codexReviewEffort` /
  `codexWorkerEffort` / `npmHardeningMode`)が schema の値以外(未知の文字列・大文字違い・boolean・数値・null・
  配列・欠落)なら apply が fail して Codex の profile file を作らないこと。両 profile file template の
  execute-template も同じエラーで fail すること。
- home path の escape(#329): JSON の特殊文字と shell の特殊文字(`"` `\` `&` `<` `'` 空白 `$`)を含む home で
  render しても、`~/.claude/settings.json` / `~/.codex/hooks.json` / `~/.config/opencode/opencode.json` がちょうど
  1 つの JSON の object(`strict_json_object`)で、statusLine と各 hook の command を shell が意図した単語(path は
  1 語)に分けること。OpenCode の instructions の path も一致すること。通常の文字だけの home(固定の `/dotfiles-render-test-home`。host の `$HOME` に
  依らない。chezmoi はこの dir を作らない)では、statusLine・各 hook の command・instructions が引用符なしの
  以前と同じ文字列であること。test-claude-settings / test-codex-settings の hook の期待値は、test-lib の
  `shell_word` / `shell_single_quote`(template と同じ規則)で host の `$HOME` から作る。
- GitHub の HTTPS の credential helper(#492): work の apply は、chezmoi の PATH に gh があり、その path が引用の要らない
  絶対 path のときだけ `~/.config/git/gh-credential.gitconfig` を出し、github.com と gist.github.com の helper の list を
  「空にしてから gh」にすること。gh が無い・空白を含む path・`enableGhCredentialHelper=false` では空に render し、前の
  apply の file を消すこと。chezmoi は絶対 path で起動し、PATH は fake の gh だけか空にする(host の gh を見つけない)。
  render した home で `git credential fill` を回し、github.com では gh だけが、別の host では system の helper だけが
  呼ばれること(system の helper は、呼び出しを記録する fixture の file を `GIT_CONFIG_SYSTEM` で渡す)。

chezmoi と jq と git が必要(chezmoi は CI では version pin して導入する)。

## test-claude-settings.sh

managed `~/.claude/settings.json` の rendered content を検証する。throwaway repo copy で
capability(`enforceAiSandbox` / `gateGitHubMcp` / `gateUnusedClaudeMcp`)を flip し、secret floor の無条件 deny
30 件と #304 の hook の skip(`git commit` / `git push` 直後の `--no-verify`・`git commit -n`)と参照先 note への Edit の deny 4 件が
順序込みで常時出力されること(personal 既定では `gateGitHubMcp` の `mcp__github` と `gateUnusedClaudeMcp` の 21 件(#341)を足して計 56 件。#136 で credential-store 読取 4 件、#234 で
OpenCode の `auth.json`、#315 で gh token の表示と keychain の password の読み出し・dump・export を option の置き方の違いも
含めて追加)、1Password の CLI 全体(1 件)と #334 / #381 の secret を含みうる設定 file の読み取り(4 件)と #304 / #334 の作業を捨てる git と
hook の skip(71 件)の計 76 件の無条件 ask、`allow` が `mcp__pencil` だけで permissions にほかの key が無いこと(key の順には依らない)、その rule を Claude Code の
docs の照合規則(`*` は空白を含む任意の文字列、末尾の唯一の ` *` は bare の command にも一致、deny → ask の順)で git の
command の集合に当てた判定(作業を捨てる形と代表的な束ね(`-uf` / `-df` / `-qf`)は ask、hook の skip は
`git commit` / `git push` の直後なら deny でそれ以外(global option・後ろや最後の語・束ね・引用の中の言及)は ask、
`--force-with-lease`・`feature-f` のような branch 名・branch の作成と切替・merge 済みの `-d`・`--soft` などの日常の git と、
`cleanup` / `restored` のように語の一部として含む commit message はどちらでもない。独立した語(`add clean support`)
として含む message は ask になりうる)、gate 系 deny/ask ブロックが capability に応じて出る/出ないこと(`enforceAiSandbox=true` の deny / ask も順序込みで、allow も exact pin。`gateGitHubMcp` / `gateUnusedClaudeMcp` を false にした render は既定の render から、`gateGitHubMcp=false` と `enforceAiSandbox=true` を合わせた render は `enforceAiSandbox=true` の render から、その gate の deny を除いたものと JSON 全体で一致すること)、#93 で
取り込んだ global preference キーの保持、statusLine が `<home>/go/bin/tacho statusline` を走らせる command 型で padding 0 であること(#305 / #333)、第三者の plugin marketplace がすべて `ref` を固定し `autoUpdate: false` であること(#317)、hooks 登録(`enableGitHubIsolatedReader` の PreToolUse / `enableQualityLoopHooks` の
PostToolUse + Stop / `enableHerdrIntegration` の SessionStart / `enableToolCallRecordHook` の記録の hook。各 capability が自分の event だけを足し、全部 false で `hooks` キーが消えること。#137 / #199 / #225 / #353)を exact に確認する(personal 既定の render では `hooks` の object 全体を pin するので、entry に足された key(safe-gh の `async` や `timeout` など)も落ちる)。
managed file は modify script(#360)なので、live の file がある home への apply も確かめる: `autoMode` / `modelSettings` /
未知の key と `/model` の選択(`model`)が値も位置もそのまま残る、managed の key の古い値は render に戻り要らない
`sandbox` は消える、2 回目の apply で byte 単位で変わらず `chezmoi diff` が空、object の key の順だけ違う値は live の
byte のまま残る、`model` が無ければ template の値が入る、hook の capability が全部 false なら live の `hooks` が消える、
capability で出し入れする top-level の key が script の削除の一覧(`hooks` / `sandbox`)と同じ、ちょうど 1 つの JSON の
object でない live の file(配列・壊れた JSON・空白だけ・object 2 つ・改行だけ・NUL を含む。末尾の NUL も)は apply を止めて
byte 単位で変えない、UTF-8 でない byte を string に含むだけの live の file は UTF-8 の locale でも apply が通り byte 単位で
変わらない、file の無い home への初回の apply の直後も `chezmoi diff` が空で 2 回目の apply が byte を変えない(chezmoi は script に
command を `CHEZMOI_COMMAND` で渡すので、diff と 2 回目の apply の両方を走らせる)。script が
live の file のために自分で一時 file を作らず、jq の引数にも置かないこと(#446)も確かめる: `TMPDIR` が無い dir を指しても、
live の file への `chezmoi diff` は通常の `TMPDIR` のときと同じ差分を出し、apply は同じ file を書き、その後の
`chezmoi status` は空(chezmoi 自身が script を置く `scriptTempDir` は在る dir にする)。その 3 回では PATH の先頭の shim で、
mktemp が走らず(BSD の mktemp は `TMPDIR` が無いと別の dir に作る)、jq が live の file を pipe から読む(/bin/sh の bash は
here-document を一時 file に置く)ことも見る。決まった path への書き込みまでは見ない。PATH の先頭に置いた jq の shim が
記録する引数に、live の file の `autoMode` だけにある値が diff・apply・2 回目の diff のどこでも出ない(見るのは jq の引数
だけ)。chezmoi と jq が必要(render job)。

## test-codex-settings.sh

managed `~/.codex/hooks.json` と `~/.codex/rules/default.rules` の rendered content を検証する。hooks 登録は
Claude 側と同じ exact pin(PreToolUse は timeout 10、PostToolUse / Stop は timeout なし、SessionStart は herdr installer と同一形の
`bash '<path>' session` + timeout 10。#181 / #199 / #225)に加え、
top-level key が `{hooks}` だけであること(Codex 0.142.5 の parse 制約 #185)、既定と各 capability を切った render の
`hooks.json` がちょうど 1 つの JSON の object であること(Codex は厳格に parse する。手で comma を組む template の
区切りの誤りを、寛容な yq ではなく jq で捕まえる)、hook capability が全部 false のとき
apply 済み file が **削除される**こと(template 自己 gate)、rules baseline の exact content(read-only / local の allow 9 と、
#304 / #334 の作業を捨てる git の prompt 10・commit / push 直後の hook の skip の forbidden 2・merge / rebase / am / pull 直後の
`--no-verify` の prompt 1、#334 の secret の床の forbidden 6・prompt 3)と gate の独立性(#139)を確認する。`codex` が install されていれば、render した rules を
`codex execpolicy check`(rules を評価するだけで何も実行しない)に当て、subcommand の直後の作業を捨てる形は prompt、
直後の hook の skip は forbidden(`git commit` の allow に勝つ)、日常の形は allow か一致なし、prefix で拾えない形
(後ろの option・global option)は拾われないことを確かめる(#304)。CI の render job は version と sha256 を固定した
codex(release の Linux 用 binary。npm は通さない)を入れてこの評価を回す(#332 F36)。CI の codex は手元の版と同じとは限らないので、
手元の codex の版が変わったときの解釈の変化は、手元でのこの test と doctor の rules の意味の検査が受け持つ。rules を変える PR は、
codex の入った手元でもこの test を回す。`codex` が無いと、
手元ではその旨を表示して飛ばし(exact pin だけが効く)、CI(`CI=true`)では fail にする(#330 の age と同じ。分かれ目は test-lib.sh の
`ci_gate` で、test-policy.sh が確かめる)。install されているのに `execpolicy check` が使えない、非 0 で終わる、decision も空の
`matchedRules` も無い答えを返す、のどれも「一致なし」とはせず fail にする。答えの読み取り(decision は allow / prompt /
forbidden だけ、一致なしは decision が無く `matchedRules` が空の配列のときだけ)は、codex が無くても固定の答えで確かめる。Codex review / worker 用 profile file(#264 / #299)は、1 行目の managed-by header・設定が capability の値
どおりであること(どちらも `model_reasoning_effort` だけ。review 用 file に `service_tier` を書かない)・全行が agent-tools の読み手(worker preflight と同じ)の top-level の形に収まること、
値が capability から来ること(別の値で render)、`off` で apply 済み file が消え他の file は残ることを確認する。
chezmoi と jq が必要(render job)。

## test-opencode-settings.sh

managed `~/.config/opencode/opencode.json`(OpenCode の permission 床・#234)の rendered content を検証する。
`permission.read` / `permission.bash` の rule map を**順序込みで exact pin**(OpenCode は last-match-wins なので
順序も契約。read = secret floor の deny 6 + `.env` 系 + #334 / #381 の secret を含みうる設定 file の ask 4、bash = 既定 ask の直後に local の command の allow 戻し 78(#381。38 command の完全一致と `… *` の組 + `git remote` / `git remote -v`)と `rg` の `--pre` / `--hostname-bin` の ask、その後に外向き・昇格と `gh *` の既定 ask と
1Password の CLI 全体の ask 計 7、read 系 `gh` subcommand の allow 戻し 44、末尾に env dump / gh secret・token 表示 /
ssh 鍵 / keychain の password の読み出し・dump・export の deny 21 と、#304 / #334 の作業を捨てる git と hook の skip の ask 71・
`git commit` / `git push` 直後の hook の skip の deny 6。#240 / #315 / #304)、`permission.edit` が allow-all の上で参照先 note
`.agent-context.local.md` / `*/.agent-context.local.md` を deny し、名前の似た file は allow のままであること(相対・sub dir・
絶対の path に docs の glob で当てる。実行中の OpenCode での path の形は未検証。#304)、`permission.external_directory` が `ask`
に固定されていること(#315)、
`autoupdate: false` / `share: "disabled"` / `instructions` が agent-tools の運用ルール 1 件だけ(絶対 path)であること、
top-level key が `$schema / autoupdate / share / instructions / permission` だけ(provider / model / plugin / mcp / agent を
managed に書かない)、secret / email らしき文字列が無いこと、file がちょうど 1 つの JSON の object であること
(`strict_json_object`)を確認する(work で render されないことは test-render.sh の managed set が固定する)。
加えて rendered の bash map を OpenCode の規則(glob・last match wins)で評価し、doctor.sh の外向き probe と `gh` の
mutation・短縮 flag・alias、deny、維持すべき read からなる固定 command 集合の判定が、`docs/ai-policy.md` から手で書いた
期待値(allow / ask / deny。map からは導かない)と一致することを確認する(`*` 以外の pattern 文字を含む rule は fail、#240)。
加えて doctor.sh の `outward_probe_commands` / `secret_read_probe_commands` を literal に読み出し(source しない)、全 probe が
この command 集合の行にあることを機械的に確かめる(配列が読めない・行が `"..."` だけの plain な quoted 文字列の形に
完全一致しない entry があれば fail、#332)。
chezmoi と jq が必要(render job)。

## test-git-signing.sh

git-signing module の gating を検証する。`enableGitSigning` の on/off で
`~/.config/git/signing.gitconfig` が管理される/されないこと、signing mechanism
(gpg.format=ssh + op-ssh-sign)が public-safe な骨格のみであることを render で確認する。
signing mechanism の値は文字列の部分一致ではなく、render した `~/.gitconfig` の include を Git 自身にたどらせて
(`git config --global --includes --get`)`gpg.format` と `gpg.ssh.program` を完全一致で確かめる。行をコメントにした
copy と、signer を `[gpg "ssh"]` の外に置いた copy を対照にし、どちらも弾くことを確かめる(#384)。
`enableGitSigning=false` の render では、signing.gitconfig だけが落ち、`~/.config/git` 配下の別 module の file
(git-ignore の `~/.config/git/ignore`)は残ること(allowlist の祖先導出、#207)も確かめる。
chezmoi が必要(render job)。

## test-git-ignore.sh

git-ignore module(#248)を検証する。personal で `~/.config/git/ignore` が apply され work では
されないこと、managed-by header と pattern 2 行(`.agent-packets/`、`**/.claude/settings.local.json`)の
exact pin、`.agent-context.local.md` を global では除外しないこと、そして `.gitignore` を持たない
throwaway repo に対して `env -i` の throwaway HOME で `git status` を回し、agent local-only file だけが
消え通常 file は残ること(空 home の control run で全 file が出ることを先に確認し、`git check-ignore -v`
で判定源が managed file であることも確認)。`enableGitSigning=false` でもこの file が残ること(#207)は、同じ
flip と render を持つ `test-git-signing.sh` が確かめる。chezmoi と git が必要(render job)。実 home や実 global
git config には触れない。

## test-herdr-config.sh

herdr-config module(#261)を検証する。personal で `~/.config/herdr/config.toml` が apply され work では
されないこと(work が持つ自前の config は byte 単位で不変)、1 行目の managed-by header、TOML として parse でき
設定値が pin どおりであること(`[ui.toast] delivery = "system"` を含む。key を sort して比べる)、mode が file 0644 /
directory 0755 であること(既存 host の初回 apply で権限を変えない。apply した file の mode は apply する process の umask に従うので、
test は umask 022 に固定して確かめる。#332 F38)、隣に置いた `session.json` と log が apply で
変わらないこと(herdr の実行時状態には触れない)。chezmoi と yq が必要(render job)。実 home には触れない。

## test-agent-tools-usage-reader.sh

agent-tools-usage-reader module(#301)を検証する。personal で `~/.config/agent-tools/usage-reader.json` が apply され
work ではされないこと(work が持つ自前の file は byte 単位で不変)、strict な JSON で key が agent-tools の契約どおり
`argv` / `timeout_sec` だけであること(知らない key は wrapper が拒否する)・`argv` が `[<home>/go/bin/tacho, "status",
"--json"]`・`timeout_sec` が整数 20、`"` `\` `&` `<` を含む home の path が JSON の escape を経ても壊れないこと、
mode が file 0644 / directory 0755 であること(umask 022 に固定して確かめる。#332 F38)、`~/.config/agent-tools/` の隣の
file が apply で変わらないこと。chezmoi と yq が必要(render job)。実 home には触れない。

## test-git-hook-gates.sh

git-hook-gates module(#196)の配線内容と武装条件を検証する。武装の条件は、capability(意図)と、destination に
agent-tools の deploy 4 本(dispatcher + public-safety / git-identity / ai-trailer gate、#239)が実行可能な状態で
揃っていること(readiness)の 2 段 gate。bare destination、dispatcher だけの部分 deploy、identity gate が欠けた旧
deploy(agent-tools#281 以前の 3 本)、実行 bit の無い dispatcher のどれでも、shim と `hooks.gitconfig` が render
されない(武装しない)ことを確認する。完全 deploy では modules.yaml が宣言する 23 本の shim(実行可能。#361)がちょうど
render され、置かない 5 stage(`reference-transaction` / `post-index-change` / `push-to-checkout` / `proc-receive` /
`fsmonitor-watchman`)には無く、どれも stage 名だけが違う exact な内容であること、`hooks.gitconfig`(`core.hooksPath`)が
exact な内容で render されること、render した `~/.gitconfig` 経由の実 commit で dispatcher が pre-commit →
prepare-commit-msg → commit-msg → post-commit の順に呼ばれること、失敗する gate(dispatcher)が commit を止めること、
`--no-verify` が pre-commit / commit-msg の 2 stage だけを迂回すること(best-effort の既知の限界)と、迂回されない
prepare-commit-msg の identity の検査が失敗すれば `--no-verify` の commit も止まること(agent-tools#449。#431)、checkout で
素通しの post-checkout が shim を通ることを確認する。`enableGitHookGates=false` の apply で適用済みの配線が
**削除される**こと、配備(deploy 4 本)が消えた後の同じ source での再 apply でも配線が削除されること、
`enableGitSigning=false` でも gate が武装したままであること(全 shim と `hooks.gitconfig` が、signing を落とさないときと同じ exact な内容で render される)、doctor / preflight が `core.hooksPath` を
`--includes` 付きで読むこと(静的 pin)と、deploy 4 本の一覧が武装の template・doctor・preflight・この test で同じであること
(静的 pin、#307。doctor / preflight の部分 deploy での振る舞いは test-doctor / test-preflight が固定する)も確認する。
throwaway destination に render し、実 home には触れない。
chezmoi が必要(render job)。end-to-end 検査は git を使う(無ければ skip)。

## test-ssh.sh

ssh-1password module の gating と安全契約を検証する。`enable1PasswordSSH` の on/off gating、
managed `~/.ssh/config` に host 名・秘密鍵・`Host *` への agent 付与・forwarding が混入しない
こと、`Match all` 後の `Include config.local` 構造、`ssh -G` での実挙動(managed-wins と
config.local の解決)を確認する。chezmoi が必要(render job)。

## test-gclone.sh

dot_zshrc の `gclone` helper(#177)をマーカー抽出 + fixture HOME + `zsh -f` で検証する。
実 clone はしない(`-n` の解決のみ)。context 解決の順序(local の repo 行 → managed の
kosako ルール → local の owner 行 → fail-closed 中断。#260)、URL 3 形式(https / ssh:// / scp)の parse、
path traversal と絶対 path の context の拒否、既存 dest の非破壊、末尾改行の無い最終行も 1 行として読むこと(#281)を固定する。
zsh が必要(validate job、apt で導入)。

## test-starship.sh

`private_dot_config/starship.toml`(template ではない source)を render せずに検証する。identity の実値
(`name =` / `email =` の代入や `@`)が含まれないこと、TOML として parse できること(tomllib。python3 や tomllib が
無ければ手元は skip、CI では fail。#484)を静的に確認する。さらに source から `custom.git_ctx_personal` / `git_ctx_other` / `git_ctx_none` の
3 module の `when` を取り出し(どれかが取り出せなければ fail)、隔離した HOME / Git config と dummy identity の
git fixture で実行する。fixture の personal.gitconfig は `$HOME/.config/git/` にだけ置き、`XDG_CONFIG_HOME` は別の空
directory に向けるので、分類が gitconfig の include と同じ local の `~/.config/git/personal.gitconfig` を読むことも
実行で確かめる。personal / 別 email / email 未設定では対応する module だけが成立し、repo 外では
すべて不成立になることを確認する。host の環境変数・global / system Git config・init template は使わない。
抽出は tomllib を優先し、無ければ現在の multiline literal を awk で読む(明示的な `shell` 設定や別の
TOML 記法には tomllib が必要)。実行 shell は module の `shell` 設定、未設定なら `sh` を使う。
git が必要。chezmoi / starship binary は不要(CI では render job で実行)。

## lib-policy.sh

他 script から source される共通 helper。
data file path、profile/module/capability 取得、出力 helper、command availability check、Git remote credential 検出(`git_remotes_with_credentials`。remote 名のみを出力し、URL 値は出力しない)、global excludes の解決(`git_excludes_file_setting`: global > system・`GIT_CONFIG_NOSYSTEM` 尊重・unset / empty / path / error の 4 状態、`git_default_excludes_file`: XDG 既定。doctor と preflight が共有、#248)を提供する。ほかに、BSD/GNU をまたぐ octal mode 取得(`file_mode`)、doctor / preflight が共有する policy ゲート(`run_policy_validation`)と標準 project roots 報告(`report_standard_project_roots`)、catalog source → package manager の対応表(`manager_present`。installer と catalog drift 報告の単一 source)を持つ。environmentKind の禁止の表を読む判定(違反の一覧 `profile_environment_kind_violations`、capability ごとの許可 `profile_grants_capability`、副作用のある入口での拒否 `require_environment_kind_limits`)もここにあり、validate-policy・install-packages・private-backup が共有する(#357)。

policy data(`.chezmoidata/*.yaml`)の読み取りは mikefarah/yq v4 で行う。`require_yq` が yq の存在と variant・版を検査し、満たさなければ fail closed する(`validate-policy.sh` / `install-packages.sh` / `private-backup.sh` と、`test-render.sh` / `test-npmrc.sh` / `test-claude-settings.sh` / `test-codex-settings.sh` / `test-opencode-settings.sh` / `test-git-signing.sh` / `test-git-ignore.sh` / `test-herdr-config.sh` / `test-agent-tools-usage-reader.sh` / `test-preflight.sh` / `test-git-hook-gates.sh` / `test-ssh.sh` / `test-shell-syntax.sh` が yq を使う前に呼ぶ。`doctor.sh` / `preflight.sh` は内部で `validate-policy.sh` を先に実行するため間接的にカバーされる。例外として catalog drift 報告(`report_catalog_drift`)は、yq を満たさないとき fail closed せず warn を出して skip する)。profile / module / capability 名は `strenv()` 経由で渡し、yq 式へ展開しない。
