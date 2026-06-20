# <エージェント名>（claude-flywheel エージェント）

> claude-flywheel をベースにした自律エージェントのリポジトリ。
> このファイルはセッション開始時に自動ロードされる**ベースライン**。ここには要点だけ置き、詳細は載せず必要に応じて recall する（軽量に保つ）。

## ポジション（守備範囲）

- 定義: `positions/<domain>.md`
- 概要: <一言で。bootstrap / flywheel-init が記入>

## ドメイン記憶

- 索引: `memory/<domain>/INDEX.md`
- **詳細は全ロードしない**。関連分だけ `claude-flywheel:agent-memory` の **recall** で引く。
- 種別: `map`（地図）/ `tacit`（暗黙知）/ `experience`（経験）/ `reference`（参照）

## 課題

- 台帳: `challenge-ledger.md`（共有ソースから自分に関係する分だけ取り込み）

## 自走

- 1 周回す: `/claude-flywheel:run-cycle`
- 内省（低頻度・ハーネス改善）: `/claude-flywheel:reflect`（run-cycle が残した good/bad の記録を集計し改修提案）

## 注意

- この CLAUDE.md はベースラインのみ。大きな知識は memory に置き recall する。
- サブエージェント／別セッションへ委譲する場合、前提知識はブリーフに明記して渡す（CLAUDE.md は引き継がれない）。
