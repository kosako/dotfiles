# Secrets

secret(API token、credential など)の**供給方式の規約**。実 secret 値はこの repository に入れない。

この repo の既存方針は「secret を repo に入れない」「secret store を AI に直接読ませない」という**禁止**だけを定義してきた。本 doc は、その裏側で抜けていた「**ではどう供給するのが正解か**」を規約として埋める。具体方式は 1Password の `op` + direnv による**実行時注入**とし、平文をディスク・repo に置かない。

## dotfiles の責務範囲(線引き)

dotfiles が提供するのは**規約とガードレールだけ**で、secret そのものや `op://` 参照は配置しない。実際の取得は利用者本人の手元操作に閉じる。

- **dotfiles がやること**: 供給方式の規約化、capability gate(`allowSecretsAccess`)、`doctor` による report-only の供給 readiness 確認。
- **dotfiles がやらないこと**: `op://` 参照の保持、`op run` / `op read` の実行(実 fetch)、平文 secret のディスク・repo 配置。

この線引きにより、既存の「secret store を fetch しない」境界([git-identity](git-identity.md) / [ai-policy](ai-policy.md))と矛盾しない。fetch するのは利用者であって dotfiles ではない。

## 供給方式: op + direnv による実行時注入

平文の secret をファイル・repo に置かず、プロセス起動時に環境変数として注入する。

- project root に入った瞬間、direnv が `op` 経由で secret を解決し、その shell / 実行プロセスにだけ環境変数を渡す。
- secret の所在は `op://vault/item/field` 形式の **参照**で表現する。参照を書いた file(`.envrc` や env template)は **project local に置き、commit しない**(`.gitignore` 対象)。
- 永続化するのは「参照」であって「値」ではない。値はメモリ上にだけ存在し、ディスクには落とさない。

最小例(いずれも project local、非 commit):

```bash
# .envrc  — direnv が project 入場時に評価する。op:// 参照だけを持ち、値は持たない。
export DATABASE_URL="$(op read 'op://Personal/example-db/url')"
```

または env template を `op run` で包む:

```bash
# .env.tmpl  — op:// 参照のみ。実行時に op が解決する。
DATABASE_URL=op://Personal/example-db/url
```

```bash
op run --env-file=.env.tmpl -- <command>
```

どちらも **値はディスクに書かれない**。`op read` / `op run` は利用者の手元で実行され、dotfiles はこの incantation を repo に焼き込まない。

## capability gate

secret 供給が有効になるのは `allowSecretsAccess=true` の profile に限る。

- `allowSecretsAccess` は [policy-model](policy-model.md) の environmentKind 不変条件により、**work / client / sandbox / agent では `false` 必須**(`validate-policy.sh` が hard fail で強制)。供給規約が効くのは `personal` 等に限られる。
- `doctor` の `1Password` section は `allowSecretsAccess=true` のときだけ `op` の存在と sign-in を report-only で確認する。secret 値そのものは読まない。`false` の profile では「secret access disabled」と報告して終わる。

この gate は **secret 供給という用途だけ**を縛る。direnv 一般の利用(後述)は別 capability で、ここでは縛らない。

## identity は別ルール(二層)

secret 全般は op + direnv で供給してよいが、**Git identity は対象外**。混同しないこと。

- [git-identity](git-identity.md) の identity 値(`user.name` / `user.email`)は「secret というより設定値」であり、**secret store を参照せず完全手動 local** と確定済み(Issue #19)。`allowSecretsAccess=false` の profile でも identity は使えなければならないため。
- つまり「**secret = op 供給可 / identity = secret store 参照しない手動 local**」の二層。identity を本 doc の供給規約に乗せない。

## AI agent との関係

[ai-policy](ai-policy.md) の default deny は維持する。dotfiles は供給規約を置くだけで、AI に secret store を読ませる動線は作らない。

- AI agent は secret store に直接アクセスしない(default deny)。secret access は明示承認が必要。
- 本 doc の供給方式は**利用者本人**のプロセス起動時注入であって、AI agent への自動供給ではない。

## direnv 一般との関係

direnv には 2 つの用途がある。本 doc が扱うのは後者(secret 供給)だけ。

- **project env(PATH / runtime 切り替え等、secret 無関係)**: `enableDirenv` capability が制御する([runtime](runtime.md))。`work-dev` のように `enableDirenv=true` かつ `allowSecretsAccess=false` の構成があり得る(direnv は使うが secret 注入はしない)。
- **secret 供給**: 本 doc の規約。`allowSecretsAccess` で別途 gate する。

`direnv allow` / `mise trust` は自動化しない([runtime](runtime.md))。direnv の有効化と secret 供給の許可は独立した判断とする。

## 検査

- `doctor`(report-only、副作用なし): `allowSecretsAccess=true` のとき `1Password` section が `op` の存在と sign-in を確認する。`enableDirenv=true` のとき `runtime and shell` section が `direnv` の存在を確認する。いずれも secret 値は読まない。

## 対象外

- `op://` 参照の repo 保持、`op run` / `op read` の repo 内実行(実 fetch は利用者側)。
- 平文 secret のディスク・repo 配置。
- マシンローカルに置かざるを得ない秘密素材の暗号化(age 等)は別 Issue で扱う。
- 会社・クライアント固有の vault 名・item 名・参照を repo / docs に入れない。例の `op://` 参照は placeholder。
