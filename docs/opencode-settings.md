# OpenCode settings

OpenCode(`~/.config/opencode/`)のハーネス設定の管理規約(Issue #234 = OpenCode 導入 Phase 1)。dotfiles は
**personal の public-safe な `opencode.json` だけ**を control plane として管理する。
Claude Code([claude-settings](claude-settings.md))・Codex(`codex-settings`)と同じ型で、
「公開して問題ない床」を repo に置き、認証・model の好み・plugin は local に残す。

## 何を管理し、何を管理しないか

| 対象 | 置き場所 | 管理 |
| --- | --- | --- |
| permission の床(secret floor の read / bash deny、外向き・昇格 bash の ask)、`autoupdate: false`、`share: "disabled"`、`instructions`(agent-tools 配布の運用ルール) | public repo(`private_dot_config/opencode/opencode.json.tmpl` → `~/.config/opencode/opencode.json`、`opencode-settings` module) | ✅ managed(personal のみ) |
| provider / model / small_model、plugin、mcp、agent、server | `OPENCODE_CONFIG` が指す local file(例 `~/.config/opencode/opencode.local.json`。global の後に merge されるので上書きできる) | ❌ 管理外 |
| TUI 設定 | `~/.config/opencode/tui.json`(`opencode.json` とは別 file。`OPENCODE_TUI_CONFIG` で path を変えられる) | ❌ 管理外 |
| 認証(`/connect` で貼った API key・OAuth token) | `~/.local/share/opencode/auth.json` | ❌ 管理外・backup 対象外(1Password が SoR)。Claude 側の secret floor が `Read` を deny |
| skill / instruction 本体 | agent-tools が `~/.claude/` に配布したもの。skill(`~/.claude/skills/<name>/SKILL.md`)は OpenCode が直接読む。instruction(`~/.claude/agent-tools/CLAUDE.md`)は、OpenCode がユーザー手書きの `~/.claude/CLAUDE.md` の `@` import を辿らないため、1 行目の managed な `instructions` が絶対 path で参照する | ❌ 別 repo の責務・OpenCode 向けの再配布はしない |
| agent-tools の plugin(`plugins/personal-*.js`: safe-gh 誘導・品質ループ。OpenCode 導入 Phase 2 = agent-tools#295) | global の plugins dir(`~/.config/opencode/plugins/`)。置けば起動時に自動で読まれ、`opencode.json` への登録は不要(`opencode --pure` で外せる)。safe-gh は実行後に model へ付ける注記(steering)で、止めるのは permission の床。品質ループの結果は人には log(`~/.local/share/opencode/log/opencode.log`)にしか出ない | ❌ 管理外(agent-tools の sync が配置・更新・撤去。dotfiles は doctor で読込の見え方だけを確認) |
| herdr integration の plugin(`plugins/herdr-agent-state.js`) | herdr の installer(`herdr integration install opencode`)が置く | ❌ 管理外(入れるかは任意。doctor は herdr の見え方を中立表示) |

work / client には配らない(`opencode-settings` module を持たない。claude-settings / codex-settings と同じ)。

## 床の中身と根拠

- **permission**: OpenCode の既定は **allow all**。rule は pattern の **last-match-wins**。
  - `read`: `*` allow の上に、SSH 鍵 / credential store(`~/.aws`、`~/.config/gh`、`~/.netrc`、Codex と
    OpenCode の `auth.json`)/ `.env` 系を deny(`.env.example` は allow)。SSH 鍵と credential store は
    Claude の secret floor(`Read` 側 6 件)と同じ集合。`.env` 系の deny は Claude では secret floor ではなく
    `enforceAiSandbox` 連動の human-legit gate(personal では off)に当たるので、この点は OpenCode の床の方が厳しい。
    **read の deny は read tool にだけ効く**: OpenCode の `grep` は正規表現に、`glob` は pattern に当てる別の permission で、
    path の deny に従わない(OpenCode の docs)。project の外の path はどの tool でも `external_directory`(下記、ask)が
    掛かるが、**project の中の `.env` などは grep で読める**。home を project root にして OpenCode を起動しない(#315)。
  - `bash`: `*` allow の上に、マシン外に出る操作と昇格(`git push` / `git clone` / `sudo` / `curl` / `wget`)を
    **ask**。GitHub CLI は **`gh *` を既定 ask** にし、read 系の subcommand(`pr view|list|diff|checks|status`、
    `issue view|list|status`、`repo view`、`release view|list`、`run view|list`、`workflow view|list`、
    `label list`、`gist view|list`、`search`、`status`、bare の `auth status`、`--version` / `version` / `help`)だけを
    allow に戻す(#240: mutation を列挙する方式では `gh issue edit` / `gh pr close` / `gh api -XPOST` などが
    allow-all に落ちた。`gh api` は method に関わらず ask — 短縮 flag `-XPOST` / `-ftitle=x` は flag 照合を
    すり抜け、GraphQL は read でも POST を使う)。1Password の CLI は **`op` の全 subcommand を ask**(`op read` /
    `op item get` / `op run` などの読み出し系は global option をどこにでも置けるので、subcommand の列挙ではなく program
    単位にする。人が指示する場面があるので deny にしない、#315)。deny(env dump `env` / `printenv`、`gh secret` /
    `gh api *secrets*`、token 表示 `gh auth token` / `gh auth status --show-token` / `-t` / `-at` と、`auth` の前か直後に
    option を置いた `gh auth`(`gh -* auth *` / `gh auth -*`。同じ subcommand に届く置き方なので丸ごと deny)、
    `cat ~/.ssh/*`、keychain の password の読み出し・dump・
    export `security find-generic-password` / `find-internet-password` / `dump-keychain` / `export`(`-q` などの前置
    option を挟む形も。#315))は **map の末尾**に置く(last-match-wins で、
    後続の広い ask に deny を弱めさせないため)。Claude の secret floor と同じ集合(#315)。
    ([ai-policy](ai-policy.md): ローカル完結の read は無確認、外向きと昇格は都度承認。)
    `gh *` は space 付きなので `ghq` 等は対象外、bare `gh` は help 表示で allow-all に落ちる。read の allow は原則
    「完全一致」と「`… *`(space 付き)」の 2 本 1 組で命令名を区切る(`gh status*` のような space なしの allow だと
    `gh status-token` のような alias 名まで通る。ask / deny は過剰一致しても安全側なので space なし `*` のまま)。
    例外: `gh search` は `gh search *` だけで bare の `gh search` は ask。`gh auth status` / `gh --version` /
    `gh version` は完全一致だけ。
  - **破壊的な git と hook の skip(#304)**: Claude の床([claude-settings](claude-settings.md))と同じ rule を `bash` に
    足す。作業を捨てる git(`reset --hard`、`clean`、`checkout -- <path>` / `checkout <...> .`、`checkout` / `switch` の
    `-f` / `--force` / `--discard-changes`、`restore`、`push` の `--force` / `-f` / `+refspec`、`branch -D` / `--force` /
    `-f`)と、`--no-verify` / `git commit -n` の置き方のうち `git commit` / `git push` の直後以外は **ask**。option は
    単独の語として照合し(`git *push* -f` と `git *push* -f *`)、global option の後ろや他の引数の後ろでも拾い、
    `feature-f` のような branch 名の一部には一致しない。2 文字の代表的な束ね(`-uf` / `-df` / `-qf` など)も拾い、
    それ以外の束ねと省略形は拾わない。`git commit` / `git push` の直後の `--no-verify` と `git commit -n` は **deny** で、
    map の末尾に置く(後続の ask に弱めさせないため)。OpenCode には末尾の ` *` が bare の command にも一致する規則が
    無いので、deny は bare の形も並べる。`git push` は既存の `git push*` で元から全部 ask。
  - `edit`(#304): `*` allow の上に、user の参照先 note を **deny**(agent は読むだけ)。起動 dir からの相対 path 用の
    `.agent-context.local.md` と、sub dir や絶対 path 用の `*/.agent-context.local.md` の 2 本(OpenCode の `*` は `/` を
    含む任意の文字に一致する)。`example.agent-context.local.md` のような名前の似た file には一致しない。
    OpenCode が edit の rule にどの形の path(相対か絶対か)を渡すかは docs に書かれておらず、実行中の OpenCode では
    確かめていない。2 本の pattern は、docs の glob の上でどちらの形にも一致することを test で確かめている。
    `edit` は edit / write / patch をまとめて扱うが、bash からの書き込みには効かない。
  - `external_directory` は managed な床で `ask` に固定する(#315。OpenCode の既定も ask だが、read の deny が
    効かない grep / glob に対する project の外の守りなので、既定に任せない)。`doom_loop` は OpenCode 既定(ask)のまま。
- **`autoupdate: false`**: 起動時の本体の自動更新を止める([update-policy](update-policy.md))。更新は catalog の
  source(brew)で意図的に行う。起動時の DL がすべて止まるわけではない: plugin を設定していなくても、OpenCode は
  config dir(`~/.config/opencode/` など)へ `@opencode-ai/plugin` を npm install する(`package.json` / `node_modules` が
  できる)。これは `autoupdate` では止まらない。
- **`share: "disabled"`**: session の公開 upload 面を閉じる(public safety)。
- **`instructions`**: OpenCode は `~/.claude/CLAUDE.md` を Claude Code 互換で読むが **`@` import を辿らない**ため、
  import 先の `~/.claude/agent-tools/CLAUDE.md`(運用ルール・相互レビュー契約)を絶対 path で明示する。

## 射程と限界(過大評価しない)

- permission は OpenCode 内部で評価されるが、`bash` の rule は command 文字列への glob 照合なので、Claude の Bash matcher と同じく
  **steering であって enforcement ではない**(`$( )` や等価な別 command で迂回しうる。下記)。さらに **boundary では
  ない**: 設定は global → `OPENCODE_CONFIG` → project `opencode.json` → … の順で **merge・後勝ち**なので、
  project の `opencode.json` や agent 定義が床を allow に戻せる。managed `~/.claude/settings.json` と同じ
  「public-safe な既定」の位置づけ([ai-environment-boundary](ai-environment-boundary.md))。
- `bash` の pattern は解析後の command に対する glob。`$( )` や別経路(plugin・MCP)は対象外。
- OpenCode 自身の egress / fs sandbox は無い。OS 側の sandbox tier は別([ai-environment-boundary](ai-environment-boundary.md))。

## 導入手順(personal)

1. `brew install opencode`(catalog: `opencode`、homebrew-core の formula。`anomalyco/tap` の方が更新は速いが
   catalog に tap の概念が無いので当面 core を使う)。
2. `chezmoi apply` → `~/.config/opencode/opencode.json`(床)。既存の手書き `opencode.json` があれば、apply 前に
   `opencode.local.json` 等へ退避し `~/.zshrc.local` で `export OPENCODE_CONFIG=~/.config/opencode/opencode.local.json`。
3. `opencode` を起動し `/connect` で provider(OpenCode Go は API key を貼る)を繋ぐ → `auth.json` に保存。
4. `/models` で model を選ぶ(local。managed には書かない)。

## 検査

- `scripts/doctor.sh` の `OpenCode` section(report-only): `opencode` の presence、managed 床の presence
  (module 非 active なら「not managed」)、`auth.json` は**存在のみ**(中身も provider 名も読まない)。
  床の乖離は managed drift section が `chezmoi status` で拾う。
  agent-tools の plugin(#263)は **静的に**確認する: global の plugins dir(`plugins/personal-*.js`)にあるか、
  **二重読込**になる配置(`.ts` / `.mjs` の併置、単数形 `plugin/` dir の copy、OpenCode が読む設定 — managed の床と `OPENCODE_CONFIG` が指す file — の `plugin` 欄に同じ
  plugin 名)が無いか(読まれていない `opencode.local.json` に載っているだけなら注記にとどめる)。doctor は OpenCode を起動しない — `opencode debug config` でさえ OpenCode の DB
  (`~/.local/share/opencode/opencode.db`)に書き込むため(1.18.30 で実測)、doctor の副作用なしの規則に反する。
  設定ファイルは secret を含みうるので `plugin` 欄だけを読み、中身は表示しない。配置だけでは init の成功は
  分からない(init の throw は user に見えず、1.18.30 の log にも plugin の読込は出ない)。
- **plugin の init の確認(#311、agent-tools#343)**: `personal-agent-tools` は init を終えた時点で目印の行
  (`agent-tools:plugin-init v=1 name=personal-agent-tools build_id=<sha256:64 桁の小文字 hex | unknown>`。
  agent-tools の公開契約)を OpenCode の log に出す。doctor は **既にある log を読むだけ**(OpenCode は起動しない)で、
  `${XDG_DATA_HOME:-~/.local/share}/opencode/log/opencode.log`(1.18.30 の場所。regular file のときだけ読む)の中で
  message がこの接頭辞で始まるいちばん新しい行の build_id が、配置中の `plugins/personal-agent-tools.js` の 1 行目の
  marker の build_id と一致するときだけ「確認できた」(ok)とする。1 行目は agent-tools の marker の接頭辞と、この
  plugin を示す field(`repo=agent-tools name=personal-agent-tools target=opencode artifact_kind=plugin`)を持つ
  ときだけ marker とみなす(marker 全体の検査は agent-tools の doctor の担当)。それ以外は失敗とは言わず
  「未確認」の info に理由を添える: 1 行目がこの plugin の marker でない / log が無い(未起動)/ log が regular file で
  ない / 行が無い(配備後に未起動・`--pure`・INFO より上の log level・rotate・init の throw)/ build_id の不一致
  (同期後に未起動・旧い build のままの process)/ `unknown` / v=1 の形でない(版違い・余分な token・桁や大文字の
  違い)/ log を読めない / `XDG_DATA_HOME` が相対 path(OpenCode の起動 dir で場所が変わる)。
  行は 1.18.30 の `timestamp=… level=… run=… message="…"` の形で、見るのは各行の**最初の** `message=` の値だけ。
  その値が目印の接頭辞で始まる行のうちいちばん新しいものを選び(後の行が message の途中で目印を引用しても、本物の
  目印を隠さない)、その値が `"` で囲まれた目印そのもので閉じているときだけ目印とみなす(空白を含む message は
  必ず `"` で囲まれるので、囲まれていない形は受け付けない)。build_id はその形で切り出し、行の末尾の位置には
  頼らない。
  表示は判定・build_id・短い理由だけで、log の行も過去の log も出さない。
  **限界**: 行は「この build で init が return まで到達した起動が過去にあった」証拠で、直近の起動が成功した証拠では
  ない(同じ build の古い行が残っていれば、その後の起動が init に失敗しても「確認できた」になる)。
  `opencode.local.json` があるのに doctor を実行した shell で `OPENCODE_CONFIG` が未設定 / 別 file を指す場合も
  報告する(`~/.zshrc.local` に export があれば、非対話 shell 由来として中立表示)。
- `scripts/test-opencode-settings.sh`: render した `opencode.json` の exact pin(read / bash の rule map を順序込みで、
  autoupdate / share / instructions、top-level key の集合、secret / email らしき文字列の不在、work は非 render)。
  加えて bash の rule map を OpenCode の意味論(glob・last-match-wins)で固定の command 集合に当てて判定を
  assert する(#240): doctor の Codex probe 30 本(外向き・昇格 27 + 認証情報の表示 3、#287)+ 短縮 flag / alias / read 形の約 100 本。期待値は
  ai-policy から手で固定し、map から導かない。rule に `*` 以外の pattern 文字(`?` `[` `]` `\`)が入ると fail
  (bash `case` との意味の乖離を避ける)。
- `scripts/test-claude-settings.sh`: Claude 側 secret floor に `Read(~/.local/share/opencode/auth.json)` が入っている
  こと(secret floor 30 件 + #304 の hook の skip と note の deny 4 件 + personal 既定の `mcp__github` で計 35 件の deny と、
  1Password の CLI 全体と #304 の作業を捨てる git・hook の skip の ask 55 件を順序込みで exact pin。#315 / #304)。
