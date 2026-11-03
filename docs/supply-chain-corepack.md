# Supply Chain: Corepack

`supply-chain-corepack` module の方針。Corepack の availability と `packageManager` field の扱いを `corepackMode` capability で段階制御する。

## Mode

```text
off     何も管理しない。doctor も Corepack を検査しない前提の profile 向け。
report  doctor が Corepack の availability と version を表示するだけ。
enable  明示 opt-in。`corepack enable` を実行済みであることを前提に doctor が shim を確認する。
```

- 現在の全 profile は `report`。
- `enable` にしても、dotfiles の script が `corepack enable` を実行することはない。有効化は必ず手動で行う。

```sh
corepack enable
```

## `packageManager` field の方針

- project ごとに `package.json` の `packageManager` field で package manager を exact version で pin する。

```json
{
  "packageManager": "pnpm@10.0.0"
}
```

- pin は project 側の責務。dotfiles は global に package manager を強制しない。
- range 指定は避け、上の例のような exact version で pin する。

## update policy との関係

`docs/update-policy.md` の「自動 upgrade を避ける」方針と整合させる。

- Corepack は `packageManager` の pin に従って package manager を取得する。pin が exact なら、勝手に新しい version へ上がることはない。
- pin の更新は project 側での明示的な変更として行う。Corepack 側の自動 upgrade 機構には依存しない。
- 注意: `corepack enable` 後、pin された package manager の初回実行時に Corepack が network から該当 version を取得する。これは `enable` の opt-in に含まれる副作用として扱う。

## doctor の検査

- `corepackMode` と Corepack の availability / version を表示する。
- `off` では検査をスキップする。
- `enable` では pnpm / yarn の shim が解決できるかを report-only で確認する。見つからない場合は `corepack enable` を手動実行するよう warning を出すだけで、実行はしない。
- corepack が PATH に無いときは、PATH の node の版で分ける(#500)。Node 25 から corepack は node に同梱されないので、Node 25 以降では無いのが普通の状態になる。
  - `report`: Node 25 以降なら warning にせず、「使うなら `npm i -g corepack`」と案内する。Node 24 以下、または node の版を読めないときは warning。
  - `enable`: Node 25 以降でも warning (pnpm / yarn の shim には corepack が要る)。`npm i -g corepack` の後に `corepack enable` を手動で実行するよう案内する。
- preflight の必要 command の一覧も同じに扱う。Node 25 以降の node では、corepack が無くても `report` / `off` では warning にせず、`enable` では warning を残す。

## Node 25 以降で corepack を使う

Node 25 以降は corepack を別に入れる。dotfiles は install しない。

```sh
npm i -g corepack
corepack enable
```

- npm の global は node の版ごとの prefix に入るので、node の major を上げたら入れ直す。
- software catalog には載せない。doctor の catalog の検査は npm の global の `corepack` を runtime の領分として undeclared にしない。

## 対象外

- Corepack の暗黙 enable(script からの `corepack enable` 実行)。
- package manager の自動 install / upgrade。
- project ごとの pin の強制。
- private registry / token / auth config。
