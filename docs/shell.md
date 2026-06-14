# Shell (shell-extra)

`shell-extra` module の方針。zsh の設定(`~/.zshrc` / `~/.zprofile`)を chezmoi 管理に載せる。

## 方針

- 管理するのは**汎用で公開しても安全な部分のみ**。machine 固有・secret・会社/クライアント固有の値は managed file に入れない。
- 現在の構成は oh-my-zsh ベース(theme `robbyrussell`、plugin `git`)。
- oh-my-zsh は**自動 install しない**。`~/.oh-my-zsh/oh-my-zsh.sh` が無くても shell が起動するよう、source は存在チェックで guard する。
- managed file の末尾で local override を source する(local が勝つ)。詳細は [docs/local-overrides.md](local-overrides.md)。

## 管理対象と gate

- `shell-extra` module の `paths:` に `.zshrc` / `.zprofile` を宣言している(`.chezmoidata/modules.yaml`)。
- `shell-extra` module を持つ profile(`personal` / `work-dev`)でのみ管理対象になる。持たない `work-minimal` では `.chezmoiignore` の生成によって除外され、既存の `~/.zshrc` はそのまま残る。

## local override(repo に入れない)

machine 固有の設定は local file に置く。repo には commit しない。

- `~/.zshrc.local` — machine 固有 PATH(IDE / tool の bin)、tool 環境変数、secret など。
- `~/.zprofile.local` — login shell の machine 固有環境。

managed file はこれらを末尾で source するので、local 側が最終的に勝つ。例えばツールが `~/.zshrc` に自動追記する PATH(home 配下の絶対パス)は、managed file ではなく `~/.zshrc.local` に置く。

## 移行手順

既存の `~/.zshrc` / `~/.zprofile` があるため、apply は backup と diff 確認を伴って行う(この module 単体では apply しない。実際の apply は別途)。

1. **backup**: 元の状態を変更する前に取る。`cp ~/.zshrc ~/.zshrc.pre-chezmoi`(`~/.zprofile` も同様)。
2. **machine 固有行を退避**: 既存 `~/.zshrc` の中で managed に含めない行(ツール / IDE の PATH、tool env、secret)を `~/.zshrc.local` に移す。`~/.zprofile` も同様に `~/.zprofile.local` へ。
3. **影響確認**: `./scripts/preflight.sh personal` の "shell config (apply impact)" section を見る。
4. **diff 確認**: `chezmoi diff ~/.zshrc ~/.zprofile`。
5. **apply**: `chezmoi apply ~/.zshrc ~/.zprofile`。
6. **検証**: 新しい shell を開き、oh-my-zsh の prompt が出ること、`~/.zshrc.local` に退避した PATH 等が効いていることを確認する。

## rollback

```sh
cp ~/.zshrc.pre-chezmoi ~/.zshrc
cp ~/.zprofile.pre-chezmoi ~/.zprofile
```

managed 化自体を戻す場合は `chezmoi forget ~/.zshrc ~/.zprofile` の後に backup を復元する。

## 対象外

- oh-my-zsh / plugin の自動 install。
- machine 固有値・secret の repo への持ち込み。
- この module 単体での実 home への apply。
