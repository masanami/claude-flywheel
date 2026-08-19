---
name: flywheel-init
description: claude-flywheel を導入したワークスペースに、運用状態（課題台帳・positions・memory・runtime）を初期化（scaffold）する。Triggers on：「flywheel をセットアップ」「flywheel-init」「自走環境を初期化」。プラグイン導入後に最初に一度だけ実行する。
---

# flywheel-init

claude-flywheel プラグインを導入した**利用先ワークスペース**に、運用状態（live state）を scaffold するスキル。

> claude-flywheel は **プラグイン（機械）** と **状態（利用先で生成）** を分離している。本スキルは後者を作る。

## 前提

- claude-flywheel がプラグインとして導入済み。
- カレントが、状態を置きたいワークスペース（Git リポジトリ推奨）であること。

## 生成するもの（利用先ワークスペース直下）

```text
<workspace>/
├── CLAUDE.md                 # ベースライン（ポジション要約・記憶INDEX参照・recall手順。自動ロード）
├── challenge-ledger.md       # 課題台帳（正本・テンプレートから生成）
├── challenge-sources.md      # 課題の取り込み元宣言（任意・外部ソースを使うとき。テンプレートから生成）
├── priority-policy.md        # タスク優先度の決定方針（正本・切り替えの意思決定は人間〔編集は人間指示を受けたAI代行可〕。テンプレートから生成。run-cycleが読む）
├── repos.tsv                 # 関連リポジトリのマニフェスト（テンプレートから生成）
├── .claude/settings.json     # 自走委譲の権限（Bash(claude -p:*) を allow。§権限前提）
├── positions/                # ポジション定義（最初は空。bootstrap で生成）
├── memory/                   # エージェント記憶（最初は空。運用で蓄積）
├── runtime/                  # 自律実行ランタイム設定（テンプレートから生成）
├── container/                # コンテナ隔離モード雛形（execution_mode: container 用。Dockerfile・compose.yml。テンプレートから生成）
├── journal/                  # サイクルジャーナル（README/雛形をテンプレートから生成。cycle-template.md は run-cycle step 6 が参照。実体は run-cycle が生成）
├── .flywheel/
│   └── cadence.json          # 拍動設定（業務時間・run-cycle間隔・発火分オフセット・実行モード・reflectしきい値・拍動停止検知しきい値。start-day / run-cycle スキルが読む。運用設定のため Git 追跡＝gitignore 対象外）
└── .gitignore                # .flywheel/ 配下のローカル実行状態（作業用クローン・ロック・runs.jsonl 等）を除外。cadence.json だけは例外的に追跡
```

## 2 つのモード（初回 scaffold / 再実行＝テンプレート追従）

本スキルは**同じコマンドで 2 つの仕事**をする。`challenge-ledger.md` の有無で分岐する:

| モード | 条件 | すること |
| --- | --- | --- |
| **初回 scaffold** | `./challenge-ledger.md` が無い | 下の「手順」（不足分をテンプレートから生成する。既存は上書きしない） |
| **再実行＝テンプレート追従（マイグレーション）** | `./challenge-ledger.md` がある | 下の「手順」（不足ファイルの補完）に加えて **§再実行（テンプレート追従）** を実行する |

> **なぜ再実行が要るか**: 初回 scaffold は「既存を上書きしない」冪等設計のため、**scaffold 後にテンプレートが更新されても既存ワークスペースは追従しない**。実際、`templates/challenge-ledger.md` に「タスク案」行と承認チェックボックス行が入った後（PR #39）、それ以前に scaffold された 2 エージェントが追従できず、3 エージェントで 3 通りのタスク案形式に分岐し、観測プレーンで承認対象が欠落表示になった（Issue [#87](https://github.com/masanami/claude-flywheel/issues/87) / [#88](https://github.com/masanami/claude-flywheel/issues/88)）。

## 手順

