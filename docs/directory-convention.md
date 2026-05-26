# Directory Convention

開発 project の配置は以下に統一する。

```text
~/src/personal/<repo>
~/src/work/<org>/<repo>
~/src/client/<client>/<repo>
~/src/sandbox/<repo>
~/src/agent/<repo>
```

この階層を Git identity、secret access、install policy、AI agent policy の判定基準にする。

## Git Identity

Git config では `user.useConfigOnly = true` を使い、known directory 外では不用意に `user.name` / `user.email` が解決されない状態を目指す。

例:

```ini
[user]
  useConfigOnly = true

[includeIf "gitdir:~/src/personal/"]
  path = ~/.config/git/personal.gitconfig

[includeIf "gitdir:~/src/work/"]
  path = ~/.config/git/work.gitconfig

[includeIf "gitdir:~/src/client/"]
  path = ~/.config/git/client.gitconfig

[includeIf "gitdir:~/src/sandbox/"]
  path = ~/.config/git/sandbox.gitconfig
```

## Rules

- 個人 project と会社 project を同じ階層に置かない。
- client project は client ごとの下位階層に分ける。
- agent project は `~/src/agent` に分離する。
- unknown directory では doctor が警告する。
