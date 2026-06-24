# AI Policy

AI tools は後続 module とする。ただし、AI agent の権限ポリシーは初期段階で定義する。

`dotfiles` と別 project として管理する AI skills / agents repository の境界は [AI Environment Boundary](ai-environment-boundary.md) に定義する。

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

- **read**: 自分の本文 = allow / 他人 = metadata only(title も入れない)/ 他人のコメント =
  count + 警告のみ(本文・著者名・プレビューを混ぜない)/ bot = 全 untrusted。
- **write**: untrusted content がセッションに無い(self 起点・clean)ときだけ comment / label /
  PR create / push(`ai/*` 限定)を自律許可。untrusted が混ざったら gate。secret access は
  **常に hard deny**。
- enforcement の射程と限界(現状は best-effort / steering で boundary ではない)は
  [ai-environment-boundary](ai-environment-boundary.md)、capability 正本は
  [policy-model](policy-model.md)。
