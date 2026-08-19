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
assert_case "見出し降格（先頭課題の前文化）を孤児フィールドとして指摘する" 1 "属さないフィールド行" \
  -- ledger "$FIXTURES/ledger/invalid/heading-demoted.md"
assert_case "見出し降格（## [C- 化）を見出し候補として指摘する" 1 "見出し候補" \
  -- ledger "$FIXTURES/ledger/invalid/heading-demoted.md"
assert_case "見出し行の削除（後続課題の吸収）をフィールド重複として指摘する" 1 "回出現" \
  -- ledger "$FIXTURES/ledger/invalid/heading-deleted.md"
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
assert_case "journal-index: seq が 1e999（Infinity へオーバーフロー）は違反（exit 2 に丸めない）" 1 "integer" \
  -- journal-index "$FIXTURES/journal-index/invalid/seq-infinity.jsonl"
assert_case "runs: うるう秒 :60 の ts を指摘する（消費者 heartbeat の GNU date と整合）" 1 ":7:" \
  -- runs "$FIXTURES/runs/invalid/bad-ts.jsonl"
assert_case "runs: session_id/id の \" と \\\\ を指摘する（log-run-event check の対応付けキー前提）" 1 "session_id" \
  -- runs "$FIXTURES/runs/invalid/key-unsafe-chars.jsonl"

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

# うるう秒 :60 は format 層単独でも違反にする（pattern 層が無いスキーマでも消費者
# heartbeat-check（GNU date が :60 を拒否）と整合する値だけを受理する）
mkdir -p "$tmp/fmt-only"
printf '%s\n' '{"type":"object","properties":{"ts":{"type":"string","format":"date-time"}}}' > "$tmp/fmt-only/journal-index.schema.json"
printf '%s\n' '{"ts":"2026-01-01T12:00:60Z"}' > "$tmp/leap.jsonl"
assert_case "うるう秒 :60 は format 層単独でも違反（DateTime の受理を明示検査で上書き）" 1 "うるう秒" \
  -- journal-index "$tmp/leap.jsonl" --schema-dir "$tmp/fmt-only"

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
assert_case "--tail がレコード数を超える場合は不足違反＋全レコード検証で exit 1" 1 "非空レコードが 2 件" \
  -- journal-index "$tmp/legacy-index.jsonl" --tail 99

# --tail は非空レコード基準で数える（物理行基準だと末尾空行で実レコードが検証範囲から漏れ、
# 不正な当周成果物が exit 0 でコミットされる）。あわせて「追記の実在」も検証する:
# 末尾の空行（＝空行のみの追記の痕跡）と非空レコードの件数不足は違反。
bad='{"date":"bad"}'
printf '%s\n\n' "$bad" > "$tmp/trailing-blank.jsonl"
assert_case "不正レコード＋末尾空行でも --tail 1 は実レコードを検証して exit 1" 1 ":1:" \
  -- journal-index "$tmp/trailing-blank.jsonl" --tail 1
printf '%s\n\n' "$good" > "$tmp/trailing-blank-good.jsonl"
assert_case "空行のみの追記（末尾空行）は --tail 1 で違反（前周レコードの検証で誤証明しない）" 1 "末尾が空行" \
  -- journal-index "$tmp/trailing-blank-good.jsonl" --tail 1
printf '%s\n\n%s\n' "$legacy" "$good" > "$tmp/interleaved-blank.jsonl"
assert_case "空行介在でも --tail 1 は最後の実レコードだけを見て exit 0" 0 - \
  -- journal-index "$tmp/interleaved-blank.jsonl" --tail 1
assert_case "空行介在でも --tail 2 はレガシー不正レコードまで遡って exit 1" 1 ":1:" \
  -- journal-index "$tmp/interleaved-blank.jsonl" --tail 2
: > "$tmp/empty-tail.jsonl"
assert_case "空ファイルへの --tail 1 は違反（追記されたはずのレコードが無い）" 1 "非空レコードが 0 件" \
  -- journal-index "$tmp/empty-tail.jsonl" --tail 1

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

# --- archive の --expect-ids: 追記エントリのみ検証＋同一性（追記 ID 一致）の証明 ---
# 契約導入前の壊れた過去エントリ（備考行欠落）が残るアーカイブに、正常なエントリを 1 件
# 追記したシナリオ。全体検証は exit 1 のままでよい（フィクスチャ・全体契約用）が、
# run-cycle 手順6 の呼び出し形（--expect-ids <移動した課題ID>）は追記分だけを見て exit 0 に
# なり、かつ「台帳から削除したのにアーカイブへ追記しなかった」（末尾が古いエントリのまま）を
# ID 不一致として検出すること。

