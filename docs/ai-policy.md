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

## Approval Required

- package install
- GUI app install
- network tunnel
- production access
- secret access
- work / client 情報の外部送信
