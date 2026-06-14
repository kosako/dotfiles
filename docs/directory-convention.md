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

[includeIf "gitdir:~/src/agent/"]
  path = ~/.config/git/agent.gitconfig
```

実体は `dot_gitconfig` が管理する。identity file の置き場所と扱いは `docs/git-identity.md` に従う。

## Home config directory

`~/.config` は chezmoi の管理対象で、permission を 0700 にする(`private_dot_config` による)。個人の設定 directory を他ユーザーから保護する意図で、全 profile に適用される(中身がすべて ignore でも directory 自体は管理される)。

既存 host で `~/.config` が 0755 の場合、初回 apply で 0700 に変わる。これは仕様。`chezmoi diff` に mode 変更として表示され、`preflight` も apply 前にこの差分を warning で知らせる。0700 を望まない場合は、その host で apply しないか、profile 構成を見直す。

## Rules

- 個人 project と会社 project を同じ階層に置かない。
- client project は client ごとの下位階層に分ける。
- agent project は `~/src/agent` に分離する。
- unknown directory では doctor が警告する。
