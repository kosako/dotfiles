# Shell (shell-extra)

`shell-extra` module の方針。zsh の設定(`~/.zshenv` / `~/.zshrc` / `~/.zprofile`)と starship prompt(`~/.config/starship.toml`)を chezmoi 管理に載せる。

## 方針

- 管理するのは**汎用で公開しても安全な部分のみ**。machine 固有・secret・会社/クライアント固有の値は managed file に入れない。
- **explicit-first / フレームワーク無し**(#96)。oh-my-zsh やプラグインマネージャは使わず、必要なツール(starship・fzf・zoxide・補完/入力補助プラグイン・modern CLI)を catalog(`.chezmoidata/packages.yaml`)で宣言 → brew で install → `~/.zshrc` から直接 init / source する。何が読み込まれるかが managed file 上で明示され、監査可能。
- 各 source / init は**存在チェックで guard**(`command -v` / `[ -r ... ]`)。ツールが未 install でも shell は起動する(no-op)。
- managed file の(syntax-highlighting より前の)末尾で local override を source する(local が勝つ)。詳細は [docs/local-overrides.md](local-overrides.md)。

## `~/.zshrc`(対話シェルのスタック、#96)

すべて catalog 宣言 + brew install 済みで、`~/.zshrc` が guard 付きで読み込む:

- **プロンプト**: starship(`~/.config/starship.toml`)。2行・git 状態・実行時間・exit code・関連 project でのみ runtime version を表示(mise 連動)・**git identity context**(personal=緑 / その他=黄+email / repo 内で identity 未解決=赤)で誤コミットを視覚的に防ぐ。identity の分類は runtime に local の `~/.config/git/personal.gitconfig` と照合し、managed file に identity 値を入れない([docs/git-identity.md](git-identity.md))。
- **移動**: zoxide(`z` / `zi`)+ fzf(`Ctrl-R` 履歴 / `Ctrl-T` ファイル / `Alt-C` サブディレクトリ cd)。
- **補完**: zsh-completions を fpath に足し、compinit はキャッシュ(dump が無い/24h 超で再生成、通常は `-C` の高速パス)。fzf-tab で TAB 補完を fzf 化。
- **入力補助**: zsh-autosuggestions(履歴ベース)+ zsh-syntax-highlighting。**syntax-highlighting は必ず最後に source**(直前までに定義した全 widget を wrap するため)。
- **履歴**: 大容量・重複除去・セッション共有・タイムスタンプ。`HIST_IGNORE_SPACE` で行頭スペースのコマンドは記録しない(secret の手動オプトアウト。secret は op/direnv 供給でインライン入力しない = [docs/secrets.md](secrets.md))。off-machine 同期はしない。
- **modern CLI**: eza(`ls` 系 alias)/ bat(`cat` alias、pager 無しで cat 風)。**alias は対話シェル限定**でスクリプトに影響せず、`command ls` / `command cat` で原本に届く。ripgrep / fd は fzf の裏方。
- **runtime/env(別レイヤを compose)**: mise activate(対話)+ direnv hook。mise = runtime version、direnv = project env / op secret 注入([docs/runtime.md](runtime.md) / [docs/secrets.md](secrets.md))。新しい version スイッチャ(nvm/pyenv 等)は入れない(mise と競合)。

読み込み順序は widget の wrap 関係に従う: compinit → fzf-tab → fzf / zoxide / starship / direnv / mise → alias → local override → zsh-autosuggestions → zsh-syntax-highlighting(最後)。

## `~/.zshenv`(非対話 shell の PATH)

`~/.zshenv` は **すべての zsh 起動**(対話/非対話・login/非login)で読まれる。ここに mise の shims(`$HOME/.local/share/mise/shims`)を PATH 前置し、子プロセスが spawn する非対話 shell でも mise 管理 runtime(`node` 等)が解決するようにする。`~/.zshrc` の `mise activate` は対話 shell でしか走らないため、非対話側は shims が拾う(両者は併用、削除不要)。詳細は [docs/runtime.md](runtime.md)。

- **最小限に保つ**: 全 zsh 起動で走るので、`.zshenv` には PATH 以外の重い処理・副作用を入れない。
- **local override は無し**: `.zshenv` は `~/.zshenv.local` を source しない(副作用を避けるため)。machine 固有 PATH は `~/.zshrc.local`(対話)に置く。
- `MISE_DATA_DIR` を変更している場合は、shims パスをその値に合わせる(既定 `$HOME/.local/share/mise/shims`)。

## 管理対象と gate

- `shell-extra` module の `paths:` に `.zshenv` / `.zshrc` / `.zprofile` / `.config/starship.toml` を宣言している(`.chezmoidata/modules.yaml`)。
- `shell-extra` module を持つ profile(`personal` / `work-dev`)でのみ管理対象になる。持たない `work-minimal` ではいずれも `.chezmoiignore` の生成によって除外され、既存ファイルはそのまま残る。

## local override(repo に入れない)

machine 固有の設定は local file に置く。repo には commit しない。

- `~/.zshrc.local` — machine 固有 PATH(IDE / tool の bin)、tool 環境変数、secret など。
- `~/.zprofile.local` — login shell の machine 固有環境。

managed file はこれらを末尾で source するので、local 側が最終的に勝つ。例えばツールが `~/.zshrc` に自動追記する PATH(home 配下の絶対パス)は、managed file ではなく `~/.zshrc.local` に置く。

## 移行手順

既存の `~/.zshrc` / `~/.zprofile`(および `~/.zshenv` / `~/.config/starship.toml` があれば)が apply で置き換わるため、apply は backup と diff 確認を伴って行う(この module 単体では apply しない。実際の apply は別途)。

1. **backup**: 元の状態を変更する前に取る。`cp ~/.zshrc ~/.zshrc.pre-chezmoi`(`~/.zprofile` / `~/.zshenv` / `~/.config/starship.toml` も存在すれば同様)。
2. **machine 固有行を退避**: 既存 `~/.zshrc` の中で managed に含めない行(ツール / IDE の PATH、tool env、secret)を `~/.zshrc.local` に移す。`~/.zprofile` も同様に `~/.zprofile.local` へ。`.zshenv` は local override を持たないので、既存 `~/.zshenv` の行も対話用なら `~/.zshrc.local` へ移す。`~/.config/starship.toml` は local override を持たない(managed が全体)ので、独自のプロンプト設定は managed file に畳み込む。
3. **影響確認**: `./scripts/preflight.sh personal` の "shell config (apply impact)" section を見る。
4. **diff 確認**: `chezmoi diff ~/.zshenv ~/.zshrc ~/.zprofile ~/.config/starship.toml`。
5. **apply**: `chezmoi apply ~/.zshenv ~/.zshrc ~/.zprofile ~/.config/starship.toml`。
6. **検証**: 新しい shell を開き、starship の prompt が出ること、補完/履歴(fzf)・zoxide が効くこと、`~/.zshrc.local` に退避した PATH 等が効くこと、`zsh -c 'command -v node'` が mise shim を返すことを確認する。

## rollback

```sh
cp ~/.zshrc.pre-chezmoi ~/.zshrc
cp ~/.zprofile.pre-chezmoi ~/.zprofile
# ~/.zshenv / ~/.config/starship.toml を backup していれば復元、無ければ削除(apply 前は不在だったため)
```

managed 化自体を戻す場合は `chezmoi forget ~/.zshenv ~/.zshrc ~/.zprofile ~/.config/starship.toml` の後に backup を復元する。

## 対象外

- プラグインマネージャ / oh-my-zsh(explicit-first 方針で不使用)。ツールの install は catalog + `install-packages.sh` の領分。
- machine 固有値・secret の repo への持ち込み。
- この module 単体での実 home への apply。
