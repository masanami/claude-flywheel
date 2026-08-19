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
assert_case "runs: cycle_end.result の語彙逸脱（completed/abandoned 以外）を指摘する" 1 "許可された語彙ではありません" \
  -- runs "$FIXTURES/runs/invalid/cycle-end-bad-result.jsonl"
assert_case "runs: 桁形状だけ合う不正 ts（2026-99-99T99:99:99+99:99）を指摘する" 1 ":3:" \
  -- runs "$FIXTURES/runs/invalid/bad-ts.jsonl"
assert_case "runs: 暦日として存在しない ts（2026-02-31・値域は妥当）を意味検証で指摘する" 1 "ISO 8601 の日時として不正" \
  -- runs "$FIXTURES/runs/invalid/bad-ts.jsonl"
assert_case "journal-index: 暦日として存在しない date（2026-02-30）を意味検証で指摘する" 1 "ISO 8601 の日付として不正" \
  -- journal-index "$FIXTURES/journal-index/invalid/date-invalid.jsonl"

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

# --- 検査不能（exit 2）: キーワード値の形が不正なスキーマ（JSON としては妥当）を
#     正常（空入力で exit 0）にも違反（未捕捉例外の exit 1）にも丸めない ---

# 入力の空/非空に関わらずスキーマ受理の時点で exit 2 になることを両方で固定する
: > "$tmp/empty-input.jsonl"
malformed_schema_case() {
  desc="$1"; schema_json="$2"
  printf '%s\n' "$schema_json" > "$tmp/journal-index.schema.json"
  # bash 3.2 は全角文字直前の変数展開でブレース必須（${desc}）
  assert_case "不正スキーマ（${desc}）は非空入力で exit 2" 2 - \
    -- journal-index "$FIXTURES/journal-index/valid/readme-sample.jsonl" --schema-dir "$tmp"
  assert_case "不正スキーマ（${desc}）は空入力でも exit 2" 2 - \
    -- journal-index "$tmp/empty-input.jsonl" --schema-dir "$tmp"
}

malformed_schema_case "required が文字列" '{"type":"object","required":"date"}'
malformed_schema_case "oneOf がオブジェクト" '{"oneOf":{}}'
malformed_schema_case "enum が文字列" '{"type":"object","properties":{"date":{"enum":"x"}}}'
malformed_schema_case "pattern が不正な正規表現" '{"type":"object","properties":{"date":{"type":"string","pattern":"["}}}'
malformed_schema_case "additionalProperties がサブスキーマ" '{"type":"object","additionalProperties":{"type":"string"}}'
malformed_schema_case "minLength が文字列" '{"type":"object","properties":{"date":{"type":"string","minLength":"1"}}}'
malformed_schema_case "type が配列" '{"type":["string","null"]}'
malformed_schema_case "format が未対応の値" '{"type":"object","properties":{"date":{"type":"string","format":"email"}}}'

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

# --- append-only の恒久記録: 当周の追記分だけを検証する（過去の不正行で恒久失敗しない） ---
# 契約導入前の不正行（実事故形）が残る index.jsonl に正しい 1 行を append したシナリオ。
# 全行検証は exit 1 のままでよい（契約全体の検証・パーサテスト用）が、run-cycle 手順6 の
# 呼び出し形（--tail 1）は当周の追記行だけを見て exit 0 になること。

legacy='{"date":"2026-08-15","seq":1,"touched_issues":[],"delegations":[],"pr_urls":[],"pending_approvals":[],"decisions":"レガシーの不正行（string の decisions）"}'
good='{"date":"2026-08-19","seq":1,"touched_issues":[],"delegations":[],"pr_urls":[],"pending_approvals":[],"decisions":[]}'
printf '%s\n%s\n' "$legacy" "$good" > "$tmp/legacy-index.jsonl"
assert_case "レガシー不正行入り index.jsonl: 全行検証は exit 1（絶対行番号で報告）" 1 ":1:" \
  -- journal-index "$tmp/legacy-index.jsonl"
assert_case "レガシー不正行入り index.jsonl: --tail 1（run-cycle の呼び出し形）は exit 0" 0 - \
  -- journal-index "$tmp/legacy-index.jsonl" --tail 1
assert_case "--tail 2 はレガシー行を含み exit 1" 1 - \
  -- journal-index "$tmp/legacy-index.jsonl" --tail 2
printf '%s\n%s\n' "$good" "$legacy" > "$tmp/legacy-last.jsonl"
assert_case "--tail 1 でも末尾行が不正なら exit 1（当周の違反は検出する）" 1 ":2:" \
  -- journal-index "$tmp/legacy-last.jsonl" --tail 1
assert_case "--tail がファイル行数を超えても全行を検証して動く" 1 - \
  -- journal-index "$tmp/legacy-index.jsonl" --tail 99

# --tail は非空レコード基準で数える（物理行基準だと末尾空行で実レコードが検証範囲から漏れ、
# 不正な当周成果物が exit 0 でコミットされる）
bad='{"date":"bad"}'
printf '%s\n\n' "$bad" > "$tmp/trailing-blank.jsonl"
assert_case "不正レコード＋末尾空行でも --tail 1 は実レコードを検証して exit 1" 1 ":1:" \
  -- journal-index "$tmp/trailing-blank.jsonl" --tail 1
printf '%s\n\n' "$good" > "$tmp/trailing-blank-good.jsonl"
assert_case "正常レコード＋末尾空行の --tail 1 は exit 0" 0 - \
  -- journal-index "$tmp/trailing-blank-good.jsonl" --tail 1
