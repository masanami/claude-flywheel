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
├── repos.tsv                 # 関連リポジトリのマニフェスト（テンプレートから生成）
├── .claude/settings.json     # 自走委譲の権限（Bash(claude -p:*) を allow。§権限前提）
├── positions/                # ポジション定義（最初は空。bootstrap で生成）
├── memory/                   # エージェント記憶（最初は空。運用で蓄積）
├── runtime/                  # 自律実行ランタイム設定（テンプレートから生成）
└── .gitignore                # .flywheel/repos/（作業用クローン実体）を除外
```

## 手順

1. カレントワークスペースを確認する（既存ファイルを上書きしない。あれば差分を提示して承認を得る）。
2. プラグインの雛形（`${CLAUDE_PLUGIN_ROOT}/templates/`）を読み込み、カレントワークスペースに生成する:
   - `${CLAUDE_PLUGIN_ROOT}/templates/CLAUDE.md` → `./CLAUDE.md`（既存 CLAUDE.md があれば追記/マージ。上書きしない）
   - `${CLAUDE_PLUGIN_ROOT}/templates/challenge-ledger.md` → `./challenge-ledger.md`
   - `${CLAUDE_PLUGIN_ROOT}/templates/challenge-sources.md` → `./challenge-sources.md`（**任意**。外部ソースから取り込む場合のみ。初期は内部台帳直接記入だけでも可＝生成を省略できる）
   - `${CLAUDE_PLUGIN_ROOT}/templates/repos.tsv` → `./repos.tsv`（関連リポジトリのマニフェスト）
   - `${CLAUDE_PLUGIN_ROOT}/templates/runtime/README.md` → `./runtime/README.md`
   - `${CLAUDE_PLUGIN_ROOT}/templates/settings.json` → `./.claude/settings.json`（既存があれば `permissions.allow` に `Bash(claude -p:*)` を追記/マージ。上書きしない）
   - `positions/`・`memory/` は空ディレクトリ（`.gitkeep`）で作成。
3. `.gitignore` に **作業用クローンの実体**を除外する行を追記する（既存の `.gitignore` があれば追記、無ければ作成。重複追記しない）:

   ```text
   # 関連リポジトリの作業用クローン（実体はコミットしない。マニフェストは repos.tsv）
   .flywheel/repos/
   ```

4. 次の一手を案内する:
   - ドメインが未知なら bootstrap-domain-map スキルを実行して `positions/`・`memory/`・`repos.tsv`（＋任意で `challenge-sources.md` の取り込み元候補）を生成。
   - 既にドメインが分かっていれば `${CLAUDE_PLUGIN_ROOT}/templates/position.md` を雛形に `positions/<domain>.md` を作成し、関連リポジトリを `repos.tsv` に記入。
   - 課題は**共有ソース**に集約し、run-cycle（観測ステップ＝ ingest-challenges）が自分に関係する分だけ `challenge-ledger.md` へ取り込む。外部ソース（Notion/Doc/Slack 等）から取り込むなら `challenge-sources.md` に取り込み元を宣言する（秘密情報は書かない。認証は実行者環境に委ねる）。
   - 関連リポジトリを clone したくなったら `${CLAUDE_PLUGIN_ROOT}/scripts/sync-repos.sh` で `.flywheel/repos/`（作業用＝編集・ブランチ・コミット可）に clone/fetch する。
5. 生成物を Git コミットする（秘密情報は含めない。`.flywheel/repos/` はコミットしない）。

## 自走委譲の権限前提（`.claude/settings.json`）

run-cycle の実行ステップは、実作業を **cwd＝作業用クローンの独立 `claude -p` セッション**へ委譲する（設計背景は plugin の `${CLAUDE_PLUGIN_ROOT}/docs/architecture.md` §3.9.2）。このとき **親（このワークスペース）から headless `claude -p` を spawn する行為は、事前許可が無いと Claude Code の auto-mode セーフティ分類器にブロックされ、routine/cron の自走が実装ステップに到達できない**。

そのため本スキルは `.claude/settings.json` に `Bash(claude -p:*)` を **allow として scaffold し、自律委譲を opt-in 化**する。分類器を経ずに委譲 spawn できるようになる。

- 委譲の子セッションには **`--allowedTools Bash` のような“無制限 Bash”を渡さない**。子の権限は **cwd の対象 repo が持つ `.claude/settings.json`（allow/ask/deny）に統治させる**（“広範 Bash”警戒を避けつつ設計どおり委譲するための指針）。
- 多ターン継続（`claude -p -c` / `claude -p --resume <id>`）も同じ allow ルールで通るよう、**`-p` を先頭に置く**呼び出し形にする。
- 対象 repo 側（`.flywheel/repos/<name>`）にも、子セッションが実装作業できるよう `.claude/settings.json`（lint/test/build/git 等を allow、破壊的操作を deny）を整えておくと安全（各 repo 側の `/init-project` 等で生成）。

## 注意

- **状態はプラグイン内に作らない**（プラグインは配布物・読み取り専用扱い）。必ず利用先ワークスペースに作る。
- 再実行時は既存状態を尊重し、不足分のみ補う（冪等）。
- `.claude/settings.json` は**破壊的操作までは許可しない**（`Bash(claude -p:*)` の opt-in に留める）。マージ／本番影響／削除／履歴破壊（force-push 等）といった真に不可逆な操作は run-cycle の承認ゲート（FR-22）で扱う。**topic push・PR 作成は可逆な外向き操作**でサイクル内自律可（[#24](https://github.com/masanami/claude-flywheel/issues/24)）。