1. カレントワークスペースを確認する（既存ファイルを上書きしない。あれば差分を提示して承認を得る）。
2. `${CLAUDE_PLUGIN_ROOT}/templates/` 配下のうち、**上記ツリーに列挙したファイル/ディレクトリのみ**を対応パスへ生成する（既存ファイルは上書きしない）。`templates/position.md` はここでは生成しない（利用先へコピーする雛形ではなく、手順4で bootstrap 時にその場で参照する雛形）。**特別扱いが必要な項目のみ**:
   - `templates/CLAUDE.md` → `./CLAUDE.md`: 既存があれば追記/マージ。テンプレート内のプレースホルダのうち**エージェント名はワークスペース名またはユーザーへの確認で埋める**。ポジション概要など bootstrap 後に決まる項目はプレースホルダのまま残し、手順4で bootstrap-domain-map の実行を案内する。
   - `templates/challenge-sources.md` → `./challenge-sources.md`（**任意**。外部ソースから取り込む場合のみ生成。初期は内部台帳直接記入だけでも可）。
   - `templates/settings.json` → `./.claude/settings.json`（非自明なパス対応）。既存があれば `permissions.allow` に `Bash(claude -p:*)` を追記/マージする。
   - `templates/cadence.json` → `./.flywheel/cadence.json`（非自明なパス対応）。
   - `positions/`・`memory/` は空ディレクトリ（`.gitkeep`）で作成。
3. `.gitignore` に**ローカル実行状態**（`.flywheel/` 配下）を除外する行を追記する（既存の `.gitignore` があれば追記、無ければ作成。重複追記しない）。**`cadence.json` は運用設定として Git 追跡する**ため、ディレクトリ丸ごとの ignore（`.flywheel/`）ではなく `.flywheel/*` ＋個別 unignore の形にする（`dir/` 形式で丸ごと ignore すると Git がディレクトリ内を走査せず `!` の例外が効かないため）:

   ```text
   # ローカル実行状態（作業用クローン .flywheel/repos/・run-cycle のロック・実行イベントログ runs.jsonl 等。コミットしない。マニフェストは repos.tsv）
   # cadence.json のみ運用設定として Git 追跡する（start-day スキル参照）
   .flywheel/*
   !.flywheel/cadence.json
   ```

   既存の `.gitignore` に旧来の `.flywheel/`（ディレクトリ丸ごと ignore）が既にある場合は、上記の `.flywheel/*` ＋ `!.flywheel/cadence.json` の形へ置き換える（`cadence.json` を Git 追跡させるため）。

   同じ手順で `container/.env` の ignore 行も追記する（コンテナ隔離モードを使う場合に人間が作成するファイル。ホスト固有の絶対パス・UID/GID を含むため Git 追跡しない。詳細は `runtime/README.md`「container モードの前提条件」）:

   ```text
   # コンテナ隔離モード（execution_mode: container）の環境変数ファイル。ホスト固有のため追跡しない
   container/.env

   # 台帳マイグレーション（§再実行）の一時ファイル。正常時は残らないが、万一残ってもコミットしない
   *.migrate-tmp
   ```

4. **再実行なら §再実行（テンプレート追従）を実行する**（`challenge-ledger.md` が既にあった場合。初回 scaffold ではスキップ）。
5. 次の一手を案内する:
   - ドメインが未知なら bootstrap-domain-map スキルを実行して `positions/`・`memory/`・`repos.tsv`（＋任意で `challenge-sources.md` の取り込み元候補）を生成。
   - 既にドメインが分かっていれば `${CLAUDE_PLUGIN_ROOT}/templates/position.md` を雛形に `positions/<domain>.md` を作成し、関連リポジトリを `repos.tsv` に記入。
   - 課題は**共有ソース**に集約し、run-cycle（観測ステップ＝ ingest-challenges）が自分に関係する分だけ `challenge-ledger.md` へ取り込む。外部ソース（Notion/Doc/Slack 等）から取り込むなら `challenge-sources.md` に取り込み元を宣言する（秘密情報は書かない。認証は実行者環境に委ねる）。
   - タスクの優先度判定・着手順の方針を状況に応じて切り替えたい場合は、生成された `priority-policy.md` の「現在のモード」（`active:` 行）を編集してコミットする（既定は `normal`）。**切り替えの意思決定は人間のみ**が行う（run-cycle 手順1・手順2が毎周参照する）。編集は人間が直接行うか、対話セッションで人間から明示指示を受けたエージェントが代行してよい（自律実行〔cron〕中のエージェントは読むだけで自分の判断では書き換えない）。
   - 定期自走を始めるには `/claude-flywheel:start-day` を実行する（`.flywheel/cadence.json` を読み込み、初回 `run-cycle` の実行とセッション内 cron の登録までを行う。詳細は `runtime/README.md`）。
   - 関連リポジトリを clone したくなったら `${CLAUDE_PLUGIN_ROOT}/scripts/sync-repos.sh` で `.flywheel/repos/`（作業用＝編集・ブランチ・コミット可）に clone/fetch する。新規クローンは trust 承認が必要（下記「自走委譲の権限前提」参照）。