printf '%s\n\n%s\n\n\n' "$legacy" "$good" > "$tmp/interleaved-blank.jsonl"
assert_case "空行介在＋末尾空行複数でも --tail 1 は最後の実レコードだけを見て exit 0" 0 - \
  -- journal-index "$tmp/interleaved-blank.jsonl" --tail 1
assert_case "空行介在でも --tail 2 はレガシー不正レコードまで遡って exit 1" 1 ":1:" \
  -- journal-index "$tmp/interleaved-blank.jsonl" --tail 2

# runs: 最後の cycle_start 以降だけを検証する（1 周の追記行数が可変のため tail でなく範囲指定）
cat > "$tmp/legacy-runs.jsonl" <<'EOF'
{"ts":"2026-08-01T10:00:00+09:00","event":"cycle_begin","cycle":"legacy-broken"}
{"ts":"2026-08-01T10:30:00+09:00","event":"cycle_end","cycle":"2026-08-01-cycle","result":"done"}
{"ts":"2026-08-19T09:00:00+09:00","event":"cycle_start","cycle":"2026-08-19-cycle"}
{"ts":"2026-08-19T09:05:00+09:00","event":"delegate_start","challenge":"C-031","repo":"claude-flywheel","session_id":"550e8400-e29b-41d4-a716-446655440000"}
{"ts":"2026-08-19T10:00:00+09:00","event":"delegate_end","challenge":"C-031","repo":"claude-flywheel","session_id":"550e8400-e29b-41d4-a716-446655440000","result":"done"}
{"ts":"2026-08-19T10:05:00+09:00","event":"cycle_end","cycle":"2026-08-19-cycle","result":"completed"}
EOF
assert_case "レガシー不正行入り runs.jsonl: 全行検証は exit 1" 1 - \
  -- runs "$tmp/legacy-runs.jsonl"
assert_case "runs --since-last-cycle-start（run-cycle の呼び出し形）は当周分のみで exit 0" 0 - \
  -- runs "$tmp/legacy-runs.jsonl" --since-last-cycle-start
printf '%s\n' '{"ts":"2026-08-19T10:06:00+09:00","event":"cycle_end","cycle":"2026-08-19-cycle"}' >> "$tmp/legacy-runs.jsonl"
assert_case "runs --since-last-cycle-start は当周の違反（result 欠落）を絶対行番号で検出" 1 ":7:" \
  -- runs "$tmp/legacy-runs.jsonl" --since-last-cycle-start
printf '\n\n' >> "$tmp/legacy-runs.jsonl"
assert_case "runs --since-last-cycle-start は末尾空行があっても当周の違反を検出（範囲漏れなし）" 1 ":7:" \
  -- runs "$tmp/legacy-runs.jsonl" --since-last-cycle-start

printf '%s\n' '{"ts":"2026-08-19T10:00:00+09:00","event":"cycle_end","cycle":"x","result":"completed"}' > "$tmp/no-start-runs.jsonl"
assert_case "runs --since-last-cycle-start: cycle_start 不在は exit 2（0 件と読み替えない）" 2 - \
  -- runs "$tmp/no-start-runs.jsonl" --since-last-cycle-start

# 範囲指定オプションの引数エラー（exit 2）
assert_case "--tail 0 は exit 2" 2 - -- journal-index "$tmp/legacy-index.jsonl" --tail 0
assert_case "--tail 非整数は exit 2" 2 - -- journal-index "$tmp/legacy-index.jsonl" --tail abc
assert_case "--tail は md タイプに使えず exit 2" 2 - -- ledger "$FIXTURES/ledger/valid/archive.md" --tail 1
assert_case "--since-last-cycle-start は runs 以外に使えず exit 2" 2 - \
  -- journal-index "$tmp/legacy-index.jsonl" --since-last-cycle-start
assert_case "--tail と --since-last-cycle-start の同時指定は exit 2" 2 - \
  -- runs "$tmp/legacy-runs.jsonl" --tail 1 --since-last-cycle-start

# --- 実行環境の前提（container モードのイメージがバリデータのランタイムを保証する） ---
# run-cycle 手順6の検算は /usr/bin/ruby 前提（macOS 標準）。execution_mode: container の
# ベースイメージ（node:20-slim）には ruby が無いため、Dockerfile 側の導入が契約の一部。
# あわせて ingest/periodic-audit の fp 算式（shasum -a 256）が前提とする perl も固定する。

DOCKERFILE="$REPO_ROOT/templates/container/Dockerfile"
for pkg in ruby perl; do
  if grep -q "^      $pkg \\\\\$" "$DOCKERFILE"; then
    PASS=$((PASS + 1))
    echo "ok   - container イメージが $pkg を導入する（run-cycle 前提ツールの保証）"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL - container イメージが $pkg を導入する（run-cycle 前提ツールの保証）"
  fi
done

# --- 空ファイル・空行の扱い ---

: > "$tmp/empty.md"
assert_case "空の台帳（エントリ 0 件）は受理" 0 - -- ledger "$tmp/empty.md"
: > "$tmp/empty.jsonl"
assert_case "空の jsonl は受理（0 行＝違反なし）" 0 - -- journal-index "$tmp/empty.jsonl"

echo
echo "passed: $PASS / failed: $FAIL"
[ "$FAIL" -eq 0 ]
