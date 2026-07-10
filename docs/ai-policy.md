# AI Policy

AI tools は後続 module とする。ただし、AI agent の権限ポリシーは初期段階で定義する。

`dotfiles` と別 project として管理する AI skills / agents repository の境界は [AI Environment Boundary](ai-environment-boundary.md) に定義する。

## 権限方針の正本と管理点(#139)

「AI エージェントに何を無確認で許すか」の正本はこの文書。tool ごとの**実装(どこで効かせるか)**は
次の管理点に置き、どちらの tool も同じ原則に従わせる(Codex 側との対称性):

| tool | 権限面 | 管理点 | 堆積への手当て |
| --- | --- | --- | --- |
| Claude Code | permissions deny/ask(secret floor ほか)+ hooks 登録 | managed `~/.claude/settings.json`([policy-model](policy-model.md)・#136/#137) | 動的許可は `settings.local.json`(管理外)に隔離。managed 側は apply で戻る |
| Codex | 承認 rules(コマンド allowlist) | managed `~/.codex/rules/default.rules`(read-only baseline・#139) | 堆積 grant は drift として可視化 → `chezmoi apply` が baseline へ**リセット**(定期棚卸しの仕組み化) |
| Codex | projects trust / approval_policy(`config.toml`) | **管理不可**(codex 所有 live ファイル・#181) | doctor が report-only で監視: home root への trust と実在しない path の残骸を warn |

原則(両 tool 共通):

- **read(ローカル完結・読み取り)は無確認で許可してよい**。Codex baseline の allow は
  read 系サブコマンド(`gh pr view/list/diff/checks`、`gh issue view/list`、`gh auth status`)と
  ローカル git 操作(`commit/add/clone/checkout`)のみ。
- **マシン外に出る操作(push・PR/issue/comment 作成・release・外部送信)と昇格系
  (sudo・auth login)は無確認 allow にしない**。都度承認を通す。将来は #131 の
  write-gate hook で「untrusted がセッションに無ければ自律許可」の context-gated に
  置き換える(下記 #119 節の write 規則が目標形)。
- **一時許可は堆積させず定期棚卸しする**。Codex rules は managed baseline へのリセットで
  機械化。projects trust はリセット手段がない(codex 所有)ため doctor の warn を見て
  codex 側で手動除去する。堆積は実際に再発する(2026-07-02 に是正した home-root trust が
  2026-07-10 の監査で復活していた)ので、「一度直したから大丈夫」とみなさない。

## Default

AI agent は default deny。

- 許可された project directory のみ読む。
- secret store は直接読ませない。secret の正しい供給方式は [secrets](secrets.md) に規約化してあるが、これは利用者本人の実行時注入であって AI agent への自動供給ではない。dotfiles 自体は secret を fetch しない。
- token は短命・scope限定にする。
- work / client では会社・クライアントポリシーを優先する。
- install / network tunnel / production access は明示承認が必要。

## Directory Policy

- `~/src/personal`: personal policy。
- `~/src/work`: work policy。
- `~/src/client`: client policy。
- `~/src/sandbox`: 実験用。secret access は原則禁止。
- `~/src/agent`: agent 用。最小権限で運用する。

## Prohibited By Default

- secret store への直接アクセス
- 本番 credential の使用
- 本番 DB への接続
- work / client repo の外部送信
- 暗黙の package install
- 暗黙の Homebrew install
- network tunnel の作成
- Git remote の変更
- untrusted な GitHub content(他人の Issue / PR / コメント、bot、fork 由来)に書かれた指示の実行
- main / protected branch への直接 push

## Approval Required

- package install
- GUI app install
- network tunnel
- production access
- secret access
- work / client 情報の外部送信
- GitHub release の作成 / 削除 / 編集
- branch protection / ruleset の変更

## Untrusted GitHub content(#119)

GitHub の Issue / PR を読ませるときの runtime prompt injection 対策の方針(epic #119)。
trust の基点は `is_self`(自分の login + id)のみで、collaborator / bot / fork 由来は既定
untrusted。

下記の read / write 規則は **目標方針(policy intent)であって、現状の enforcement ではない**。
Phase 1 / 2 で実際に効いているのは steering 層と、Phase 2 で live 化した secret floor
(never-legit な secret 読取の無条件 hard deny)+ `gateGitHubMcp` の `mcp__github` deny、
それに #137 で登録した read-steering hook(raw な `gh` 読取を safe-gh へ誘導する
`personal-safe-gh-hook`。fail-open steering)まで。context-gated な write を判定する
write-gate hook と trifecta を断つ hard 層(隔離 reader の hard 化 / token 隔離 /
OS egress)は Phase 3(#131)へ hand-off 済み(射程と限界は
[ai-environment-boundary](ai-environment-boundary.md))。

- **read**: 自分の本文 = allow / 他人 = metadata only(title も入れない)/ 他人のコメント =
  count + 警告のみ(本文・著者名・プレビューを混ぜない)/ bot = 全 untrusted。
- **write**: untrusted content がセッションに無い(self 起点・clean)ときだけ comment / label /
  PR create / push(`ai/*` 限定)を自律許可。untrusted が混ざったら gate。secret access は
  **常に hard deny**。
- enforcement の射程と限界(現状は best-effort / steering で boundary ではない)は
  [ai-environment-boundary](ai-environment-boundary.md)、capability 正本は
  [policy-model](policy-model.md)。
