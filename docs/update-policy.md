# Update Policy

広範な自動 upgrade は避ける。

## Rules

- `brew upgrade` は自動実行しない。
- `mise upgrade` は自動実行しない。
- shell plugin update は自動実行しない。
- `doctor` は状態を報告するだけにする。
- 更新は明示コマンドとして実行する。

## Rationale

勝手に全体を最新版へ上げることは、再現性とサプライチェーン安全性の両方を弱める。

この repository では、install と update を分ける。

- install: 足りないものを入れる。
- update: 既存のものを新しい version に上げる。

update は自動 apply の対象にしない。
