# Supply Chain: npm

`supply-chain/npm` module の方針。npm 経由の supply-chain 攻撃(install script、typosquatting、公開直後の悪性 version)への防御を `npmHardeningMode` capability で段階制御する。

## Mode

```text
off     何も管理しない。doctor も npm hardening を検査しない前提の profile 向け。
report  ~/.npmrc は管理しない。doctor が現在の npm config を表示するだけ。
enforce chezmoi が ~/.npmrc を管理し、hardening 設定を出力する。
```

- `report` / `off` では `~/.npmrc` は chezmoi の管理対象外になる(既存 `.npmrc` を上書きしない)。この gate は `supply-chain/npm` module の `paths:` / `requires:` 宣言(`.chezmoidata/modules.yaml`)から `.chezmoiignore` に生成される。
- `enforce` は現在 `personal` profile のみ。work 系は `report` で、会社側の npm 設定を壊さない。

## enforce 時の `~/.npmrc`

`dot_npmrc.tmpl` が出力する設定とその意図:

```text
ignore-scripts=true  install 時の lifecycle script(postinstall 等)を実行しない
save-exact=true      依存を range ではなく exact version で保存する
fund=false           funding 表示を抑制する(ノイズ削減)
audit=true           install 時の audit を有効に保つ
min-release-age=7    公開から 7 日未満の version を install しない(日数単位)
```

token、registry URL、auth 設定は一切含めない。それらは project 側または環境側の責務で、この repo では扱わない。

## token / auth が必要なとき

npm publish や private registry の認証で token が要る場合も、**グローバル `~/.npmrc` に平文 token を置かない**(hardening 適用でこのファイルは token-free に保つ)。token は [secrets](secrets.md) の供給規約に従い、1Password に保管して実行時に環境変数で注入する。値はディスク・repo に落とさず、永続化するのは `op://` 参照だけにする。

npm は `.npmrc` 内で環境変数を参照できる。token 参照を持つ `.npmrc` は **project local に置き、commit しない**(`.gitignore` 対象)。

```text
# project local .npmrc(非 commit)— 値ではなく env 参照を持つ
//registry.npmjs.org/:_authToken=${NPM_TOKEN}
```

```bash
# token は 1Password から実行時に注入(値はディスクに落とさない)
# op:// は placeholder。実際の vault / item 名は repo に書かない。
NPM_TOKEN="$(op read 'op://<vault>/<item>/credential')" npm publish
```

失効・未使用の token をグローバル `~/.npmrc` に放置しない。必要になったら `npm login` で再発行し、上記の供給方式に乗せる。

## `ignore-scripts=true` の逃げ道

build script が必要な package(esbuild、sharp など)は install 後に明示的に実行する。

```sh
npm install
npm rebuild <package> --foreground-scripts
```

または、信頼できる project に限り project local で override する。

```sh
npm install --ignore-scripts=false
```

project の `.npmrc` に `ignore-scripts=false` を置く方法もあるが、その project の依存全体に効くため、理由を project 側に書き残すこと。

### Claude Code(ネイティブバイナリを postinstall で配置する例)

Anthropic 公式 CLI `@anthropic-ai/claude-code` 2.x は、~226MB のネイティブバイナリを optional dependency(`@anthropic-ai/claude-code-<platform>`)として配布し、`postinstall`(`install.cjs`)でそれを package の bin にハードリンク配置する。`ignore-scripts=true` だと postinstall が走らずバイナリが配置されず(optional dep 自体は取得されている)、`claude` 実行時に次で落ちる:

```text
Error: claude native binary not installed.
```

`ignore-scripts` は all-or-nothing で npm に package 単位の許可機能が無いため、信頼できる first-party の `claude-code` についてのみ、**グローバルの `ignore-scripts=true` は維持したまま、監査済みの installer 1 本だけを path 指定で明示実行**する(hardening を全体で緩めない、という enforce の方針と最も整合する逃げ道)。

```sh
# 通常 install(optional dep を取得)→ 既知の installer だけを明示実行
npm i -g @anthropic-ai/claude-code --include=optional
node "$(npm root -g)/@anthropic-ai/claude-code/install.cjs"
```

この 2 手は `dot_zshrc` の `claude-update` 関数にまとめてある(更新時はこれを実行する)。

検証:

```sh
claude --version                                       # → 2.x (Claude Code)
ls -la "$(npm root -g)/@anthropic-ai/claude-code/bin/" # 本体が ~226MB(スタブでない)
```

`min-release-age=7` により最新ではなく公開 7 日以上経った版が入るのは仕様(下記「`min-release-age` の注意」)。

## `min-release-age` の注意

- 単位は日数。pnpm の `minimumReleaseAge`(分単位)と混同しないこと。
- npm 11.10.0 以降でサポートされる。古い npm では unknown config として扱われるだけで、保護は効かない。
- npm は `min-release-age` を内部で `before`(= 現在 − 指定日数の日付)へ変換し、元のキーを削除する。このため `npm config get min-release-age` は設定済みでも常に `null` を返す。`doctor.sh` は実効キー `before` が**現在から約 7 日前(±12h)の cutoff になっているか**で honored を判定する(`before` の有無だけでは、短い日数や手書きの遠い未来日付も通ってしまい不十分なため)。
- `doctor.sh` が npm version と各設定値を report-only で表示する。

## doctor の検査

- `npmHardeningMode` と npm version、主要 config 値を表示する。
- `enforce` の場合は、期待値(上記)と現在の `npm config get` の値を比較し、不一致を `[warn]` で報告する。
  apply 前は不一致になるのが正常。report-only で exit code は変えない。

## 対象外

- npm package の install / 削除。
- private registry、token、auth config。
- 会社・クライアント固有 registry の扱い(work 側環境の責務)。