cat > "$tmp/legacy-archive.md" <<'EOF'
# 課題アーカイブ（Challenge Archive）

---

### [C-001] 契約導入前の壊れた過去エントリ（備考行なし・原文保存につき修復しない）

**人間記入欄**
- 起票者 / 起票日: old / 2026-01-01
- 説明: 古いエントリ。
- 完了条件（任意）:
- 体感の緊急度（任意）:

**分類欄（エージェントが記入）**
- 担当ポジション: harness
- 関連サービス:
- 優先度: P1
- ステータス: 完了
- タスク案: なし
- 承認（人間がチェック）:
  - [x] 計画を承認（FR-13）
  - [x] 完了を承認（FR-32）
- 取り込み元:

### [C-002] 当周に追記された正常なエントリ

**人間記入欄**
- 起票者 / 起票日: new / 2026-08-19
- 説明: 追記されたばかりのエントリ。
- 完了条件（任意）:
- 体感の緊急度（任意）:

**分類欄（エージェントが記入）**
- 担当ポジション: harness
- 関連サービス:
- 優先度: P2
- ステータス: 完了
- タスク案: 対応する
- 承認（人間がチェック）:
  - [x] 計画を承認（FR-13）
  - [x] 完了を承認（FR-32）
- 取り込み元:
- 備考:
EOF
assert_case "レガシー破損エントリ入りアーカイブ: 全体検証は exit 1" 1 "備考" \
  -- archive "$tmp/legacy-archive.md"
assert_case "アーカイブ --expect-ids C-002（run-cycle の呼び出し形）は追記分のみで exit 0" 0 - \
  -- archive "$tmp/legacy-archive.md" --expect-ids C-002
assert_case "--expect-ids C-001,C-002 はレガシーエントリを含み exit 1" 1 "備考" \
  -- archive "$tmp/legacy-archive.md" --expect-ids C-001,C-002
assert_case "移動漏れ（期待 ID がアーカイブ末尾に無い）を ID 不一致で検出" 1 "一致しません" \
  -- archive "$tmp/legacy-archive.md" --expect-ids C-003
assert_case "複数移動の一部漏れ（期待 2 件・末尾は別 ID）も ID 不一致で検出" 1 "一致しません" \
  -- archive "$tmp/legacy-archive.md" --expect-ids C-002,C-003
assert_case "--expect-ids がエントリ総数を超える場合は不足違反（追記の消失を素通しにしない）" 1 "エントリが 2 件" \
  -- archive "$tmp/legacy-archive.md" --expect-ids C-001,C-002,C-003

# 追記エントリ自体の違反（見出し前の空行欠落＝事故a）は範囲限定でも検出する
# （C-002 見出し直前の空行を除去した「空行なし連結」状態を生成。macOS awk は多バイト文字の
# 等値比較に難があるため、日本語を含む行の加工は ruby で行う）
/usr/bin/ruby -e 'ls = File.readlines(ARGV[0]); i = ls.index { |l| l.start_with?("### [C-002]") }; abort "C-002 見出しが見つからない" unless i && i > 0 && ls[i - 1].strip.empty?; ls.delete_at(i - 1); File.write(ARGV[1], ls.join)' "$tmp/legacy-archive.md" "$tmp/glued-archive.md"
assert_case "追記エントリの見出し前空行欠落は --expect-ids でも検出" 1 "空行がありません" \
  -- archive "$tmp/glued-archive.md" --expect-ids C-002

# 追記エントリの見出し破損（### → ## への降格）は --expect-ids の ID 照合が検出する
# （破損見出しのエントリは認識されず、末尾エントリの ID が期待と一致しなくなるため。
# 見出し破損検査を範囲限定モードで前文＝レガシー領域へ広げない根拠でもある）
/usr/bin/ruby -e 'File.write(ARGV[1], File.read(ARGV[0]).sub("### [C-002]", "## [C-002]"))' \
  "$tmp/legacy-archive.md" "$tmp/demoted-archive.md"
assert_case "追記エントリの見出し破損は --expect-ids の ID 照合が検出" 1 "一致しません" \
  -- archive "$tmp/demoted-archive.md" --expect-ids C-002

# --- journal-index の --expect-cycle: 当周の append が実際に起きたことの証明 ---
# legacy-index.jsonl の末尾レコードは date=2026-08-19 seq=1。当周がそれと一致するなら
# exit 0、一致しない（＝当周の append が丸ごと欠落し前周の行が末尾のまま）なら違反。

