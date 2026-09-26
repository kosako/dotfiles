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

## プロンプト表示(starship、Issue #96)

どの identity で commit するかを取り違えないよう、starship プロンプトが現在の context を常時表示する
([docs/shell.md](shell.md))。**personal=緑 / その他の解決済み identity=黄(email 表示)/ repo 内で
identity 未解決(`useConfigOnly` の fail-closed)=赤**。分類は runtime に「解決された committer email」と
**local の `~/.config/git/personal.gitconfig`** を照合して行い、managed な `starship.toml` には identity 値を
一切持たない(public-safe。`scripts/test-starship.sh` が回帰固定)。

## Remote URL による二次判定(hasconfig、Issue #52)

identity の判定は「置き場所(gitdir)」が一次。加えて、**personal だけ** remote URL でも判定する
二次ルール(`includeIf "hasconfig:remote.*.url:..."`、Git 2.36+)を持つ。`~/src/personal/` の
外に clone した personal リポでも、remote が `github.com/kosako/**` なら personal identity が
当たる保険(fail-closed と相性が良い「置き場所」と「remote」の二重判定)。

- **gitdir が authoritative**: hasconfig ルールは gitdir ルールより **前**に置く。includeIf は
  後勝ちなので、置き場所(gitdir)が当たればそちらが優先される(例: `~/src/work/` に置いた
  `github.com/kosako` remote のリポは work identity)。hasconfig は gitdir が当たらないときだけ効く。
  ただし「後勝ち」は context file が**値を持っているとき**しか効かない — context file が無い /
  空だと hasconfig が入れた personal identity がそのまま残る。これを塞ぐのが次節の identity
  reset(#202)。
- **personal に限る(public 制約)**: `dot_gitconfig` は public repo に入るため、会社・クライアントの
  org 名 / URL は書けない。公開可能な personal(`github.com/kosako`)だけを二次判定し、work / client は
  gitdir のみ + org 名は local identity file 側に留める。
- **URL 表記を網羅**: HTTPS(`https://github.com/kosako/**`)、scp 形 SSH(`git@github.com:kosako/**`)、
  `ssh://` 形(`ssh://git@github.com/kosako/**`)はそれぞれ別文字列として literal にマッチするため、
  3 つとも宣言する(1 つでも欠けるとその clone 形では取りこぼす)。
- work / client を `~/src/` の外に clone した場合は二次判定が無いので commit は fail-closed(安全側)。

## 非 personal context の identity reset(Issue #202)

`~/src/work/` 等の非 personal context に置いた repo でも、remote が `github.com/kosako/**` に
一致し、その context の identity file が**無い / 空**だと、上の二次判定が入れた personal
identity がそのまま commit に使われていた(後勝ちで上書きする値が無いため)。name だけの
部分設定では context の name + personal email が混在した。directory による分離と
「未設定なら commit 拒否」の契約違反。

対策として、managed な **identity reset file**(`~/.config/git-profile/identity-reset.gitconfig`、
`git-profile` module。`[user] name =` / `email =` の空値だけで identity 値は持たない)を、非 personal
4 context それぞれの gitdir include の**直前**に include する:

```ini
[includeIf "gitdir:~/src/work/"]
	path = ~/.config/git-profile/identity-reset.gitconfig
[includeIf "gitdir:~/src/work/"]
	path = ~/.config/git/work.gitconfig
```

reset が先に identity を空にするので、それまでに何が当たっていても(personal fallback を含む)
context file の値だけが残る。include 順は契約なので `scripts/test-gitconfig.sh` が exact pin する。

**reset file は `.gitconfig` と必ず一緒に配備する(#241)。** Git は欠損 include を黙って無視するため、
`.gitconfig` だけを apply した home(README Quickstart の初回 apply がかつてそうだった)では、この節の
契約は成立せず #202 以前の挙動(personal fallback の流入)に戻る。

- **初回 apply**: README の Quickstart は `mkdir -p ~/.config` の後に
  `~/.gitconfig ~/.config/git-profile ~/.config/git-profile/identity-reset.gitconfig` を 1 回で apply する。
  親 directory の target を省くと chezmoi が stat error になる。`~/.config` は target 外の祖先なので chezmoi が
  作らず、target にすると subtree ごと apply されて最小にならない。`scripts/test-render.sh` がその command 行と
  「その 3 target だけの apply で `.gitconfig` と reset の 2 file だけが配備されること」を pin する。
- **doctor**: reset の presence を検査し(値は持たない file なので中身は見ない)、欠損なら mkdir + apply を
  next action に出す。
- **reset 欠損時の非 personal context の案内**: 流入は**条件付き**で、remote が personal の hasconfig pattern に
  一致し、personal identity が設定されている repo に限る(それ以外は `useConfigOnly` で従来どおり拒否)。
  - identity file が無い: 「commit 拒否」ではなく「personal identity を継承しうる」。
  - partial: 「**未指定**の key は personal identity を継承する(混在 identity)。明示的な空値(`name =`)は
    上書きするので空のまま」。継承と commit 可否は別で、name が明示的に空なら email を継承しても commit は
    拒否される(Git は空 name を拒否)。
- **key の 3 状態**(doctor の判別):
  - 未指定: `git config --get` が exit 1。
  - 空値: exit 0 で空出力。
  - `=` 無しの key(`email` だけの行、boolean 省略記法): `--get` は空値と同じに見えるが、Git の identity
    読み込みは `fatal: missing value for 'user.email'` で拒否する(git 2.50.1 実測)。doctor は
    `--list` に `=` 無しで現れることで判別し、reset の有無に関わらず「値なし key・commit 不能」として別に報告する。

`~/.config/git/` 配下に置かなかったのは、#207 以前の denylist 時代に `git-signing` module が
`~/.config/git` を directory ごと宣言しており、signing off の profile では subtree ごと管理外になった
ため(git-hook-gates と同じ判断)。現行の allowlist では祖先 directory は活性 module の宣言 path から
union されるので、この制約はもう無い([git-hook-gates](git-hook-gates.md) の「置き場所が `~/.config/git/`
配下でない理由(経緯と現行の契約)」節)。配置は経緯どおり維持する。

context file の状態ごとの config 層の結果(git hook gates を通さない素の `git commit`。`scripts/test-gitconfig.sh`
の matrix が固定):

| context file | 結果 |
| --- | --- |
| 無い / 空 / email だけ | commit 拒否(`fatal: empty ident name (for <>) not allowed`) — fail-closed |
| name だけ | config 層では context の name + **空 email** で commit が通る(Git は空 name は拒否するが空 email は受理する)。personal ではないが壊れた identity。gate が武装したマシンでは pre-commit の `personal-git-identity-gate` が止める(下記)。prompt は赤(no-identity)、`doctor` が partial として action、gate の無い環境では `git log` で `<>` が見える |
| 完全 | その context の identity |

- **部分設定は config 層では塞げない**。可視化(prompt / doctor / log)で検知し、commit 時は git hook gates の
  pre-commit gate `personal-git-identity-gate`(agent-tools#281 / #239)が空 email 等の partial identity を
  止める([git-hook-gates](git-hook-gates.md))。ただしこれは配線が武装した環境(`enableGitHookGates` が true の
  personal profile で、agent-tools の gate が配備済み)の通常経路だけで効く best-effort guardrail で、
  `--no-verify` や repo local の `core.hooksPath` で迂回できる。work profile や未武装のマシンでは可視化が
  残る検知手段になる。
- **`~/src/` の外**には reset は当たらない(gitdir 条件)。personal remote なら二次判定で personal、
  それ以外は従来どおり fail-closed。
- **linked worktree / submodule は主 repo の `.git` の場所で判定される**(includeIf の gitdir は
  `.git` file の先の実体 directory を見る)。personal repo の worktree を `~/src/work/` に置いても
  personal のまま(reset も当たらない)。置き場所による分離が効かない既知の制約で、test が
  特性として固定している。

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

known project root(`~/src/{personal,work,client,sandbox,agent}/`)の外では gitdir の includeIf が当たらず、
remote が `github.com/kosako/**` の repo(上記の二次判定で personal が当たる)以外では、どの identity file も include されない。
`useConfigOnly = true` のため、Git は identity を自動推測せず、commit は以下のように失敗する。

```text
fatal: no email was given and auto-detection is disabled
```

これは意図した挙動。誤った identity で commit するより、commit できない方を選ぶ。

意図的に `~/src` の外で運用する project では、repo ごとに `git config user.name` /
`user.email` を設定して fail-closed を解除する(承知の上で「置き場所」による自動分離を
使わない選択。personal は remote URL による二次判定(Issue #52)が当たれば設定不要)。
非標準配置の扱いは [directory-convention](directory-convention.md) を参照。

## 検査

- `scripts/doctor.sh` は report-only で以下を確認する。
  - `user.useConfigOnly=true` / `transfer.credentialsInUrl=die`
  - identity reset file(`~/.config/git-profile/identity-reset.gitconfig`)の presence(#241。欠損なら
    mkdir + apply を action に出す)
  - 各 context の identity file が存在するか、意図的に未設定か。存在する file は `user.name` /
    `user.email` の**有無だけ**(値は出さない)を見て、どちらか(または両方)が欠ける partial と、
    `=` 無しの値なし key を action として出す(#202 / #241。git が parse できない file はその旨を warn)。
- `scripts/preflight.sh` は apply 前に既存の home Git config(`~/.gitconfig`、`~/.config/git/config`)と
  global identity の設定有無を検知する。値そのものは表示しない。同じ `~/.config/git/` 配下の
  global gitignore(`git-ignore` module、#248)の置換 warn もここに出る([git-ignore](git-ignore.md))。
- `scripts/test-gitconfig.sh` は `dot_gitconfig` の安全設定と includeIf の挙動を local fixture で検証する
  (include 順の exact pin、非 personal context × identity file 状態 × personal remote 表記 / multi-remote
  の matrix を実 commit の author / committer で検証、linked worktree の特性)。

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
