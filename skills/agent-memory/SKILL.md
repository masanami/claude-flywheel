---
name: agent-memory
description: claude-flywheel エージェントの**ドメイン記憶**（リポジトリ内 memory/<domain>/ の map/tacit/experience/reference）を構造化して管理する。save/recall/promote/maintain を提供。主に run-cycle・bootstrap-domain-map からの委譲、または「ドメイン記憶を記録/参照」「agent-memory」と明示されたときに使う。汎用的な「覚えておいて/思い出して」（ユーザーや作業文脈の記憶）は対象外＝公式 Claude Code memory の領分。
---

# agent-memory

エージェントの**ドメイン記憶**（`memory/<domain>/`）の読み書きを一箇所に集約する共通スキル。frontmatter・type・confidence・INDEX・重複排除・リンクの規律をここで担保する。

> 記憶の設計・ライフサイクルは claude-flywheel の `docs/agent-memory.md`。実行時は本スキルの規約に従えば足りる。
> 扱うのは**エージェントrepo内の `memory/`**（Git追跡・共有・レビュー対象）。個人ローカルの公式 Claude Code memory（`~/.claude/...`）とは別物で、そちらには書かない。
> **汎用的な「覚えておいて／思い出して」（ユーザーの好み・作業文脈）は本スキルではなく公式 memory の領分**。本スキルは「このエージェントのドメイン知識・経験」専用（使い分けは docs 参照）。

## 格納規約

- **1 ファイル = 1 事実**。パス: `memory/<domain>/<type>-<slug>.md`（`<type>` ∈ `map` / `tacit` / `experience` / `reference`）。
- frontmatter:
  ```yaml
  ---
  name: <short-kebab-case-slug>
  description: <one-line。recall の関連判定に使う>
  domain: <ドメイン名>
  metadata:
    type: map | tacit | experience | reference
    sources: [<根拠ファイル / URL / 会話>]
    confidence: high | medium | low   # 推定か確証か（特に tacit）
  ---
  <本文。関連記憶は [[name]] でリンク>
  ```
- 各ドメインに `memory/<domain>/INDEX.md`（1 行/件: `- [<name>] <type>/<confidence> — <description>`）。

### experience 型の信号フィールド（自己改善ループ用）

`type: experience` の記憶には、内省ループ（[reflect](../reflect/SKILL.md)）が傾向を集計できるよう信号フィールドを足す。run-cycle の学習ステップが **append のみ**で記録し、評価・改修はしない（設計は `${CLAUDE_PLUGIN_ROOT}/docs/self-improvement.md`）。

```yaml
metadata:
  type: experience
  outcome: good | bad                 # この経験の評価
  target: skill:<name> | subagent:<name> | brief | position | recall | other  # どの資産の改善に効くか
  signal: <何が効いた/詰まったか 1行>
  recurrence: <同種が何回目か（任意。reflect が集計時に更新してよい）>
  confidence: high | medium | low
```

- bad は改修トリガー、good は再利用資産化・回帰ガード・recall 正例に使う（詳細は self-improvement.md §2）。

## 操作

### save（記録）
1. 記録する事実の `type` と `domain` を決める。
2. **重複チェック**: 同 domain の `INDEX.md` を見て、既存の同義エントリがあれば**新規作成せず更新**（`sources` / `confidence` を統合）。
3. `memory/<domain>/<type>-<slug>.md` を作成/更新し、frontmatter を付与。**推定は `confidence: low`**。
4. 関連する既存記憶へ `[[name]]` でリンク。
5. `INDEX.md` の該当行を追加/更新。
6. **秘密情報（認証・接続文字列）は記録しない。**

### recall（参照）
- 対象 `domain`（と任意のクエリ）を受け、`INDEX.md` から関連エントリを選び、本文をロードする。
- タスク着手・レビュー前の**前ロード**に使う。`confidence: low` は「未確証」として扱う。

### promote（確証昇格）
- 人間確認が取れた推定（主に `tacit`）の `confidence` を low → medium/high に上げ、`sources` に確認根拠を追記する。

### maintain（棚卸し）
- 古い・誤り・重複を整理（統合/削除）し、`INDEX.md` を同期する。**削除は人間承認のうえ**で行う。

## 委譲（他スキルからの利用）

- `bootstrap-domain-map`: 生成する `map` / `reference` / `tacit`（推定は low）を **save** で記録。
- `run-cycle`: 着手・レビュー前に **recall**、学習フェーズで `experience`（信号フィールド付き）/ 新 `tacit` を **save**。
- `reflect`: `experience(outcome)` を **recall** して傾向を集計し、改修採用後に「適用済み」を **save**（自己改善ループ）。

## 注意
- 粒度は小さく（1 事実 1 ファイル）保ち、recall と更新を容易にする。
- `confidence` を必ず付け、コードからの確証と未確認の推定を区別する。
