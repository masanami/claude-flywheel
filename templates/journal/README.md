# journal — サイクルジャーナル【成果物】

`run-cycle` が 1 周ごとに残す**行動の履歴（append-only）**。台帳（`challenge-ledger.md`）が「課題の現在状態」を表すのに対し、journal は「その状態にどう至ったか」を表す。可観測性（FR-50・NFR-02）を担う仕組みの一つ。

> **台帳とジャーナルは役割が違う**: 台帳の備考には要点（要相談の理由など）だけを残し、経緯・委譲結果・判断根拠といった行動履歴はここへ書く。備考欄に経緯が積み上がると台帳が肥大し recall 効率が落ちるため、混ぜない。

## 生成するもの

```text
journal/
├── README.md                    # 本ファイル（flywheel-init が scaffold）
├── cycle-template.md            # 1 周分 .md の雛形（flywheel-init が scaffold）
├── YYYY-MM-DD-cycle.md          # 1 周 1 ファイル（run-cycle step 6 が生成）
├── YYYY-MM-DD-cycle-2.md        # 同日 2 周目以降は連番サフィックス
└── index.jsonl                  # 同内容の機械可読版（1 周 1 行 append）
```

## 規則

- **append-only・1 周 1 ファイル**。既存の `.md` ファイルは書き換えない（過去の周の記録を後から改変しない）。
- ファイル名は `YYYY-MM-DD-cycle.md`。**同日に複数周走った場合は `-2` / `-3` ... を連番で付与**する（既存ファイルの存在で判定）。
- `index.jsonl` は既存内容を書き換えず、**末尾に 1 行 append** する。
- **秘密情報（トークン・資格情報・Cookie 等）は書かない**（run-cycle 本体の原則を踏襲）。
- `run-cycle --dry-run` 実行時は journal への書き込みを行わない（コミットも発生しない）。

## `.md` の定型セクション（5 つ・この順）

1. **触った課題**: ID とステータス遷移（例 `C-002-4: 分類済 → 計画承認待ち`）。
2. **委譲**: 対象 repo / 実行スキル / **子セッション ID**（`claude -p --output-format json` の `session_id`）/ 結果 1 行。
3. **作成した PR・ブランチの URL**: run-cycle step 3 の FR-22 節運用注記「自律で PR を作成したら PR URL を必ずサイクルレポートに出す」の固定置き場。
4. **承認待ちゲート一覧**: その周で保留になった人間承認ゲート（FR-13 / FR-22 / FR-32 等）を 1 箇所に集約。
5. **判断と根拠**: 非自明な意思決定を 1〜3 行で。

雛形は `cycle-template.md` を参照（コピーして日付を埋めて使う）。

## `index.jsonl` のスキーマ

1 行 1 周・1 JSON オブジェクト。`date`/`seq` はファイル名を機械的に導くためのメタ情報、残り 5 フィールドは `.md` の 5 セクションに 1:1 対応する。

| フィールド | 型 | 内容 |
| --- | --- | --- |
| `date` | string (`YYYY-MM-DD`) | 実行日 |
| `seq` | number | 同日内の連番（**1 始まり**。`seq: 1` はファイル名にサフィックスを付けない＝ `YYYY-MM-DD-cycle.md`、`seq: 2` から `-2` を付ける） |
| `touched_issues` | array<object> | `{ "id": "C-002-4", "from": "分類済", "to": "計画承認待ち" }` |
| `delegations` | array<object> | `{ "repo": "<name>", "skill": "<skill名>", "session_id": "<claude -p の session_id>", "result": "<結果1行>" }` |
| `pr_urls` | array<string> | 作成した PR / ブランチの URL |
| `pending_approvals` | array<object> | `{ "gate": "FR-13", "issue": "C-003", "summary": "<1行>" }` |
| `decisions` | array<string> | 判断と根拠（1〜3 行を要素として） |

サンプル（1 行）:

```json
{"date":"2026-07-04","seq":1,"touched_issues":[{"id":"C-002-4","from":"着手中","to":"検証中"}],"delegations":[{"repo":"service-a","skill":"tdd-impl","session_id":"sess-abc123","result":"実装完了・PR起票"}],"pr_urls":["https://github.com/org/service-a/pull/12"],"pending_approvals":[{"gate":"FR-13","issue":"C-003","summary":"タスク起票の承認待ち"}],"decisions":["既存パターンに合わせフォールバック処理を追加"]}
```

`reflect` スキルはこのファイルを、`experience`（good/bad）と並ぶ集計入力として使う。

## 子セッション ID を残す理由

委譲は独立した `claude -p --output-format json` セッションで行われ、返り値の `session_id` をジャーナルへ記録する。普段はジャーナルの `.md` / `index.jsonl` だけ読めば周の内容が分かり、怪しい周だけ `claude -p --resume <session_id>` やトランスクリプト（`~/.claude/projects/`）で深掘りできる。
