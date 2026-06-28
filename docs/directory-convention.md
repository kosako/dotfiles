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

## 許容された非標準配置

標準は上記の `~/src/<context>/` だが、project を `~/src` の外(例: 単一の作業 directory に
まとめる運用)に置くことも許容する。その場合は以下を理解した上で運用する。

- **Git identity**: `includeIf "gitdir:~/src/<context>/"` は当たらないため identity が
  自動解決されず、`user.useConfigOnly = true` により commit は fail-closed で失敗する。
  意図的に非標準配置で運用するなら、repo ごとに `git config user.name` / `user.email` を
  設定して解除する(personal は remote URL による二次判定(Issue #52)が当たれば設定不要)。
  この場合、identity の安全装置は「置き場所」ではなく repo-local 設定が担う。
- **agent-tools の監視**: doctor が探す checkout path は `AGENT_TOOLS` env で実体を指す
  (override 機構は Issue #71、root pin は Issue #73)。具体 path は tracked file に焼かず、
  非追跡の `~/.zshrc.local` に置く。
- **doctor / preflight の検査範囲**: standard root の presence check と remote URL の
  credential scan は `~/src` を前提とする(ただし credential scan は dotfiles repo 自身を
  常に対象に含む)。dotfiles 以外の非標準配置 repo はこれらの自動検査の対象外になる
  (どちらも report-only なので実害はないが、網羅性は下がる)。

doctor / preflight は標準 root の不在を中立に報告し(警告ではない)、非標準配置を妨げない。
ただし標準の `~/src/<context>/` 構造の方が identity 判定・secret access・policy の自動適用を
受けられるので、特段の理由がなければ標準配置を推奨する。

## Rules

- 個人 project と会社 project を同じ階層に置かない。
- client project は client ごとの下位階層に分ける。
- agent project は `~/src/agent` に分離する。
- `~/src` の外(unknown directory)では Git identity が解決されず commit が fail-closed に
  なる(意図した安全側の挙動)。標準 root の不在自体は doctor が中立に報告する(警告ではない)。
  非標準配置で運用する場合の解除方法は上の「許容された非標準配置」を参照。
