# agent-tools の残量の読み取り口(`agent-tools-usage-reader` module、#301)

agent-tools の作業の割当と maintenance sweep は、使用量の枠の残量を「読み取り口」から読んで、担当や規模を
決める。agent-tools#385 で、読み取り口の実行は agent-tools が配る固定の wrapper `personal-usage-reader` に
一本化された(それまでは repo root の `.agent-context.local.md` に書かれた command を実行していたが、
data-only の note の中身を実行するのは境界を破るため)。wrapper が**どの実行ファイルで読むか**は machine ごとの
設定で、その中身を dotfiles が置く(#264 の Codex の profile file と同じ分担)。この module はその設定 file を
managed にする。

## 何を管理するか

managed file `~/.config/agent-tools/usage-reader.json`(source:
`private_dot_config/agent-tools/usage-reader.json.tmpl`)の 1 file だけ。中身:

```json
{
  "argv": ["<home>/go/bin/tacho", "status", "--json"],
  "timeout_sec": 20
}
```

- 読み取り口は statusLine と同じ tacho(software catalog の go_install)の `status --json`。path は managed
  statusLine と同じく `{{ .chezmoi.homeDir }}/go/bin` で決める(絶対 path を source に書かない。`GOBIN` を
  変えている machine では合わない点も statusLine と同じ)。home の path は `toJson` で JSON として escape する。
- **file 名と key は agent-tools の公開契約**(正本は agent-tools の `docs/boundary-with-dotfiles.md`
  「残量の読み取り口の設定」)。key は `argv`(必須。空でない文字列の配列で、`argv[0]` は絶対 path の実行できる
  regular file)と `timeout_sec`(任意。1〜120 の整数、既定 20)**だけ**で、知らない key があると wrapper は
  失敗する(exit 2)。そのため managed-by の見出しを置けない(strict な JSON で comment も無い)。
- agent-tools はこの file を作らず、書き換えず、sync の対象にもしない。`~/.config/agent-tools/` の他の file には
  触れない(`.chezmoiignore` は allowlist。`test-agent-tools-usage-reader.sh` が pin)。

## wrapper の読み方(agent-tools の契約の要約)

- 場所は `${XDG_CONFIG_HOME:-$HOME/.config}/agent-tools/usage-reader.json` 固定(path を引数で受け取らない)。
  `XDG_CONFIG_HOME` は**絶対 path のときだけ**使い、相対や空なら `~/.config` を見る。
- `argv` を shell を通さずに起動する(cwd `/`、stdin `/dev/null`)。exit 0 で空でない stdout だけを使う。
  設定 file が無ければ exit 3(読み取り口なし)、不正・失敗・timeout は exit 2。
- 置かない machine では「読み取り口なし」になる: 割当は残量を見ずに向き不向きだけで決め、sweep は規模を広げない。

## profile

- **personal のみ列挙**。work は非列挙: 会社機には tacho がまだ無い。読み取り口を持たせるときは、tacho の
  導入と合わせて改めて列挙を決める(手で置いた file も wrapper は読む)。
- module 列挙だけで gate する(capability は無い。herdr-config / git-ignore と同型)。managed-by の見出しが
  無いので、profile 切替で非 active になった残置は managed-path orphan scan では拾えない(#201 の残置と同じ
  扱い。doctor の非 active profile の表示が「在る」ことだけを中立に出す。`XDG_CONFIG_HOME` で読み先がずれて
  いれば、wrapper が読むのはその先だと示す)。

## doctor / preflight

- `preflight`(apply 前): module active で file が**既にある**と「apply が置換する。`.local` は無いので
  diff してから」の warn(中身は読まない)。非 active profile では left-as-is の item。
- `doctor`(apply 後、「agent-tools usage reader」section): **静的な確認だけ**。wrapper も読み取り口も
  実行しない(tacho は実行時に cache を書くので、doctor の副作用なしを保つため)。
  1. 読み先: doctor を実行した環境の `XDG_CONFIG_HOME` が絶対 path で別の場所を指す → warn(相対・空は
     wrapper と同じく無視。同じ file かは、末尾 `/` を落とした同じ綴りか `-ef` で判定)。
  2. managed file: 無い → action(`mkdir -p ~/.config` と `chezmoi apply` の手順。読み先がずれていれば
     「ずれを直すまで効かない」と書く)。regular file でない → action。ある → 契約の形(JSON object・
     key は `argv` / `timeout_sec` だけ・`argv` は空でない文字列の配列で制御文字を含まない・`timeout_sec` は
     1〜120 の整数・`argv[0]` は絶対 path)を外れていれば、外れ方を固定の文言で示す action(手順は
     `chezmoi apply`。読み先がずれていれば「ずれを直すまで効かない」と書き、wrapper が失敗するとは断定しない)。
     `argv[0]` が実行できる regular file でなければ、tacho の導入(`install-packages.sh`)を示す action。
     すべて満たせば ok。
  - `timeout_sec` は書かれた字面で判定する(yq は `20.0` や `2e1` を整数に正規化するが、wrapper の JSON parser は
    Float として読み拒否するため)。それでも重複した key や不正な UTF-8 などは真似ておらず、厳密な規則の正本は wrapper。
    ok は「形が契約どおりで `argv[0]` が実行できる」の意味で、実際に残量を読めたかは確かめていない。
  - 表示は固定の文言だけで、設定の値(path や引数)は出さない。中身の drift は managed drift section が出す。

## 検証

`scripts/test-agent-tools-usage-reader.sh`: personal で apply され work ではされない(work が持つ自前の
file は byte 単位で不変)、strict な JSON で key が `argv` / `timeout_sec` だけ・`argv` が
`[<home>/go/bin/tacho, "status", "--json"]`・`timeout_sec` が整数 20、`"` `\` `&` `<` を含む home の path が
escape を経ても壊れない、mode が file 0644 / directory 0755、`~/.config/agent-tools/` の隣の file が apply で
変わらないこと。doctor の分岐は `test-doctor.sh`、preflight の warn は `test-preflight.sh`。導入時に、render した
file を scratch の `XDG_CONFIG_HOME` に置いて実際の wrapper で読めること(exit 0 で tacho の JSON)と、知らない
key を足すと exit 2 になることを手で確認した(#301)。
