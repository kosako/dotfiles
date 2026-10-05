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
  statusLine と同じく `{{ .chezmoi.homeDir }}/go/bin` で決める(絶対 path を source に書かない)。managed な mise
  config が GOBIN を設定させないので、catalog の go_install(`install-packages.sh`)も同じ `~/go/bin` に入れる
  (#305。[runtime](runtime.md))。GOBIN / GOPATH を別に設定した machine では合わなくなり、doctor の
  runtime and shell の節が action として報告する。home の path は `toJson` で JSON として escape する。
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
- `--check`(agent-tools#400): 設定と `argv[0]` の実行ファイルを同じ規則で検査するだけで `argv` を起動しない
  (exit 0 = 契約どおり / 3 = 無い / 2 = 不正、stdout は常に空)。対応しているかは `--help` の 1 行目の `[--check]` で
  分かる。
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
- `doctor`(apply 後、「agent-tools usage reader」section): 読み取り口は実行しない(tacho は実行時に cache を
  書くので、doctor の副作用なしを保つため)。契約の規則は写さず、wrapper の `--check`(agent-tools#400)に
  判定させる(#303)。
  1. 読み先: doctor を実行した環境の `XDG_CONFIG_HOME` が絶対 path で別の場所を指す → warn(相対・空は
     wrapper と同じく無視。同じ file かは、末尾 `/` を落とした同じ綴りか `-ef` で判定)。
  2. managed file の有無(dotfiles の管轄): 無い → action(`mkdir -p ~/.config` と `chezmoi apply` の手順。
     読み先がずれていれば「ずれを直すまで効かない」と書く)。指す先の無い symlink → 無いときと同じ扱いの action
     (wrapper は辿った先が無いと「読み取り口なし」(exit 3) にする)。regular file でない → action。
  3. 契約に合うか(wrapper の管轄): regular file のときだけ、配備済みの
     `~/.claude/agent-tools/scripts/personal-usage-reader` の `--check` を呼ぶ。`--check` は設定と `argv[0]` の
     実行ファイルを通常の起動と同じコードで検査し、`argv` を起動しない(file を書かない・子 process を起動しない・
     network を使わない)。
     - **他の repo のコードを実行するので opt-in の下でだけ呼ぶ**: `status.sh` と同じく `enableAgentToolsStatus=true`
       のときだけ。opt-in していなければ「未確認」の item で、wrapper を一度も呼ばない。
     - 呼ぶ前に `--help` の 1 行目に `[--check]` があることを確かめる(agent-tools の公開契約。`--check` を知らない
       旧い wrapper は `--check` を usage error の exit 2 にし、「不正」と区別できないため)。無い → 「旧版」、
       wrapper が無い・実行できない → 「未配備」として、どちらも未確認と agent-tools の sync を示す action。
       `--help` 自体が失敗する(interpreter が無いなど、起動できない wrapper もありうる)→ 旧版とは断定せず未確認の
       warn。
     - `--check` は `XDG_CONFIG_HOME` を外して呼ぶ(読み先がずれていても managed file を判定するため)。どちらの
       呼び出しも `bounded_probe` で期限付き(5 秒)にする。
     - exit 0 → ok。exit 2 → wrapper の理由の 1 行(接頭辞 `personal-usage-reader: ` を外し、制御文字を除く)を
       添えた action。手順は `chezmoi apply` と、理由が実行ファイルなら tacho の導入(`install-packages.sh`)。読み先が
       ずれていれば「ずれを直すまで効かない」と書き、wrapper が失敗するとは断定しない。それ以外の exit や期限切れ →
       未確認の warn。
  - ok は「`--check` が受け入れた」の意味で、実際に残量を読めたかは確かめていない。
  - 表示するのは doctor の固定の文言と、wrapper の理由の 1 行だけ。理由に設定の中身と path が出ないことは
    agent-tools の契約(`docs/boundary-with-dotfiles.md`)。中身の drift は managed drift section が出す。

## 検証

`scripts/test-agent-tools-usage-reader.sh`: personal で apply され work ではされない(work が持つ自前の
file は byte 単位で不変)、strict な JSON で key が `argv` / `timeout_sec` だけ・`argv` が
`[<home>/go/bin/tacho, "status", "--json"]`・`timeout_sec` が整数 20、`"` `\` `&` `<` を含む home の path が
escape を経ても壊れない、mode が file 0644 / directory 0755、`~/.config/agent-tools/` の隣の file が apply で
変わらないこと。doctor の分岐は `test-doctor.sh`、preflight の warn は `test-preflight.sh`。導入時に、render した
file を scratch の `XDG_CONFIG_HOME` に置いて実際の wrapper で読めること(exit 0 で tacho の JSON)と、知らない
key を足すと exit 2 になることを手で確認した(#301)。`--check` への置き換え(#303)では、実機の managed file で ok に
なることと、scratch の HOME に実際の wrapper を置いて、知らない key・無い実行ファイル・`timeout_sec` の `20.0` が
理由つきの action になること、`XDG_CONFIG_HOME` が別の場所を指しても managed file を判定すること、読み取り口が
起動しないことを手で確認した。
