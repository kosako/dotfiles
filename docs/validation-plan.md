# Validation Plan

この repository の検証レイヤーと、検証戦略に関する決定の記録。
検証メモや試行錯誤は Notion(検証戦略ページ)に置き、確定した計画だけをここに置く。

## 検証レイヤー

```text
1. 静的検証 + テスト   CI が PR ごとに実行(.github/workflows/validate.yml が single source)
2. render 検証         test-render.sh: 全 profile を throwaway destination に apply し
                       managed target 一覧を期待値と比較(CI の render job)
3. 実 host への適用    target を絞った chezmoi apply(diff 全文確認後)
```

検証コマンドの一覧は `docs/github-workflow.md` の「最低限の validation」を参照する。

## 新しい file 種別を managed にするときの標準手順

1. module の `paths:` / `requires:` を `.chezmoidata/modules.yaml` に宣言する(`docs/policy-model.md`)。
2. throwaway destination で apply し、`scripts/test-render.sh` の期待 managed 一覧を更新する。
3. 実 host では `chezmoi diff` の全出力を確認してから、target を絞って apply する。
4. 適用後に `./scripts/doctor.sh <profile>` を確認する。

## 決定記録

### 2026-06-12: VM 検証を経ず host 直行に下方修正

当初計画(Notion 検証戦略)は clean / existing VM での apply 検証を経て host に適用する段階方式だった。
実際には以下の組み合わせで VM 検証を代替し、host へ直行する方式に変更した。

- throwaway destination での apply 検証(実 home に触れない)
- CI の render / managed-set 検証(`test-render.sh`)
- 実 host では target を絞った apply(初回は `~/.gitconfig` のみ。Issue #9)

### 2026-06-12: 初回 apply は personal の target 絞りで実施

当初案は「副作用が最小の work-minimal を最初に apply する」だったが、この host の主用途が
personal であるため、personal profile で target を `~/.gitconfig` に絞って初回 apply を実施した(Issue #9)。
profile 指定だけでは適用範囲は絞れないため、初回適用は必ず target 指定で行う。

### 2026-06-12: zsh 移行前の検証は CI render 検証の拡張で行う

login shell を壊しうる zsh 移行(Issue #15)の前提検証は、VM 検証の復活ではなく
CI の render / managed-set 検証の拡張で行う(本人決定)。あわせて `docs/local-overrides.md` の
規約に従い、既存 `~/.zshrc` の棚卸しを移行前に行う。
