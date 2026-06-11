# Runtime

`runtime` module の方針。mise で runtime(node、python など)を管理する。

## 方針

- global の mise config(`~/.config/mise/config.toml`)は最小限に保ち、global に tool version を置かない。
- version pin は project 側の `.mise.toml` の責務。exact version で pin する(例: `templates/project/python/.mise.toml`)。
- runtime の自動 install はしない。`not_found_auto_install = false` を設定し、install は明示的な `mise install` で行う。
- `mise trust` / `direnv allow` は自動化しない。
- `enableRuntimeManagement=false` の profile では、`.chezmoiignore` により mise config を chezmoi 管理対象外にする。

## capability との対応

- `enableRuntimeManagement`: mise config の管理と `doctor.sh` の mise 検査を制御する。
- `enableDirenv`: direnv の利用方針と `doctor.sh` の direnv 検査を制御する。

## update policy との関係

runtime の upgrade は project 側の pin 変更として明示的に行う。global での自動 upgrade はしない(`docs/update-policy.md`)。

## 対象外

- mise 自体の install(package install は後続 phase)。
- runtime の自動 install / upgrade。
- project ごとの version 強制。
