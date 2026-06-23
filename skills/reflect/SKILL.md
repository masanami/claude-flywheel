---
name: reflect
description: 自己改善（内省）ループを1周実行する。run-cycle が残した good/bad の記録（experience）を集計し、skill/サブエージェント/ブリーフ/ポジション/recall の改修を提案する。改修は提案までで人間承認まで適用しない。Triggers on：「内省して」「reflect」「ハーネスを改善」。run-cycle とは別に低頻度（N周ごと／しきい値到達／手動）で起動する。
---

# reflect

実行ループ（[run-cycle](../run-cycle/SKILL.md)）とは独立した**自己改善（内省）ループ**。蓄積した good/bad の記録から傾向を読み、**ハーネス自体（skill・サブエージェントのブリーフ・ポジション・recall）の改修を提案**する。

> 設計の詳細は claude-flywheel の `${CLAUDE_PLUGIN_ROOT}/docs/self-improvement.md`（2 層設計・good/bad の扱い・スコープ）。
> **run-cycle では改修しない**。run-cycle は good/bad を記録するだけ（step 5）。本スキルが低頻度で傾向を集計し改修を提案する（コストを抑えるための分離）。
> **改修は提案まで**。ハーネスの自己書き換えは影響が大きいため、適用は人間承認後（承認ゲート）。

## 前提

- 運用中で `memory/<domain>/` に `experience`（`outcome` 付き）が蓄積されている。
- experience に追加するフィールドの規約は agent-memory スキル（`experience` 型）。

## 入力（任意）

- 対象ドメイン（省略時は全ドメイン）。
- 集計窓（例: 直近 N 周 / 期間。省略時は未処理の experience 全部）。
- `--dry-run`: 提案のみで Issue 起票・記録もしない。

## 起動タイミング（毎周は回さない）

- **N サイクルごと**（`runtime/` のスケジュールで定義）。
- **しきい値到達**: 同種 bad の `recurrence ≥ 2`。
- **手動**: `/claude-flywheel:reflect`。

## 手順

### 1. 集計
- 対象ドメインの `experience`（`outcome: good|bad` 付き）を **agent-memory の recall** で集める。
- `target` と `signal` でグルーピングし、同種の `recurrence` を数える（必要なら experience の `recurrence` を更新）。

### 2. 抽出
- **bad**: `recurrence ≥ 2`（再発）を改修候補にする。単発 bad は様子見（次の再発で昇格）。
- **good**: 再現性がありそうな手順・レビュー観点（複数回 good）を**資産化候補**にする。

### 3. 分類（改修対象 = target）
改修対象を `target` 別に仕分ける。スコープの線引きが重要（`self-improvement.md §4`）:

| target | 実体 | 扱い |
| --- | --- | --- |
| `position` | `positions/<domain>.md` | 直接 diff 提案 |
| `recall` | `CLAUDE.md` の recall ヒント / INDEX の引き方 | 直接 diff 提案 |
| `brief` | サブエージェント／別セッションのブリーフ雛形 | 直接 diff 提案 |
| ローカル skill | エージェントrepo 内の独自スキル | 直接 diff 提案 |
| `skill:<plugin共通>` | **プラグイン本体の共通スキル**（run-cycle 等） | **編集不可** → upstream Issue |

### 4. 提案（承認ゲート）
- **エージェントrepo ローカル資産**（position / recall / brief / ローカル skill）: 具体的な **diff 案**を提示する。
  - bad → 修正 or ガードレール追加（再発防止）。
  - good → skill/パターンへ昇格、recall の正例として INDEX へ反映（再現）。
- **プラグイン本体の共通スキル**: 直接編集せず、**upstream（claude-flywheel）へ改善 Issue を起票**する案を提示する。
- **出力規約（AI 可読性）**: 内省レポート・diff 案・position/recall の更新で図を出す場合は **mermaid**、コードフェンスには言語タグを付ける（ASCII art は使わない）。規約は `${CLAUDE_PLUGIN_ROOT}/docs/authoring-style.md`。
- **【承認ゲート】** いずれの diff も**適用前に人間承認**。承認まで適用しない。

### 5. 記録（冪等）
- 採用された改善を `experience` に「**適用済み**」として **agent-memory の save** で記録（同じ記録から二重提案しないため）。
- 起票した upstream Issue の番号・リンクも記録する。

## 出力

- 内省レポート（再発 bad / 資産化候補 good / 提案 diff / upstream Issue 案）。
- 承認後: 更新された `positions/` `CLAUDE.md` ブリーフ雛形 / ローカル skill、`experience` の適用済み記録。

## 注意

- **改修は提案まで**。適用は人間承認後（ハーネスの自己書き換えは承認ゲート必須）。
- **プラグイン本体は読み取り専用**。共通スキルの改善は直接編集せず upstream Issue に倒す。
- good を捨てない（回帰ガード・再現の正例になる）。bad だけ見ると局所最適に陥る。
- 単発の bad で即改修しない（`recurrence ≥ 2` を基本線に、過剰な作り込みを避ける）。