assert_case "journal-index --expect-cycle 一致（run-cycle の呼び出し形）は exit 0" 0 - \
  -- journal-index "$tmp/legacy-index.jsonl" --tail 1 --expect-cycle 2026-08-19-cycle
assert_case "当周 append の欠落（date 不一致）を検出" 1 "当周の行ではありません" \
  -- journal-index "$tmp/legacy-index.jsonl" --tail 1 --expect-cycle 2026-08-20-cycle
assert_case "同日複数周の欠落（seq 不一致）を検出" 1 "当周の行ではありません" \
  -- journal-index "$tmp/legacy-index.jsonl" --tail 1 --expect-cycle 2026-08-19-cycle-2
assert_case "空ファイルへの --expect-cycle はレコード不在で exit 1" 1 "レコードがありません" \
  -- journal-index "$tmp/empty-tail.jsonl" --expect-cycle 2026-08-19-cycle

# --- runs の --expect-cycle: 当周のサイクル名を持つ cycle_start をアンカーに要求 ---
# 当周の cycle_start が best-effort で書かれなかった場合、前周の stale な cycle_start を
# アンカーに前周分を「当周の検証」として誤証明しないこと。

cat > "$tmp/stale-runs.jsonl" <<'EOF'
{"ts":"2026-08-18T09:00:00+09:00","event":"cycle_start","cycle":"2026-08-18-cycle"}
{"ts":"2026-08-18T10:00:00+09:00","event":"cycle_end","cycle":"2026-08-18-cycle","result":"completed"}
EOF
assert_case "stale な前周 cycle_start を受理しない（期待サイクルの start 不在＝違反）" 1 "見つかりません" \
  -- runs "$tmp/stale-runs.jsonl" --since-last-cycle-start --expect-cycle 2026-08-19-cycle
assert_case "期待サイクルの cycle_start があれば当周分のみ検証して exit 0" 0 - \
  -- runs "$tmp/stale-runs.jsonl" --since-last-cycle-start --expect-cycle 2026-08-18-cycle
assert_case "--expect-cycle 無しの従来モードは最後の cycle_start を使う（後方互換）" 0 - \
  -- runs "$tmp/stale-runs.jsonl" --since-last-cycle-start

# --expect-cycle は終端の cycle_end（同名）の実在も要求する（best-effort append の失敗で
# 閉じられていない run が観測プレーンに残るのを検出。検証は cycle_end 記録後に走る前提）
cat > "$tmp/no-end-runs.jsonl" <<'EOF'
{"ts":"2026-08-19T09:00:00+09:00","event":"cycle_start","cycle":"2026-08-19-cycle"}
{"ts":"2026-08-19T09:05:00+09:00","event":"delegate_start","challenge":"C-001","repo":"service-a","session_id":"550e8400-e29b-41d4-a716-446655440000","title":"委譲"}
{"ts":"2026-08-19T09:40:00+09:00","event":"delegate_end","challenge":"C-001","repo":"service-a","session_id":"550e8400-e29b-41d4-a716-446655440000","result":"done"}
EOF
assert_case "期待サイクルの cycle_end 欠落（run が閉じられていない）を検出" 1 "cycle_end が見つかりません" \
  -- runs "$tmp/no-end-runs.jsonl" --since-last-cycle-start --expect-cycle 2026-08-19-cycle
assert_case "--expect-cycle 無しなら cycle_end は要求しない（後方互換）" 0 - \
  -- runs "$tmp/no-end-runs.jsonl" --since-last-cycle-start

# --anchor-after-line: クラッシュ後のサイクル名再利用で「同名の旧 cycle_start」を当周の
# 証明に使わせない（追記前の行数＝起動ごとに一意な位置でアンカーを固定する）
cat > "$tmp/reused-name-runs.jsonl" <<'EOF'
{"ts":"2026-08-19T08:00:00+09:00","event":"cycle_start","cycle":"2026-08-19-cycle"}
{"ts":"2026-08-19T09:00:00+09:00","event":"cycle_end","cycle":"2026-08-19-cycle","result":"abandoned"}
{"ts":"2026-08-19T09:30:00+09:00","event":"cycle_end","cycle":"2026-08-19-cycle","result":"completed"}
EOF
assert_case "同名の旧 cycle_start を当周の証明に使わせない（--anchor-after-line 2 で違反）" 1 "見つかりません" \
  -- runs "$tmp/reused-name-runs.jsonl" --since-last-cycle-start --expect-cycle 2026-08-19-cycle --anchor-after-line 2
