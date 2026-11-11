# local の OpenTelemetry backend(`otel-backend` module、#514 / #517)

AI agent(Codex など)の telemetry を、手元で受けて見るための backend。
[grafana/docker-otel-lgtm](https://github.com/grafana/docker-otel-lgtm)(OpenTelemetry Collector・Prometheus・Tempo・
Loki・Pyroscope・Grafana が 1 つの image に入ったもの)を、Colima の上の container として動かす。

agent-tools#652 は、skill が起動する Codex の telemetry を loopback の受け口へ送る形を決め、受け口の構築を
「machine の環境の話」として agent-tools の外に置いた。その受け口をこの repo が持つ。

upstream は、この image を開発・demo・検証向けとしている(production 向けではない)。ここでも、壊れたら volume ごと
作り直す前提で使う。作り直しても失いたくない生の telemetry は、別の場所に保管する(下の「生データの保管と読み戻し」)。

## 何を管理するか

| 対象 | 持ち主 | 入れ方 |
| --- | --- | --- |
| container runtime(`colima`・`docker`・`docker-compose`) | dotfiles の software catalog(#515) | `install-packages.sh --apply`(人が明示して実行) |
| container の定義 `~/.config/otel-lgtm/compose.yaml` | dotfiles(`private_dot_config/otel-lgtm/compose.yaml`、静的 file) | `chezmoi apply` |
| Collector の保管の設定 `~/.config/otel-lgtm/otelcol/archive.yaml` | dotfiles(#517) | `chezmoi apply` |
| Grafana の dashboard と provider `~/.config/otel-lgtm/grafana/` | dotfiles(#517) | `chezmoi apply` |
| 生データの保管の directory `~/.local/share/otel-lgtm/archive/` | 人(中身は Collector が書く。管理しない) | `mkdir`(初回の手順) |
| Colima の VM と設定(`~/.colima/`)、docker の context(`~/.docker/config.json`) | Colima / docker(管理しない) | `colima start`(初回の引数は下記) |
| 常駐の登録(LaunchAgent `sh.brew.colima`) | Homebrew(管理しない) | `brew services start colima` |
| container・volume・image | docker(管理しない) | `docker-compose ... up -d` |
| telemetry を送る側の設定(Codex の `[otel]` など) | 各 tool(管理しない) | 各 tool の設定 file を直接編集 |

`chezmoi apply` は file を置くだけで、何も起動しない。VM の起動・常駐の登録・container の起動は、暗黙の install や
常駐を避ける方針([update-policy](update-policy.md))のとおり、人が明示して実行する。

compose file の定義:

| 項目 | 値 | 理由 |
| --- | --- | --- |
| `image` | `grafana/otel-lgtm:<版>@sha256:<digest>` | 版だけだと upstream が tag を付け替えられる。digest だけだと、どの release か分からない |
| `ports` | `127.0.0.1:3000`(Grafana)・`127.0.0.1:4317`(OTLP/gRPC)・`127.0.0.1:4318`(OTLP/HTTP) | 下の「port を 127.0.0.1 に限る理由」 |
| `volumes` | named volume `data` を `/data` に。bind は下の表の 4 つ | backend の data は VM の中、host から渡すのは決めた path だけ |
| `restart` | `unless-stopped` | docker の daemon と一緒に戻る(常時起動の 2 段目) |
| `environment` | `PROMETHEUS_EXTRA_ARGS: --enable-feature=otlp-deltatocumulative` | 下の「metric の temporality」 |
| `environment` | `OTELCOL_EXTRA_ARGS: --config=file:/otel-lgtm/otelcol-archive.yaml` | image の Collector の設定に、保管の pipeline を重ねる |

bind(どれも long syntax で `bind.create_host_path: false`):

| host の path(compose の directory から) | container の path | 書き込み |
| --- | --- | --- |
| `./otelcol/archive.yaml` | `/otel-lgtm/otelcol-archive.yaml` | 読み取りだけ |
| `./grafana/provisioning/agents.yaml` | `/otel-lgtm/grafana/conf/provisioning/dashboards/agents.yaml` | 読み取りだけ |
| `./grafana/dashboards` | `/otel-lgtm/agent-dashboards` | 読み取りだけ |
| `${HOME}/.local/share/otel-lgtm/archive` | `/archive` | 書き込み可 |

- 相対 path は docker-compose が compose file の directory から解決し、絶対 path として daemon に渡す。daemon は VM の
  中で動くので、その path が VM に mount されている必要がある(下の「VM の mount」)。
- `create_host_path: false` は、VM に無い path を daemon が VM の中に作らず、container の作成を
  `bind source path does not exist` で失敗させる(実測)。作られてしまうと、生データが host に届かず VM の中に
  溜まるのに、何も失敗しない。

### port を 127.0.0.1 に限る理由

- Grafana は、認証なしで API に応える(image の起動 script が匿名の access を Admin の権限で有効にする。実測: 匿名で
  datasource の一覧と query が通った)。届く相手がそのまま読める。
- Colima(Lima)の転送の規則では、VM の中で `0.0.0.0` に公開した port は、host でも `0.0.0.0`(全 interface)に
  出る。VM の中で `127.0.0.1` に公開した port だけが、host の `127.0.0.1` に出る。address を省いた `3000:3000` は
  LAN に出る。

`test-otel-backend.sh` が、すべての port が `127.0.0.1:` で始まる文字列であることを pin する。

### VM の mount

Colima の VM には、host の directory を次の 2 つだけ mount する(#517。それまでは `--mount none`)。

| host の directory | 書き込み | 使い道 |
| --- | --- | --- |
| `~/.config/otel-lgtm` | 読み取りだけ | Collector の保管の設定と、Grafana の dashboard を container に渡す |
| `~/.local/share/otel-lgtm/archive` | 書き込み可 | 生データの書き先 |

- `$HOME` 全体は VM に見せない(Colima の既定は `$HOME` を書き込み可で mount する)。docker の socket を使える
  process から届く host の path は、この 2 つの directory だけになる。
- 読み取りだけの mount は、VM の中から書けない(実測: `Read-only file system`)。
- VM の root が書いた file は、host では自分の持ち主になる(実測)。

## 初回の手順

1. runtime を入れる(未導入のとき)。

   ```sh
   ./scripts/install-packages.sh          # dry-run で 3 つが would install に出ることを見る
   ./scripts/install-packages.sh --apply
   ```

2. 定義を置き、保管の directory を作る。VM が mount する 2 つの directory は、VM を起動する前に在る必要がある。

   ```sh
   chezmoi apply ~/.config/otel-lgtm
   mkdir -p ~/.local/share/otel-lgtm/archive
   chmod 700 ~/.local/share/otel-lgtm ~/.local/share/otel-lgtm/archive
   ```

3. Colima の VM を作る。**初回は必ずこの引数を付ける**(付けないと、既定の動作で `$HOME` が書き込み可で VM に
   mount され、managed な `~/.ssh/config` が書き換えられる)。

   ```sh
   colima start --vm-type vz --cpu 2 --memory 4 --disk 30 \
     --mount ~/.config/otel-lgtm --mount ~/.local/share/otel-lgtm/archive:w --ssh-config=false
   ```

   | 引数 | 意味 |
   | --- | --- |
   | `--mount ~/.config/otel-lgtm` | 設定の directory を読み取りだけで mount する(`:w` が無い mount は読み取りだけ) |
   | `--mount ~/.local/share/otel-lgtm/archive:w` | 保管の directory を書き込み可で mount する |
   | `--ssh-config=false` | `~/.ssh/config` を書き換えない(既定は書き換える。SSH の設定は `~/.colima/ssh_config` にも出る) |
   | `--memory 4` | 既定の 2GiB では足りない見込み(container は起動の直後で約 0.5GiB) |
   | `--disk 30` | backend の data の置き場の上限。作成の後は増やすことしかできない |
   | `--vm-type vz` | macOS の Virtualization.Framework(この版の既定。明示しておく) |

   確かめる:

   ```sh
   colima ssh -- mount | grep virtiofs    # 2 行だけで、config は (ro、archive は (rw
   colima ssh -- ls /Users/$USER          # 2 つの directory への途中の directory だけが見える
   ./scripts/doctor.sh personal           # managed drift が「no drift」のまま
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
   ls -la ~/.local/share/otel-lgtm/archive                                # telemetry が届くと *.jsonl ができる
   ```

   Grafana は `http://127.0.0.1:3000`。dashboard は「AI agents」folder の「AI agents (Codex)」。

6. 常時起動にする(login のときに Colima が起動し、container は restart policy で戻る)。

   ```sh
   brew services start colima     # 解除は brew services stop colima
   ```

### `--mount none` で作った VM を移す(#517 の前の手順で作ったとき)

mount は、VM を止めて引数を付けて起動し直せば変わる(実測。新しい mount は設定 file に保存され、引数なしの再起動でも
保たれる)。VM の disk はそのままなので、backend の data も残る。

```sh
chezmoi apply ~/.config/otel-lgtm
mkdir -p ~/.local/share/otel-lgtm/archive
chmod 700 ~/.local/share/otel-lgtm ~/.local/share/otel-lgtm/archive
colima stop
colima start --mount ~/.config/otel-lgtm --mount ~/.local/share/otel-lgtm/archive:w
docker-compose -f ~/.config/otel-lgtm/compose.yaml up -d
```

## Colima の動き(実測、colima 0.10.3)

- 初回の引数は Colima の設定 file(`~/.colima/default/colima.yaml`)に保存される(`--save-config` の既定が true)。
  `brew services` は引数なしの `colima start -f` を実行するが、mount と `sshConfig: false` は保たれた(引数なしの
  `colima start` でも同じ)。
- **VM を作り直すとき(`colima delete` の後)は、同じ引数をもう一度付ける。**
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

実測(codex-cli 0.165.0、2026-11-11): この `[otel]` を置いた `config.toml` で `codex exec` を動かすと、log(Loki)・
trace(Tempo)・metric(Prometheus)の 3 つが届く。service の名前は `codex_exec`。`log_user_prompt = false` で、prompt の
本文は伏せられる。`headers` は書かない(agent-tools#652 は、`headers` のある `[otel]` を skill の起動へ引き継がずに
止める)。

確かめ方:

- trace は、Tempo の検索に TraceQL の `{}` を渡す(TraceQL なしの検索では出ない)。
- event の名前(`codex.sse_event` など)は Loki の stream の label ではなく structured metadata なので、LogQL では
  `{service_name="codex_exec"} | event_name="codex.sse_event"` のように絞る。
- 届いていないときは、Collector の受付と送信の数を Prometheus で見る(`otelcol_receiver_accepted_*_total` と
  `otelcol_exporter_send_failed_*_total`)。

### metric の temporality

Codex は metric をすべて delta の temporality で送る(61 種類すべてで確認)。Prometheus の OTLP の受け口は、既定では
delta を受け付けず、`invalid temporality and type combination` で拒否する(#517 で確認。log と trace は届くのに、metric
だけが Collector の送信で失敗する)。image の Collector には delta を変換する processor が無いので、Prometheus の
`--enable-feature=otlp-deltatocumulative` で取り込みのときに cumulative に直す。`test-otel-backend.sh` がこの指定を
pin する。

- 変換の状態は Prometheus の memory にあり、container を作り直すと counter は 0 から数え直す(`rate()` /
  `increase()` は reset として扱う)。
- Codex の resource には process を区別する attribute が無いので、同じ service の複数の process の値は 1 つの系列に
  足し合わされる。

## dashboard

Grafana の「AI agents」folder に、「AI agents (Codex)」(uid `ai-agents-codex`)を provisioning する。

| 段 | panel | 出どころ |
| --- | --- | --- |
| 概要 | 会話・API request・API request の失敗・input / output / cached token(表示している期間の合計) | Loki |
| token と request | token(model と種類ごと)、API request(endpoint と status ごと) | Loki |
| 応答の速さと turn | turn の TTFT(p50 / p95)、turn の数(model ごと) | Loki |
| tool | tool の呼び出し(tool と成否ごと)、tool の所要時間(p95) | Loki |
| 最近の動き | 会話の開始、失敗した request、trace | Loki、Tempo |

- 上の `service` の変数で service を絞る(既定は `codex` で始まるもの全部)。Claude Code などを足すときは、変数の
  条件と panel を足す。
- 正本は dotfiles の JSON。Grafana の UI での変更は保存できない(provider の `allowUiUpdates: false`)。変えるときは
  `private_dot_config/otel-lgtm/grafana/dashboards/agents.json` を直して apply する。Grafana は 30 秒ごとに読み直す。
- datasource は image が provisioning する `loki`・`prometheus`・`tempo` を uid で指す。
- 数は log から数える。`codex exec` は短命の process で、metric は終わるときに 1 回だけ delta で届く。Prometheus の
  `increase()` は系列の最初の値を増分として数えず、delta の変換の状態は Prometheus を起動し直すと 1 から数え直すので、
  metric の増分は実際の回数より小さくなる(実測: 2 回の run で `codex_conversation_turn_count_total` が 1 → 1、増分 0)。
  metric は Prometheus に残るので、所要時間の分布などは Grafana の Explore で見る。
- Codex の event と attribute(LogQL で使うもの): `codex.conversation_starts`(model・reasoning_effort・originator・
  approval_policy・sandbox_policy)、`codex.api_request`(endpoint・http_response_status_code・success・duration_ms)、
  `codex.sse_event` の `event_kind="response.completed"`(input / output / cached / reasoning_token_count)、
  `codex.turn_ttft`(duration_ms)、`codex.tool_result`(tool_name・success・duration_ms)。

## 生データの保管と読み戻し

いずれ別の server を立てて収集し直すときのために、Collector が受け取った telemetry を、そのまま host の
`~/.local/share/otel-lgtm/archive/` に書く(#517)。backend の volume や VM を作り直しても残る。

- 書くのは image の Collector に重ねた 3 つの pipeline(`traces/archive`・`metrics/archive`・`logs/archive`)。receiver は
  `otlp` だけで processor を通さないので、Codex が送ったままの形になる。image の既存の pipeline の定義には触れず、
  名前の違う pipeline を足すだけ(Collector の設定の重ね方では、list は置き換わり、map は足される)。
- file は signal ごとに `traces.jsonl`・`metrics.jsonl`・`logs.jsonl`。中身は改行区切りの OTLP JSON(1 行が 1 回の
  export)で、圧縮しない。
- 64MB を超えると、`<名前>-<UTC の時刻>-size.jsonl` に回して新しい file に書く。**古い file は消さない**: 期間の上限
  (`max_days`)は付けず、残す数(`max_backups`)は 0 にした。0 は回した file を全部残す(この image の Collector で実測、
  #517: 1MB で回す設定で、0 は回した 7 つを全部残し、1 は最新の 1 つだけを残した。upstream の README には 0 の意味が
  書かれていない)。0 以外の数は、古いものから消す。容量は増え続ける。目安(実測、2026-11-11): 短い `codex exec` の 1 回で約 1.1MB(trace が約 0.88MB、metric が
  約 0.18MB、log が約 0.03MB)。skill が起動した review(effort が xhigh)の 1 回では、数分で約 8MB になった(ほとんどが
  trace)。大きさと最後に書いた時刻は doctor が出す(`du -sh ~/.local/share/otel-lgtm/archive` でも見られる)。
- Collector の自分の metric(`prometheus/collector` の scrape)は入らない。agent から届いたものだけ。

読み戻すとき(将来の server の Collector で):

- `otlpjsonfile` receiver(opentelemetry-collector-contrib)が、圧縮しない改行区切りの OTLP JSON を読める
  (upstream の README)。signal ごとに receiver を分け、file を `include` で指す。この image の Collector の build には
  `otlpjsonfile` receiver が無いので、読み戻しは別の Collector で行う。
- 元の時刻のまま送られるので、読み戻す先の backend が古い時刻を受け付けるか(Prometheus の
  `out_of_order_time_window` など)を確かめる。
- metric は Codex が送った delta のまま保管している。読み戻す先が delta を受け付けないときは、そちらで変換する。

保管の file には、Loki と同じ中身が入る(tool の出力の抜粋、account の email などの attribute)。directory は 0700 に
し、外へは送らない。

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
3. 新しい image の Collector が保管の設定を受け付けるかを確かめる(`otlp` receiver の名前と `file` exporter が在る
   こと)。

   ```sh
   docker run --rm -i --entrypoint sh grafana/otel-lgtm@sha256:<digest> -c \
     'cat > /tmp/a.yaml && cd /otel-lgtm && ./otelcol-contrib/otelcol-contrib validate \
        --feature-gates service.profilesSupport \
        --config=file:./otelcol-config.yaml --config=file:/tmp/a.yaml' < ~/.config/otel-lgtm/otelcol/archive.yaml
   ```

   `--feature-gates service.profilesSupport` は、image の設定にある profiles の pipeline のために要る(image の
   `run-otelcol.sh` も付けて起動する。付けないと validate がその pipeline で止まる)。

4. `private_dot_config/otel-lgtm/compose.yaml` の版と digest、`scripts/test-otel-backend.sh` の pin を、同じ PR で
   変える。
5. merge の後、`chezmoi apply` してから `docker-compose -f ~/.config/otel-lgtm/compose.yaml up -d` を実行する
   (container が新しい image で作り直される。volume と保管の file は残る)。

設定の file(保管の設定・provider)を変えたときは、`docker-compose -f ~/.config/otel-lgtm/compose.yaml up -d
--force-recreate` で作り直す(どちらも起動のときにだけ読まれる。file の bind は作成のときの file を指し続けるので、
`restart` では新しい中身が見えないことがある)。dashboard の JSON は作り直さなくても読み直される。

## data

- backend の data は named volume `otel-lgtm_data`(VM の disk の中)。container や VM を再起動しても残る。
- 消すとき: `docker-compose -f ~/.config/otel-lgtm/compose.yaml down -v`(container と volume を消す)。VM ごと
  消すなら `colima delete`。**どちらも保管の file には触れない**(host にあるため)。保管の file を消すのは、
  `~/.local/share/otel-lgtm/archive/` を人が消すときだけ。
- backend の保持期間と volume の増え方は未確認(起動の直後で約 0.7GB)。upstream は、`PROMETHEUS_EXTRA_ARGS` や
  `LOKI_EXTRA_ARGS` で保持期間を渡す例を README に載せている。保持期間で backend から消えても、保管の file には残る。
- telemetry には tool の出力の抜粋が入りうる(agent-tools#652)。data は手元に留め、外へは送らない。外部の
  backend への転送と項目の絞り込みは、この module の範囲外。

## profile

- **personal のみ列挙**。work は非列挙: container runtime を入れるか、agent の telemetry を手元に貯めるかを
  決めていない。
- module 列挙だけで gate する(capability は無い。herdr-config と同型)。managed-by の見出しを持つので(dashboard の
  JSON は description に持つ)、profile 切替で非 active になった残置は doctor の managed-path orphan scan が拾う。

## doctor

「otel backend」section(report-only)。module が active な profile で、まず compose file の presence を見る。無ければ
action(`mkdir -p ~/.config` と `chezmoi apply` の手順)で、ほかは見ない。managed file の drift は managed drift section が
出す。

compose file があるときは、実行時の状態と保管の directory を**読むだけ**で確かめる(何も起動せず、何も変えない)。
使う command は `docker ps`・`docker inspect`・`colima ssh -- mount` の 3 つで、どれも期限付き(`bounded_probe`)。

| 見ること | 結果 |
| --- | --- |
| docker が PATH にあるか | 無ければ「未確認」の item(catalog の section が未導入を出す) |
| docker が daemon に届くか | 届かなければ action(保管の directory を作って `chmod 700` し、2 つの mount で `colima start`)で、container と VM の確認はしない。期限内に答えなければ「未確認」の warn |
| container があり、running か | 無い・止まっているなら action(`docker-compose -f <file> up -d`)。image と port は見ないが、VM の mount と常駐の登録は続けて見る |
| container の image が、定義の固定と同じか | 違えば action(managed file が進んだ後に作り直していない、など) |
| 公開した port が、すべて `127.0.0.1` か | 1 つでも違えば action(`0.0.0.0`・空の address・IPv6 の any)。公開が 0 なら warn。port の JSON は、strict な 1 つの object と読めたときだけ使う(下の注) |
| VM の host の share が、上の 2 つだけか | 2 つだけで設定が `ro`、保管が `rw` なら ok。ほかの share、設定が `rw`、保管が `ro`、2 つのどちらかが無い、のどれかなら、それを全部並べた 1 つの action(`colima stop` の後、保管の directory を作って `chmod 700` し、2 つの mount で起動し直す。`colima start --mount` は VM の mount を指定どおりに置き換えるので、どれもこの手順で直る)。share の行で形が読めないものがあれば「未確認」 |
| Colima が login の常駐に登録されているか | どちらでも中立の item(常時起動にするかは選べる) |
| 保管の directory | 無ければ action(`mkdir` と `chmod 700`)、0700 でなければ action(`chmod 700`)。一覧できなければ「未確認」。file が無ければ item、あれば数・大きさ・最後に書いた時刻の item(中身は読まない。`du` が失敗したら大きさは「未確認」) |

- daemon に届かないときの手順に 2 つの mount と `--ssh-config=false` を付けているのは、VM が無い状態で裸の
  `colima start` を実行すると、既定の動作(`$HOME` の mount と `~/.ssh/config` の書き換え)で新しい VM が作られるため。
  VM が既にあるときは、mount を指定どおりに置き換える(保存された設定と同じなら、その繰り返し)。
- `chmod 700` を `colima start` より先にするのは、container が VM と一緒に戻って(restart policy)、すぐに保管に書き
  始めるため。
- `docker-compose up` を手順に持つ action(container が無い・止まっている、image の違い、広い port)は、section の最後に
  まとめて出す。次の手順の一覧は action が出た順に並ぶので、mount と保管の権限を直す手順が先に来る(container の bind は、
  VM の 2 つの mount と 0700 の保管の directory を前提にするため)。
- port の JSON は、Bridge One の確認が `~/.claude/settings.json` を読むのと同じ方法で strict に読む: jq に raw の文字列で
  渡し、文字列の外の token が `true`・`false`・`null`・JSON の数値だけかを確かめてから `fromjson` する(2 つ目の値も
  拒む)。yq の JSON の reader は comma の欠けを受け付け、jq の parser は `NaN`・`01`・`+1` を数値として受け付けるため。
- 答えが取れない・読めないとき(command の失敗、期限切れ、1 つの JSON の object と読めない出力、形の読めない share の
  行、一覧できない directory)は「未確認」と書き、ok にはしない。
- VM の mount は、Colima の設定 file ではなく VM の mount の一覧(`virtiofs`・`9p`・`fuse.sshfs` の行)で見る。

## 残る risk

- loopback の port には、同じ Mac の process と browser から届く。Grafana は認証なしで、Admin の権限で応える。
- docker の socket は、使える process にとって強い権限になる。VM に mount する host の directory を 2 つ(設定は
  読み取りだけ、保管だけ書き込み可)に限ることで、影響を狭めている。doctor がこの mount の形を確かめる。
- 保管の file は消さないので、容量は増え続ける。
- image は 3.6GB あり、production 向けではない。
- catalog は profile で分かれていないので、work の doctor には `not installed` の warning が 3 つ出る
  (report-only)。

## 検証

`scripts/test-otel-backend.sh`: personal で 4 つの file が apply され work ではされない(work が持つ自前の file は
byte 単位で不変)、managed-by の見出し(dashboard は description)、compose file が YAML として parse でき定義が pin
どおり。pin とは別に、定義が守る性質も確かめる: image が版と digest の両方で固定、すべての port が `127.0.0.1`
だけ、host の path は許可した bind だけ(compose の directory の下を読み取りだけで、保管の directory を `/archive` に
書き込み可で、どれも `create_host_path: false`)、named volume の宣言の中身が空、Prometheus が delta の metric を
変換する指定、Collector が bind した保管の設定を読む指定、権限を広げる key(`privileged`・`network_mode` など)が
無い、restart policy。保管の設定は、名前が `*/archive` の pipeline を signal ごとに 1 つずつ足すだけで、`otlp` から
processor なしで file に書き、file は `/archive` の下の JSON、期間の上限なし、`max_backups` が 0(全部残す)。provider は
bind した dashboard の directory を指し、UI での変更を拒む。dashboard は strict な JSON の object で、uid が決まっていて、
どの datasource の参照も `loki`・`prometheus`・`tempo` の uid を持つ object(名前の文字列は不合格)。保管の bind は
ちょうど 1 つ。mode が file 0644 / directory 0755。container runtime とは
通信しない。doctor の分岐は `test-doctor.sh`。
