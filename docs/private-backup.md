# Private-config backup

public な dotfiles git には置けない **private な設定**(`.local` 上書き、curated な
アプリ設定)を、ユーザー指定先に **age 暗号化**で退避し、再セットアップ時に復元する
仕組み。目的は同期インフラではなく **災害復旧(単方向 backup→restore)**。

`docs/local-overrides.md` は「private な値は `.local` に置き git に入れない」と定めるが、
それを退避・復元する手段が無い(バックアップ空白地帯)。本機能がその空白を埋める。

設計の正本と論点は issue #60。本ドキュメントは確定した規約をまとめる(上書き更新)。

## 確定した規約

- **対象は curated 宣言ベース。** 層1(`.local` 上書き)+ 層2(個別アプリ設定 file)。
  plist 丸ごとは扱わない(キャッシュ・GUI 状態・マシン固有値が混ざり復元事故になる)。
- **アーカイブは secret を含みうる前提。** `.zshrc.local` 等は secret を含み得る
  (`docs/local-overrides.md`)。よって **age 暗号化は必須**。1Password は secret の
  system-of-record(意図的な単独 secret はそちらに置き、この backup を secret 倉庫に
  しない)であって、設定に混入する secret を捕捉することとは排他ではない。
- **暗号化は age identity 鍵(X25519)**。長期 secret は identity(`AGE-SECRET-KEY-1...`)で、
  1Password に保管する(「1Password に単一 secret」を維持)。backup は公開鍵(recipient
  `age1...`)で暗号化するので secret 不要。verify / restore は identity で復号する。
  当初は passphrase(scrypt)方式だったが、age CLI が passphrase を実 TTY からしか読めず
  op からの非対話供給(#51)ができないため identity 鍵方式へ変更した(経緯は issue #60)。
- **保管先はユーザー指定パス。** 固定 git repo に縛らない(外付け / クラウド同期
  フォルダ等)。成果物生成と保管場所を分離する。指定先を選ばないため、成果物自体を
  暗号化しておく。

## 2 層リスト

- **public baseline**(`.chezmoidata/backup-paths.yaml`、本 repo にコミット):
  誰の環境でも当たり障りない public-safe なパスのみ。「何を追っているか」を repo で
  可視化する。
- **local 補足**(`~/.config/dotfiles/backup-paths.local`、非コミット):
  client 固有・private なパスはここだけに書く。**暗号化アーカイブに同梱**され、
  復元時に参照される。public-safety を守りつつリストごと復元できる。

`backup-paths.yaml` の各 entry:

| field | 必須 | 内容 |
| --- | --- | --- |
| `path` | ✓ | home-relative パス。先頭 `/`・`..`・glob メタ文字(`* ? [`)は禁止。`path` を最後に持つ行形式なので path 中の `|` も曖昧にならない |
| `type` | | `file` / `dir`(期待する種別)|
| `category` | | public-safe な自由ラベル(例 `shell` / `ssh`)|

`validate-policy.sh` がこれらを機械的に検査する(home-relative / glob 禁止 / type 既定値 /
path 重複を fail-closed)。パスの public-safety 自体は人間レビューの責務。

## スクリプト

`scripts/private-backup.sh`(手動起動のみ):

```sh
# backup: baseline + local 補足を解決し、暗号化アーカイブと marker を書く
private-backup.sh backup --out PATH [--recipient AGE1... | --recipients-file PATH] \
                         [--local-supplement PATH] [--yes]
# verify: アーカイブを 0700 temp に復号し manifest と突き合わせ検証(HOME には書かない)
private-backup.sh verify --in PATH (--identity PATH | --identity-command CMD)
# restore: verify した上で HOME(or --target-home)へ復元。既定 dry-run、--apply で実行
private-backup.sh restore --in PATH (--identity PATH | --identity-command CMD) \
                          [--apply] [--skip-existing] [--target-home DIR]
```

- recipient は flag か非コミットの `~/.config/dotfiles/private-backup.recipient` から取得。
  無ければ fail-closed(平文や宛先なしのアーカイブを作らない)。公開鍵は repo にコミットしない。
- identity は `--identity PATH` か `--identity-command CMD`(= #51 の op seam、`op read op://...`
  を想定)。後者は出力を /dev/fd 経由で age に渡し、秘密鍵をディスクに置かない。
- archive は `tar | age` を pipe して平文 tar をディスクに残さない。アーカイブ内のパスは
  home 相対(`-C` で絶対パスを含めない)。
- backup は捕捉 0 件なら空アーカイブを書かず fail。symlink / 不在 / 非正規ファイルは skip(warn)。
- restore は verify を通った後のみ復元する(整合 NG なら拒否)。**既定 dry-run**(何も書かない)、
  `--apply` で実行。既存ファイルは上書き前に **timestamp 付き退避 dir**(`~/.local/state/dotfiles/
  restore-backup-<ts>/`)へ move。`--skip-existing` で既存は触らない。**symlink 化した親ディレクトリ
  経由の書き込みを拒否**して HOME 外への escape を防ぐ。verify と同じ展開前 member 検証を共有。

## 段階

- **第1段(完了)**: リスト schema + parser + validate + `age` を catalog に追加(宣言レイヤ)。
  runtime secrets gate。backup(machine-neutral manifest + age identity 暗号化 +
  指定先書き出し + local 補足同梱)+ verify。doctor の report-only section
  (public baseline の解決 + marker からバックアップ有無/最終日時。local 補足は存在のみ・
  中身は読まない)。
- **第2段(完了)**: restore(dry-run 既定 / `--apply` / 既存は timestamp 退避 / 0700 temp /
  home-relative 検証 / symlink 親ディレクトリ経由の書き込み拒否 / verify 済みアーカイブのみ復元)。
  冒頭で `require_secrets_access` を通す。

## 安全境界(後続スクリプトが守る規約)

- backup / restore は **手動起動のみ**・`chezmoi apply` 非結合。
- **runtime gate**: 実 profile を chezmoi config から fail-closed に取得し、
  `allowSecretsAccess != true`(work / client / agent など)では実行を拒否する。
- restore は home-relative entry のみ許可・**0700 temp** に展開して検証後 copy・
  symlink / hardlink は既定禁止・`..` / 絶対パスを拒否し HOME 外を壊さない。
- 復号物・一時展開は確実に削除(trap)し平文を残さない。
- doctor は report-only。public baseline の解決とバックアップ有無 / 最終日時のみ表示し、
  local 補足は **存在のみ**(中身・件数を出さない。`docs/local-overrides.md` の規約に従う)。
- marker・manifest に絶対 home path / host 名 / private list path を入れない。
- 復元チェーンの循環を避ける: 復元に必要な op 設定 / 1Password sign-in 材料を
  アーカイブにだけ置かない。新マシンで最初に手動で用意するものを docs に固定する。
