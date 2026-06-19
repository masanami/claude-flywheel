# docs

claude-flywheel の設計ドキュメント置き場。

| ドキュメント | 内容 | ステータス |
| --- | --- | --- |
| [challenges.md](./challenges.md) | 課題・テーマ（現場の具体課題 / Why） | ドラフト |
| [requirements.md](./requirements.md) | 要件定義（何を満たすべきか / What） | ドラフト |
| [agent-memory.md](./agent-memory.md) | エージェントmemory運用方針（地図・暗黙知・経験） | ドラフト |
| [architecture.md](./architecture.md) | アーキテクチャ・実現方式（どう作るか / How） | ドラフト |
| [challenge-ledger-format.md](./challenge-ledger-format.md) | 課題台帳の記入形式（人間記入欄＋分類欄） | ドラフト |

> 要件（What）とアーキテクチャ（How）を分離して管理する。本ディレクトリではまず要件を固め、合意後にアーキテクチャを別ドキュメントで設計する。

## 配布形態（fleet：複数の独立エージェントを作る土台）

claude-flywheel は **Claude Code プラグイン**として配布し、1 つのプラグインから**プロジェクトごとに独立した複数のエージェント（fleet）** を作る。構成は 3 層（[architecture.md §1.1/§4](./architecture.md)）。

| 層 | 配置 | 中身 |
| --- | --- | --- |
| 機械（プラグイン） | claude-flywheel: `skills/` `templates/` `docs/` `.claude-plugin/` | スキル群・雛形・設計（全エージェント共通の土台） |
| 各エージェント（state＋harness） | エージェントごとの独立リポジトリ | `challenge-ledger.md` `positions/` `memory/` `runtime/` ＋ 独自ハーネス |
| 共有課題ソース（intake） | 共有リポジトリ/ドキュメント | 人間が課題を集約する単一の入口（各エージェントが自分の分だけ取り込み） |

## スキル（`skills/`）

| スキル | 用途 |
| --- | --- |
| [flywheel-init](../skills/flywheel-init/SKILL.md) | エージェントのリポジトリに状態を初期化（scaffold） |
| [bootstrap-domain-map](../skills/bootstrap-domain-map/SKILL.md) | ドメイン地図づくり → ポジション案・記憶 seed |
| [run-cycle](../skills/run-cycle/SKILL.md) | 自走サイクル1周（観測→…→学習→報告） |
| [agent-memory](../skills/agent-memory/SKILL.md) | ドメイン記憶の構造化管理（save/recall/promote/maintain） |

## テンプレート（`templates/` ＝利用先に scaffold する雛形）

| テンプレート | 用途 |
| --- | --- |
| [CLAUDE.md](../templates/CLAUDE.md) | エージェントのベースライン（ポジション要約・記憶INDEX参照・recall手順） |
| [challenge-ledger.md](../templates/challenge-ledger.md) | 課題台帳の雛形 |
| [position.md](../templates/position.md) | ポジション定義の雛形 |
| [runtime/README.md](../templates/runtime/README.md) | 自律実行ランタイム設定の雛形 |