6. 生成物を Git コミットする（秘密情報は含めない。`.flywheel/repos/` はコミットしない）。

## 再実行（テンプレート追従＝マイグレーション）

**判断と変換はスクリプトが行う**（散文の手順書には型検査が効かないため、決定的な処理をスクリプトへ寄せる。`validate-artifact.rb` と同じ方針）。本節はその**呼び出し規定**であり、エージェントが手で台帳を書き換えることはしない。

```bash
# 1) まず dry-run（既定）。何をどう変えるかだけを出す。1 バイトも書かない
"${CLAUDE_PLUGIN_ROOT}/scripts/migrate-workspace.rb" --workspace <ワークスペースのルート>

# 2) 出力を確認したうえで適用（変更前ファイルは自動でバックアップされる）
"${CLAUDE_PLUGIN_ROOT}/scripts/migrate-workspace.rb" --workspace <ワークスペースのルート> --apply
```

- **exit code**: `0`＝追従済み（変更なし）／`--apply` で適用完了、`3`＝要移行（dry-run で変更が必要）、`1`＝検算に失敗（**元ファイルは書き換えていない・一時ファイルも残さない**）、`2`＝検査不能（テンプレート/バリデータ不在・引数不正等）。`1` / `2` はサイクルレポート・報告に理由を残す（「変更なし」に読み替えない）。
- **dry-run は `--apply` と同じ検算（バリデータの前後比較を含む）を通す**。dry-run が exit 3 なら、**検算を理由に `--apply` が失敗することはない**（残る失敗要因は書き込み側の事故＝バックアップ先の衝突・I/O エラーだけで、いずれも元ファイルを書き換えずに終わる）。
- **`--apply` は人間に dry-run 出力を見せてから**行う。自律実行（cron）中に台帳の構造変換を無断で適用しない（ライブデータの一括変換であり、承認の意味を持つ行が動くため）。
- **自動適用の範囲は `challenge-ledger.md` / `challenge-archive.md` の構造変換だけ**。この 2 つだけが「テンプレート由来の構造」と「運用中のライブデータ」が同居し、ファイル単位の再生成では追従できない。それ以外（scaffold 済みのドキュメント・設定）は**検出して提示するだけ**で書き換えない——テンプレート版マーカーを埋めていないため、機械には「テンプレートが更新された」と「利用先がカスタマイズした」の区別が付かず、自動上書きは利用先の編集を静かに壊すため。線引きの根拠は [`docs/challenge-ledger-format.md` §既存ワークスペースの移行](../../docs/challenge-ledger-format.md)。
- **削除するのは「既知テンプレート由来と証明できた行」だけ**。記入例に人間が書き足した行が 1 行でもあれば手を出さず報告する（人間が書いたセクション・注意書きの無言消失を防ぐ）。同じ理由で、タスク案の太字見出しブロックに項目以外の行が混じる形は**部分変換せず**報告する。
- **承認（`[x]`）は機械が代筆も無効化もしない**。承認事実が見出し文言にしか無い形は常に**未チェックで新設**し、旧見出しの文言を HTML コメントとして保全したうえで「人間判断が必要」へ列挙する。既存のチェック行が正規形でない（インデント揺れ・旧表記）エントリでは、未チェック行を足すと既存の `[x]` が実質無効化されるため**承認欄に一切触れず**報告する。**出力のこの節は人間へそのまま伝える**（承認プロトコルの真正性。`docs/challenge-ledger-format.md` §承認プロトコル）。
- 出力の「人間判断が必要」「scaffold 追従レポート」は**自動では直さない**もの。エージェントは内容を報告に転記し、勝手に直さない。
- 適用後は `git diff` で差分を確認し、**手順6と同じ扱いでコミット**する（バックアップ先は `.flywheel/` 配下＝gitignore 対象なのでコミットされない）。

