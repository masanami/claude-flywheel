# 課題の取り込み元（challenge sources）

> このエージェントが課題を**取り込む外部ソース**の宣言。`ingest-challenges` スキルがこれを読み、
> 各ソースから自分に関係する課題を正本 `challenge-ledger.md` へ冪等に取り込む。
> （このファイルは claude-flywheel の `templates/challenge-sources.md` から生成された雛形。任意。無い場合は取り込み時に確認するか共有 repo 直参照にフォールバックする）
>
> - **ソースは差し替え可能（pluggable）**: 共有 repo / Notion / Google Doc / Slack 等、実体は問わない。
> - **正本は内部**（`challenge-ledger.md`）。分類・ステータスは内部で管理し、外部へは書き戻さない。
> - **秘密情報（トークン・資格情報・Cookie）はここに書かない**。認証は実行者環境（MCP 接続 / 環境変数 / SSH）に委ねる。

---

## ソース一覧

各ソースを 1 ブロックで宣言する（不要な行は省略可）。`id` は取り込み元マーカーに使う**安定した短い識別子**にする。

### [source-1] <ソースの呼び名>

- **id**: `<source-id>`  <!-- 例: shared-repo / product-notion / ops-slack。マーカーに使うので後から変えない -->
- **type**: `repo-file` | `mcp-doc` | `mcp-chat` | `github-issue`
- **locator**: `<場所>`  <!-- repo-file: repos.tsv の <name> とパス / mcp-doc: ドキュメント URL か page id / mcp-chat: チャンネル / github-issue: owner/name（複数列挙可） -->
- **access**: `<読み取り方式>`  <!-- repo-file: ローカルクローンを Read / mcp-doc: 接続済み Google Drive MCP / mcp-chat: 接続済み Slack MCP。ツールは実行者の接続済みサーバから discover / github-issue: gh issue list --repo <owner/name> --state open --json number,title,body,author,createdAt,labels,url --limit 200（認証は実行者の gh 認証に委ねる。PR は対象外。--limit は既定30件のため明示） -->
- **filter**（任意）: `<関心キーワード / ラベル / セクション>`  <!-- 自ポジションに関係する分だけ取り込むための絞り込み -->
- **external-key**（冪等の要）: `<外部キーの取り方>`  <!-- 安定 ID を最優先。例 Notion page id / Slack ts / 見出し ID / github-issue は <repo>#<number>。無ければ見出しテキスト -->
- **mapping**（任意・既定から変える場合のみ）:
  - 起票者/起票日 ← `<外部フィールド>`
  - 説明 ← `<外部フィールド>`
  - 完了条件 ← `<外部フィールド>`
  - 体感の緊急度 ← `<ラベル/絵文字 → 高/中/低 の対応>`
- **備考**（任意）: `<運用メモ。取り込み頻度など>`

<!-- 追加のソースは同じブロックをコピーして id を変えて増やす。

### [source-2] <別ソース>
- id: `...`
- type: `...`
...

-->

### 記入例: `github-issue`（複数リポジトリ）

`type: github-issue` は次のように宣言するだけでよい（`access` に直接コマンドを書くワークアラウンドは不要）:

```markdown
### [core-repo-issues] 編集対象リポジトリの GitHub Issue
- id: core-repo-issues
- type: github-issue
- locator: owner-a/repo-a, owner-b/repo-b  <!-- 複数リポジトリを列挙可。読めない/権限不足のリポジトリはスキップ -->
- access: gh issue list --repo <repo> --state open --json number,title,body,author,createdAt,labels,url --limit 200
- filter: 自ポジションの関心範囲（open Issue 全件を候補にし関連度で判定）
- external-key: <repo>#<number>
- mapping: 起票者←author.login / 起票日←createdAt / 説明←body / 緊急度←ラベル（例: `priority:*` → 高/中/低）
```

## 運用メモ

- **正規化の既定**: 作成者→起票者、作成日→起票日、本文→説明、明示があれば完了条件・緊急度。取れない欄は空にし、判断が要る箇所は台帳の「備考」に**仮定として明記**する（推測で埋めない）。
- **冪等**: 同じ課題を再取り込みしても二重登録しない。既存エントリの `fp`（フィンガープリント）が変われば**人間記入欄だけ**更新し、分類・ステータスは保持する（台帳の記入形式は `challenge-ledger.md` の記入例を参照）。
- **頻度**: 手動（`/ingest-challenges`）／`run-cycle` の観測ステップから自動／routine 連動のいずれでもよい。
