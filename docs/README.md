# docs

claude-flywheel の設計ドキュメント置き場。

| ドキュメント | 内容 | ステータス |
| --- | --- | --- |
| [challenges.md](./challenges.md) | 課題・テーマ（現場の具体課題 / Why） | ドラフト |
| [requirements.md](./requirements.md) | 要件定義（何を満たすべきか / What） | ドラフト |
| [agent-memory.md](./agent-memory.md) | エージェントmemory運用方針（地図・暗黙知・経験） | ドラフト |
| [self-improvement.md](./self-improvement.md) | 自己改善（内省）ループ運用方針（run-cycle と分離した reflect） | ドラフト |
| [architecture.md](./architecture.md) | アーキテクチャ・実現方式（どう作るか / How） | ドラフト |
| [challenge-ledger-format.md](./challenge-ledger-format.md) | 課題台帳の記入形式（人間記入欄＋分類欄） | ドラフト |
| [authoring-style.md](./authoring-style.md) | ドキュメント出力規約（AI 可読性: 図は mermaid・言語タグ・キャプション） | ドラフト |
| [runtime-text-conventions.md](./runtime-text-conventions.md) | 実行時テキスト（`skills/` `templates/`）と docs の書き分け（[#117](https://github.com/masanami/claude-flywheel/issues/117)）: 判定軸「この文を削るとモデルの振る舞いが変わるか」と、実行時テキストから `docs/` を参照しない規約。検査は [scripts/tests/runtime-text-refs.test.sh](../scripts/tests/runtime-text-refs.test.sh) | 確定 |
| [noop-cycle-batching.md](./noop-cycle-batching.md) | no-op 周の軽量化（[#82](https://github.com/masanami/claude-flywheel/issues/82)）: 変化ゼロの周のコミットを次の周へ束ねる設計、3 案の比較と採用根拠、「変化なし」の機械的定義 | 確定 |
| [heartbeat-detection.md](./heartbeat-detection.md) | 拍動停止の検知（[#83](https://github.com/masanami/claude-flywheel/issues/83)）: 実装済みの最小緩和の設計と、セッション寿命に拍動を紐づけない方式の選択肢比較（採否は人間判断・未決） | ドラフト |
| [template-version-marker.md](./template-version-marker.md) | テンプレート版マーカー（[#118](https://github.com/masanami/claude-flywheel/issues/118)）: scaffold 生成物に `flywheel-template` マーカーを刻み、追従検出を項目ごとの手書き検出器から汎用検出へ移す設計。粒度・形式・置き場所・既存世代の扱い・内容ベース検出器との併用の決定 | 確定 |
| [run-cycle-context-budget.md](./run-cycle-context-budget.md) | run-cycle の文脈コスト実測と規定の棚卸し（[#97](https://github.com/masanami/claude-flywheel/issues/97)）: 毎周ロードされる固定文脈の内訳（SKILL.md 27,652 tok / 課題台帳 27,913 tok）、151 規定単位の「残す・移す・消す」仕分け、置き場所候補ごとの到達性、許可パスの正本の充足判定。**採否は未決** | ドラフト |

> 要件（What）とアーキテクチャ（How）を分離して管理する。本ディレクトリではまず要件を固め、合意後にアーキテクチャを別ドキュメントで設計する。

## 配布形態（fleet：複数の独立エージェントを作る土台）

claude-flywheel は **Claude Code プラグイン**として配布し、1 つのプラグインから**プロジェクトごとに独立した複数のエージェント（fleet）** を作る。構成は 3 層（[architecture.md §1.1/§4](./architecture.md)）。

| 層 | 配置 | 中身 |
| --- | --- | --- |
| 機械（プラグイン） | claude-flywheel: `skills/` `templates/` `scripts/` `docs/` `.claude-plugin/` | スキル群・雛形・スクリプト・設計（全エージェント共通の土台） |
| 各エージェント（state＋harness） | エージェントごとの独立リポジトリ | `challenge-ledger.md` `positions/` `memory/` `runtime/` ＋ 独自ハーネス |
| 共有課題ソース（intake） | 共有リポジトリ/ドキュメント | 人間が課題を集約する単一の入口（各エージェントが自分の分だけ取り込み） |

## スキル（`skills/`）

| スキル | 用途 |
| --- | --- |
| [flywheel-init](../skills/flywheel-init/SKILL.md) | エージェントのリポジトリに状態を初期化（scaffold） |
| [bootstrap-domain-map](../skills/bootstrap-domain-map/SKILL.md) | ドメイン地図づくり → ポジション案・記憶 seed |
| [ingest-challenges](../skills/ingest-challenges/SKILL.md) | 外部ソース（共有 repo / Notion / Doc / Slack 等）から課題を正本台帳へ冪等に取り込み（pluggable） |
| [start-day](../skills/start-day/SKILL.md) | 一日の自走を開始（cadence 読込→初回 run-cycle→セッション内 cron 登録） |
| [run-cycle](../skills/run-cycle/SKILL.md) | 自走サイクル1周（観測→…→学習→報告） |
| [agent-memory](../skills/agent-memory/SKILL.md) | ドメイン記憶の構造化管理（save/recall/promote/maintain） |
| [reflect](../skills/reflect/SKILL.md) | 自己改善（内省）ループ1周（good/bad の記録を集計→改修提案、低頻度） |

## テンプレート（`templates/` ＝利用先に scaffold する雛形）

| テンプレート | 用途 |
| --- | --- |
| [CLAUDE.md](../templates/CLAUDE.md) | エージェントのベースライン（ポジション要約・記憶INDEX参照・recall手順） |
| [challenge-ledger.md](../templates/challenge-ledger.md) | 課題台帳の雛形 |
| [challenge-sources.md](../templates/challenge-sources.md) | 課題の取り込み元宣言の雛形（任意・外部ソース ingestion 用） |
| [priority-policy.md](../templates/priority-policy.md) | タスク優先度の決定方針の雛形（正本・切り替えの意思決定は人間〔編集は人間指示を受けたAI代行可〕。run-cycle が手順1/2で参照。不在時は現状どおりエージェント裁量） |
| [position.md](../templates/position.md) | ポジション定義の雛形 |
| [repos.tsv](../templates/repos.tsv) | 関連リポジトリのマニフェスト雛形（作業用クローン） |
| [settings.json](../templates/settings.json) | 自走委譲の権限雛形（`Bash(claude -p:*)` を allow。`.claude/settings.json` として scaffold） |
| [cadence.json](../templates/cadence.json) | 拍動設定の雛形（業務時間・run-cycle 間隔・発火分オフセット・実行モード `execution_mode`・reflect しきい値・拍動停止検知しきい値 `heartbeat.stale_after_business_days`。`start-day` / `run-cycle` が読む） |
| [container/{Dockerfile,compose.yml}](../templates/container/) | コンテナ隔離モード（`execution_mode: container`）の雛形。start-day 層をコンテナに閉じ込める |
| [runtime/README.md](../templates/runtime/README.md) | 自律実行ランタイム設定の雛形（実行イベントログ `runs.jsonl` の仕様の正本を含む） |
| [journal/README.md](../templates/journal/README.md) | サイクルジャーナル（行動履歴・append-only）の説明の雛形 |
| [journal/cycle-template.md](../templates/journal/cycle-template.md) | サイクルジャーナル 1 周分の雛形（run-cycle step 6 が参照） |

## スクリプト（`scripts/` ＝機械的処理。純シェルと、Markdown/JSON を決定的に扱う ruby）

| スクリプト | 用途 |
| --- | --- |
| [sync-repos.sh](../scripts/sync-repos.sh) | `repos.tsv` を読み、関連リポジトリを `.flywheel/repos/` へ冪等に clone/fetch（作業用・ローカル作業を壊さない安全同期） |
| [trust-clone.sh](../scripts/trust-clone.sh) | 作業用クローンを Claude Code の trust 承認済みにする（`~/.claude.json` を更新。人間が一度だけ手動実行） |
| [log-run-event.sh](../scripts/log-run-event.sh) | 実行イベントログ `.flywheel/runs.jsonl` へ 1 イベントを append（読み取り専用の検算サブコマンド `check` 同梱。環境要因の失敗は exit 0＝best-effort、引数エラーは exit 2＝イベント未記録。[#98](https://github.com/masanami/claude-flywheel/issues/98)） |
| [cycle-lock.sh](../scripts/cycle-lock.sh) | run-cycle の多重起動を排他するロック `.flywheel/cycle.lock` の取得・解放（stale 回収時の `abandoned` 代筆を内包） |
| [heartbeat-check.sh](../scripts/heartbeat-check.sh) | 拍動停止の検知（最終 `cycle_end` からの空白営業日数がしきい値超過なら未終了 `*_start` とともに警告。読み取り専用。[#83](https://github.com/masanami/claude-flywheel/issues/83)） |
| [noop-check.rb](../scripts/noop-check.rb) | 当周に外部状態の変化があったかの機械判定（run-cycle 手順6 がコミット／保留の分岐に使う。読み取り専用。許可パスの正本は [contracts/cycle-commit-paths.txt](../contracts/cycle-commit-paths.txt)。[#82](https://github.com/masanami/claude-flywheel/issues/82)） |
| [validate-artifact.rb](../scripts/validate-artifact.rb) | run-cycle 成果物のフォーマット契約バリデータ（台帳・アーカイブ・journal・jsonl。run-cycle 手順6 が書き込み後・コミット前に呼ぶ。契約は [contracts/README.md](../contracts/README.md)。[#91](https://github.com/masanami/claude-flywheel/issues/91)） |
| [migrate-workspace.rb](../scripts/migrate-workspace.rb) | 既存ワークスペースを現行テンプレートの構造へ追従させる（台帳・アーカイブの構造マイグレーション＋ scaffold 追従レポート。既定は dry-run。flywheel-init の再実行から呼ばれる。[#88](https://github.com/masanami/claude-flywheel/issues/88)） |
