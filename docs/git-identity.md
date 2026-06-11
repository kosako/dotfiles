# Git Identity

Git identity の分離方針。実 identity 値(`user.name` / `user.email`)はこの repository に入れない。

## 方針

- `~/.gitconfig` は chezmoi が `dot_gitconfig.tmpl` から生成する。identity 値は含まない。
- `user.useConfigOnly = true` により、identity が解決されない directory では commit が失敗する。
- `transfer.credentialsInUrl = die` により、credential 入り remote URL を拒否する。
- identity 値は context ごとの local file に置き、`includeIf` で directory convention に紐づける。

## Identity context と local file

| context | project root | identity file |
| --- | --- | --- |
| personal | `~/src/personal/` | `~/.config/git/personal.gitconfig` |
| work | `~/src/work/` | `~/.config/git/work.gitconfig` |
| client | `~/src/client/` | `~/.config/git/client.gitconfig` |
| sandbox | `~/src/sandbox/` | `~/.config/git/sandbox.gitconfig` |
| agent | `~/src/agent/` | `~/.config/git/agent.gitconfig` |

identity file の中身は最小限にする。

```ini
[user]
	name = Example Name
	email = example@example.invalid
```

## 管理方式の決定(2026-06-11、Issue #19)

identity file は当面、完全手動・local only とする。

- chezmoi の prompt による半管理(`promptStringOnce` で値を聞いて local state に保存)は採用しない。
- 1Password など secret store からの参照も採用しない。identity は secret というより設定値で、`allowSecretsAccess=false` の profile で使えなくなるため。
- 新 host のセットアップで手動作成が実際に苦になった時点で、personal context に限った prompt 半管理を別 Issue として再検討する。
- 作り忘れは該当 context での commit 失敗(fail-closed)と `doctor.sh` の warning で検知できる。

## Local identity file の扱い

- identity file は手元で作成し、この repository には commit しない。
- chezmoi の管理対象にもしない。secret store からの自動 fetch もしない。
- 会社・クライアント固有の値(実名、メールアドレス、組織名、内部 URL)は identity file 側にのみ存在する。
- 使わない context の identity file は作らなくてよい。その context では commit が失敗するだけで、安全側に倒れる。
- client 配下で client ごとに identity を変える場合は、`client.gitconfig` の中でさらに `includeIf` を重ねる。重ねた先も local file に限る。

## Unknown directory での挙動

known project root(`~/src/{personal,work,client,sandbox,agent}/`)の外では、どの identity file も include されない。
`useConfigOnly = true` のため、Git は identity を自動推測せず、commit は以下のように失敗する。

```text
fatal: no email was given and auto-detection is disabled
```

これは意図した挙動。誤った identity で commit するより、commit できない方を選ぶ。

## 検査

- `scripts/doctor.sh` は report-only で以下を確認する。
  - `user.useConfigOnly=true` / `transfer.credentialsInUrl=die`
  - 各 context の identity file が存在するか、意図的に未設定か。
- `scripts/preflight.sh` は apply 前に既存の home Git config(`~/.gitconfig`、`~/.config/git/config`)と
  global identity の設定有無を検知する。値そのものは表示しない。
- `scripts/test-gitconfig.sh` は `dot_gitconfig.tmpl` の安全設定と includeIf の挙動を local fixture で検証する。

## 対象外

- Git signing(後続 `git-signing` module)。
- secret store(1Password など)からの identity / signing material の取得。
- Git remote mutation。
