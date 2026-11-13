# local の OpenTelemetry backend(`otel-backend` module、#514 / #517 / #520)

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
| `environment` | `PROMETHEUS_EXTRA_ARGS: --enable-feature=otlp-deltatocumulative --storage.tsdb.retention.time=365d` | 下の「metric の temporality」と「保存期間」 |
| `environment` | `LOKI_EXTRA_ARGS` と `TEMPO_EXTRA_ARGS`(保持の指定) | 下の「保存期間」 |
| `environment` | `OTELCOL_EXTRA_ARGS: --feature-gates=exporter.file.nativeCompression --config=file:/otel-lgtm/otelcol-archive.yaml` | image の Collector の設定に、保管の pipeline を重ねる。gate は保管の zstd に要る(下の「生データの保管と読み戻し」) |

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
   ls -la ~/.local/share/otel-lgtm/archive                                # telemetry が届くと *.jsonl.zst ができる
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

Claude Code は、managed な `~/.claude/settings.json` が送る(#523。`enableClaudeTelemetry`)。送り先は repo に入れず、
`~/.config/dotfiles/claude-telemetry.local` に 1 行で書いてから `chezmoi apply` する:

```text
http://127.0.0.1:4318
```

`localhost` は使わない。この Mac の `localhost` は `::1` を先に引き、Collector は `127.0.0.1` でしか待ち受けない。
service の名前は `claude-code`。送る中身と止め方は [claude-settings](claude-settings.md) の「telemetry」。

実測(Claude Code 2.1.322、2026-11-11): この設定で `claude -p` を 1 回動かすと、Loki に event(`user_prompt`・
`api_request`・`assistant_response` など)、Prometheus に metric(`claude_code_token_usage_tokens_total` など。job は
`claude-code`)が届き、保管の file にも入った。prompt と応答の本文は `<REDACTED>` で、長さだけが残る。event の名前は、
Loki の structured metadata では `claude_code.` を付けない形なので、`{service_name="claude-code"} | event_name="user_prompt"`
のように絞る。

確かめ方:

- trace は、Tempo の検索に TraceQL の `{}` を渡す(TraceQL なしの検索では出ない)。
- event の名前(`codex.sse_event` など)は Loki の stream の label ではなく structured metadata なので、LogQL では
  `{service_name="codex_exec"} | event_name="codex.sse_event"` のように絞る。
- 届いていないときは、Collector の受付と送信の数を Prometheus で見る(`otelcol_receiver_accepted_*_total` と
  `otelcol_exporter_send_failed_*_total`)。

### metric の temporality

Codex は metric をすべて delta の temporality で送る(61 種類すべてで確認)。Prometheus の OTLP の受け口は、既定では
delta を受け付けず、`invalid temporality and type combination` で拒否する(#517 で確認。log と trace は届くのに、metric
だけが Collector の送信で失敗する)。Prometheus の `--enable-feature=otlp-deltatocumulative` で、取り込みのときに
cumulative に直す(使い捨ての container で、捕まえた Codex の payload が受け付けられることを確かめた)。
`test-otel-backend.sh` がこの指定を pin する。

- image の Collector の build にも、delta を変換する processor(`delta_to_cumulative`)はある。#517 の時点では、名前の
  下線を見落として「無い」と判断していた(2026-11-11 に訂正)。Prometheus の側で直す今の形で動くので、変えていない。

- 変換の状態は Prometheus の memory にあり、container を作り直すと counter は 0 から数え直す(`rate()` /
  `increase()` は reset として扱う)。
- Codex の resource には process を区別する attribute が無いので、同じ service の複数の process の値は 1 つの系列に
  足し合わされる。

## dashboard

Grafana の「AI agents」folder に、「AI agents (Codex)」(uid `ai-agents-codex`)と「AI agents (Claude Code)」
(uid `ai-agents-claude-code`。#525)を provisioning する。

### Codex

| 段 | panel | 出どころ |
| --- | --- | --- |
| 概要 | 会話・API request・API request の失敗・input / output / cached token(表示している期間の合計) | Loki |
| token と request | token(model と種類ごと)、API request(endpoint と status ごと) | Loki |
| 応答の速さと turn | turn の TTFT(p50 / p95)、turn の数(model ごと) | Loki |
| tool | tool の呼び出し(tool と成否ごと)、tool の所要時間(p95) | Loki |
| 最近の動き | 会話の開始、失敗した request、trace | Loki、Tempo |

- 上の `service` の変数で service を絞る(既定は `codex` で始まるもの全部)。
- 正本は dotfiles の JSON。Grafana の UI での変更は保存できない(provider の `allowUiUpdates: false`)。変えるときは
  `private_dot_config/otel-lgtm/grafana/dashboards/` の JSON を直して apply する。Grafana は 30 秒ごとに読み直す。
  provider は directory の file をすべて読むので、dashboard を足すときは module の paths と `test-otel-backend.sh` の
  一覧にも足す。
- datasource は image が provisioning する `loki`・`prometheus`・`tempo` を uid で指す。
- 数は log から数える。`codex exec` は短命の process で、metric は終わるときに 1 回だけ delta で届く。Prometheus の
  `increase()` は系列の最初の値を増分として数えず、delta の変換の状態は Prometheus を起動し直すと 1 から数え直すので、
  metric の増分は実際の回数より小さくなる(実測: 2 回の run で `codex_conversation_turn_count_total` が 1 → 1、増分 0)。
  metric は Prometheus に残るので、所要時間の分布などは Grafana の Explore で見る。
- Codex の event と attribute(LogQL で使うもの): `codex.conversation_starts`(model・reasoning_effort・originator・
  approval_policy・sandbox_policy)、`codex.api_request`(endpoint・http_response_status_code・success・duration_ms)、
  `codex.sse_event` の `event_kind="response.completed"`(input / output / cached / reasoning_token_count)、
  `codex.turn_ttft`(duration_ms)、`codex.tool_result`(tool_name・success・duration_ms)。

### Claude Code

| 段 | panel | 出どころ |
| --- | --- | --- |
| 概要 | prompt のあった session・prompt・API request・API error・cost・output token(表示している期間の合計) | Loki |
| token と cost | token(model と種類ごと)、cost(model ごと) | Loki |
| 応答の速さ | TTFT(p50 / p95)、API request の所要時間(p50 / p95) | Loki |
| tool | tool の呼び出し(tool と成否ごと)、tool の許可(判定と出どころごと)、tool の所要時間(p95) | Loki |
| 最近の動き | tool の呼び出し(tool の入力を含む)、API error | Loki |

- `service` の変数は `claude-code` で始まるもの全部(Desktop の Code tab の session は `claude-code-desktop`)。
- 数は Codex と同じく log から数える。cost は Claude Code が見積もった API の料金で、plan で使うときは請求額ではない。
- session の数は、`user_prompt` の `session_id` の種類の数(prompt を 1 つも送らない session は数えない)。
- trace は送っていない(beta。[claude-settings](claude-settings.md) の「telemetry」)ので、trace の panel は無い。
- Claude Code の event と attribute(LogQL で使うもの。2.1.322 で実測。`api_error` はまだ届いていないので Claude Code の docs による): `user_prompt`(session_id・prompt_length)、
  `api_request`(model・input / output / cache_read / cache_creation_tokens・cost_usd・duration_ms・ttft_ms)、
  `api_error`(model・status_code・attempt・error)、`tool_result`(tool_name・success・duration_ms・tool_input)、
  `tool_decision`(tool_name・decision・source)。event の名前は structured metadata の `event_name` で、`claude_code.`
  を付けない。

## 保存期間

telemetry は、backend も保管の file も 1 年残す(#520)。image の既定では、Prometheus は 15 日、Tempo は 14 日で消え、
Loki は消さない。

| 対象 | 指定 | 実効の値(使い捨ての container で確認) |
| --- | --- | --- |
| Prometheus(metric) | `PROMETHEUS_EXTRA_ARGS` に `--storage.tsdb.retention.time=365d` | `storageRetention: 1y` |
| Loki(log) | `LOKI_EXTRA_ARGS` に `-store.retention=365d -compactor.retention-enabled=true -compactor.delete-request-store=filesystem` | `compactor.retention_enabled: true`、`limits_config.retention_period: 1y` |
| Tempo(trace) | `TEMPO_EXTRA_ARGS` に `-backend-scheduler.provider.work.compaction.block-retention=8760h -backend-worker.compaction.block-retention=8760h` | 2 か所の `block_retention` が `8760h` |
| 保管の file | 保管の設定の `rotation.max_days: 365` | 下の「生データの保管と読み戻し」 |

- 値は image の起動 script が空白で引数に分けて、各 backend の起動の引数の末尾に足す。
- Prometheus の `--storage.tsdb.retention.time` は、3.15 で DEPRECATED になった(設定 file の項目が推奨)。この版では
  動く。image を更新するときは、flag が残っているかを確かめる(下の「image の更新」)。
- Loki は、compactor の保持を有効にしないと `-store.retention` が効かない(flag の help のとおり)。期間を過ぎた
  chunk は、compactor が既定の 2 時間の猶予の後に消す。
- Tempo 3 は 1 つの process(`target: all`)で動き、`block_retention` が backend scheduler と backend worker の 2 か所に
  ある。どちらが消す側かを決め打ちせず、両方を指定する。
- `test-otel-backend.sh` が、4 つとも 1 年であることを確かめる(どれか 1 つだけ期間が違う状態を防ぐ)。
- 実効の値の確かめ方(container の中から):

  ```sh
  docker exec otel-lgtm curl -s http://127.0.0.1:9090/api/v1/status/runtimeinfo | grep -o '"storageRetention":"[^"]*"'
  docker exec otel-lgtm curl -s http://127.0.0.1:3100/config | grep -E '^\s+(retention_enabled|retention_period):'
  docker exec otel-lgtm curl -s http://127.0.0.1:3200/status/config | grep -E '^\s+block_retention:'
  ```

  Loki は `retention_period` を 2 行出す。`1y` が `limits_config` の値で、`0s` は今の storage(tsdb と compactor)では使われない
  `table_manager` の項目。

容量(2026-11-11 の観測): docker の data は VM の別の disk(`/var/lib/docker`、30GB)にあり、使用は 4.0GB(image 3.6GB、
backend の volume 0.7GB)。1 年でどれだけ増えるかは未確認。`colima ssh -- df -h /var/lib/docker` で見る。足りなく
なったら `colima stop` の後に `colima start --disk <GB>` で大きくする(増やすことしかできない)。

## 生データの保管と読み戻し

いずれ別の server を立てて収集し直すときのために、Collector が受け取った telemetry を、そのまま host の
`~/.local/share/otel-lgtm/archive/` に書く(#517)。backend の volume や VM を作り直しても残る。

- 書くのは image の Collector に重ねた 3 つの pipeline(`traces/archive`・`metrics/archive`・`logs/archive`)。receiver は
  `otlp` だけで processor を通さないので、Codex が送ったままの形になる。image の既存の pipeline の定義には触れず、
  名前の違う pipeline を足すだけ(Collector の設定の重ね方では、list は置き換わり、map は足される)。
- file は signal ごとに `traces.jsonl.zst`・`metrics.jsonl.zst`・`logs.jsonl.zst`。中身は改行区切りの OTLP JSON(1 行が
  1 回の export)を、標準の zstd で圧縮したもの(#527)。`zstd -d` で元の改行区切りの JSON に戻る。
  - 圧縮するのは、Codex の trace が多いため。圧縮しないと 1 日に約 100MB 増え、1 年で約 36GB になる見込みだった
    (2026-11-11〜13 の観測。量の 8 割は `handle_responses`・`receiving`・`append_items` などの内部の span)。
  - 標準の zstd で書くには、Collector の feature gate `exporter.file.nativeCompression`(Alpha、既定は off)が要る。
    compose の `OTELCOL_EXTRA_ARGS` で渡す。gate が無いと、`compression: zstd` は batch ごとに圧縮して長さを前に付ける
    独自の形で書き、`zstd -d` でも読めない(upstream の README)。
  - gate があると、batch ごとに 1 つの zstd の frame を書く。今書いている file もいつでも展開でき、Collector が
    再起動した後は同じ file に足していく(この image の Collector で実測)。
  - gate は compose が container を作るときにだけ渡る。保管の設定や compose を変えた apply の後は、すぐに
    `docker-compose -f ~/.config/otel-lgtm/compose.yaml up -d` で作り直す。作り直す前に container が再起動すると、
    新しい保管の設定を gate なしで読み、読めない形で書きうる。doctor は container の環境変数を定義と比べる
    (下の「doctor」)。
- 64MB(圧縮した後の大きさ。この image の Collector で実測)を超えると、`<名前>.jsonl-<UTC の時刻>-size.zst` に
  回して新しい file に書く。**回した file は 1 年残す**(#520):
  - `max_days: 365` で、回した file を、名前の時刻(回した時刻)から 365 日で消す(この image の Collector で実測:
    `max_days: 1` の設定に 2 年前の時刻の名前の file を置くと、次に回したときに消え、新しく回った file は残った。
    #527 で、zstd の名前の file でも同じく消えることを確かめた)。
  - file の中の最も古い data は、1 年より少し古いことがある(回すまでの間の data が 1 つの file に入るため)。
  - 今書いている file は、期間では消えない。64MB に達するまで回らないので、量が少ないと 1 年より長く残る。
  - 残す数(`max_backups`)は 0 にした。0 は回した file を全部残す(実測、#517: 1MB で回す設定で、0 は回した 7 つを
    全部残し、1 は最新の 1 つだけを残した。upstream の README には 0 の意味が書かれていない)。0 以外の数は、期間より
    先に古いものを消す。
- 容量の目安: 圧縮する前の量は、短い `codex exec` の 1 回で約 1.1MB(trace が約 0.88MB、metric が約 0.18MB、log が
  約 0.03MB。2026-11-11 の実測)。skill が起動した review(effort が xhigh)の 1 回では、数分で約 8MB になった
  (ほとんどが trace)。zstd では、回した traces の file 1 つ(66.9MB)が 3.1MB になった(約 21 分の 1。#527 で、この
  image の Collector に同じ data を送って実測)。2026-11-11〜13 の使い方なら、traces は 1 日に約 5MB、1 年で約 2GB の
  見込み。大きさと最後に書いた時刻は doctor が出す(`du -sh ~/.local/share/otel-lgtm/archive` でも見られる)。
- Collector の自分の metric(`prometheus/collector` の scrape)は入らない。agent から届いたものだけ。

#527 より前の file(`*.jsonl` と、回した `<名前>-<UTC の時刻>-size.jsonl`)は、圧縮しないまま残る。今の設定の名前と
合わないので、Collector は期間でも消さない。doctor は、その数を分けて出す。

- 小さくするなら、container を作り直した後(doctor が「environment matches」を出し、`*.jsonl` に書かれなくなった後)に
  gzip にする。読み戻しの `otlpjsonfile` receiver は gzip を読める(`compression: gzip`)。

  ```sh
  cd ~/.local/share/otel-lgtm/archive && gzip -- *.jsonl
  ```

- gzip にした file(`*.jsonl.gz`)も期間では消えない。要らなくなったら人が消す。

読み戻すとき(将来の server の Collector で):

- 保管に残るのは、おおむね直近の 1 年分。回した file は、名前の時刻(回した時刻)から 365 日で消える。今書いている
  file と、回した file の中の古い data は、それより少し長く残る(上の注意)。backend の data も 1 年で消える。
- `otlpjsonfile` receiver(opentelemetry-collector-contrib)が、改行区切りの OTLP JSON を読める(upstream の README)。
  signal ごとに receiver を分け、file を `include` で指す。この image の Collector の build にも `otlp_json_file` の名前で
  入っている(#517 の時点では名前の下線を見落として「無い」としていた。2026-11-11 に訂正)。
- この receiver が読める圧縮は gzip だけで、zstd は読めない(upstream の README)。`*.zst` は、先に `zstd -d` で展開して
  から読ませる(#527 で、この image の Collector が書いた file を展開し、送った行と span がすべて戻ることを確かめた)。
  #527 より前の `*.jsonl` はそのまま、`*.jsonl.gz` は `compression: gzip` で読める。
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
   こと、zstd の gate が在ること)。

   ```sh
   docker run --rm -i --entrypoint sh grafana/otel-lgtm@sha256:<digest> -c \
     'cat > /tmp/a.yaml && cd /otel-lgtm && ./otelcol-contrib/otelcol-contrib validate \
        --feature-gates service.profilesSupport --feature-gates=exporter.file.nativeCompression \
        --config=file:./otelcol-config.yaml --config=file:/tmp/a.yaml' < ~/.config/otel-lgtm/otelcol/archive.yaml
   docker run --rm --entrypoint /otel-lgtm/otelcol-contrib/otelcol-contrib grafana/otel-lgtm@sha256:<digest> \
     featuregate | grep exporter.file.nativeCompression
   ```

   `--feature-gates service.profilesSupport` は、image の設定にある profiles の pipeline のために要る(image の
   `run-otelcol.sh` も付けて起動する。付けないと validate がその pipeline で止まる)。
   `exporter.file.nativeCompression` は Alpha の gate(0.164.0 で確認)。無い gate を渡すと、Collector は
   `no such feature gate` で起動しない(0.164.0 で確認)。gate が無くなっていたら、upstream の README で、標準の zstd で
   書く方法がどう変わったかを確かめてから、compose と保管の設定を合わせて更新する。

4. 新しい image の Prometheus・Loki・Tempo が保持の指定を受け付けるかを確かめる(上の「保存期間」の command を、
   使い捨ての container で実行する。Prometheus の flag は DEPRECATED なので、残っているかを見る)。
5. `private_dot_config/otel-lgtm/compose.yaml` の版と digest、`scripts/test-otel-backend.sh` の pin を、同じ PR で
   変える。
6. merge の後、`chezmoi apply` してから `docker-compose -f ~/.config/otel-lgtm/compose.yaml up -d` を実行する
   (container が新しい image で作り直される。volume と保管の file は残る)。

設定の file(保管の設定・provider)を変えたときは、`docker-compose -f ~/.config/otel-lgtm/compose.yaml up -d
--force-recreate` で作り直す(どちらも起動のときにだけ読まれる。file の bind は作成のときの file を指し続けるので、
`restart` では新しい中身が見えないことがある)。dashboard の JSON は作り直さなくても読み直される。

## data

- backend の data は named volume `otel-lgtm_data`(VM の disk の中)。container や VM を再起動しても残る。
- 消すとき: `docker-compose -f ~/.config/otel-lgtm/compose.yaml down -v`(container と volume を消す)。VM ごと
  消すなら `colima delete`。**どちらも保管の file には触れない**(host にあるため)。保管の file は、回した file が
  365 日で消える(上の「生データの保管と読み戻し」)ほかは、`~/.local/share/otel-lgtm/archive/` を人が消すときだけ消える。
- backend と保管の file は、どちらも 1 年で消える(上の「保存期間」。保管は回した file の単位で、今書いている file は期間
  では消えない)。volume の増え方は未確認(起動の直後で約 0.7GB)。
- telemetry には tool の出力の抜粋が入りうる(agent-tools#652)。data は手元に留め、外へは送らない。外部の
  backend への転送と項目の絞り込みは、この module の範囲外。

## profile

- **personal のみ列挙**。work には配布しない(2026-11-11 に決定)。個人の machine の間でだけ、agent の telemetry の
  送り先と方式をそろえる(どの agent も手元の Collector の `127.0.0.1:4318` へ OTLP/HTTP で送る)。work と共通にする
  ための capability などは作らない。
- module 列挙だけで gate する(capability は無い。herdr-config と同型)。managed-by の見出しを持つので(dashboard の
  JSON は description に持つ)、profile 切替で非 active になった残置は doctor の managed-path orphan scan が拾う。

## doctor

「otel backend」section(report-only)。module が active な profile で、まず compose file の presence を見る。無ければ
action(`mkdir -p ~/.config` と `chezmoi apply` の手順)で、ほかは見ない。managed file の drift は managed drift section が
出す。

compose file があるときは、実行時の状態と保管の directory を**読むだけ**で確かめる(何も起動せず、何も変えない)。
使う command は `docker ps`・`docker inspect`(image と port、環境変数の 2 回)・`colima ssh -- mount` で、どれも期限付き
(`bounded_probe`)。

| 見ること | 結果 |
| --- | --- |
| docker が PATH にあるか | 無ければ「未確認」の item(catalog の section が未導入を出す) |
| docker が daemon に届くか | 届かなければ action(保管の directory を作って `chmod 700` し、2 つの mount で `colima start`)で、container と VM の確認はしない。期限内に答えなければ「未確認」の warn |
| container があり、running か | 無い・止まっているなら action(`docker-compose -f <file> up -d`)。image と port は見ないが、VM の mount と常駐の登録は続けて見る |
| container の image が、定義の固定と同じか | 違えば action(managed file が進んだ後に作り直していない、など) |
| container の環境変数に、定義の `environment` がすべて同じ値であるか(#527) | 違う・無い変数があれば、その名前だけを並べた action(`up -d`。値は出さない)。`OTELCOL_EXTRA_ARGS` が違うときは、保管が読めない形になりうることも書く。image の持つほかの変数はあってよい。答えが取れない、または定義の `environment` が 1 行の文字列の map でなければ「未確認」 |
| 公開した port が、すべて `127.0.0.1` か | 1 つでも違えば action(`0.0.0.0`・空の address・IPv6 の any)。公開が 0 なら warn。port の JSON は、strict な 1 つの object と読めたときだけ使う(下の注) |
| VM の host の share が、上の 2 つだけか | 2 つだけで設定が `ro`、保管が `rw` なら ok。ほかの share、設定が `rw`、保管が `ro`、2 つのどちらかが無い、のどれかなら、それを全部並べた 1 つの action(`colima stop` の後、保管の directory を作って `chmod 700` し、2 つの mount で起動し直す。`colima start --mount` は VM の mount を指定どおりに置き換えるので、どれもこの手順で直る)。share の行で形が読めないものがあれば「未確認」 |
| Colima が login の常駐に登録されているか | どちらでも中立の item(常時起動にするかは選べる) |
| 保管の directory | 無ければ action(`mkdir` と `chmod 700`)、0700 でなければ action(`chmod 700`)。一覧できなければ「未確認」。file が無ければ item、あれば数・大きさ・最後に書いた時刻の item(中身は読まない。`du` が失敗したら大きさは「未確認」)。数えるのは `*.jsonl.zst`(回した `*.jsonl-*.zst` も)と、#527 より前の `*.jsonl`・`*.jsonl.gz` で、前の 2 つはその数を分けて出す(期間では消えないため) |

- daemon に届かないときの手順に 2 つの mount と `--ssh-config=false` を付けているのは、VM が無い状態で裸の
  `colima start` を実行すると、既定の動作(`$HOME` の mount と `~/.ssh/config` の書き換え)で新しい VM が作られるため。
  VM が既にあるときは、mount を指定どおりに置き換える(保存された設定と同じなら、その繰り返し)。
- `chmod 700` を `colima start` より先にするのは、container が VM と一緒に戻って(restart policy)、すぐに保管に書き
  始めるため。
- `docker-compose up` を手順に持つ action(container が無い・止まっている、image や環境変数の違い、広い port)は、section の最後に
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
- 保存期間は 1 年なので、それまでは容量が増え続ける。保管の traces は、今の使い方で 1 年に約 2GB の見込み(上の
  「生データの保管と読み戻し」)。backend の 1 年分の量は未確認で、Tempo の増え方は #528 で扱う。
- 保管の zstd は Alpha の feature gate に頼る。image を更新するときに gate の有無を確かめる(上の「image の更新」)。
- apply の後、container を作り直す前に再起動が入ると、gate なしで新しい保管の設定を読み、`zstd -d` で読めない形で
  書きうる。doctor が環境変数の違いを action にするので、すぐに `up -d` で作り直す。
- 1 年を過ぎた telemetry は、backend からも保管からも消えていく(保管は回した file の単位で、今書いている file は期間
  では消えない)。将来の server へ読み戻せるのは、おおむね直近の 1 年分。
- image は 3.6GB あり、production 向けではない。
- catalog は profile で分かれていないので、work の doctor には `not installed` の warning が 3 つ出る
  (report-only)。

## 検証

`scripts/test-otel-backend.sh`: personal で 4 つの file が apply され work ではされない(work が持つ自前の file は
byte 単位で不変)、managed-by の見出し(dashboard は description)、compose file が YAML として parse でき定義が pin
どおり。pin とは別に、定義が守る性質も確かめる: image が版と digest の両方で固定、すべての port が `127.0.0.1`
だけ、host の path は許可した bind だけ(compose の directory の下を読み取りだけで、保管の directory を `/archive` に
書き込み可で、どれも `create_host_path: false`)、named volume の宣言の中身が空、Prometheus が delta の metric を
変換する指定、Prometheus・Loki・Tempo が 1 年残す指定(引数ごとに完全一致)、Collector が zstd の gate を有効にして
bind した保管の設定を読む指定、権限を広げる key(`privileged`・`network_mode` など)が無い、restart policy。保管の設定は、名前が `*/archive` の pipeline を signal ごとに 1 つずつ足すだけで、`otlp` から
processor なしで file に書き、file は `/archive` の下の zstd の JSON(`*.jsonl.zst`、`compression: zstd`)、`max_days` が
365、`max_backups` が 0。provider は
bind した dashboard の directory を指し、UI での変更を拒む。dashboard は strict な JSON の object で、uid が決まっていて、
どの datasource の参照も `loki`・`prometheus`・`tempo` の uid を持つ object(名前の文字列は不合格)。保管の bind は
ちょうど 1 つ。mode が file 0644 / directory 0755。container runtime とは
通信しない。doctor の分岐は `test-doctor.sh`。
