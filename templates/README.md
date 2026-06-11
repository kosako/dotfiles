# templates

新規 repository 用の初期 file 置き場。

この directory は chezmoi の apply 対象ではない(`.chezmoiignore` で除外)。script による自動展開もしない。必要な file を手でコピーして使う。

## 使い方

```sh
# 共通(まず generic を入れる)
cp ~/dotfiles/templates/project/generic/.editorconfig <repo>/
cp ~/dotfiles/templates/project/generic/.gitignore <repo>/

# Node project なら重ねる
cp ~/dotfiles/templates/project/node/.npmrc <repo>/
cat ~/dotfiles/templates/project/node/.gitignore >> <repo>/.gitignore
# package.json は templates/project/node/package.json を参考に作る

# Python project なら重ねる
cat ~/dotfiles/templates/project/python/.gitignore >> <repo>/.gitignore
cp ~/dotfiles/templates/project/python/.mise.toml <repo>/
```

## 方針

- template には secret、token、registry URL、会社・クライアント固有値を入れない。
- node の `.npmrc` / `packageManager` は `docs/supply-chain-npm.md` / `docs/supply-chain-corepack.md` の方針に従う。
- runtime の version pin は project 側の `.mise.toml` の責務(exact pin)。
- devcontainer template は現時点では追加しない。コンテナ前提の開発を始める時点で別 Issue として判断する。
