# SSH

SSH 設定(`~/.ssh/config`)の管理規約。dotfiles は **public-safe な骨格だけ**を
管理し、秘密鍵・host 名などの機密は一切持たない。設計の正本と論点は issue #17。

## 何を管理し、何を管理しないか

| 対象 | 置き場所 | 管理 |
| --- | --- | --- |
| public-safe な `~/.ssh/config` の骨格(public host への agent 設定 + 末尾 Include) | public repo(`private_dot_ssh/config.tmpl`) | ✅ chezmoi(**personal profile のみ**) |
| machine 固有の host(社内 VM、bastion、private IP など)、host ごとの調整 | `~/.ssh/config.local` | ❌ 非コミット・管理外([local-overrides](local-overrides.md)) |
| 秘密鍵 / 公開鍵 / `known_hosts` | `~/.ssh/`(各マシン) | ❌ 管理外(鍵は 1Password、再セットアップ時に再配布) |

`~/.ssh` 自体は `private_dot_ssh` として 0700 で管理する(SSH が要求する権限)。chezmoi は
managed file 以外(鍵・`known_hosts`・`config.local`)を削除しないので、既存の鍵類はそのまま残る。

## 1Password SSH agent(capability gate)

1Password SSH Agent を使うかは `enable1PasswordSSH` capability で制御する(personal=true、
work-*=false)。`true` のとき managed config に `Host github.com` の `IdentityAgent`(1Password
の agent socket)だけを出力する。

- **`Host *` には付けない**。agent 設定を broad に出すと、接続先すべてに鍵リストを提示し得る。
  agent を使う host は **明示した host にだけ** scope する(github.com、その他は `config.local`)。
- agent socket のパス(`~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock`)は
  1Password 固定で **public-safe**。鍵そのものは含まない。
- `ForwardAgent` は出さない(広域有効化は安全境界を壊す)。

## managed-wins(末尾 Include)

managed config は末尾で config.local を Include する。ssh_config は **first-match-wins** なので、
managed の上のブロックが勝つ = **managed-wins**([local-overrides](local-overrides.md))。
`config.local` は managed が定義していない host を **追加する**用途に限る(managed の安全設定を
上書きさせない)。`config.local` が無くても SSH は壊れない(欠落 Include は無視される)。

```text
Host github.com
    IdentityAgent "...op-agent.sock"

Match all
Include config.local
```

**`Match all` が必須**。ssh_config の section は次の `Host`/`Match` まで続くので、`Include` を
`Host github.com` ブロックの**直後にそのまま**置くと Include がそのブロックに閉じ込められ、
config.local は **github.com に接続したときしか読まれない**(他 host が解決されない)。`Match all`
で global section に戻してから Include すると、config.local は全 host に効きつつ、上の managed
ブロックが先に評価されて勝つ(#121 で `ssh -G` 検証)。capability OFF で managed ブロックが
無いときは `Include config.local` 単体で既に global。

## 既存 `~/.ssh/config` からの移行

`enable1PasswordSSH` が有効な profile(personal)で `chezmoi apply` すると、`~/.ssh/config` は
managed 版に **置き換わる**。既存の host を失わないよう、apply の前に必ず次を行う。

1. **棚卸し**: 現 `~/.ssh/config` の中身を確認する(host alias、`IdentityAgent`、`HostName` 等)。
2. **backup / 退避**: machine 固有の host を `~/.ssh/config.local` に移す。
   ```sh
   cp ~/.ssh/config ~/.ssh/config.local   # まず丸ごと退避(現挙動を保てる)
   ```
   `config.local` は末尾 Include されるので、managed が定義しない host(社内 VM 等)はそのまま効く。
   managed が `Host github.com` を定義するため、github.com の agent は managed 側が勝つ。
3. **diff 確認**: `chezmoi diff ~/.ssh/config` で置き換え後の内容を確認する。
4. **apply**: `chezmoi apply ~/.ssh/config`(targeted)。
5. **検証**: `ssh -G github.com` と `ssh -G <自分の host>` で `identityagent` 等が期待通り解決するか確認する。

`preflight.sh` は ssh-1password が有効な profile で `~/.ssh/config` が存在するとき、置き換えと
`config.local` への退避を warning で促す(report-only、中身は読まない)。

## バックアップ

`~/.ssh/config.local` は git/chezmoi 管理外だが、暗号化バックアップの対象にできる
([private-backup](private-backup.md)、issue #60)。秘密鍵は 1Password が source of record。

## 関連

- [local-overrides](local-overrides.md) — managed-wins / local-wins の境界規約。
- [secrets](secrets.md) — 鍵・secret の供給方式(平文を repo に置かない)。
- [git-identity](git-identity.md) — context 別の Git 設定(SSH 署名は [git-signing 関連] 参照)。
