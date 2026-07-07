---
name: agent-memory
description: claude-flywheel エージェントの**ドメイン記憶**（リポジトリ内 memory/<domain>/ の map/tacit/experience/reference）を構造化して管理する。save/recall/promote/maintain を提供。主に run-cycle・bootstrap-domain-map からの委譲、または「ドメイン記憶を記録/参照」「agent-memory」と明示されたときに使う。汎用的な「覚えておいて/思い出して」（ユーザーや作業文脈の記憶）は対象外＝公式 Claude Code memory の領分。
---

# agent-memory

エージェントの**ドメイン記憶**（`memory/<domain>/`）の読み書きを一箇所に集約する共通スキル。frontmatter・type・confidence・INDEX・重複排除・リンクの規律をここで担保する。

> 実行時は本スキルの規約に従えば足りる。
> 扱うのは**エージェントrepo内の `memory/`**（Git追跡・共有・レビュー対象）。個人ローカルの公式 Claude Code memory（`~/.claude/...`）とは別物で、そちらには書かない。
> **汎用的な「覚えておいて／思い出して」（ユーザーの好み・作業文脈）は本スキルではなく公式 memory の領分**。本スキルは「このエージェントのドメイン知識・経験」専用。

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
    sources: [<根拠ファイル / URL / 会話。tacit は確証方法の明記が必須>]
    confidence: high | medium | low   # どれくらい確信しているか（特に tacit）
  ---
  <本文。関連記憶は [[name]] でリンク>
  ```
- 各ドメインに `memory/<domain>/INDEX.md`（1 行/件: `- [<name>] <type>/<confidence> — <description>`）。

### tacit の sources 規約（確証方法・provenance）

`confidence` は「**どれくらい確信しているか**」しか表現できず、「**どうやって確信したか（確証方法）**」を表せない。推論・ドキュメント読解由来の知識が `confidence: high` で保存され、recall 時に確定知識として誤って扱われる事故を防ぐため、`sources` には**確証方法を必ず明記**する。**confidence とは独立の軸**として扱い、一方が高くても他方を省略しない。

- **実コード確証（file:path 付き）**: 実装コードを実際に読んで確認した場合。根拠ファイルのパス（可能なら行番号）を `sources` に書く。例: `実コード確証（services/billing/src/api.ts:42）`。
- **ドキュメント・推論由来（要検証）**: README・設計ドキュメント・会話・類推など、コード確証を経ていない場合。例: `ドキュメント・推論由来（要検証・docs/architecture.md より推定）`。

recall・委譲側（run-cycle 等）は `confidence` の高低だけで確定知識として扱わず、`sources` の確証方法が「ドキュメント・推論由来（要検証）」の記憶は**未確証**として扱い、ブリーフ等へ「確定」として渡さない。**`sources` が複数件ある場合、1件でも「ドキュメント・推論由来（要検証）」を含むなら記憶全体を未確証として扱う**（一部が実コード確証済みでも、全体としては要検証が確定するまで確定情報として渡さない）。

### experience 型の追加フィールド（自己改善ループ用）

`type: experience` の記憶には、内省ループ（reflect スキル）が傾向を集計できるよう次のフィールドを足す。run-cycle の学習ステップが **append のみ**で記録し、評価・改修はしない。

```yaml
metadata:
  type: experience
  outcome: good | bad                 # この経験の評価
  target: skill:<name> | subagent:<name> | brief | position | recall | other  # どの資産の改善に効くか
  signal: <何が効いた/詰まったか 1行>
  recurrence: <同種が何回目か（任意。reflect が集計時に更新してよい）>
  confidence: high | medium | low
```

- bad は改修トリガー、good は再利用資産化・回帰ガード・recall 正例に使う。

## 操作

### save（記録）
1. 記録する事実の `type` と `domain` を決める。
2. **重複チェック**: 同 domain の `INDEX.md` を見て、既存の同義エントリがあれば**新規作成せず更新**（`sources` / `confidence` を統合）。
3. `memory/<domain>/<type>-<slug>.md` を作成/更新し、frontmatter を付与。**推定は `confidence: low`**。**`tacit` は `sources` に確証方法（実コード確証 / ドキュメント・推論由来）の明記が必須**（省略しての保存は不可。上記「tacit の sources 規約」参照）。
4. 関連する既存記憶へ `[[name]]` でリンク。
5. `INDEX.md` の該当行を追加/更新。
6. **秘密情報（認証・接続文字列）は記録しない。**
7. 本文に図（サービス関係・フロー等）を載せる場合の**出力規約（AI 可読性）**: 図は **mermaid**（ASCII art 不可。mermaid ラベル内の `<`/`>` は `&lt;`/`&gt;`、改行は `<br/>`）、**各図の直前に1行キャプション**、**全コードフェンスに言語タグ**（ディレクトリツリーは `text` 例外）。

### recall（参照）
- 対象 `domain`（と任意のクエリ）を受け、`INDEX.md` から関連エントリを選び、本文をロードする。
- タスク着手・レビュー前の**前ロード**に使う。`confidence: low` は「未確証」として扱う。**`sources` の確証方法が「ドキュメント・推論由来（要検証）」の場合も、`confidence` の高低に関わらず未確証として扱い、渡す側に確定情報として扱わせない**（委譲ブリーフへの明記は run-cycle 側の規約を参照）。

### promote（確証昇格）
- 人間確認が取れた推定（主に `tacit`）の `confidence` を low → medium/high に上げ、`sources` に確認根拠を追記する。**このとき `sources` の確証方法マーカーも実態に合わせて更新する**（例: 実コード確認が取れたら「ドキュメント・推論由来（要検証）」を「実コード確証（file:path）」に置き換える。実コード確証を経ない人間確認のみなら「要検証」マーカーは残す）。**古い「要検証」マーカーを残したまま `confidence` だけを上げない**（recall・委譲側は確証方法マーカーで確定/未確証を判定するため、`confidence` と `sources` の記載が食い違うと誤判定の原因になる）。**これは意図的な設計**: 人間確認のみでは実装コードとの整合まで担保されないため、`confidence` が高くても実コード確証を経ない限り「要検証」のまま扱ってよい（委譲ブリーフで確定情報として渡すには実コード確証が必要）。

### maintain（棚卸し）
- 古い・誤り・重複を整理（統合/削除）し、`INDEX.md` を同期する。**削除は人間承認のうえ**で行う。

## 委譲（他スキルからの利用）

- `bootstrap-domain-map`: 生成する `map` / `reference` / `tacit`（推定は low）を **save** で記録。
- `run-cycle`: 着手・レビュー前に **recall**、学習フェーズで `experience`（自己改善ループ用フィールド付き）/ 新 `tacit` を **save**。
- `reflect`: `experience(outcome)` を **recall** して傾向を集計し、改修採用後に「適用済み」を **save**（自己改善ループ）。

## 注意
- 粒度は小さく（1 事実 1 ファイル）保ち、recall と更新を容易にする。
- `confidence` を必ず付け、コードからの確証と未確認の推定を区別する。
- **`tacit` の `sources` には確証方法（provenance）を必ず明記**し、`confidence` とは独立に管理する。推論・ドキュメント読解由来の記憶を確定情報として委譲ブリーフ等へ渡さない（実運用事故: 推論由来の tacit が `confidence: high` のまま確定知識として注入され、no-op 実装が品質ゲートを素通りして本番マージされた）。
