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
  重複なしであること。entry の構造(map・非空 string の `path`・`type` / `category` は `|` と制御文字を
  含まない string)は共有 parser `backup_paths_in` が file 全体を先に検査し、不正なら
  `backup-paths entry invalid` で fail する(#246。local 補足の backup 時読み取りも同じ検査)。
- capability registry(#151): 全 capability が `implemented: true|false` を持ち、
  `implemented: false` は doctor.sh が言及していること(source-text の静的 proxy)。

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
- Git: `user.useConfigOnly` / `transfer.credentialsInUrl` に加えて、次の 2 つを見る。
  - Git signing: `enableGitSigning` の SSH 署名 mechanism が managed か、capability true で module inactive の dangling か。
  - global gitignore: `git-ignore` module が active な profile で managed `~/.config/git/ignore` の presence、git が実際に読む excludes path との一致 — `core.excludesFile` は global が system に勝ち、`GIT_CONFIG_NOSYSTEM` なら system を飛ばす。明示的に空なら「global excludes を読まない」、config が読めなければ「不明」で、どちらも ok にしない。無ければ XDG 既定(末尾の `/` はすべて落とし、`-ef` でも同じ file と判定する、#309)— と、`.agent-packets/` と `**/.claude/settings.local.json` の pattern 行の drift。行の exact 一致で見る — `git check-ignore` は repository を要し doctor は何も作らない(#248)。
- git hook gates(report-only): `enableGitHookGates` が true で module が active なら、shim 2 本(`~/.config/git-hook-gates/hooks/pre-commit` / `commit-msg`)が実行可能に置かれているか、global `core.hooksPath`(`--includes` 付きで読む)が managed shim directory を指すか(別の値なら値は出さずに warn)、agent-tools deploy 4 本(dispatcher + gate 3 本)が揃っているかを report する。配線済みなのに deploy が欠けていれば commit が fail-closed で止まる旨を warn し、`core.hooksPath` が未設定なら action。capability true で module inactive なら dangling として warn。capability=false で shim / hooksPath が残っていれば action(lingering)。git-hook-gates module が active な profile では apply で除去する手順、module が非 active な profile(profile 切替後の残置。#201)では apply が触れないので、残っている file を `rm -i` で消す手順と、`core.hooksPath` が managed shim directory を指さなくなったかの確認(まだ指すなら表示された設定元の行を消す)を出す(managed file が無く `core.hooksPath` だけが残るときは設定元を探す手順。#258)。`--no-verify` と repo-local `core.hooksPath` で迂回できる best-effort である旨も表示する(#196 / #239。詳細は `docs/git-hook-gates.md`)。
- Git identity contexts: `git-profile` module が active な profile では、managed な identity reset `~/.config/git-profile/identity-reset.gitconfig` の presence を見る — 中身は見ない。無ければ、context file の無い非 personal repo で personal pattern に一致する remote が personal identity を継承して commit 拒否にならないので、`mkdir -p ~/.config` → `chezmoi apply`(dir と file)を action にする(#241)。各 context の identity file が存在するか、意図的に未設定かも見る。存在する file は `user.name` / `user.email` の有無だけを見て partial を action 化し、値の無い key(`=` なし。git が identity 全体を拒否する)は別の action、git が parse できない file は warn — 値は出さない。partial は managed な identity reset が塞げない唯一の状態なので doctor が主な検出手段になる(#202)。
- Git remote URLs: credential らしき userinfo の有無。url と pushurl を見る。URL の値は表示しない。
- npm hardening / Corepack: 検査内容は下記の docs に従う。
- software catalog(report-only): catalog 宣言 vs 実機の brew/npm/go/mas。declared-missing / undeclared-sprawl / source-mismatch を report-only で表示。
- runtime and shell: mise(`enableRuntimeManagement`)・direnv(`enableDirenv`)・zsh・starship の有無。mise を管理する profile では `go install` の行き先(`go env GOBIN`、空なら GOPATH の先頭の `bin`)が `~/go/bin` かを確かめ、違えば action(mise config の apply と、古い GOBIN を持たない新しい shell。installer は同じ行き先で導入済みを判定するので、usage reader の installer の案内より前に出る。#305)、PATH に `~/go/bin` が無ければ info。
- 1Password: `allowSecretsAccess=true` のとき `op` の存在と sign-in。`op whoami` は 5 秒の期限付き・stdin `/dev/null` で回し、応答なしは「未確認」の warn にして doctor を止めない — 未ログインの `op` が対話 unlock 待ちで固まり診断全体が止まっていた(#231)。
- SSH (1Password agent): `enable1PasswordSSH` の managed `~/.ssh/config` が active か dangling か。
- private-backup(report-only): public baseline の各 target の存在と、marker からのバックアップ有無・最終日時と、捕捉が完全かどうか(`capture: complete`。#242 以前の marker は `unknown`)を表示する。`capture_incomplete=true` なら warn とし、読めない entry を直してから再 backup する手順を next actions に出す(#242)。backup 未実行は allowSecretsAccess=true の profile でのみ warn — false の profile は backup 実行自体を拒否する設計なので中立表示(#174)。local 補足は **存在のみ**で中身・件数は出さない。アーカイブや captured file の中身は読まない。
- managed-path orphans: managed-by header があるのに現 profile で管理対象でない file。profile 切替の残骸検出。宣言済み **file** path のみ検査し、その祖先の directory(allowlist が親として通すだけ、#207)の下には再帰しない — セッションログ等の header 引用を偽 orphan にしない(#174)。
- managed drift(report-only): `chezmoi status` の乖離を report-only で warn。`chezmoi status` が失敗したとき、chezmoi の config が無ければ未初期化の item、あれば config / template の error(apply も壊れている)として `chezmoi status` を示す action(#309)。enforce profile では `~/.npmrc` の `_authToken` 行の有無をキー名のみで scan — 値は読まない・出さない — と managed-by header の有無も報告(#148)。
- AI policy: `enableAiPolicy` / `enableAiTools` の現状。codex-settings が active な profile では Codex 権限面も監視 — managed rules baseline の presence と、**外向き/昇格 probe(push・PR/issue/comment 作成・release・sudo・auth login・clone・curl 等)と、認証情報の表示・secret の読み出しの probe(gh token の表示・env の一覧・keychain の password・1Password の CLI。#334)の固定リストを `codex execpolicy check` で live rules に評価**し auto-allow を warn。probe には Codex が読む rules dir の `*.rules` をすべて渡し(Codex は `default.rules` だけでなく通常 file の `*.rules` を全部読む。symlink と `default.rules.bak.<日付>` は読まない)、baseline 以外の rules file は管理外として名前だけ warn する(#316。見るのは user layer だけで、trusted な project の `.codex/rules/` は対象外)(行 grep は blanket prefix・複数行 rule・decision 省略の既定 allow を見逃し、rule 行 echo は任意文字列由来の secret を漏らしうるため不採用 — doctor は rules file を読まず path を codex に渡すだけ・echo するのは自前の probe 文字列のみ。codex CLI 不在時は skip を明示)、`config.toml` の `[projects]` trust は yq の TOML parser で読み、`trust_level = "trusted"` の project の **key(path)だけ**を取り出す(設定値は出さない・yq の error も捨てる、#148 と同じキー名限定規律)。trusted な home root と実在しない path の残骸を warn(#139)。正当な書き方は TOML の意味どおりに数え、TOML として読めない・projects が文字列や配列・trusted な key が空か制御文字を含む、のときは INCOMPLETE(0 件とは言わない、#292 / #309)。claude-settings が active な profile では Claude の project 級の allow の堆積も監視する(#334): 承認の「次から聞かない」で project の `.claude/settings.local.json` に溜まる allow rule(と `.claude/settings.json` の allow)を、標準の project root(`~/src/{personal,work,client,sandbox,agent}`)直下の repo と、HOME の下にあるときのこの repo について読み(同じ dir は 1 回だけ。`.` で始まる名前の repo も含む。検索・一覧できない root は空ではなく読めない扱い)、外向きの probe(Codex と同じ 30 本。secret の読み出しは floor の deny が allow に勝つので含めない)に Claude Code(2.1.293)の分類どおりに当てる。rule は JSON の文字列ごとに読む(NUL 区切り。改行を含む rule も 1 つの rule のまま)。読むのは 1 回(`yq eval-all`)で、JSON の文書がちょうど 1 つで、同じ object の中で key が重ならないこと(yq は最初の、`JSON.parse` は最後の値を採るため)を求め、評価が最後まで成功したときだけ yq が出す終端の印が無ければ読めなかった扱いにする。中身は先に `\(` `\)` `\\` を戻し、末尾が `:*` で前が空でなく行末の文字(改行・CR・U+2028・U+2029)を含まなければ旧式の prefix(引数なしにも一致、空白の連続は 1 つ、prefix の中の `*` は展開されないのでその rule は一致しない)、`*` を含めば wildcard(前後を JavaScript の `trim()` と同じ文字の集合で locale に依らず落とし(NBSP・BOM などを含む)、rule と command の両方で空白と tab の連続を 1 つの空白に読む。`*` は空白を含む任意の文字列、`\*` は文字の `*`、`/**/` は 0 個以上の dir、唯一の wildcard が末尾の ` *` なら引数なしにも一致)、それ以外は書かれたとおりの完全一致。`Bash` / `Bash()` / `Bash(*)` は全部に一致し、閉じ括弧が escape された rule は Claude Code と同じく無効として飛ばす。live の `~/.claude/settings.json` と、その project 自身の 2 つの file の deny / ask が止める probe は除き(どの file にあっても deny / ask は allow に勝つ)、残りを file ごとに action(先頭 5 本の名前と残りの件数。rule は token を含みうるので出さない)。JSON として読めない file(permissions が object でない、list が配列でないものを含む)と、確かめた不在でないもの(`.claude` が権限などで開けない、設定の path が通常の file でない。cd の errno で見分ける)は item で、1 つでもあれば ok にしない(読めた file に問題が無くても「clean ではない」と item で言う)。live の floor が読めないときも item。clone の中の clone のような深い checkout は見ない。
- OpenCode(report-only): `opencode` の presence、`opencode-settings` module が active な profile では managed な permission 床 `~/.config/opencode/opencode.json` の presence — 無ければ apply 手順の action、非 active なら not managed。credential store `~/.local/share/opencode/auth.json` は**存在のみ**で中身も provider 名も読まない(#234)。agent-tools の plugin(`plugins/personal-*.js`)は静的に、global の plugins dir にあるかと、`personal-agent-tools` の init(OpenCode の既存の log の目印の行で「確認できた / 未確認(理由つき)」。いちばん新しい目印の build_id が配置中の marker と一致するときだけ確認できた。過去の起動の証拠で、直近の起動の成功ではない。log の行は出さない。#311)と、二重読込(`.ts` / `.mjs` の併置・単数形 `plugin/` dir・OpenCode が読む設定 — managed の床と `OPENCODE_CONFIG` の指す file — の `plugin` 欄に同じ名前。読まれていない `opencode.local.json` だけなら注記)を報告する — OpenCode は起動しない(`opencode debug config` でさえ DB に書き込むため)、設定ファイルは `plugin` 欄だけを読み表示しない。`opencode.local.json` があるのに `OPENCODE_CONFIG` が未設定 / 別 file を指す場合も報告する(#263)。この section の末尾に enforceAiSandbox(sandbox ブロックと human-legit write gate の live state)の行も出る。
- Claude MCP exposure(report-only): `gateUnusedClaudeMcp` の deny(claude.ai の Gmail / Google Calendar / Google Drive / Claude Docs の connector と、利用の無いかまれな Notion の書込 tool)の wired 状態。live の file は読まない(#341)。
- GitHub injection guard(report-only): secret floor は常時 deny、`gateGitHubMcp` の MCP deny の wired 状態、`enableGitHubIsolatedReader` の PreToolUse hook 登録の wired 状態と hook body の presence — body は agent-tools 配布なので存在のみを contents-blind で見る(#137)。
- quality loop hooks(report-only): `enableQualityLoopHooks` の PostToolUse / Stop hook 登録を両 home で wired 状態と body presence で report し、check 宣言 `~/.config/agent-tools/checks.local.json` は **presence のみ**を見る — hook が実行する command を列挙する file なので中身は読まない(#199)。
- herdr integration(report-only): `enableHerdrIntegration` の SessionStart hook 登録を両 home で wired 状態と herdr 配置 body の presence で report し、herdr が PATH にあれば `herdr integration status` の currency(current / outdated / needs repair)も出す — body header を読むだけで server 不要。5 秒の期限付きで実行し exit 0 のときだけ採用、不在・失敗・hang は「未確認」と明示して doctor を止めない(一時ファイル不使用・stdin `/dev/null`・期限到達と中断時は probe の process tree ごと回収。doctor 共通の `bounded_probe` helper で、1Password の `op whoami` と共有、#231)。capability=false は宣言上の状態として報告し、herdr 自身の見え方を module の active / inactive に応じた所有者説明つきで添える(#225)。OpenCode が入っていれば、herdr から見た OpenCode integration の状態も中立に表示する(plugin は herdr の installer が置き、dotfiles に登録の役割は無い。#263)。
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
まとまる(global gitignore の欠損 / pattern drift、git hook gates の hooksPath 未設定 / lingering、
identity reset の欠損、identity file の不在 / partial / 値の無い key、private-backup の不完全な捕捉、
managed-path orphan、managed drift、Codex projects trust の stale / home 全体、OpenCode の permission 床の
欠損、herdr integration の body 不在 / outdated / work 機での未導入、herdr config の欠損 / `herdr config check` の不合格、残量の読み取り口の設定の欠損 / `--check` の不合格 / wrapper の未配備・旧版、agent-tools の dirty / stale)。
判断が要る warning(catalog 外 package 等)は warn のまま。
`--actions-only` は `[fail]` と summary 以外を mute するだけで、doctor はファイルを書かない(report-only)。
手順行も key-name-only / secret を出さない規律の対象。

## test-preflight.sh

`preflight.sh` の report-only 契約と apply-impact 警告を fixture HOME で検証する(#150)。
空 home の exit 0 / shell-extra・ssh-1password の replace 警告と override pointer /
非管理 profile の left-as-is / `~/.config` 権限分岐 / config.local の中身非表示 /
`-` 始まりの引数(`-h` / `--all` / `--list-profiles` など)と 2 つ目の引数を exit 2 で拒否し report を走らせない(#309)/
git-ignore の apply impact(既存 `~/.config/git/ignore` の置換 warn と `.git/info/exclude` への pointer、
`core.excludesFile` が設定済み・明示的な空値のときの warn(値は出さない)、work の left-as-is、不在時の ok。
`env -i` で hermetic に回す、#248)/
herdr config の apply impact(既存 `~/.config/herdr/config.toml` の置換 warn、work の left-as-is、不在時の ok、#261)/
agent-tools の残量の読み取り口の apply impact(既存 `~/.config/agent-tools/usage-reader.json` の置換 warn、work の left-as-is、不在時の ok、#301)/
policy validation 失敗時のみ非 0 / commands 節が確認する tool がすべて catalog(name / pkg / bin)か
catalog 外の前提(git / brew / node / npm / corepack)であること(catalog から外れた tool が毎回 warn しない、#259)/
git hook gates の deploy 4 本の readiness(完全な deploy は script ごとと武装と hooksPath が ok、identity gate が欠けた旧 deploy は
その script と「武装しない」の warn、#307)/ global の identity・hooksPath・excludesFile、usage-reader.json、herdr config の
値を出さないこと(それぞれの warn は出し、canary は出ない、#307)、をカバーする。

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
  status を変えないこと。
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
- enum capability の許可値を正しく受け入れること。
- unknown profile / module / capability(module の `requires:` 内も)、重複 capability、enum の不正値を拒否すること。
- boolean capability・`requires:`・`implemented:` は YAML boolean の小文字 `true` / `false` だけを受け入れ、
  文字列 / 数値 / null / 大文字綴りを拒否すること(#206)。
- 同一 path を複数 module が宣言したら fail、`requires:` を持つ module は `paths:` 必須。
- software catalog(#53): unknown source / go_install の pkg 欠落 / name 重複 / track_only 不正 / 空 catalog を拒否。
- backup-paths(#60 / #246): 絶対 path / `..` / glob / unknown type / 重複 / 空 entry / 空 catalog に加え、
  共有 parser の構造検査として category の `|`・path 内の改行・非 string の type・list の代わりの scalar
  (`backup_paths: false`)を拒否。
- environmentKind 制約: work / client / agent で権限付与型 capability の true、sandbox の
  allowSecretsAccess、`npmHardeningMode=off` を hard fail。安全強化型(`enforceAiSandbox` /
  GitHub guard 2 本 / `enableQualityLoopHooks` / `enableHerdrIntegration`)は全 kind で true を許容
  (forbidden 表に入っていないことの pin)。forbidden-enum 表の不正行は fail closed。
- capability registry(#151): `implemented:` 欠落は fail、`implemented: false` は doctor.sh がその名前に
  言及していなければ fail(undisclosed dormant)。
- 単一 dash の option は usage error、非 mikefarah yq / v4 未満は fail closed、空の profiles / schema は fail closed。
- software catalog drift(`report_catalog_drift`): fake の brew / npm / go(と yq・coreutils)だけを置いた PATH で、
  drift なし・catalog 外の brew leaf / go binary・未 install の宣言・source 不一致(info)・Go toolchain 自身の
  binary を sprawl にしないこと・manager 不在時の skip を検証し、いずれも exit 0(report-only)であること。

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

静的検査は chezmoi 無しで実行できる(CI の validate job)。chezmoi がある環境では加えて personal を
throwaway destination に実 render し、生成された `~/.npmrc` の内容(hardening 値・token / registry の
不在)も検査する(#150。CI では render job が担い、chezmoi の無い validate job は skip を warn する)。

## test-doctor.sh

fixture HOME(+ repo copy の capability flip・PATH 先頭の fake command)で doctor の各 section を
検証する。実 home には触れない。op / herdr / codex / opencode は、冒頭で PATH の先頭に置く stub が受け、実機の tool は
起動しない(#306)。stub は PATH 上に在り、実行すると記録して exit 1 になる(在るが使えない側の分岐。たとえば op は
「not found」ではなく「サインインしていない」)。fake が
要る section は、その前に自分の fake を置く。package manager(brew / npm など)は、software catalog の section が読み取りの
query だけを実機で実行する(書き込みはしない)。

```sh
./scripts/test-doctor.sh
```

検証内容(section ごと):

- managed-path orphan: header があり現 profile で管理対象でない file が warning / 管理対象の
  profile では orphan にならない / header 無しは対象外 / 宣言した file の祖先の directory の下に再帰しない(#174 / #207)。
- managed drift: fake chezmoi の status 行ごとに warn、空なら ok、`chezmoi status` の失敗は、chezmoi の config が無ければ
  「not initialized」の item で skip、あれば `chezmoi status` を示す action(#309。いずれも exit 0)/ enforce の `~/.npmrc` は `_authToken` 行を件数だけで warn(値は出さない)し、
  managed-by header の欠落も warn(#148)。
- agent-tools: status.sh 実行が opt-in(`enableAgentToolsStatus`)/ opt-in 時は summary + `conflict` を
  warn / contract version 不一致・status.sh 欠如・非ゼロ exit・不正 JSON・不在でも warning のみ /
  `AGENT_TOOLS` override(#71 / #73)。
- private-backup: marker 不在は allowSecretsAccess=true の profile だけ warn(false は中立)、marker
  ありで最終成功時刻 / archive / 件数、不正 marker は unreadable、local 補足は**存在のみ**(#174)。marker の
  `capture_incomplete` が false なら `capture: complete`、true なら再 backup 手順の action、field の無い旧 marker
  なら unknown になること(#242)。
- global gitignore(#248): managed file を git が読んでいれば ok / 不在は `mkdir -p` → `chezmoi apply` の action /
  `core.excludesFile`(global、または system だけの設定)や `XDG_CONFIG_HOME` で別の file に振り替わっていれば
  warn(`GIT_CONFIG_NOSYSTEM=1` なら system の値は無視。`XDG_CONFIG_HOME` が `~/.config//` や `~/.config` への symlink なら同じ
  file として ok、#309)/ 明示的な空値は「global excludes を読まない」warn /
  config が読めなければ「不明」の warn / pattern 行の欠落は drift の action / work は not managed。どの run も
  `env -i` で hermetic。
- git signing / SSH(1Password): capability true + module active は managed、module 除去は dangling。
- GitHub injection guard(#119 / #137): secret floor 常時 deny、`gateGitHubMcp` / `enableGitHubIsolatedReader`
  の wired 状態、hook body の presence(contents-blind)、`enforceAiSandbox` の human-legit gate 開示。
- quality loop hooks(#199): 両 home の登録 + body presence、`checks.local.json` は presence のみ(canary で
  中身を漏らさない)、cap off の not-wired、live file に残置した登録の lingering warn、module 除去の dangling。
- herdr integration(#225): body 不在 / exec bit なし body / dir body / 末尾改行なしの status 応答 /
  outdated・needs repair / status が非ゼロ exit(出力を採用しない)/ hang(期限で process tree ごと回収)/
  probe 稼働中に doctor を SIGTERM(trap で回収・rc 143)/ cap off の module active・inactive 別の表示 /
  module 除去の dangling。fake herdr は ok・fail・hang・interrupt・ok-nonl の mode を持つ。
- herdr config(#261): PATH 先頭の fake herdr で `herdr config check` の exit を決め、`__rc=0` などの行を出してから
  失敗しても終了状態として読まれないこと(#335)、present + exit 0 → ok /
  exit 1 → action / missing → `mkdir -p` → `chezmoi apply` の連続 2 step の action / `HERDR_CONFIG_PATH`(別 file・
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
- 1Password(#231): fake op の signed in(ok 1 行だけ)/ signed out(既存 warn)/ hang(期限で process tree
  ごと回収し「未確認」の warn で次の section へ進む。signed in / out とは断定しない)/ stdin 隔離(doctor の
  stdin に行を流し、fake は自分の stdin が `/dev/null` のときだけ signed in を返す)。fake op は ok・fail・
  hang・stdin の mode を持つ。
- Git identity contexts(#202 / #241): identity file の状態(missing / empty / name-only / email-only / complete /
  parse 不能 / 明示的な空値 / 値の無い key(`=` なし))ごとに、missing と partial は action(手順に file path)、
  complete は ok、parse 不能は warn、値の無い key は「git が identity 全体を拒否する」別の action になること
  (4 万行の file の末尾にあっても検出する)。managed な identity reset の presence も見て、無ければ `mkdir -p` →
  `chezmoi apply` の連続 2 step の action になること(空白を含む home でも `%q` で一致)。その場合、非 personal
  context の文言は「remote が personal pattern に一致する repo で personal identity を継承」に変わる(継承するのは
  未指定の key だけで、明示的な空値は空のまま)。値は出力に現れない(canary の email / name で pin)。
- OpenCode(#234): fake opencode を PATH 先頭に置き、personal で床 missing → apply 手順の action / 床 present → ok /
  work → not managed(action なし)。credential store は存在のみ(fake auth.json の provider 名と key を canary にして
  非表示を pin)。
- OpenCode の plugin(#263): 静的な検査だけで、PATH 先頭の fake opencode が一度も起動されないこと(実行の記録で pin)。
  plugin の発見・二重読込・`OPENCODE_CONFIG` の状態・herdr から見た OpenCode を report し、config の canary を出さないこと。
  init の目印(#311): fixture の log で、quoted の一致 → ok、1 行目がこの plugin の marker でない(marker なし・
  build_id を含むだけの comment・別の plugin 名・別の target)・log なし・FIFO の log(期限 120 秒の実行で、超えたら
  process tree を回収して fail)・行なし・不一致(両方の build_id を表示)・`unknown`・v=1 の形でない(v=2・余分な
  token・65 桁・大文字)・囲まれていない message や message の途中(`"` つきの引用を含む)や別の plugin 名の行(目印と
  みなさない)・読めない log → それぞれの理由の「未確認」。本物の目印の後に目印を引用しただけの行があっても
  「確認できた」のまま。いちばん新しい行だけを見ること(古い
  一致 + 新しい不一致、その逆)、`XDG_DATA_HOME` の絶対 path / 空 / 相対の扱い。log の行に canary を入れ、行が
  出力に出ないこと。init の行は 1 run に 1 行。
- Codex review / worker profile(#264 / #299): personal で file 欠損 → apply の action / present → ok(fixture の canary で
  中身の非表示を pin)/ capability が off なのに file が残る → action / work では手置き・欠損を中立に表示し、off 以外の値を
  dangling として warn / `CODEX_HOME` が `~/.codex` 以外(末尾 `/` は同じ扱い)→ warn。
- Git の節(#307): global の `user.useConfigOnly=true` / `transfer.credentialsInUrl=die` でなければ warn、そうなら ok。remote URL の
  scan が `~/src` の personal / work / client / sandbox / agent のすべてを巡り、credential らしい userinfo の remote を URL を
  出さずに warn すること(canary で pin)。
- git hook gates の readiness(#307): module が active な profile で、配線 + deploy 4 本 → 全部 ok / 配線 + identity gate の
  欠けた旧 deploy、または実行 bit の無い gate → commit が止まる warn / 配線なし + dispatcher だけ → 両方が不完全の warn。
  doctor の一覧が短くなれば落ちる。
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
- AI policy(#139 / #210): fake `codex execpolicy check` で probe の実効判定(nested allow を誤判定しない)、
  engine 失敗は INCOMPLETE、probe に渡す rules file の集合が Codex の読む集合と一致すること(隠し file を含み、symlink・dir・
  `.bak`・bare の `.rules` を含まない)と管理外 file の名前の warn(制御文字などは `display_safe` で `?` に置換)、symlink の `default.rules` は
  baseline 無効として warn、読めない rules dir は INCOMPLETE(#316)、`config.toml` の projects trust は yq の TOML parser で読み、trusted な project の key だけを
  取り出す(値は出さない、#309)。正当な書き方(`[projects]` table・inline table・dotted / quote / escape を含む key・
  複数行文字列)は TOML の意味どおりに数え、TOML として読めない・projects が文字列や配列・trusted な key が空か制御文字を含む、
  のときだけ INCOMPLETE(0 件とは言わない)。
- Claude の project 級の allow(#334): 専用の fixture HOME で、`:*` が引数なしに一致、floor の deny / ask と project 自身の ask が allow に勝つ、
  `Bash` 単体(先頭 5 本と残りの件数)、rule の途中の `*`、regex の文字は文字どおり(`sudo.*` は `sudo -v` に一致しない)、
  旧式の `:*` の前の `*` は展開されない(`gh *:*` は何にも一致しない)、`/**/` は 0 個以上の dir、旧式の prefix は空白の連続を
  1 つに詰める、wildcard でも rule と command の空白と tab の連続を 1 つに読む、同じ file の deny も allow に勝つ、改行を含む rule は 1 つのまま(floor の複数行の ask が `Bash` 単体に読めない、
  allow の末尾の改行は落とす)、JSON でない file は item(中身を出さない)、深い checkout は読まない、file の中の canary を出さない。
  floor が止める allow だけなら ok(読んだ file の数)、読めない file があれば ok を出さず「clean ではない」の item、HOME の下の
  標準の root に置いたこの repo の写しは 1 回だけ読む、標準の root の外(`~/dotfiles`)の写しも `//` を含む HOME で読む、floor の file が無ければ全部 warn、floor が読めなければ(JSON の文書が 2 つ、key が重なる、`~/.claude` が開けない floor を含む)not checked、開けない `.claude`・通常の file でない設定の path・一覧できない project root(`~/src` が開けない場合を含む)は読めない扱い(root では chmod の case を飛ばす)、`.` で始まる名前の repo も読む、work は
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
- Corepack(#150): `corepackMode=off` なら intentionally unmanaged、report なら fake corepack の version 行を表示すること。
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

`test-inventory.sh` はこの test から実行する inventory 回帰検証で、単独でも実行できる。fake manager だけを PATH に置き、Go toolchain 自動取得の抑止、GOBIN / GOPATH の PATH 外 executable の再 install 防止、PATH 上にだけある Go の copy は導入済みとみなさず Go の bin dir に入れること(#305)、inventory の取得・解析失敗時に install しないこと、doctor の INCOMPLETE / exit 0 と成功 source の検査継続を確認する。実 manager・実 install・実 home は使わない。

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
  HOME には一切書かない read-only。復号物・展開物は trap で確実削除。
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
では skip(exit 0)。

```sh
./scripts/test-private-backup.sh
```

検証内容:

- backup がアーカイブと machine-neutral marker(絶対 home path を漏らさない)を書くこと。
- verify が正アーカイブを受理し、wrong identity / 改竄アーカイブを拒否すること。
- `--identity-command`(op seam)経由でも verify できること。
- manifest 不整合(checksum mismatch / 台帳外ファイル / symlink 混入)を検出すること。
- 通常の file の mode を持たせた hardlink の header(python3 で byte 単位に作る。無ければ skip)を verify が拒否すること
  (bsdtar では展開後の検査で、GNU tar では展開前の一覧の検査で)。展開後の検査を private-backup.sh から取り出し、
  symlink・fifo・hardlink を拒否し、通常の file と dir の tree を通し、辿れない dir を拒否することを、戻り値と message の両方で直接
  確かめる。mode 000 の dir(中に file)を残す archive を verify が拒否し、その後に temp が中身ごと消え、archive 由来の名前が
  出ないことも確かめる(root では飛ばす。#335)。
- 拒否 profile(work)では backup が実行拒否し、アーカイブを書かないこと。
- 非コミットの local 補足にある unsafe path(`..` 等)を skip し、baseline は捕捉すること。
- local 補足リストの構造不正(#246): path の無い entry・category の `|`・path 内の改行・list の代わりの scalar
  (`backup_paths: false`)があれば、`backup-paths entry invalid` で backup ごと fail し、archive も marker も
  書かないこと(個々の unsafe path を skip する上の扱いとは別)。`|` を含まない自由な category label は通り、
  宣言どおり manifest に記録されること。
- recipient 未指定は usage error(exit 2)になること。
- restore が dry-run では何も書かず、`--apply` で原文どおり復元すること。
- restore の上書きで既存ファイルを timestamp 退避すること。`--skip-existing` で既存を触らないこと。
- restore が **symlink 化した親ディレクトリ経由の書き込みを拒否**し escape しないこと。
- restore が復元先と退避先に新しく作る親 directory が 0700 であること(#295)。
- `--out` は file の path で、既存の directory と directory への symlink を書き込みの前に拒否し、引数の検査の後に
  directory が現れる競合(fake の `mv`)でも成功を表示しないこと。既存の regular file は上書きできること(#298)。
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
- directory 列挙の途中失敗を無警告の成功にしないこと(#242): PATH 先頭の fake `find`(fixture の directory
  にだけ部分 NUL 一覧を出して exit 1、他は実 find に委譲)で、列挙できた file は捕捉しつつ
  `directory enumeration incomplete` と `capture INCOMPLETE` を warn し、skip 1 件を計上し、marker の
  `capture_incomplete` が true になること。正常 run では false。その archive の verify は通ること
  (整合と完全性は別)。

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
- render した mise config が `go.set_gobin = false`(GOBIN を設定させない)で、`.zshenv` が `~/go/bin` を PATH の末尾に足すこと(#305)。
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

chezmoi が必要(CI では version pin して導入する)。

## test-claude-settings.sh

managed `~/.claude/settings.json` の rendered content を検証する。throwaway repo copy で
capability(`enforceAiSandbox` / `gateGitHubMcp` / `gateUnusedClaudeMcp`)を flip し、secret floor の無条件 deny
30 件と #304 の hook の skip(`git commit` / `git push` 直後の `--no-verify`・`git commit -n`)と参照先 note への Edit の deny 4 件が
順序込みで常時出力されること(personal 既定では `gateGitHubMcp` の `mcp__github` と `gateUnusedClaudeMcp` の 21 件(#341)を足して計 56 件。#136 で credential-store 読取 4 件、#234 で
OpenCode の `auth.json`、#315 で gh token の表示と keychain の password の読み出し・dump・export を option の置き方の違いも
含めて追加)、1Password の CLI 全体(1 件)と #334 の secret を含みうる設定 file の読み取り(3 件)と #304 / #334 の作業を捨てる git と
hook の skip(71 件)の計 75 件の無条件 ask、その rule を Claude Code の
docs の照合規則(`*` は空白を含む任意の文字列、末尾の唯一の ` *` は bare の command にも一致、deny → ask の順)で git の
command の集合に当てた判定(作業を捨てる形と代表的な束ね(`-uf` / `-df` / `-qf`)は ask、hook の skip は
`git commit` / `git push` の直後なら deny でそれ以外(global option・後ろや最後の語・束ね・引用の中の言及)は ask、
`--force-with-lease`・`feature-f` のような branch 名・branch の作成と切替・merge 済みの `-d`・`--soft` などの日常の git と、
`cleanup` / `restored` のように語の一部として含む commit message はどちらでもない。独立した語(`add clean support`)
として含む message は ask になりうる)、gate 系 deny/ask ブロックが capability に応じて出る/出ないこと(`enforceAiSandbox=true` の deny / ask も順序込みで exact pin)、#93 で
取り込んだ global preference キーの保持、第三者の plugin marketplace がすべて `ref` を固定し `autoUpdate: false` であること(#317)、hooks 登録(`enableGitHubIsolatedReader` の PreToolUse / `enableQualityLoopHooks` の
PostToolUse + Stop / `enableHerdrIntegration` の SessionStart。各 capability が自分の event だけを足し、全部 false で `hooks` キーが消えること。#137 / #199 / #225)を exact に確認する。
chezmoi が必要(render job)。

## test-codex-settings.sh

managed `~/.codex/hooks.json` と `~/.codex/rules/default.rules` の rendered content を検証する。hooks 登録は
Claude 側と同じ exact pin(PreToolUse は timeout 10、PostToolUse / Stop は timeout なし、SessionStart は herdr installer と同一形の
`bash '<path>' session` + timeout 10。#181 / #199 / #225)に加え、
top-level key が `{hooks}` だけであること(Codex 0.142.5 の parse 制約 #185)、hook capability が全部 false のとき
apply 済み file が **削除される**こと(template 自己 gate)、rules baseline の exact content(read-only / local の allow 9 と、
#304 / #334 の作業を捨てる git の prompt 10・commit / push 直後の hook の skip の forbidden 2・merge / rebase / am / pull 直後の
`--no-verify` の prompt 1、#334 の secret の床の forbidden 6・prompt 3)と gate の独立性(#139)を確認する。`codex` が install されていれば、render した rules を
`codex execpolicy check`(rules を評価するだけで何も実行しない)に当て、subcommand の直後の作業を捨てる形は prompt、
直後の hook の skip は forbidden(`git commit` の allow に勝つ)、日常の形は allow か一致なし、prefix で拾えない形
(後ろの option・global option)は拾われないことを確かめる(#304)。`codex` が無い環境(CI)ではその旨を表示して飛ばし、
exact pin だけが効く。install されているのに `execpolicy check` が使えない、非 0 で終わる、decision も空の
`matchedRules` も無い答えを返す、のどれも「一致なし」とはせず fail にする。答えの読み取り(decision は allow / prompt /
forbidden だけ、一致なしは decision が無く `matchedRules` が空の配列のときだけ)は、codex の無い CI でも固定の答えで確かめる。Codex review / worker 用 profile file(#264 / #299)は、1 行目の managed-by header・設定が capability の値
どおりであること(どちらも `model_reasoning_effort` だけ。review 用 file に `service_tier` を書かない)・全行が agent-tools の読み手(worker preflight と同じ)の top-level の形に収まること、
値が capability から来ること(別の値で render)、`off` で apply 済み file が消え他の file は残ることを確認する。
chezmoi が必要(render job)。

## test-opencode-settings.sh

managed `~/.config/opencode/opencode.json`(OpenCode の permission 床・#234)の rendered content を検証する。
`permission.read` / `permission.bash` の rule map を**順序込みで exact pin**(OpenCode は last-match-wins なので
順序も契約。read = secret floor の deny 6 + `.env` 系 + #334 の secret を含みうる設定 file の ask 3、bash = allow-all の上に外向き・昇格と `gh *` の既定 ask と
1Password の CLI 全体の ask 計 7、read 系 `gh` subcommand の allow 戻し 44、末尾に env dump / gh secret・token 表示 /
ssh 鍵 / keychain の password の読み出し・dump・export の deny 21 と、#304 / #334 の作業を捨てる git と hook の skip の ask 71・
`git commit` / `git push` 直後の hook の skip の deny 6。#240 / #315 / #304)、`permission.edit` が allow-all の上で参照先 note
`.agent-context.local.md` / `*/.agent-context.local.md` を deny し、名前の似た file は allow のままであること(相対・sub dir・
絶対の path に docs の glob で当てる。実行中の OpenCode での path の形は未検証。#304)、`permission.external_directory` が `ask`
に固定されていること(#315)、
`autoupdate: false` / `share: "disabled"` / `instructions` が agent-tools の運用ルール 1 件だけ(絶対 path)であること、
top-level key が `$schema / autoupdate / share / instructions / permission` だけ(provider / model / plugin / mcp / agent を
managed に書かない)、secret / email らしき文字列が無いこと、work では `~/.config/opencode` が render されないことを確認する。
加えて rendered の bash map を OpenCode の規則(glob・last match wins)で評価し、doctor.sh の外向き probe と `gh` の
mutation・短縮 flag・alias、deny、維持すべき read からなる固定 command 集合の判定が、`docs/ai-policy.md` から手で書いた
期待値(allow / ask / deny。map からは導かない)と一致することを確認する(`*` 以外の pattern 文字を含む rule は fail、#240)。
chezmoi が必要(render job)。

## test-git-signing.sh

git-signing module の gating を検証する。`enableGitSigning` の on/off で
`~/.config/git/signing.gitconfig` が管理される/されないこと、signing mechanism
(gpg.format=ssh + op-ssh-sign)が public-safe な骨格のみであることを render で確認する。
chezmoi が必要(render job)。

## test-git-ignore.sh

git-ignore module(#248)を検証する。personal で `~/.config/git/ignore` が apply され work では
されないこと、managed-by header と pattern 2 行(`.agent-packets/`、`**/.claude/settings.local.json`)の
exact pin、`.agent-context.local.md` を global では除外しないこと、`enableGitSigning=false` でも
`~/.config/git` 配下の file が残ること(allowlist の祖先導出、#207)、そして `.gitignore` を持たない
throwaway repo に対して `env -i` の throwaway HOME で `git status` を回し、agent local-only file だけが
消え通常 file は残ること(空 home の control run で全 file が出ることを先に確認し、`git check-ignore -v`
で判定源が managed file であることも確認)。chezmoi と git が必要(render job)。実 home や実 global
git config には触れない。

## test-herdr-config.sh

herdr-config module(#261)を検証する。personal で `~/.config/herdr/config.toml` が apply され work では
されないこと(work が持つ自前の config は byte 単位で不変)、1 行目の managed-by header、TOML として parse でき
設定値が pin どおりであること(`[ui.toast] delivery = "system"` を含む。key を sort して比べる)、mode が file 0644 /
directory 0755 であること(既存 host の初回 apply で権限を変えない)、隣に置いた `session.json` と log が apply で
変わらないこと(herdr の実行時状態には触れない)。chezmoi と yq が必要(render job)。実 home には触れない。

## test-agent-tools-usage-reader.sh

agent-tools-usage-reader module(#301)を検証する。personal で `~/.config/agent-tools/usage-reader.json` が apply され
work ではされないこと(work が持つ自前の file は byte 単位で不変)、strict な JSON で key が agent-tools の契約どおり
`argv` / `timeout_sec` だけであること(知らない key は wrapper が拒否する)・`argv` が `[<home>/go/bin/tacho, "status",
"--json"]`・`timeout_sec` が整数 20、`"` `\` `&` `<` を含む home の path が JSON の escape を経ても壊れないこと、
mode が file 0644 / directory 0755 であること、`~/.config/agent-tools/` の隣の file が apply で変わらないこと。
chezmoi と yq が必要(render job)。実 home には触れない。

## test-git-hook-gates.sh

git-hook-gates module(#196)の配線内容と武装条件を検証する。武装の条件は、capability(意図)と、destination に
agent-tools の deploy 4 本(dispatcher + public-safety / git-identity / ai-trailer gate、#239)が実行可能な状態で
揃っていること(readiness)の 2 段 gate。bare destination、dispatcher だけの部分 deploy、identity gate が欠けた旧
deploy(agent-tools#281 以前の 3 本)、実行 bit の無い dispatcher のどれでも、shim と `hooks.gitconfig` が render
されない(武装しない)ことを確認する。完全 deploy では shim 2 本(`pre-commit` / `commit-msg`、実行可能)と
`hooks.gitconfig`(`core.hooksPath`)が exact な内容で render されること、render した `~/.gitconfig` 経由の実 commit で
dispatcher が pre-commit → commit-msg の順に呼ばれること、失敗する dispatcher が commit を止めること、`--no-verify` で
両方を迂回できること(best-effort の既知の限界)を確認する。`enableGitHookGates=false` の apply で適用済みの配線が
**削除される**こと、`enableGitSigning=false` でも gate が武装したままであること、doctor / preflight が `core.hooksPath` を
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
path traversal 拒否、既存 dest の非破壊、末尾改行の無い最終行も 1 行として読むこと(#281)を固定する。
zsh が必要(validate job、apt で導入)。

## test-starship.sh

`private_dot_config/starship.toml`(template ではない source)を render せずに検証する。identity の実値
(`name =` / `email =` の代入や `@`)が含まれないこと、git-identity context が runtime に local の
`~/.config/git/personal.gitconfig` と照合する形で `custom.git_ctx_personal` / `git_ctx_other` / `git_ctx_none` の
3 module を定義していること、TOML として parse できること(tomllib。python3 や tomllib が無ければ skip)を確認する。
さらに source から 3 module の `when` を取り出し、隔離した HOME / Git config と dummy identity の
git fixture で実行する。personal / 別 email / email 未設定では対応する module だけが成立し、repo 外では
すべて不成立になることを確認する。host の環境変数・global / system Git config・init template は使わない。
抽出は tomllib を優先し、無ければ現在の multiline literal を awk で読む(明示的な `shell` 設定や別の
TOML 記法には tomllib が必要)。実行 shell は module の `shell` 設定、未設定なら `sh` を使う。
git が必要。chezmoi / starship binary は不要(CI では render job で実行)。

## lib-policy.sh

他 script から source される共通 helper。
data file path、profile/module/capability 取得、出力 helper、command availability check、Git remote credential 検出(`git_remotes_with_credentials`。remote 名のみを出力し、URL 値は出力しない)、global excludes の解決(`git_excludes_file_setting`: global > system・`GIT_CONFIG_NOSYSTEM` 尊重・unset / empty / path / error の 4 状態、`git_default_excludes_file`: XDG 既定。doctor と preflight が共有、#248)を提供する。ほかに、BSD/GNU をまたぐ octal mode 取得(`file_mode`)、doctor / preflight が共有する policy ゲート(`run_policy_validation`)と標準 project roots 報告(`report_standard_project_roots`)、catalog source → package manager の対応表(`manager_present`。installer と catalog drift 報告の単一 source)を持つ。

policy data(`.chezmoidata/*.yaml`)の読み取りは mikefarah/yq v4 で行う。`require_yq` が yq の存在と variant・版を検査し、満たさなければ fail closed する(`validate-policy.sh` / `install-packages.sh` / `private-backup.sh` と、`test-render.sh` / `test-npmrc.sh` / `test-claude-settings.sh` / `test-codex-settings.sh` / `test-opencode-settings.sh` / `test-git-signing.sh` / `test-git-ignore.sh` / `test-herdr-config.sh` / `test-agent-tools-usage-reader.sh` / `test-preflight.sh` / `test-git-hook-gates.sh` / `test-ssh.sh` / `test-shell-syntax.sh` が yq を使う前に呼ぶ。`doctor.sh` / `preflight.sh` は内部で `validate-policy.sh` を先に実行するため間接的にカバーされる。例外として catalog drift 報告(`report_catalog_drift`)は、yq を満たさないとき fail closed せず warn を出して skip する)。profile / module / capability 名は `strenv()` 経由で渡し、yq 式へ展開しない。
