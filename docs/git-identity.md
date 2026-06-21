# Git Identity

Git identity の分離方針。実 identity 値(`user.name` / `user.email`)はこの repository に入れない。

## 方針

- `~/.gitconfig` は chezmoi が `dot_gitconfig` から生成する。identity 値は含まない。
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

## Remote URL による二次判定(hasconfig、Issue #52)

identity の判定は「置き場所(gitdir)」が一次。加えて、**personal だけ** remote URL でも判定する
二次ルール(`includeIf "hasconfig:remote.*.url:..."`、Git 2.36+)を持つ。`~/src/personal/` の
外に clone した personal リポでも、remote が `github.com/kosako/**` なら personal identity が
当たる保険(fail-closed と相性が良い「置き場所」と「remote」の二重判定)。

- **gitdir が authoritative**: hasconfig ルールは gitdir ルールより **前**に置く。includeIf は
  後勝ちなので、置き場所(gitdir)が当たればそちらが優先される(例: `~/src/work/` に置いた
  `github.com/kosako` remote のリポは work identity)。hasconfig は gitdir が当たらないときだけ効く。
- **personal に限る(public 制約)**: `dot_gitconfig` は public repo に入るため、会社・クライアントの
  org 名 / URL は書けない。公開可能な personal(`github.com/kosako`)だけを二次判定し、work / client は
  gitdir のみ + org 名は local identity file 側に留める。
- **URL 表記を網羅**: HTTPS(`https://github.com/kosako/**`)、scp 形 SSH(`git@github.com:kosako/**`)、
  `ssh://` 形(`ssh://git@github.com/kosako/**`)はそれぞれ別文字列として literal にマッチするため、
  3 つとも宣言する(1 つでも欠けるとその clone 形では取りこぼす)。
- work / client を `~/src/` の外に clone した場合は二次判定が無いので commit は fail-closed(安全側)。

## 管理方式の決定(2026-06-11、Issue #19)

identity file は当面、完全手動・local only とする。

- chezmoi の prompt による半管理(`promptStringOnce` で値を聞いて local state に保存)は採用しない。
- 1Password など secret store からの参照も採用しない。identity は secret というより設定値で、`allowSecretsAccess=false` の profile で使えなくなるため。secret 全般の供給規約は [secrets](secrets.md) にあるが、identity はその対象外(secret = op 供給可 / identity = 手動 local の二層)。
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
- `scripts/test-gitconfig.sh` は `dot_gitconfig` の安全設定と includeIf の挙動を local fixture で検証する。

## SSH 署名(git-signing module、Issue #85 / 既定 off は Issue #97)

commit / tag は 1Password の op-ssh-sign で **SSH 署名**できるが、**署名は既定 OFF(人も AI も
区別なし)**。一人プロジェクトの無人 commit が署名プロンプトで止まらないためで、署名は「必須」では
なく「必要な repo だけ opt-in」する。署名インフラ(鍵・mechanism)は残すので opt-in は一発。

- **既定 off は managed**: `dot_gitconfig`(global)が `[commit] gpgsign=false` / `[tag] gpgsign=false`
  を **includeIf 群より前** に持つ。includeIf は last-match-wins なので、後続の context include や
  repo-local の `git config commit.gpgsign true` が上書きして opt-in できる。`false` の既定は無鍵
  context でも安全(global に `true` を置くと署名鍵の無い context で commit が失敗するので置かない)。
- **仕組み(mechanism)は managed**: `~/.config/git/signing.gitconfig`(`gpg.format=ssh` + signer
  プログラム `/Applications/1Password.app/Contents/MacOS/op-ssh-sign`)を、`git-signing` module かつ
  `enableGitSigning=true` のときだけ配備する。`dot_gitconfig` は常時 `[include]` し、ファイル不在時
  は git が無視(no-op)。signer パスは public-safe(`/Applications` 配下・ユーザー名なし)。
- **鍵は context 別 local、gpgsign の opt-in も local か per-repo**: `user.signingkey`(どの鍵)は
  `~/.config/git/<context>.gitconfig` に置く。**managed 側には鍵を置かず、gpgsign は false の既定
  だけ置く**(`true` の opt-in は repo-local の `git config commit.gpgsign true`、または常時署名したい
  context の local file)。
- **トレードオフ**: 既定 off なので直接 commit に GitHub "Verified" は付かない。PR を web / squash
  merge した履歴は GitHub の web-flow 鍵で Verified のまま。
- 署名鍵の**実体は 1Password**(SSH key)で、`user.signingkey` はその公開鍵参照。
- GitHub では鍵を **Signing Key として登録**する(Authentication Key とは別枠)。committer email が
  そのアカウントの verified email であること。
- 復元との関係: identity + 署名紐付けを持つ `personal.gitconfig` は backup catalog に含めるので
  (#85)、新マシンでは復元される([private-backup](private-backup.md))。

## 対象外

- secret store(1Password など)からの identity 値の自動取得(署名鍵は 1Password agent 経由で
  使うが、dotfiles は identity / 鍵素材を fetch しない)。
- Git remote mutation。
