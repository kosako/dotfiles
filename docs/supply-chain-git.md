# Supply Chain: Git

`supply-chain/git` module の方針。Git 経由の credential 漏洩を防ぐ。

## 二段構え

1. 予防: `transfer.credentialsInUrl = die`(`dot_gitconfig`)
   - password 部を含む URL での fetch / push / clone を Git 自体が拒否する。
2. 検出: `doctor.sh` の remote URL scan(report-only)
   - すでに設定済みの remote URL に credential らしき userinfo(`scheme://user:password@host`)が残っていないかを検査する。
   - `transfer.credentialsInUrl` は転送時にしか効かないため、設定済み remote の棚卸しは doctor が担当する。

## doctor の remote URL scan

- 検査対象: dotfiles repo 自身と、known project roots(`~/src/{personal,work,client,sandbox,agent}`)配下の Git repository。
- 検出時は repo path と remote 名だけを表示する。URL や credential の値は表示しない。
- report-only。remote の変更・削除はしない。warning だけでは exit code を変えない。
- username のみの userinfo(`https://user@host`)は警告しない。Git の `credentialsInUrl` と同様に、password 部があるものだけを対象にする。
- 検出ロジックは `scripts/lib-policy.sh` の `git_remotes_with_credentials` に置き、`scripts/test-gitconfig.sh` の fixture で検証する。

## 検出された場合の対処

remote URL から credential を取り除き、credential helper(macOS keychain、`gh auth` など)に移す。

```sh
git -C <repo> remote set-url <remote> <credential を含まない URL>
```

この操作は手動で行う。script からは実行しない。

## 対象外

- Git remote の自動変更・修復。
- credential の削除や書き換え。
- 会社・クライアント固有 host の列挙や allow / deny list。
- secret store へのアクセス。
