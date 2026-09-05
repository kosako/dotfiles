# GitHub Workflow

この repository では、Phase 2 以降の作業を GitHub Issues / Pull Requests で管理する。

## 目的

- 実装単位、判断、検証結果を GitHub に残す。
- Notion の設計背景と GitHub の実装証跡を分ける。
- `main` に入る変更を PR で確認できる状態にする。
- policy、capability、secret、install、AI agent 境界に関わる変更の理由を後から追えるようにする。

## 役割分担

```text
Notion
  roadmap / design background / worklog / handoff notes

GitHub Issues
  implementation task / scope / done criteria / validation plan

GitHub Pull Requests
  code or docs change / validation result / residual risk / merge record

main
  merged PR only
```

## 標準フロー

1. Issue を作る。
2. Issue の scope、done criteria、validation を書く。
3. Issue 番号を含む branch を作る。
4. 変更する。
5. validation を実行する。
6. PR を作る。
7. PR に validation result と residual risk を書く。
8. PR を merge する。
9. 必要なら Notion worklog / handoff notes を更新する。

推奨 branch 名:

```text
phase2/git-profile
chore/issue-pr-workflow
docs/ai-boundary
fix/policy-validation
```

Issue 番号を明示したい場合:

```text
issue-12/git-profile
```

## Issue が必要な変更

- script 変更。
- profile / module / capability 変更。
- policy document 変更。
- chezmoi template 追加。
- package install / GUI app install / macOS defaults に関係する変更。
- secret access / network tunnel / AI tools に関係する変更。
- Git identity、SSH、npm、Corepack、runtime に関係する変更。
- Phase roadmap 上の task。

## PR が必要な変更

原則すべての変更は PR を通す。

特に以下は PR 必須:

- shell script の挙動変更。
- validation / doctor / preflight の終了コード変更。
- capability の追加、削除、意味変更。
- profile の permission 変更。
- install、secret、network、AI agent 境界に関わる変更。
- `AGENTS.md` や repository 運用ルールの変更。

## main 直 commit の例外

main 直 commit は例外扱いにする。

許容する例外:

- merge 後に見つかった typo の即時修正。
- broken commit の最小修正。
- GitHub / Notion 運用移行中の bootstrap。

例外を使った場合でも、Notion worklog または follow-up Issue に理由を残す。

## PR に書くこと

- Summary: 何を変えたか。
- Linked Issue: 対応 Issue。
- Validation: 実行した検証。
- Side Effects: install / secret / network / apply の有無。
- Residual Risk: 残っているリスク。
- Next: 次にやること。

## 最低限の validation

以下は GitHub Actions(`.github/workflows/validate.yml`)が PR ごとに自動実行する(shellcheck は warning 以上で fail)。手元での事前実行も引き続き推奨する。

```sh
./scripts/validate-policy.sh --all
./scripts/test-policy.sh
./scripts/test-gitconfig.sh
./scripts/test-npmrc.sh
./scripts/test-doctor.sh
./scripts/test-secrets-gate.sh
./scripts/test-private-backup.sh
./scripts/test-install-packages.sh
./scripts/test-render.sh
./scripts/test-claude-settings.sh
./scripts/test-codex-settings.sh
./scripts/test-git-signing.sh
./scripts/test-git-hook-gates.sh
./scripts/test-starship.sh
./scripts/test-ssh.sh
./scripts/test-preflight.sh
./scripts/test-gclone.sh
./scripts/test-shell-syntax.sh
bash -ec 'for file in scripts/*.sh; do bash -n "$file"; done'
bash -ec 'for file in dot_zshenv dot_zshrc dot_zprofile; do zsh -n "$file"; done'
shellcheck -S warning scripts/*.sh
git diff --check
```

`test-render.sh` / `test-claude-settings.sh` / `test-git-signing.sh` / `test-starship.sh` /
`test-ssh.sh` は chezmoi を必要とする(CI では version pin して導入する。render job 所属)。
`test-npmrc.sh` は両 job で走る(静的検査は validate job、chezmoi が要る rendered-content
検査は render job で実行される。#150)。
この一覧は `.github/workflows/validate.yml` が正なので、CI にテストを足したらここも更新する。

`preflight` / `doctor` を変更した場合:

```sh
./scripts/preflight.sh work
./scripts/doctor.sh work
```

Git config source(`dot_gitconfig`)を変更した場合:

```sh
./scripts/test-gitconfig.sh
```

## 検証レイヤー

(旧検証計画 doc から統合。#147)

```text
1. 静的検証 + テスト   CI が PR ごとに実行(.github/workflows/validate.yml が single source)
2. render 検証         test-render.sh: 全 profile を throwaway destination に apply し
                       managed target 一覧を期待値と比較(CI の render job)
3. 実 host への適用    target を絞った chezmoi apply(diff 全文確認後)
```

VM 検証は行わない(2026-06-12 決定: throwaway destination + CI render 検証 + target を
絞った host 適用で代替)。決定の経緯・検証メモは Notion(検証戦略ページ)と git 履歴。

## 新しい file 種別を managed にするときの標準手順

1. module の `paths:` / `requires:` を `.chezmoidata/modules.yaml` に宣言する(`docs/policy-model.md`)。
2. throwaway destination で apply し、`scripts/test-render.sh` の期待 managed 一覧を更新する。
3. 実 host では `chezmoi diff` の全出力を確認してから、target を絞って apply する。
4. 適用後に `./scripts/doctor.sh <profile>` を確認する。

## 禁止事項

- Issue なしで大きな scope を始める。
- PR に validation を書かずに merge する。
- policy violation と report-only warning を混同する。
- secret、token、private endpoint、会社・クライアント固有情報を Issue / PR に書く。
- `main` へ常用的に直接 commit する。
