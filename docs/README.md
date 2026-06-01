# docs

claude-flywheel の設計ドキュメント置き場。

| ドキュメント | 内容 | ステータス |
| --- | --- | --- |
| [challenges.md](./challenges.md) | 課題・テーマ（現場の具体課題 / Why） | ドラフト |
| [requirements.md](./requirements.md) | 要件定義（何を満たすべきか / What） | ドラフト |
| [agent-memory.md](./agent-memory.md) | エージェントmemory運用方針（地図・暗黙知・経験） | ドラフト |
| architecture.md | アーキテクチャ・実現方式（どう作るか / How） | 未作成（TBD） |

> 要件（What）とアーキテクチャ（How）を分離して管理する。本ディレクトリではまず要件を固め、合意後にアーキテクチャを別ドキュメントで設計する。

## テンプレート（`templates/`）

| テンプレート | 用途 |
| --- | --- |
| [position.md](./templates/position.md) | ドメイン担当エージェントのポジション定義 |
| [challenge-ledger-format.md](./templates/challenge-ledger-format.md) | 課題台帳の記入形式（人間記入欄＋分類欄） |

## 関連

- [`/challenge-ledger.md`](../challenge-ledger.md) — 課題台帳の実体（人間が一箇所に記述）
- [`.claude/skills/bootstrap-domain-map/`](../.claude/skills/bootstrap-domain-map/SKILL.md) — ドメイン地図づくりのスキル
