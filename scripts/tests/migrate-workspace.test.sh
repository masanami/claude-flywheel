#!/usr/bin/env bash
#
# migrate-workspace.test.sh — scripts/migrate-workspace.rb のテスト。
#
# 実行: bash scripts/tests/migrate-workspace.test.sh
#   - 依存: bash（macOS 標準の 3.2 でも可）・/usr/bin/ruby（macOS 標準）。テストフレームワーク不使用。
#   - 書き込みはすべて一時ディレクトリ内で完結し、リポジトリの状態を変更しない。
#
# 検査の要（Issue #88）— 台帳は**運用中のライブデータ**であり、機械編集が隣接エントリを
# 巻き添えにした事故の実績がある。したがって固定すべき性質は 4 つ:
#   1. **受理方向**: 旧形式（実測 3 形）を移行するとフォーマット契約のバリデータを通る。
#   2. **非破壊**: 人間記入欄・承認チェック（`[x]`）・備考・取り込み元マーカー・タスク案の
#      本文が保存され、触るべきでないエントリは 1 行も変わらない。
#   3. **冪等・dry-run**: 2 回目は差分ゼロ。dry-run は 1 バイトも書かない。
#   4. **検算が本当に効く**: 変換後の出力に故障を注入すると、検算が止めて**部分適用を残さない**
#      （タウトロジーでないことを変異注入で示す。復元は cp バックアップから行い、
#      `git checkout --` のようなファイル全体を戻す操作は使わない）。

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/migrate-workspace.rb"
VALIDATOR="$REPO_ROOT/scripts/validate-artifact.rb"
FIXTURES="$TESTS_DIR/fixtures/migrate"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; [ $# -gt 1 ] && echo "       $2"; }

# assert_exit <名前> <期待exit> -- <migrate-workspace.rb の引数...>
assert_exit() {
  name="$1"; want="$2"; shift 2
  [ "$1" = "--" ] && shift
  out="$(/usr/bin/ruby "$SCRIPT" "$@" 2>&1)"
  got=$?
  if [ "$got" -eq "$want" ]; then
    pass "$name"
  else
    fail "$name (exit: got=$got want=$want)" "$out"
  fi
}

# assert_out <名前> <期待部分文字列> -- <引数...>
assert_out() {
  name="$1"; want="$2"; shift 2
  [ "$1" = "--" ] && shift
  out="$(/usr/bin/ruby "$SCRIPT" "$@" 2>&1)"
  case "$out" in
    *"$want"*) pass "$name" ;;
    *) fail "$name" "期待した文言が出ない: ${want}" ;;
  esac
}

# assert_validator <名前> <type> <file> <期待exit>
assert_validator() {
  name="$1"; type="$2"; file="$3"; want="$4"
  out="$(/usr/bin/ruby "$VALIDATOR" "$type" "$file" 2>&1)"
  got=$?
  if [ "$got" -eq "$want" ]; then
    pass "$name"
  else
    fail "$name (validator exit: got=$got want=$want)" "$out"
  fi
}

# assert_grep_count <名前> <パターン> <ファイル> <期待件数>
assert_grep_count() {
  name="$1"; pat="$2"; file="$3"; want="$4"
  got="$(grep -c "$pat" "$file" 2>/dev/null || true)"
  got="$(printf '%s' "$got" | tr -d ' ')"
  if [ "$got" = "$want" ]; then
    pass "$name"
  else
    fail "$name" "件数が違う: got=${got} want=${want}（パターン: ${pat}）"
  fi
}

# assert_has <名前> <パターン> <ファイル>
assert_has() {
  if grep -q "$2" "$3" 2>/dev/null; then pass "$1"; else fail "$1" "見つからない: $2"; fi
}