assert_case "--anchor-after-line 無しだと同名旧 start で誤証明される（弱いモードの記録）" 0 - \
  -- runs "$tmp/reused-name-runs.jsonl" --since-last-cycle-start --expect-cycle 2026-08-19-cycle
cat > "$tmp/reused-name-ok-runs.jsonl" <<'EOF'
{"ts":"2026-08-19T08:00:00+09:00","event":"cycle_start","cycle":"2026-08-19-cycle"}
{"ts":"2026-08-19T09:00:00+09:00","event":"cycle_end","cycle":"2026-08-19-cycle","result":"abandoned"}
{"ts":"2026-08-19T09:10:00+09:00","event":"cycle_start","cycle":"2026-08-19-cycle"}
{"ts":"2026-08-19T09:30:00+09:00","event":"cycle_end","cycle":"2026-08-19-cycle","result":"completed"}
EOF
assert_case "当周の start が記録位置より後にあれば exit 0（run-cycle の完全形）" 0 - \
  -- runs "$tmp/reused-name-ok-runs.jsonl" --since-last-cycle-start --expect-cycle 2026-08-19-cycle --anchor-after-line 2
assert_case "--anchor-after-line がファイル行数を超える（append-only の破れ）は exit 2" 2 - \
  -- runs "$tmp/reused-name-ok-runs.jsonl" --since-last-cycle-start --expect-cycle 2026-08-19-cycle --anchor-after-line 99
assert_case "--anchor-after-line は runs の --since-last-cycle-start 専用（journal-index は exit 2）" 2 - \
  -- journal-index "$tmp/legacy-index.jsonl" --anchor-after-line 0
assert_case "--anchor-after-line 非整数は exit 2" 2 - \
  -- runs "$tmp/reused-name-ok-runs.jsonl" --since-last-cycle-start --anchor-after-line abc

# --- pattern は文字列全体アンカー（Ruby の ^ $ 行アンカー問題） ---
# 改行を含む値は 1 行が pattern に一致しても全体としては違反（禁止文字の素通し防止）
assert_case "改行入り session_id（1 行目だけ pattern 一致）を違反として検出" 1 ":3:" \
  -- runs "$FIXTURES/runs/invalid/key-unsafe-chars.jsonl"

# 期待値オプションの引数・type 制約
assert_case "--expect-ids は jsonl に使えず exit 2" 2 - \
  -- journal-index "$tmp/legacy-index.jsonl" --expect-ids C-001
assert_case "--expect-ids の空要素は exit 2" 2 - -- archive "$tmp/legacy-archive.md" --expect-ids "C-001,,C-002"
assert_case "--expect-cycle は md タイプに使えず exit 2" 2 - \
  -- ledger "$tmp/legacy-archive.md" --expect-cycle 2026-08-19-cycle
assert_case "journal-index の --expect-cycle は不正な形式なら exit 2" 2 - \
  -- journal-index "$tmp/legacy-index.jsonl" --expect-cycle bogus-name
assert_case "runs の --expect-cycle は --since-last-cycle-start 必須（無しは exit 2）" 2 - \
  -- runs "$tmp/stale-runs.jsonl" --expect-cycle 2026-08-18-cycle

# --- 実行環境の前提（container モードのイメージがバリデータのランタイムを保証する） ---
# run-cycle 手順6の検算は /usr/bin/ruby 前提（macOS 標準）。execution_mode: container の
# ベースイメージ（node:20-slim）には ruby が無いため、Dockerfile 側の導入が契約の一部。
# あわせて ingest/periodic-audit の fp 算式（shasum -a 256）が前提とする perl も固定する。

# run-cycle 手順6 の事後補記経路（journal ⑤ への追記＋追加コミット）は本体の検算より後に
# 走るため、追記後・追加コミット前の journal-md 再検証の規定が SKILL に存在することを固定する
# （規定が消えると、壊れた補記がコミットゲートを素通りする）。
SKILL_MD="$REPO_ROOT/skills/run-cycle/SKILL.md"
if grep '追加で Git コミット' "$SKILL_MD" | grep -q '再検証.*journal-md\|journal-md.*再検証'; then
  PASS=$((PASS + 1))
  echo "ok   - SKILL 手順6: 事後補記の追加コミット前に journal-md 再検証の規定がある"
else
  FAIL=$((FAIL + 1))
  echo "FAIL - SKILL 手順6: 事後補記の追加コミット前に journal-md 再検証の規定がある"
fi

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
