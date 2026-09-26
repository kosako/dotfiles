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
| plugin による hook parity(safe-gh 誘導 / 品質ループ / herdr)、相互レビュー契約への追加 | OpenCode 導入 Phase 2(agent-tools#295) | ❌ 未着手 |

work / client には配らない(`opencode-settings` module を持たない。claude-settings / codex-settings と同じ)。

## 床の中身と根拠

- **permission**: OpenCode の既定は **allow all**。rule は pattern の **last-match-wins**。
  - `read`: `*` allow の上に、SSH 鍵 / credential store(`~/.aws`、`~/.config/gh`、`~/.netrc`、Codex と
    OpenCode の `auth.json`)/ `.env` 系を deny(`.env.example` は allow)。SSH 鍵と credential store は
    Claude の secret floor(`Read` 側 6 件)と同じ集合。`.env` 系の deny は Claude では secret floor ではなく
    `enforceAiSandbox` 連動の human-legit gate(personal では off)に当たるので、この点は OpenCode の床の方が厳しい。
  - `bash`: `*` allow の上に、マシン外に出る操作と昇格(`git push` / `git clone` / `sudo` / `curl` / `wget`)を
    **ask**。GitHub CLI は **`gh *` を既定 ask** にし、read 系の subcommand(`pr view|list|diff|checks|status`、
    `issue view|list|status`、`repo view`、`release view|list`、`run view|list`、`workflow view|list`、
    `label list`、`gist view|list`、`search`、`status`、bare の `auth status`、`--version` / `version` / `help`)だけを
    allow に戻す(#240: mutation を列挙する方式では `gh issue edit` / `gh pr close` / `gh api -XPOST` などが
    allow-all に落ちた。`gh api` は method に関わらず ask — 短縮 flag `-XPOST` / `-ftitle=x` は flag 照合を
    すり抜け、GraphQL は read でも POST を使う)。deny(env dump `env` / `printenv`、`gh secret` /
    `gh api *secrets*`、token 表示 `gh auth token` / `gh auth status --show-token` / `-t`、`cat ~/.ssh/*`)は
    **map の末尾**に置く(last-match-wins で、後続の広い ask に deny を弱めさせないため)。
    ([ai-policy](ai-policy.md): ローカル完結の read は無確認、外向きと昇格は都度承認。)
    `gh *` は space 付きなので `ghq` 等は対象外、bare `gh` は help 表示で allow-all に落ちる。read の allow は原則
    「完全一致」と「`… *`(space 付き)」の 2 本 1 組で命令名を区切る(`gh status*` のような space なしの allow だと
    `gh status-token` のような alias 名まで通る。ask / deny は過剰一致しても安全側なので space なし `*` のまま)。
    例外: `gh search` は `gh search *` だけで bare の `gh search` は ask。`gh auth status` / `gh --version` /
    `gh version` は完全一致だけ。
  - `external_directory` / `doom_loop` は OpenCode 既定(ask)のまま。
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
- `scripts/test-opencode-settings.sh`: render した `opencode.json` の exact pin(read / bash の rule map を順序込みで、
  autoupdate / share / instructions、top-level key の集合、secret / email らしき文字列の不在、work は非 render)。
  加えて bash の rule map を OpenCode の意味論(glob・last-match-wins)で固定の command 集合に当てて判定を
  assert する(#240): doctor の Codex outward probe 27 本 + 短縮 flag / alias / read 形の約 100 本。期待値は
  ai-policy から手で固定し、map から導かない。rule に `*` 以外の pattern 文字(`?` `[` `]` `\`)が入ると fail
  (bash `case` との意味の乖離を避ける)。
- `scripts/test-claude-settings.sh`: Claude 側 secret floor に `Read(~/.local/share/opencode/auth.json)` が入っている
  こと(secret floor 13 件 + personal 既定の `mcp__github` で計 14 件の deny を順序込みで exact pin)。