# assert_same <名前> <fileA> <fileB>
assert_same() {
  if cmp -s "$2" "$3"; then pass "$1"; else fail "$1" "$(diff "$2" "$3" | head -8)"; fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ワークスペースを組み立てる: mkws <名前> [<台帳フィクスチャ>] [<アーカイブフィクスチャ>]
mkws() {
  ws="$tmp/$1"
  rm -rf "$ws"
  mkdir -p "$ws"
  [ $# -ge 2 ] && [ -n "$2" ] && cp "$FIXTURES/$2" "$ws/challenge-ledger.md"
  [ $# -ge 3 ] && [ -n "$3" ] && cp "$FIXTURES/$3" "$ws/challenge-archive.md"
  echo "$ws"
}

# ---------------------------------------------------------------------------
# 1. dry-run（既定）は 1 バイトも書かない
# ---------------------------------------------------------------------------

ws="$(mkws dryrun legacy-bold-heading-ledger.md legacy-missing-fields-archive.md)"
cp "$ws/challenge-ledger.md" "$tmp/dryrun-ledger.orig"
cp "$ws/challenge-archive.md" "$tmp/dryrun-archive.orig"
assert_exit "dry-run（要移行）は exit 3" 3 -- --workspace "$ws"
assert_same "dry-run は台帳を書き換えない" "$tmp/dryrun-ledger.orig" "$ws/challenge-ledger.md"
assert_same "dry-run はアーカイブを書き換えない" "$tmp/dryrun-archive.orig" "$ws/challenge-archive.md"
assert_out "dry-run は適用方法を案内する" "--apply を付けて再実行" -- --workspace "$ws"

# ---------------------------------------------------------------------------
# 2. 受理方向: 旧形式（太字見出しブロック形）を移行するとバリデータを通る
# ---------------------------------------------------------------------------

ws="$(mkws bold legacy-bold-heading-ledger.md legacy-missing-fields-archive.md)"
assert_validator "移行前: 旧テンプレート台帳はバリデータ違反" ledger "$ws/challenge-ledger.md" 1
assert_validator "移行前: 旧テンプレートアーカイブはバリデータ違反" archive "$ws/challenge-archive.md" 1
assert_exit "--apply は exit 0" 0 -- --workspace "$ws" --apply --backup-dir "$tmp/backup-bold"
assert_validator "移行後: 台帳がバリデータを通る" ledger "$ws/challenge-ledger.md" 0
assert_validator "移行後: アーカイブがバリデータを通る" archive "$ws/challenge-archive.md" 0

# 非破壊: 承認チェック・備考・取り込み元マーカー・タスク案本文の保存
assert_grep_count "承認済みチェックの [x] が保存される" '^  - \[x\] 計画を承認' "$ws/challenge-ledger.md" 1
assert_grep_count "移行がチェックを捏造しない（チェック済み行は移行前と同数の 1 行）" '^  - \[x\]' "$ws/challenge-ledger.md" 1
assert_has "備考の本文が保存される" '承認済みチェックと取り込み元マーカーは移行で失われてはならない' "$ws/challenge-ledger.md"
assert_has "取り込み元マーカーが原文のまま残る" 'shared-repo / issue-70（取り込み: 2026-07-27）<!-- fp:b3bed2c644e5 -->' "$ws/challenge-ledger.md"
assert_has "タスク案の本文が 2 スペースのネスト項目として保存される" '^  1\. 子セッションへ委譲して実装する' "$ws/challenge-ledger.md"
assert_has "タスク案の 3 項目目も保存される" '^  3\. 既定ブランチへの昇格マージは FR-22' "$ws/challenge-ledger.md"
assert_grep_count "旧形式の太字見出しブロックは残らない" '^\*\*タスク案' "$ws/challenge-ledger.md" 0
assert_has "旧見出しの文言は HTML コメントとして保全される" '<!-- 移行前の記載（#88）: \*\*タスク案（FR-13・承認済み 2026-07-27 対話承認）\*\* -->' "$ws/challenge-ledger.md"
assert_has "旧ラベルの承認行が現行ラベルへ改名される" '^- 承認（人間がチェック）:' "$ws/challenge-ledger.md"

# 台帳には参照フィールドを補うが、アーカイブ（原文保存の履歴）には補わない
assert_grep_count "台帳に参照フィールド行を補う（記入例 1 + エントリ 2）" '^- 関連リポジトリ:' "$ws/challenge-ledger.md" 3
assert_grep_count "アーカイブには参照フィールドを補わない" '^- 関連リポジトリ:' "$ws/challenge-archive.md" 0

# 承認を機械が代筆しないことの報告
ws2="$(mkws bold2 legacy-bold-heading-ledger.md)"
assert_out "承認を捏造せず人間判断として報告する" "承認チェックボックスを**未チェックで新設**した" -- --workspace "$ws2"

# ---------------------------------------------------------------------------
# 3. 冪等: 2 回目の実行は差分ゼロ
# ---------------------------------------------------------------------------

cp "$ws/challenge-ledger.md" "$tmp/idem-ledger.once"
cp "$ws/challenge-archive.md" "$tmp/idem-archive.once"
assert_exit "2 回目の dry-run は exit 0（変更なし）" 0 -- --workspace "$ws"
assert_out "2 回目は追従済みと報告する" "変更はありません" -- --workspace "$ws"
assert_exit "2 回目の --apply も exit 0" 0 -- --workspace "$ws" --apply
assert_same "2 回目でも台帳はバイト一致（冪等）" "$tmp/idem-ledger.once" "$ws/challenge-ledger.md"
assert_same "2 回目でもアーカイブはバイト一致（冪等）" "$tmp/idem-archive.once" "$ws/challenge-archive.md"

# ---------------------------------------------------------------------------
# 4. バックアップ（変更前の原本が残る）
# ---------------------------------------------------------------------------

assert_same "バックアップは移行前の台帳と一致する" "$FIXTURES/legacy-bold-heading-ledger.md" "$tmp/backup-bold/challenge-ledger.md"
assert_same "バックアップは移行前のアーカイブと一致する" "$FIXTURES/legacy-missing-fields-archive.md" "$tmp/backup-bold/challenge-archive.md"

# ---------------------------------------------------------------------------
# 5. 記入例フェンス形（Emma 形）: 記入例だけが現行化され、エントリ本文は変わらない
# ---------------------------------------------------------------------------

ws="$(mkws nested legacy-nested-list-ledger.md)"
assert_validator "移行前: フェンス形の台帳はバリデータを通る" ledger "$ws/challenge-ledger.md" 0
assert_exit "フェンス形の台帳を移行できる" 0 -- --workspace "$ws" --apply --backup-dir "$tmp/backup-nested"
assert_validator "移行後もバリデータを通る" ledger "$ws/challenge-ledger.md" 0
assert_grep_count "旧記入例の text フェンスが残らない" '^```text' "$ws/challenge-ledger.md" 0
assert_has "現行の記入例（承認対象＝タスク案）へ差し替わる" '計画を承認（FR-13・承認対象＝タスク案）' "$ws/challenge-ledger.md"
assert_has "エントリのタスク案本文は変わらない" '^  1\. 論点整理と推奨案の起草' "$ws/challenge-ledger.md"
assert_grep_count "エントリの承認チェックは変わらない" '^  - \[x\] 計画を承認$' "$ws/challenge-ledger.md" 1

# ---------------------------------------------------------------------------
# 6. すでに現行構造を満たすエントリは 1 行も変えない
# ---------------------------------------------------------------------------

ws="$(mkws untouched "" legacy-missing-fields-archive.md)"
/usr/bin/ruby "$SCRIPT" --workspace "$ws" --apply >/dev/null 2>&1
if grep -A9 '^### \[C-403\]' "$ws/challenge-archive.md" | grep -q '^- 担当ポジション: harness'; then
  pass "現行構造のエントリ（C-403）は保持される"
else
  fail "現行構造のエントリ（C-403）は保持される"
fi
assert_grep_count "現行構造のエントリに承認行を重複させない" '^- 承認（人間がチェック）:' "$ws/challenge-archive.md" 3
assert_has "引用行（外部本文の転記）は触らない" '^> 外部 Issue の本文をブロック引用で転記した説明。' "$ws/challenge-archive.md"

# ---------------------------------------------------------------------------
# 7. テンプレート自体が移行の不動点である（正本＝実行可能なシステムの固定）
# ---------------------------------------------------------------------------

ws="$(mkws template)"
cp "$REPO_ROOT/templates/challenge-ledger.md" "$ws/challenge-ledger.md"
assert_exit "テンプレートは移行の不動点（exit 0）" 0 -- --workspace "$ws"
assert_out "テンプレートは追従済みと報告される" "変更はありません" -- --workspace "$ws"

# ---------------------------------------------------------------------------
# 8. 記入例の残骸（対応する開きタグを失った `-->`）: 変換は進め、残骸は人間判断へ倒す
# ---------------------------------------------------------------------------

ws="$(mkws remnant "" legacy-example-remnant-archive.md)"
assert_out "備考行の重複を人間判断として報告する" "「備考」行が 2 回出現している" -- --workspace "$ws"
assert_exit "残骸があっても他のエントリは移行できる" 0 -- --workspace "$ws" --apply
assert_has "残骸の直前エントリのタスク案は変換される" '^  1\. 子セッションへ委譲して実装する' "$ws/challenge-archive.md"
assert_has "残骸の直後エントリのタスク案も変換される" '^  1\. 足場を生成する' "$ws/challenge-archive.md"
assert_validator "残骸そのものは自動で直さない（違反が残る）" archive "$ws/challenge-archive.md" 1

# ---------------------------------------------------------------------------
# 9. 安全ガード: 記入例コメントの閉じ忘れで実エントリを飲み込む範囲には手を出さない
# ---------------------------------------------------------------------------

ws="$(mkws broken broken-example-comment-ledger.md)"
cp "$ws/challenge-ledger.md" "$tmp/broken.orig"
assert_out "閉じ忘れの記入例範囲は人間判断として報告する" "実エントリらしい行があるため" -- --workspace "$ws"
/usr/bin/ruby "$SCRIPT" --workspace "$ws" --apply >/dev/null 2>&1
assert_same "閉じ忘れの台帳は 1 行も書き換えない" "$tmp/broken.orig" "$ws/challenge-ledger.md"

# ---------------------------------------------------------------------------
# 10. 変異注入: 検算が本当に部分適用を止める（テストがタウトロジーでないことの確認）
# ---------------------------------------------------------------------------

for fault in drop-note uncheck-approval drop-entry drop-preamble-line move-blank-into-nest; do
  ws="$(mkws "fault-$fault" legacy-bold-heading-ledger.md)"
  cp "$ws/challenge-ledger.md" "$tmp/fault.orig"
  out="$(MIGRATE_WORKSPACE_INJECT_FAULT="$fault" /usr/bin/ruby "$SCRIPT" --workspace "$ws" --apply 2>&1)"
  got=$?
  # bash 3.2 は全角文字直前の変数展開でブレース必須（${fault}）
  if [ "$got" -eq 1 ]; then
    pass "変異注入（${fault}）を検算が検出して失敗する"
  else
    fail "変異注入（${fault}）を検算が検出して失敗する (exit: got=$got want=1)" "$out"
  fi
  assert_same "変異注入（${fault}）で部分適用を残さない" "$tmp/fault.orig" "$ws/challenge-ledger.md"
  if [ -e "$ws/.flywheel/migration-backup" ]; then
    fail "変異注入（${fault}）では書き込み前に止まる（バックアップも作らない）"
  else
    pass "変異注入（${fault}）では書き込み前に止まる（バックアップも作らない）"
  fi
  rm -f "$tmp/fault.orig"
done

# ---------------------------------------------------------------------------
# 11. scaffold 追従レポート（検出のみ・書き換えない）
# ---------------------------------------------------------------------------

ws="$(mkws scaffold)"
mkdir -p "$ws/.claude" "$ws/container"
printf '%s\n' '.flywheel/' > "$ws/.gitignore"
printf '%s\n' '{"permissions":{"allow":[]}}' > "$ws/.claude/settings.json"
printf '%s\n' 'FROM debian:stable-slim' > "$ws/container/Dockerfile"
cp "$ws/.gitignore" "$tmp/scaffold-gitignore.orig"
# 期待文言はバッククォートを含む（シェルの置換を避けるため、前後の平文だけで照合する）
assert_out "旧形式の .gitignore を検出する" '（ディレクトリ丸ごと ignore）が残っている' -- --workspace "$ws"
assert_out "cadence.json の unignore 欠落を検出する" 'cadence.json は運用設定として Git 追跡する' -- --workspace "$ws"
assert_out "container/.env の ignore 欠落を検出する" 'ホスト固有のため追跡しない' -- --workspace "$ws"
assert_out "settings.json の allow 欠落を検出する" 'の allow が無い（自走委譲が分類器でブロックされる）' -- --workspace "$ws"
assert_out "Dockerfile の ruby 未導入を検出する" 'ruby を導入していない' -- --workspace "$ws"
assert_out "不足している scaffold 物を検出する" '不足: CLAUDE.md' -- --workspace "$ws"
/usr/bin/ruby "$SCRIPT" --workspace "$ws" --apply >/dev/null 2>&1
assert_same "scaffold 追従レポートは検出のみで書き換えない" "$tmp/scaffold-gitignore.orig" "$ws/.gitignore"

ws="$(mkws docdrift)"
mkdir -p "$ws/runtime"
printf '%s\n' '# 旧い runtime/README.md' > "$ws/runtime/README.md"
assert_out "ドキュメント類のテンプレート差分を検出する" 'テンプレートと差分あり: runtime/README.md' -- --workspace "$ws"

# ---------------------------------------------------------------------------
# 12. 検査不能（exit 2）: 引数不正・対象不在を「変更なし」にも「失敗」にも丸めない
# ---------------------------------------------------------------------------

assert_exit "存在しないワークスペースは exit 2" 2 -- --workspace "$tmp/no-such-dir"
assert_exit "存在しないテンプレートディレクトリは exit 2" 2 -- --workspace "$tmp" --templates-dir "$tmp/no-such-templates"
assert_exit "不明なオプションは exit 2" 2 -- --workspace "$tmp" --bogus
assert_exit "--workspace に値が無いと exit 2" 2 -- --workspace
assert_exit "--backup-dir に値が無いと exit 2" 2 -- --workspace "$tmp" --backup-dir

# 台帳が無いワークスペース（初回 scaffold が必要）は「変更なし」で正常終了する
ws="$(mkws empty)"
assert_exit "台帳が無いワークスペースは exit 0" 0 -- --workspace "$ws"
assert_out "台帳が無いことを報告する" "初回 scaffold が必要" -- --workspace "$ws"

echo
echo "passed: $PASS / failed: $FAIL"
[ "$FAIL" -eq 0 ]
