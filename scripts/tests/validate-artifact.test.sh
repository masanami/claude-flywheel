#!/usr/bin/env bash
#
# validate-artifact.test.sh — scripts/validate-artifact.rb のテスト。
#
# 実行: bash scripts/tests/validate-artifact.test.sh
#   - 依存: bash（macOS 標準の 3.2 でも可）・/usr/bin/ruby（macOS 標準）。テストフレームワーク不使用。
#   - 書き込みはすべて一時ディレクトリ内で完結し、リポジトリの状態を変更しない。
#
# 検査の要（Issue #91）:
#   - ゴールデンフィクスチャの固定: contracts/fixtures/<type>/valid は全件 exit 0（受理方向。
#     「自分の正規出力を自分が受理しない」欠陥の防止）、invalid は全件 exit 1（拒否方向。
#     実際に起きた事故の再現が検出されること）。フィクスチャを追加すると自動でテスト対象になる。
#   - テンプレート自体がバリデータを通ること（正本は実行可能なシステム、の固定）。
#   - 散文正本（journal/README.md・runtime/README.md）のサンプル行がスキーマを通ること
#     （散文とスキーマの整合をテストで固定）。
#   - 3 値 exit の区別: 検査不能（exit 2）を「違反なし（exit 0）」にも「違反（exit 1）」にも丸めない。

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/validate-artifact.rb"
FIXTURES="$REPO_ROOT/contracts/fixtures"

PASS=0
FAIL=0

# assert_case <名前> <期待exit> <期待stdout部分文字列("-"なら検査しない)> -- <スクリプト引数...>
assert_case() {
  name="$1"; want_exit="$2"; want_out="$3"
  shift 3
  [ "$1" = "--" ] && shift
  got_out="$(/usr/bin/ruby "$SCRIPT" "$@" 2>/dev/null)"
  got_exit=$?
  ok=1
  [ "$got_exit" -eq "$want_exit" ] || ok=0
  if [ "$want_out" != "-" ]; then
    case "$got_out" in
      *"$want_out"*) ;;
      *) ok=0 ;;
    esac
  fi
  if [ "$ok" -eq 1 ]; then
    PASS=$((PASS + 1))
    echo "ok   - $name"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL - $name (exit: got=$got_exit want=$want_exit)"
    echo "       stdout: $got_out"
  fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- ゴールデンフィクスチャ（valid 全件 exit 0 / invalid 全件 exit 1・自動列挙） ---

