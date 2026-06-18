---
name: agent-memory
description: エージェントのドメイン記憶（memory/<domain>/）を構造化して管理する。save（記録）/ recall（参照）/ promote（確証昇格）/ maintain（棚卸し）を提供。Triggers on：「記憶を保存」「記憶を参照」「memory に記録」「agent-memory」。bootstrap-domain-map と run-cycle はメモリ書き込み・読み込みを本スキルに委譲する。
---

# agent-memory

エージェントの**ドメイン記憶**（`memory/<domain>/`）の読み書きを一箇所に集約する共通スキル。frontmatter・type・confidence・INDEX・重複排除・リンクの規律をここで担保する。

> 記憶の設計・ライフサイクルは claude-flywheel の `docs/agent-memory.md`。実行時は本スキルの規約に従えば足りる。
> 扱うのは**エージェントrepo内の `memory/`**（Git追跡・共有・レビュー対象）。個人ローカルの公式 Claude Code memory（`~/.claude/...`）とは別物で、そちらには書かない（使い分けは docs 参照）。

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
- `run-cycle`: 着手・レビュー前に **recall**、学習フェーズで `experience` / 新 `tacit` を **save**。

## 注意
- 粒度は小さく（1 事実 1 ファイル）保ち、recall と更新を容易にする。
- `confidence` を必ず付け、コードからの確証と未確認の推定を区別する。
