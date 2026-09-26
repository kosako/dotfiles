## 変更内容

-

## 関連 Issue

Closes #

## 検証結果

- [ ] `docs/github-workflow.md` の「最低限の validation」(`.github/workflows/validate.yml` が PR ごとに自動実行。手元での事前実行も推奨)

task 固有の検証があればここに足す。

## 副作用

- install: なし / 予定 / 不明
- secret access: なし / 予定 / 不明
- network 変更: なし / 予定 / 不明
- `chezmoi apply`: 不要 / 予定 / 不明

## 残リスク

-

## 補足

secret・token・private endpoint・内部 URL・組織 / クライアント固有の機密情報は書かない。次にやることは PR には書かず、Notion worklog の `Next` か follow-up Issue に残す。
