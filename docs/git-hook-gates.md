# Git Hook Gates(commit 境界 gate の配線)

commit 境界の機械的規律(public-safety scan / AI trailer 検証)を git hook として
決定的に実行するための **dotfiles 側の配線**。gate / dispatcher の**実体**は
agent-tools が build / sync で配備し(実体 = agent-tools・配線 = dotfiles、
[config-ownership](config-ownership.md))、**契約の正本は agent-tools の
`docs/git-hook-gates.md`**。この doc は配線側(何をどこに配り、どう外すか、
どこまで守れるか)だけを扱う。Issue #196(実体側は agent-tools#202)。

## 構成

`enableGitHookGates`(capability、`git-hook-gates` module)が次を管理する:

```text
~/.gitconfig                              … 無条件 [include](missing なら git が無視)
  └─ ~/.config/git-hook-gates/hooks.gitconfig   … core.hooksPath を設定(managed)
       └─ ~/.config/git-hook-gates/hooks/
            pre-commit    … 薄い shim: dispatcher へ exec(managed)
            commit-msg    … 薄い shim: dispatcher へ exec(managed)
                 └─ $HOME/.claude/agent-tools/scripts/personal-git-hook-dispatcher
                    … gate 実行 + repo 自身の .git/hooks への chain(agent-tools 配備)
```

- shim はロジックを持たない(gate 本体の更新は agent-tools の sync が担い、
  dotfiles の再 apply は不要)。
- dispatcher は agent-tools が**両方の tool home に同一 byte** で配備する
  (agent-tools#202)。shim がどちらを指すかは dotfiles の裁定で、**`~/.claude` 側を
  正とする**(Claude 側 hooks 登録が既に同じ home を参照している並びに合わせた。
  `$HOME` は shim 実行時に sh が展開するため、render に実 home path は焼かれない)。
- `core.hooksPath` は per-repo `.git/hooks` を完全置換するが、dispatcher が
  gate 通過後に repo 自身の `.git/hooks/<stage>` へ chain するので、既存 repo hook は
  動き続ける(契約の詳細は agent-tools 側 doc)。

## gating(fail-closed 配布条件)

dispatcher は自分と同じ directory の gate が欠けていると **fail-closed(exit 2)で
commit を止める**。つまり agent-tools 未配備のマシンに配線だけ配ると、全 repo の
`git commit` が止まる。このため:

- capability は **agent-tools が配備されている profile(personal)だけ true**。
  work は false(会社マシンに agent-tools deploy はない)。
- `preflight` は apply **前**に dispatcher 不在を warn する(apply impact)。
  `doctor` は apply **後**の配線 chain(shim / hooksPath / dispatcher)を
  report-only で監視し、「配線済みなのに dispatcher 不在 = commit が止まっている」を
  最も強い警告にする。
- gate は module の `requires` ではなく **template 自己 gate**(false は空 render →
  chezmoi が既存 target も削除)。`requires` だと chezmoiignore が既存 file を prune
  せず、fail-closed な shim が残置される(#184 の教訓)。off にした後に
  `hooks.gitconfig` も消えるので、`core.hooksPath` の配線ごと外れる。

## 置き場所が `~/.config/git/` 配下でない理由

`~/.config/git` は git-signing module の宣言 path で、`enableGitSigning=false` の
profile では chezmoiignore が **directory subtree ごと**管理から外す(実測)。gate を
その下に置くと、signing を off にしただけで commit gate が黙って消える(安全機構の
silent fail-open)。独立した `~/.config/git-hook-gates/` に置くことで交差を断つ。
この配置が担保であることは `test-git-hook-gates.sh` が pin している。

## 強度ラベル(偽らない)

これは**通常経路(`git commit`)に対する best-effort guardrail** であって、
enforcement boundary ではない:

- `git commit --no-verify` は pre-commit / commit-msg をどちらも skip する。
- repo local の `core.hooksPath`(husky 等)は global 設定を上書きし、gate は
  黙って外れる。
- 別 client / 他マシンからの commit・GitHub 上の操作(squash merge 等)は対象外。
  トレーラ喪失への対処は消費側 preflight(agent-tools の routing-preflight)の領分。

hard な床(credential 隔離 / egress / CI required checks / server-side protection)の
代替にしない([ai-environment-boundary](ai-environment-boundary.md) と同じ前提)。

## 導入・無効化

- 導入: `enableGitHookGates=true` の profile で `chezmoi apply`(事前に
  `preflight`、事後に `doctor` で chain を確認)。agent-tools 側の配備は
  agent-tools の sync が行う。
- 無効化: capability を false にして `chezmoi apply`(shim と hooks.gitconfig が
  削除され、include が no-op に戻る)。緊急時(dispatcher 欠損で commit が止まった
  等)は agent-tools の sync で実体を復旧するか、上記の無効化 apply で外す。

検証は `scripts/test-git-hook-gates.sh`(render 内容の exact pin + rendered
`~/.gitconfig` で実 commit を通す end-to-end + cap-off の真の削除 + git-signing との
独立性)。実機 smoke の記録は #196。
