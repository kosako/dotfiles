# local の OpenTelemetry backend(`otel-backend` module、#514)

AI agent(Codex など)の telemetry を、手元で受けて見るための backend。
[grafana/docker-otel-lgtm](https://github.com/grafana/docker-otel-lgtm)(OpenTelemetry Collector・Prometheus・Tempo・
Loki・Pyroscope・Grafana が 1 つの image に入ったもの)を、Colima の上の container として動かす。

agent-tools#652 は、skill が起動する Codex の telemetry を loopback の受け口へ送る形を決め、受け口の構築を
「machine の環境の話」として agent-tools の外に置いた。その受け口をこの repo が持つ。

upstream は、この image を開発・demo・検証向けとしている(production 向けではない)。ここでも、壊れたら volume ごと
作り直す前提で使う。

## 何を管理するか

| 対象 | 持ち主 | 入れ方 |
| --- | --- | --- |
| container runtime(`colima`・`docker`・`docker-compose`) | dotfiles の software catalog(#515) | `install-packages.sh --apply`(人が明示して実行) |
| container の定義 `~/.config/otel-lgtm/compose.yaml` | dotfiles(`private_dot_config/otel-lgtm/compose.yaml`、静的 file) | `chezmoi apply` |
| Colima の VM と設定(`~/.colima/`)、docker の context(`~/.docker/config.json`) | Colima / docker(管理しない) | `colima start`(初回の引数は下記) |
| 常駐の登録(LaunchAgent `sh.brew.colima`) | Homebrew(管理しない) | `brew services start colima` |
| container・volume・image | docker(管理しない) | `docker-compose ... up -d` |
| telemetry を送る側の設定(Codex の `[otel]` など) | 各 tool(管理しない) | 各 tool の設定 file を直接編集 |

`chezmoi apply` は file を置くだけで、何も起動しない。VM の起動・常駐の登録・container の起動は、暗黙の install や
常駐を避ける方針([update-policy](update-policy.md))のとおり、人が明示して実行する。

managed file の定義:

| 項目 | 値 | 理由 |
| --- | --- | --- |
| `image` | `grafana/otel-lgtm:<版>@sha256:<digest>` | 版だけだと upstream が tag を付け替えられる。digest だけだと、どの release か分からない |
| `ports` | `127.0.0.1:3000`(Grafana)・`127.0.0.1:4317`(OTLP/gRPC)・`127.0.0.1:4318`(OTLP/HTTP) | 下の「port を 127.0.0.1 に限る理由」 |
| `volumes` | named volume `data` を `/data` に | host の directory を container に見せない |
| `restart` | `unless-stopped` | docker の daemon と一緒に戻る(常時起動の 2 段目) |

### port を 127.0.0.1 に限る理由

- Grafana は、認証なしで API に応える(実測: 匿名で datasource の一覧と query が通った。upstream の README は
  初期の認証を `admin` / `admin` としている)。届く相手がそのまま読める。
- Colima(Lima)の転送の規則では、VM の中で `0.0.0.0` に公開した port は、host でも `0.0.0.0`(全 interface)に
  出る。VM の中で `127.0.0.1` に公開した port だけが、host の `127.0.0.1` に出る。address を省いた `3000:3000` は
  LAN に出る。

`test-otel-backend.sh` が、すべての port が `127.0.0.1:` で始まる文字列であることを pin する。

## 初回の手順

1. runtime を入れる(未導入のとき)。

   ```sh
   ./scripts/install-packages.sh          # dry-run で 3 つが would install に出ることを見る
   ./scripts/install-packages.sh --apply
   ```

2. Colima の VM を作る。**初回は必ずこの引数を付ける**(付けないと、既定の動作で `$HOME` が書き込み可で VM に
   mount され、managed な `~/.ssh/config` が書き換えられる)。

   ```sh
   colima start --vm-type vz --cpu 2 --memory 4 --disk 30 --mount none --ssh-config=false
   ```

   | 引数 | 意味 |
   | --- | --- |
   | `--mount none` | host の directory を VM に mount しない(既定は `$HOME` を書き込み可で mount) |
   | `--ssh-config=false` | `~/.ssh/config` を書き換えない(既定は書き換える。SSH の設定は `~/.colima/ssh_config` にも出る) |
   | `--memory 4` | 既定の 2GiB では足りない見込み(container は起動の直後で約 0.5GiB) |
   | `--disk 30` | telemetry の置き場の上限。作成の後は増やすことしかできない |
   | `--vm-type vz` | macOS の Virtualization.Framework(この版の既定。明示しておく) |

   確かめる:

   ```sh
   colima ssh -- ls /Users          # 「No such file or directory」になる(host が見えない)
   ./scripts/doctor.sh personal     # managed drift が「no drift」のまま
   ```

3. 定義を置く。

   ```sh
   chezmoi apply ~/.config/otel-lgtm ~/.config/otel-lgtm/compose.yaml
   ```

4. container を起動する。

   ```sh
   docker-compose -f ~/.config/otel-lgtm/compose.yaml up -d
   ```

   初回は image(約 3.6GB)を pull する。30 秒ほどで healthy になる(image に healthcheck がある)。

5. 確かめる。

   ```sh
   docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'
   lsof -nP -iTCP -sTCP:LISTEN | grep -E ':(3000|4317|4318) \(LISTEN\)'   # 3 行出て、どれも address が 127.0.0.1
   ```

   Grafana は `http://127.0.0.1:3000`。

6. 常時起動にする(login のときに Colima が起動し、container は restart policy で戻る)。

   ```sh
   brew services start colima     # 解除は brew services stop colima
   ```

## Colima の動き(実測、colima 0.10.3)

- 初回の引数は Colima の設定 file(`~/.colima/default/colima.yaml`)に保存される(`--save-config` の既定が true)。
  `brew services` は引数なしの `colima start -f` を実行するが、mount なしと `sshConfig: false` は保たれた
  (引数なしの `colima start` でも同じ)。
- **VM を作り直すとき(`colima delete` の後)は、同じ引数をもう一度付ける。**設定 file の `mounts` は `null` と
  保存されるので、作り直しのときに既定の `$HOME` の mount に戻らないことは確かめていない。
- docker の context は `colima` に切り替わる(`~/.docker/config.json` が作られる)。
- host に `*:53` の待ち受けが見える(`limactl`)。Lima の pseudoloopback で、loopback 以外からの接続は拒否される
  (LAN の address からの DNS の問い合わせが reset されることを確認)。特権 port を `127.0.0.1` に bind できない
  macOS の制約への、Lima の対処。
- Codex の sandbox の中からは、docker の socket に届かない(`codex sandbox -- docker ps` が permission denied)。
  sandbox の外で動く agent からは届くので、docker の command を許可するかは各 agent の承認の設定で決まる。

## telemetry を送る

受け口は、OTLP/HTTP が `http://127.0.0.1:4318`、OTLP/gRPC が `127.0.0.1:4317`。

Codex の例(`~/.codex/config.toml` は Codex が持つ file で、managed ではない。[config-ownership](config-ownership.md)):

```toml
[otel]
environment = "personal"
exporter = { otlp-http = { endpoint = "http://127.0.0.1:4318/v1/logs", protocol = "binary" } }
trace_exporter = { otlp-http = { endpoint = "http://127.0.0.1:4318/v1/traces", protocol = "binary" } }
metrics_exporter = { otlp-http = { endpoint = "http://127.0.0.1:4318/v1/metrics", protocol = "binary" } }
log_user_prompt = false
```

実測(codex-cli 0.165.0): 同じ値を `-c` で渡した `codex exec` の log と metric が届いた(service の名前は
`codex_exec`。trace は届いていない)。`headers` は書かない(agent-tools#652 は、`headers` のある `[otel]` を
skill の起動へ引き継がずに止める)。

## image の更新

1. 版を選ぶ。公開から 7 日以上たったものにする(npm の `min-release-age` と同じ待ち。
   [supply-chain-npm](supply-chain-npm.md))。
2. その版の digest を registry で確かめ、attestation を検証する。

   ```sh
   gh attestation verify --repo grafana/docker-otel-lgtm \
     oci://docker.io/grafana/otel-lgtm@sha256:<digest> \
     --signer-workflow grafana/shared-workflows/.github/workflows/sign-and-attest.yml
   ```

   通れば、その digest が upstream の repository の workflow で作られたものと分かる(0.39.0 で確認。digest を
   変えると失敗する)。依存先の中身の安全を示すものではない。
3. `private_dot_config/otel-lgtm/compose.yaml` の版と digest、`scripts/test-otel-backend.sh` の pin を、同じ PR で
   変える。
4. merge の後、`chezmoi apply` してから `docker-compose -f ~/.config/otel-lgtm/compose.yaml up -d` を実行する
   (container が新しい image で作り直される。volume は残る)。

## data

- 置き場は named volume `otel-lgtm_data`(VM の disk の中)。container や VM を再起動しても残る。
- 消すとき: `docker-compose -f ~/.config/otel-lgtm/compose.yaml down -v`(container と volume を消す)。VM ごと
  消すなら `colima delete`。
- 保持期間と volume の増え方は未確認(起動の直後で約 0.7GB)。upstream は、`PROMETHEUS_EXTRA_ARGS` や
  `LOKI_EXTRA_ARGS` で保持期間を渡す例を README に載せている。
- telemetry には tool の出力の抜粋が入りうる(agent-tools#652)。data は VM の中に留め、外へは送らない。外部の
  backend への転送と項目の絞り込みは、この module の範囲外。

## profile

- **personal のみ列挙**。work は非列挙: container runtime を入れるか、agent の telemetry を手元に貯めるかを
  決めていない。
- module 列挙だけで gate する(capability は無い。herdr-config と同型)。managed-by の見出しを持つので、profile
  切替で非 active になった残置は doctor の managed-path orphan scan が拾う。

## doctor

「otel backend」section(report-only)が、module が active な profile で managed file の presence を見る。無ければ
action(`mkdir -p ~/.config` と `chezmoi apply` の手順)。中身は読まない(drift は managed drift section が出す)。

**実行時の状態は、まだ見ない**: Colima が動いているか、container が固定した image で動いているか、port が
loopback だけか、常駐が登録されているか。ok の行にもそう書く(file があることを「backend が動いている」と
読ませないため)。#514 の続きで足す。

## 残る risk

- loopback の port には、同じ Mac の process と browser から届く。Grafana は認証なしで応える。
- docker の socket は、使える process にとって強い権限になる。`--mount none` で host の directory を VM に
  見せないことで、影響を狭めている。
- image は 3.6GB あり、production 向けではない。
- catalog は profile で分かれていないので、work の doctor には `not installed` の warning が 3 つ出る
  (report-only)。

## 検証

`scripts/test-otel-backend.sh`: personal で apply され work ではされない(work が持つ自前の file は byte 単位で
不変)、1 行目の managed-by 見出し、YAML として parse でき定義が pin どおり、image が版と digest の両方で固定
されている、すべての port が `127.0.0.1` だけ、mount が宣言した named volume だけで宣言の中身が空、権限を広げる key
(`privileged`・`network_mode` など)が無い、restart policy、mode が file 0644 / directory 0755。container runtime
とは通信しない。doctor の分岐は `test-doctor.sh`。