for dir in "$FIXTURES"/*/valid; do
  type="$(basename "$(dirname "$dir")")"
  for f in "$dir"/*; do
    assert_case "valid フィクスチャ受理: $type/$(basename "$f")" 0 - -- "$type" "$f"
  done
done

for dir in "$FIXTURES"/*/invalid; do
  type="$(basename "$(dirname "$dir")")"
  for f in "$dir"/*; do
    assert_case "invalid フィクスチャ検出: $type/$(basename "$f")" 1 - -- "$type" "$f"
  done
done

# --- 事故型ごとの検出内容（メッセージが原因を特定できること） ---

assert_case "事故a: 見出し直前の空行欠落を指摘する" 1 "空行がありません" \
  -- ledger "$FIXTURES/ledger/invalid/heading-no-blank-line.md"
assert_case "事故e: 巻き添え削除された備考行を指摘する" 1 "「備考」" \
  -- ledger "$FIXTURES/ledger/invalid/missing-note-field.md"
assert_case "マーカー整合: 両種同居と重複を指摘する" 1 "マーカーの整合違反" \
  -- ledger "$FIXTURES/ledger/invalid/double-marker.md"
assert_case "事故b: decisions の string 化を指摘する" 1 "decisions: 型が array ではありません" \
  -- journal-index "$FIXTURES/journal-index/invalid/decisions-string.jsonl"
assert_case "事故c: pending_approvals の形の崩れを指摘する" 1 "pending_approvals" \
  -- journal-index "$FIXTURES/journal-index/invalid/pending-approvals-shape.jsonl"
assert_case "事故d: touched_issues.to の自由記述を指摘する" 1 "許可された語彙ではありません" \
  -- journal-index "$FIXTURES/journal-index/invalid/touched-to-freetext.jsonl"
assert_case "journal-md: 欠落セクション名を指摘する" 1 "承認待ちゲート一覧" \
  -- journal-md "$FIXTURES/journal-md/invalid/missing-section.md"
assert_case "journal-md: 順序不正を指摘する" 1 "順序が不正" \
  -- journal-md "$FIXTURES/journal-md/invalid/wrong-order.md"
assert_case "runs: 未知イベントを指摘する" 1 "どの分岐にも一致しません" \
  -- runs "$FIXTURES/runs/invalid/unknown-event.jsonl"
assert_case "runs: イベント別の必須フィールド欠落を指摘する" 1 "session_id" \
  -- runs "$FIXTURES/runs/invalid/missing-required.jsonl"

# --- テンプレート自体がバリデータを通る（正本＝実行可能なシステム、の固定） ---

assert_case "テンプレート: challenge-ledger.md（エントリ 0 件）は受理" 0 - \
  -- ledger "$REPO_ROOT/templates/challenge-ledger.md"
assert_case "テンプレート: journal/cycle-template.md は受理" 0 - \
  -- journal-md "$REPO_ROOT/templates/journal/cycle-template.md"

# --- 散文正本のサンプル行がスキーマを通る（README とスキーマの整合を固定） ---

grep '^{"date"' "$REPO_ROOT/templates/journal/README.md" > "$tmp/journal-readme-sample.jsonl"
if [ -s "$tmp/journal-readme-sample.jsonl" ]; then
  assert_case "journal/README.md のサンプル行はスキーマを通る" 0 - \
    -- journal-index "$tmp/journal-readme-sample.jsonl"
else
  FAIL=$((FAIL + 1))
  echo "FAIL - journal/README.md からサンプル行を抽出できない（README の様式が変わった可能性）"
fi

grep '^{"ts"' "$REPO_ROOT/templates/runtime/README.md" > "$tmp/runtime-readme-sample.jsonl"
if [ -s "$tmp/runtime-readme-sample.jsonl" ]; then
  assert_case "runtime/README.md のサンプル行はスキーマを通る" 0 - \
    -- runs "$tmp/runtime-readme-sample.jsonl"
else
  FAIL=$((FAIL + 1))
  echo "FAIL - runtime/README.md からサンプル行を抽出できない（README の様式が変わった可能性）"
fi

# --- archive は ledger と同じ検査（エイリアス） ---

assert_case "type=archive で archive フィクスチャを受理" 0 - \
  -- archive "$FIXTURES/ledger/valid/archive.md"
assert_case "type=archive でも事故a を検出" 1 "空行がありません" \
  -- archive "$FIXTURES/ledger/invalid/heading-no-blank-line.md"

# --- 検査不能（exit 2）: 0 件・違反のどちらにも丸めない ---

assert_case "対象ファイル不在は exit 2" 2 - -- ledger "$tmp/no-such-file.md"
assert_case "不明な type は exit 2" 2 - -- bogus-type "$FIXTURES/ledger/valid/archive.md"
assert_case "引数不足は exit 2" 2 - -- ledger
assert_case "不明なオプションは exit 2" 2 - -- ledger "$FIXTURES/ledger/valid/archive.md" --bogus
assert_case "スキーマ不在（--schema-dir が空のディレクトリ）は exit 2" 2 - \
  -- journal-index "$FIXTURES/journal-index/valid/readme-sample.jsonl" --schema-dir "$tmp"

printf '%s\n' 'not a json schema {' > "$tmp/journal-index.schema.json"
assert_case "スキーマ破損は exit 2" 2 - \
  -- journal-index "$FIXTURES/journal-index/valid/readme-sample.jsonl" --schema-dir "$tmp"

printf '%s\n' '{"type":"object","unsupportedKeyword":{}}' > "$tmp/journal-index.schema.json"
assert_case "スキーマの未対応キーワードは exit 2（黙って素通ししない）" 2 - \
  -- journal-index "$FIXTURES/journal-index/valid/readme-sample.jsonl" --schema-dir "$tmp"

if [ "$(id -u)" -ne 0 ]; then
  printf '%s\n' '# empty' > "$tmp/unreadable.md"
  chmod 000 "$tmp/unreadable.md"
  assert_case "対象ファイル読み取り不可は exit 2" 2 - -- ledger "$tmp/unreadable.md"
  chmod 644 "$tmp/unreadable.md"
else
  echo "ok   - (skip) 対象ファイル読み取り不可は exit 2（root 実行のため権限テスト不可）"
  PASS=$((PASS + 1))
fi

# --- --schema-dir の正常系（vendoring 先の層構成でも動く） ---

mkdir -p "$tmp/vendored"
cp "$REPO_ROOT/contracts/schemas/journal-index.schema.json" "$REPO_ROOT/contracts/schemas/runs.schema.json" "$tmp/vendored/"
assert_case "--schema-dir で持ち出したスキーマでも検証できる" 0 - \
  -- journal-index "$FIXTURES/journal-index/valid/readme-sample.jsonl" --schema-dir "$tmp/vendored"

# --- cwd 非依存（別ディレクトリから相対なしで実行できる） ---

if ( cd "$tmp" && /usr/bin/ruby "$SCRIPT" ledger "$FIXTURES/ledger/valid/archive.md" >/dev/null 2>&1 ); then
  PASS=$((PASS + 1))
  echo "ok   - cwd 非依存（一時ディレクトリからの実行でスキーマを自己解決）"
else
  FAIL=$((FAIL + 1))
  echo "FAIL - cwd 非依存（一時ディレクトリからの実行でスキーマを自己解決）"
fi

# --- 空ファイル・空行の扱い ---

: > "$tmp/empty.md"
assert_case "空の台帳（エントリ 0 件）は受理" 0 - -- ledger "$tmp/empty.md"
: > "$tmp/empty.jsonl"
assert_case "空の jsonl は受理（0 行＝違反なし）" 0 - -- journal-index "$tmp/empty.jsonl"

echo
echo "passed: $PASS / failed: $FAIL"
[ "$FAIL" -eq 0 ]