## 自走委譲の権限前提（`.claude/settings.json`）

run-cycle の実行ステップは、実作業を **cwd＝作業用クローンの独立 `claude -p` セッション**へ委譲する。このとき **親（このワークスペース）から headless `claude -p` を spawn する行為は、事前許可が無いと Claude Code の auto-mode セーフティ分類器にブロックされ、routine/cron の自走が実装ステップに到達できない**。

そのため本スキルは `.claude/settings.json` に `Bash(claude -p:*)` を **allow として scaffold し、自律委譲を opt-in 化**する。分類器を経ずに委譲 spawn できるようになる。

- 委譲の子セッションには **`--allowedTools Bash` のような“無制限 Bash”を渡さない**。子の権限は **cwd の対象 repo が持つ `.claude/settings.json`（allow/ask/deny）に統治させる**（“広範 Bash”警戒を避けつつ設計どおり委譲するための指針）。
- 多ターン継続（`claude -p -c` / `claude -p --resume <id>`）も同じ allow ルールで通るよう、**`-p` を先頭に置く**呼び出し形にする。
- 対象 repo 側（`.flywheel/repos/<name>`）にも、子セッションが実装作業できるよう `.claude/settings.json`（lint/test/build/git 等を allow、破壊的操作を deny）を整えておくと安全（各 repo 側の `/init-project` 等で生成）。
- **もう一つの前提: クローンの trust 承認**（`Bash(claude -p:*)` の allow とは別物）。委譲先クローンの `.claude/settings.json` の allow リストは、そのクローンの絶対パスが Claude Code に**trust 承認済み**（`~/.claude.json` の `projects["<絶対パス>"].hasTrustDialogAccepted: true`）でない限り無視される。`sync-repos.sh` が用意する新規クローンは常に未承認から始まる（同スクリプトが未承認クローンを検出し警告する）。**人間が一度だけ**、以下のコマンドを実行するか、対話的に `claude` を起動して trust ダイアログを承認する（**エージェント自身は実行禁止**。Self-Modification としてブロックされるため）。trust 承認は絶対パスをキーに記録されるため、対話的に承認する場合は**対象クローン自体を起動ディレクトリ**にする必要がある（例: `(cd "./.flywheel/repos/<name>" && claude)`）:

  ```bash
  ${CLAUDE_PLUGIN_ROOT}/scripts/trust-clone.sh <name>
  ```

  `<name>` は `repos.tsv` に定義したクローン名（`.flywheel/repos/<name>` の実体を指す）。詳細は `scripts/trust-clone.sh -h` を参照。
- **trust 承認は当該パスの将来の変更にも及ぶ**（再承認なしに対象 repo の `.claude/settings.json`・`CLAUDE.md` の更新が子セッションへ効き続けるため、書き込み権を持つ者が実質このエージェントの権限定義者になる）。委譲先の既定ブランチには branch protection を設定し、`.claude/settings.json`・`CLAUDE.md` の変更はレビュー必須とする運用を前提にする。

## 注意

- **状態はプラグイン内に作らない**（プラグインは配布物・読み取り専用扱い）。必ず利用先ワークスペースに作る。
- 再実行時は既存状態を尊重し、不足分のみ補う（冪等）。**加えて §再実行（テンプレート追従）でテンプレート更新へ追従させる**（不足分の補完だけでは、既に存在するファイルの中の構造更新に追従できないため）。
- `.claude/settings.json` は**破壊的操作までは許可しない**（`Bash(claude -p:*)` の opt-in に留める）。既定ブランチ（`main`）への昇格マージ／本番影響／削除／履歴破壊（force-push 等）といった**本番影響のある不可逆な操作**は run-cycle の承認ゲート（FR-22）で扱う。**作業ブランチへの push・PR 作成・統合ブランチ／親Issueブランチ（本番非反映）へのマージは本番影響が無く可逆**なのでサイクル内自律可。
