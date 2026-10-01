# herdr config(`herdr-config` module、#261)

herdr(AI agent 用の terminal workspace manager)の config `~/.config/herdr/config.toml` を managed に
するための module。agent-tools の herdr 運用 doc は、この file を「dotfiles の管轄」として扱い、
worker の完了を **OS の通知**で知る前提を置いている。ところが herdr の既定の通知の配信先
(`[ui.toast] delivery`)は `off` なので、新しい machine では何もしないと通知が届かない。この前提を
dotfiles が再現できるようにするため、#261 で持ち主を dotfiles に決めた(それまでは誰も管理しておらず、
両 repo が相手の管轄だと考えて宙に浮いていた)。

## 何を管理するか

managed file `~/.config/herdr/config.toml`(source: `private_dot_config/herdr/config.toml`、静的 file)の
1 file だけ。中身は導入時の live file と同じ設定値に、managed-by の見出しと注記を足したもの:

| 設定 | 値 | 意味 |
| --- | --- | --- |
| `onboarding` | `false` | 初回の案内を出さない |
| `[ui] agent_panel_sort` | `"priority"` | agent panel を優先度順に並べる |
| `[ui] show_agent_labels_on_pane_borders` | `true` | pane の枠に agent 名を出す |
| `[ui.toast] delivery` | `"system"` | 組み込み通知を OS の通知で出す(herdr の既定は `off`) |
| `[experimental] switch_ascii_input_source_in_prefix` | `true` | prefix キーで入力ソースを英数に切り替える |

- `~/.config/herdr/` の他の file(`session.json`・log・socket・`release-notes.json` 等)は herdr の
  実行時状態で、**管理しない**。`.chezmoiignore` は allowlist(#207)なので、宣言した 1 file だけが入り、
  隣の file には触れない(`test-herdr-config.sh` が pin)。
- 設定を足す・変えるときは managed file を直し、`herdr config check` で検証してから(下記)、
  `test-herdr-config.sh` の pin も意図して更新する。

## herdr がどの file を読むか(実測、herdr 0.9.0)

- 読むのは **1 file だけ**: `HERDR_CONFIG_PATH` が**設定されていれば**その path、なければ
  `XDG_CONFIG_HOME` が設定されていれば `$XDG_CONFIG_HOME/herdr/config.toml`、どちらも無ければ
  `~/.config/herdr/config.toml`。変数は**空でも「設定あり」**として扱われる(`HERDR_CONFIG_PATH=""` なら
  どの file も読まず、全部既定値)。
- include や `.local` の層は無い。host 固有の設定は managed file に入れるか、持たない
  ([local-overrides](local-overrides.md))。
- **parse error のとき herdr は黙って全部既定値で動く**(`; using defaults`)。たとえば新しい herdr が
  受け付けなくなった値が 1 つあるだけで、通知も含めて全設定が外れる。`herdr config check` はその場合と
  未知の key のときに exit 1、問題が無ければ exit 0(file を読むだけで何も書かない。file が無いときも
  exit 0 なので、存在の確認には使えない)。
- 動いている herdr server は、apply した変更を `herdr server reload-config` で読み直す。

## profile

- **personal のみ列挙**。work は非列挙: 会社 Mac にも herdr はあるが、既存の config を diff 無しで
  置き換えないため。採用するときは `preflight` で既存 file を確認し、残したい設定を managed file に
  入れてから profile に module を列挙する。
- module 列挙だけで gate する(capability は無い。git-ignore / opencode-settings と同型)。managed-by の
  見出しを持つので、profile 切替で非 active になった残置は doctor の managed-path orphan scan が拾う。

## doctor / preflight

- `preflight`(apply 前): module active で `~/.config/herdr/config.toml` が**既にある**と「apply が置換する。
  `.local` は無いので host 固有の設定は managed file に入れる」の warn(中身は読まない)。非 active profile
  では left-as-is の item。
- `doctor`(apply 後、「herdr config」section): 次の順に見る。
  1. managed file が無い → action(`mkdir -p ~/.config` と `chezmoi apply` の手順)。
  2. doctor を実行した環境の `HERDR_CONFIG_PATH` / `XDG_CONFIG_HOME` が別の file を指す(空の
     `HERDR_CONFIG_PATH` を含む)→ warn。同じ file かは文字列ではなく `-ef` で比べる
     (`XDG_CONFIG_HOME=~/.config/` のような末尾 `/` は別扱いしない)。
  3. `herdr config check` を期限付き(`bounded_probe`)で実行し、exit 0 なら ok、それ以外は action。
     herdr が PATH に無い・期限内に答えない場合は「未確認」の ok。herdr の出力は表示しない。
  - 中身の drift(live file を手で変えた等)は managed drift section が出す。

## 検証

`scripts/test-herdr-config.sh`: personal で apply され work ではされない(work が持つ自前の config は
byte 単位で不変)、1 行目の managed-by 見出し、TOML として parse でき設定値が pin どおり
(`[ui.toast] delivery = "system"` を含む)、mode が file 0644 / directory 0755(既存 host の初回 apply で
権限を変えない)、隣の `session.json` と log が apply で変わらないこと。doctor の分岐は `test-doctor.sh`
(`herdr config check` は PATH の先頭に置いた fake)、preflight の warn は `test-preflight.sh`。
