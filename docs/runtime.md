# Runtime

`runtime` module の方針。mise で言語 runtime(node、go、python など)を管理する。

## global baseline と project pin の責務分界

global の mise config(`~/.config/mise/config.toml`)と project の `.mise.toml` は役割が違う。

- **global(baseline)**: project の外でも動く必要があるグローバル CLI のための *最小 baseline runtime* だけを宣言する。具体例: npm global tool(例 `@openai/codex`)は node を、`go install` 由来の tool(例 `goreleaser`)は go を、どの project にいなくても要求する。これらが動く下地を出すのが global の役割。なお `claude`(Claude Code)は npm-global ではなく native installer で `~/.local/bin` に入れるため、この node baseline には依存しない(`docs/supply-chain-npm.md`)。
  - baseline は `lts` / major 線で宣言する(例: `node = "lts"`、`go = "1.26"`)。**再現性のための exact pin ではない**。
- **project(override)**: 各 project の `.mise.toml` が **exact version** で pin し、global baseline を override する(例: `[tools]` に `python = "3.13.5"` のような exact pin)。再現性の責務は project 側にある。

この分界は意図的な決定(2026-06-18、#54)。以前は「global に tool version を置かない」方針だったが、global CLI(npm global / go install 由来)が project 外でも runtime を要するため、global に最小 baseline を置く形へ改めた。global は「再現性 pin の置き場」ではなく「グローバルツールの稼働基盤」と位置づける。

## uv の扱い

- `uv` は **Python の tool/package manager(tool)** であって、言語 runtime の管理ではない。グローバル CLI として使うため mise の tool として供給する。
- **Python runtime の pin は別 scope**。global mise config に python を baseline 宣言しない(必要になったら別途方針を決める)。

## 方針

- runtime の自動 install はしない。`not_found_auto_install = false` を設定し、install は明示的な `mise install` で行う。baseline を宣言しても、shim 呼び出しで勝手に runtime を取りに行かない。
- `mise trust` / `direnv allow` は自動化しない。
- **`go install` の行き先は `~/go/bin`**(#305)。mise は既定で GOBIN を toolchain の install dir(`~/.local/share/mise/installs/go/<版>/bin`)に向けるが、managed な mise config は `go.set_gobin = false` で GOBIN を設定させず、Go の既定(`${GOPATH:-$HOME/go}/bin`)に入れる。software catalog の go_install(`install-packages.sh`)が入れる先と、managed な statusLine / agent-tools の usage reader が tacho を実行する path(`~/go/bin/tacho`)を一致させ、Go の版を上げても tool が古い toolchain の dir に取り残されないようにするため。`~/go/bin` は `~/.zshenv` が PATH の末尾に足す(go install した tool が system や package manager の command を隠さないよう末尾)。GOBIN / GOPATH を `~/.zshrc.local` などで別に設定しない。`doctor.sh` は行き先が `~/go/bin` でないと action として報告する(apply 前に開いた shell は mise が export した GOBIN を持ち続けるので、apply 後は新しい shell を開く)。以前の既定で toolchain の dir に入った tool は catalog の追跡の外になるので、不要なら手で消す。
- `enableRuntimeManagement=false` の profile では、mise config を chezmoi 管理対象外にする。この gate は `runtime` module の `paths:` / `requires:` 宣言(`.chezmoidata/modules.yaml`)から `.chezmoiignore` に生成される。

## config 管理と実 install の境界

`enableRuntimeManagement` が制御するのは **mise config file の chezmoi 管理**であって、runtime を実際に install することではない。

- `work` は `enableRuntimeManagement=true`(config 管理は可)だが `installPackages=false`。実際の `mise install`(runtime を取得する install 操作)は **本人の明示手動操作に限定**し、repo が work 環境で自動実行することはしない。
- environmentKind の制約上、work / client / agent では install 系 capability が false 必須(`docs/policy-model.md`)。mise config を管理することと runtime を install することは別レイヤだと理解する。

## capability との対応

- `enableRuntimeManagement`: mise config の管理と `doctor.sh` の mise 検査を制御する。
- `enableDirenv`: direnv の利用方針と `doctor.sh` の direnv 検査を制御する。

## update policy との関係

runtime の upgrade は project 側の pin 変更、または global baseline 線の明示的な変更として行う。global での自動 upgrade はしない(`docs/update-policy.md`)。

## 移行手順(brew → mise)

既に node / go / uv を Homebrew で入れている環境を mise 供給へ移す手順。**実 home への操作は本人が明示的に行う**(repo は勝手に install / uninstall しない)。npm global package は node の prefix 配下に入るため、node 供給元を切り替えると **見えなくなる**。先に入れ直すこと。

1. **mise 導入**: `brew install mise`(`.chezmoidata/packages.yaml` に `source: brew_formula` で宣言済み)。shell 統合(`mise activate`)を有効化。
2. **baseline runtime を install**: `mise install`(global config の `node` / `go` / `uv` を取得)。`not_found_auto_install=false` なのでこの明示実行が必要。
3. **PATH 確認**: 新しい shell で `command -v node npm go uv` が mise 配下(`$HOME/.local/share/mise/...`。対話 shell では `mise activate` による `installs/...`、`zsh -c` などの非対話 shell では `shims/...`)を指すことを確認。
4. **global npm tool の入れ直し**: mise の node 配下に `@openai/codex` を入れ直す。`npm root -g` が mise 配下になっていることを確認する。（`claude` は npm-global ではなく native installer で入れるため対象外。`docs/supply-chain-npm.md`）
5. **go tool**: `$HOME/go/bin` 配下の tool(`goreleaser` 等)は go バイナリと独立なので(`~/.zshenv` が PATH に足す)残るが、必要なら mise の go で再ビルドする。mise の go の `go install` も `~/go/bin` に入る(上記「方針」、#305)。
6. **検証**: `command -v node npm go uv codex` がすべて解決し、`npm root -g` が mise 配下を指すことを確認してから次へ（`claude` は native installer の `~/.local/bin` で別管理）。
7. **brew から撤去**: 検証が済んだら `brew uninstall node go uv`。node/go/uv に依存する他 formula が無いことを `brew uses --installed node go uv` で事前確認する。

### rollback

撤去前に問題が出たら `brew uninstall` を行わなければよい(mise と brew の runtime が共存している状態に戻すだけ)。撤去後に戻すなら `brew install node go uv` で再導入する。

## 対象外

- runtime の自動 install / upgrade。
- project ごとの version 強制。
- Python runtime の pin(uv は tool として扱う。runtime pin は別 scope)。
