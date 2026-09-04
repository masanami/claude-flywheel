#!/usr/bin/env bash
#
# log-run-event.test.sh — scripts/log-run-event.sh のテスト。
#
# 実行: bash scripts/tests/log-run-event.test.sh
#   - 依存: bash（macOS 標準の 3.2 でも可）・date（GNU/BSD いずれか）。テストフレームワーク不使用。
#   - すべて一時ディレクトリ内で完結し、リポジトリの状態を変更しない。
#   - 日本語を含む文字列の一致には grep -F を使う（macOS 標準の awk は非 ASCII の == を
#     誤って真にするため）。
#
# 検査の要（Issue #98）: 「値がフラグに見える」だけで**イベントを落とさない**こと、および
# 落ちたときに**呼び出し側が exit code で気付ける**こと。あわせて best-effort 契約
# （環境要因の書き込み失敗はサイクルを止めない＝exit 0）と既存の呼び出し形が壊れていないこと。

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$TESTS_DIR/../log-run-event.sh"

PASS=0
FAIL=0

tmp="$(mktemp -d)"
trap 'chmod -R u+rwx "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT

ws="$tmp/ws"
RUNS="$ws/.flywheel/runs.jsonl"
UUID="550e8400-e29b-41d4-a716-446655440000"

# 各ケースを独立させる（前ケースの追記が次ケースの判定に混ざらないように毎回作り直す）。
reset_ws() {
  chmod -R u+rwx "$ws" 2>/dev/null
  rm -rf "$ws"
  mkdir -p "$ws"
}

# スクリプトを起動し、exit code / stdout / stderr を大域変数へ取る。
RUN_EXIT=0
RUN_OUT=""
RUN_ERR=""
run_event() {
  RUN_OUT="$(bash "$SCRIPT" "$@" 2>"$tmp/stderr")"
  RUN_EXIT=$?
  RUN_ERR="$(cat "$tmp/stderr")"
}

report() {
  if [ "$2" -eq 1 ]; then
    PASS=$((PASS + 1))
    echo "ok   - $1"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL - $1"
    echo "       exit=${RUN_EXIT} stderr=${RUN_ERR}"
    if [ -f "$RUNS" ]; then
      echo "       runs.jsonl:"
      sed 's/^/         /' "$RUNS"
    else
      echo "       runs.jsonl: (不在)"
    fi
  fi
}

# assert_written <名前> <期待exit> <runs.jsonl に含まれるべき部分文字列>
assert_written() {
  ok=1
  [ "$RUN_EXIT" -eq "$2" ] || ok=0
  if [ -f "$RUNS" ]; then
    grep -F -q -- "$3" "$RUNS" || ok=0
  else
    ok=0
  fi
  report "$1" "$ok"
}

# assert_not_written <名前> <期待exit> [stderr に含まれるべき部分文字列]
assert_not_written() {
  ok=1
  [ "$RUN_EXIT" -eq "$2" ] || ok=0
  if [ -s "$RUNS" ]; then ok=0; fi
  if [ "$#" -ge 3 ]; then
    case "$RUN_ERR" in
      *"$3"*) ;;
      *) ok=0 ;;
    esac
  fi
  report "$1" "$ok"
}

# ---------------------------------------------------------------------------
# 1. Issue #98 本体: 値が `--` で始まってもイベントを落とさない
# ---------------------------------------------------------------------------

reset_ws
run_event adhoc_end --id probe98 --result "--tail オプションを非空基準へ" --workspace "$ws"
assert_written "--result の値が -- で始まっても記録される（Issue #98 の再現ケース）" 0 \
  '"result":"--tail オプションを非空基準へ"'

reset_ws
run_event delegate_end --challenge C-031 --repo claude-flywheel --session-id "$UUID" \
  --result "--base を修正して push 済み" --workspace "$ws"
assert_written "delegate_end の --result が -- で始まっても記録される" 0 '"result":"--base を修正して push 済み"'

reset_ws
run_event delegate_start --challenge C-031 --repo claude-flywheel --session-id "$UUID" \
  --title "--expect-cycle の追加" --skill "/para-impl" --workspace "$ws"
assert_written "--title の値が -- で始まっても記録される" 0 '"title":"--expect-cycle の追加"'

reset_ws
run_event cycle_end --cycle 2026-08-21-cycle --result "--dry-run パリティの確認まで完了" --workspace "$ws"
assert_written "cycle_end の --result が -- で始まっても記録される" 0 '"result":"--dry-run パリティの確認まで完了"'

# 値が既知オプション名と**完全一致**する場合だけは曖昧なので、= 形式のエスケープを用意する。
reset_ws
run_event adhoc_end --id probe98 --result=--dry-run --workspace "$ws"
assert_written "--opt=value 形式なら既知オプション名と同一の値も渡せる" 0 '"result":"--dry-run"'

reset_ws
run_event adhoc_end --id=probe98 --result=--result --workspace="$ws"
assert_written "--opt=value 形式は全オプションで使える" 0 '"result":"--result"'

reset_ws
run_event adhoc_end --id probe98 --result "= を含む値: a=b" --workspace "$ws"
assert_written "値に = を含んでも（= 形式でなければ）そのまま記録される" 0 '"result":"= を含む値: a=b"'

reset_ws
run_event adhoc_end --id probe98 --result "--work だけでは既知オプション名ではない" --workspace "$ws"
assert_written "既知オプション名の前方一致でしかない値は値として扱う" 0 \
  '"result":"--work だけでは既知オプション名ではない"'

reset_ws
run_event adhoc_end --id probe98 --result "-1 件だけ残った" --workspace "$ws"
assert_written "単一ハイフンで始まる値も値として扱う" 0 '"result":"-1 件だけ残った"'

# 意図的なトレードオフ: `--opt=<value>` 形式の**オプション名部分まで一致**する値は曖昧扱いにする
# （`--result --workspace=/x` のような「値の指定漏れ ＋ 次が = 形式のフラグ」を取りこぼさないため）。
# 落ちるのではなく exit 2 で知らせ、= 形式のエスケープを案内する。
reset_ws
run_event adhoc_end --id probe98 --result "--workspace=/tmp を修正" --workspace "$ws"
assert_not_written "= 形式のオプション名に一致する値は曖昧として exit 2（= 形式で明示する）" 2 "判別できません"

reset_ws
run_event adhoc_end --id probe98 --result="--workspace=/tmp を修正" --workspace "$ws"
assert_written "上記も = 形式なら値として渡せる" 0 '"result":"--workspace=/tmp を修正"'

# ---------------------------------------------------------------------------
# 2. 落ちるときは呼び出し側が exit code で気付ける（無言で落ちない）
# ---------------------------------------------------------------------------

reset_ws
run_event adhoc_end --id probe98 --result --dry-run --workspace "$ws"
assert_not_written "値が既知オプション名と完全一致するときは exit 2（書かずに知らせる）" 2 "--result=--dry-run"

reset_ws
run_event adhoc_end --id probe98 --result --workspace "$ws"
assert_not_written "--result の直後に既知オプションが続くときは exit 2" 2 "判別できません"

reset_ws
run_event adhoc_end --id probe98 --result
assert_not_written "末尾のオプションに値が無いときは exit 2" 2 "値がありません"

reset_ws
run_event bogus_event --cycle x --workspace "$ws"
assert_not_written "不正なイベント名は exit 2" 2 "不正なイベント名"

reset_ws
run_event cycle_start --cycle x --bogus v --workspace "$ws"
assert_not_written "不明な引数は exit 2" 2 "不明な引数"

reset_ws
run_event
assert_not_written "イベント名なしは exit 2" 2 "イベント名がありません"

reset_ws
run_event cycle_end --cycle 2026-08-21-cycle --workspace "$ws"
assert_not_written "必須オプション（--result）の欠落は exit 2" 2 "必須オプションがありません"

reset_ws
run_event delegate_start --challenge C-031 --repo r --session-id 'a"b' --workspace "$ws"
assert_not_written "--session-id の \" は exit 2" 2 "--session-id"

reset_ws
run_event cycle_start --cycle x --workspace ""
assert_not_written "空の --workspace は exit 2" 2 "--workspace が空です"

reset_ws
run_event cycle_start --cycle "" --workspace "$ws"
assert_not_written "--opt に空文字を渡した必須欠落も exit 2" 2 "必須オプションがありません"

reset_ws
run_event cycle_start --dry-run=1 --cycle x --workspace "$ws"
assert_not_written "値を取らない --dry-run への = 付与は exit 2" 2 "--dry-run"

# ---------------------------------------------------------------------------
# 3. best-effort 契約: 環境要因の書き込み失敗はサイクルを止めない（exit 0 のまま）
# ---------------------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
  reset_ws
  mkdir -p "$ws/.flywheel"
  : > "$RUNS"
  chmod 400 "$RUNS"
  run_event cycle_start --cycle 2026-08-21-cycle --workspace "$ws"
  assert_not_written "runs.jsonl に append できなくても exit 0（best-effort）" 0 "append に失敗しました"
  chmod 600 "$RUNS"

  reset_ws
  chmod 500 "$ws"
  run_event cycle_start --cycle 2026-08-21-cycle --workspace "$ws"
  ok=1
  [ "$RUN_EXIT" -eq 0 ] || ok=0
  case "$RUN_ERR" in *"ディレクトリを作成できません"*) ;; *) ok=0 ;; esac
  report "\`.flywheel\` を作成できなくても exit 0（best-effort）" "$ok"
  chmod 700 "$ws"
else
  echo "ok   - (skip) 書き込み失敗時の best-effort（root 実行のため権限テスト不可）"
  PASS=$((PASS + 1))
fi

reset_ws
run_event cycle_start --cycle 2026-08-21-cycle --dry-run --workspace "$ws"
ok=1
[ "$RUN_EXIT" -eq 0 ] || ok=0
[ -s "$RUNS" ] && ok=0
case "$RUN_OUT" in *"dry-run"*) ;; *) ok=0 ;; esac
report "--dry-run は書かずに exit 0" "$ok"

reset_ws
run_event adhoc_end --id probe98 --result "--tail を確認" --dry-run --workspace "$ws"
ok=1
[ "$RUN_EXIT" -eq 0 ] || ok=0
[ -s "$RUNS" ] && ok=0
case "$RUN_OUT" in *'"result":"--tail を確認"'*) ;; *) ok=0 ;; esac
report "--dry-run でも -- で始まる値を解釈する" "$ok"

# ---------------------------------------------------------------------------
# 4. 既存の呼び出し形（run-cycle / start-day）が壊れていない
# ---------------------------------------------------------------------------

reset_ws
run_event cycle_start --cycle 2026-08-21-cycle --workspace "$ws"
assert_written "run-cycle 手順0: cycle_start" 0 '"event":"cycle_start","cycle":"2026-08-21-cycle"'

run_event delegate_start --challenge C-044 --repo net-config --session-id "$UUID" \
  --title "レビューコメント対応の resume 委譲" --skill "/pr-review-respond" --workspace "$ws"
assert_written "run-cycle 手順3: delegate_start（title/skill 付き）" 0 '"skill":"/pr-review-respond"'

run_event delegate_end --challenge C-044 --repo net-config --session-id "$UUID" \
  --result "実装完了・PR起票（照合済み）" --workspace "$ws"
assert_written "run-cycle 手順4: delegate_end" 0 '"result":"実装完了・PR起票（照合済み）"'

run_event cycle_end --cycle 2026-08-21-cycle --result completed --workspace "$ws"
assert_written "run-cycle 手順6: cycle_end" 0 '"event":"cycle_end","cycle":"2026-08-21-cycle","result":"completed"'

run_event adhoc_start --id adhoc-20260821-1302-ci-failure --title "CI 落ちの調査" --repo net-config --workspace "$ws"
assert_written "差し込み: adhoc_start" 0 '"id":"adhoc-20260821-1302-ci-failure","title":"CI 落ちの調査"'

run_event adhoc_end --id adhoc-20260821-1302-ci-failure --result "修正PRを作成" --workspace "$ws"
assert_written "差し込み: adhoc_end" 0 '"id":"adhoc-20260821-1302-ci-failure","result":"修正PRを作成"'

# フィールド順（ts, event, cycle, challenge, repo, session_id, id, title, skill, result）は
# 消費者（観測プレーン）のパーサ・contracts/fixtures と同じ並びを保つ。
run_event delegate_start --challenge C-045 --repo net-config --session-id "$UUID" \
  --title "t" --skill "/s" --workspace "$ws"
assert_written "フィールド順が維持されている" 0 \
  '"event":"delegate_start","challenge":"C-045","repo":"net-config","session_id":"550e8400-e29b-41d4-a716-446655440000","title":"t","skill":"/s"}'

# JSON エスケープ（自由テキスト）は従来どおり
reset_ws
run_event adhoc_end --id probe98 --result 'a"b\c' --workspace "$ws"
assert_written "\" と \\ は JSON エスケープされる" 0 '"result":"a\"b\\c"'

reset_ws
run_event adhoc_end --id probe98 --result "$(printf 'a\nb')" --workspace "$ws"
ok=1
[ "$RUN_EXIT" -eq 0 ] || ok=0
[ "$(grep -c . "$RUNS" 2>/dev/null || echo 0)" -eq 1 ] || ok=0
grep -F -q -- '"result":"a b"' "$RUNS" 2>/dev/null || ok=0
report "改行はスペースへ潰され 1 イベント＝1 行が保たれる" "$ok"

# ヘルプ
reset_ws
run_event --help
ok=1
[ "$RUN_EXIT" -eq 0 ] || ok=0
case "$RUN_OUT" in *"log-run-event.sh"*) ;; *) ok=0 ;; esac
report "--help は exit 0 で使い方を出す" "$ok"

# ---------------------------------------------------------------------------
# 5. check サブコマンド（読み取り専用。exit 0/1/2 の 3 値契約）
# ---------------------------------------------------------------------------

# check_case <名前> <期待exit> <stdout に含まれるべき部分文字列("-"なら検査しない)> -- <引数...>
check_case() {
  name="$1"; want_exit="$2"; want_out="$3"
  shift 3
  [ "$1" = "--" ] && shift
  RUN_OUT="$(bash "$SCRIPT" check "$@" 2>"$tmp/stderr")"
  RUN_EXIT=$?
  RUN_ERR="$(cat "$tmp/stderr")"
  ok=1
  [ "$RUN_EXIT" -eq "$want_exit" ] || ok=0
  if [ "$want_out" != "-" ]; then
    case "$RUN_OUT" in
      *"$want_out"*) ;;
      *) ok=0 ;;
    esac
  fi
  report "$name" "$ok"
}

reset_ws
mkdir -p "$ws/.flywheel"
: > "$RUNS"
check_case "check: 空の runs.jsonl は exit 0" 0 - -- --workspace "$ws"

cat > "$RUNS" <<EOF
{"ts":"2026-08-21T10:00:00+09:00","event":"cycle_start","cycle":"2026-08-21-cycle"}
{"ts":"2026-08-21T10:05:00+09:00","event":"delegate_start","challenge":"C-044","repo":"net-config","session_id":"${UUID}","title":"未終了の委譲"}
EOF
check_case "check: 未終了 delegate_start は exit 1 で列挙" 1 "$UUID" -- --workspace "$ws"
check_case "check: --workspace=<dir> 形式でも読める" 1 "$UUID" -- --workspace="$ws"

printf '%s\n' "{\"ts\":\"2026-08-21T10:42:00+09:00\",\"event\":\"delegate_end\",\"challenge\":\"C-044\",\"repo\":\"net-config\",\"session_id\":\"${UUID}\",\"result\":\"完了\"}" >> "$RUNS"
check_case "check: 閉じられていれば exit 0" 0 - -- --workspace "$ws"

check_case "check: workspace 不在は exit 2" 2 - -- --workspace "$tmp/no-such-dir"
check_case "check: 不明な引数は exit 2" 2 - -- --bogus
check_case "check: --workspace に値が無ければ exit 2" 2 - -- --workspace

# Issue #98 と同型: check 側でも「値がフラグに見える」判定は既知オプション名の完全一致に限る。
check_case "check: --workspace の値が既知オプション名と一致すれば exit 2" 2 - -- --workspace --workspace

# 未終了 adhoc_start も検出する（run-cycle 手順6 の検算対象）
reset_ws
mkdir -p "$ws/.flywheel"
printf '%s\n' '{"ts":"2026-08-21T13:02:00+09:00","event":"adhoc_start","id":"adhoc-20260821-1302-x","title":"差し込み"}' > "$RUNS"
check_case "check: 未終了 adhoc_start も exit 1 で列挙" 1 "adhoc-20260821-1302-x" -- --workspace "$ws"

# 書き込みと check の往復（Issue #98 の二次被害の回帰）:
# -- で始まる --result で閉じた *_end が「未終了」として現れないこと。
reset_ws
run_event adhoc_start --id probe98 --title "先頭 -- の値の検証" --workspace "$ws"
run_event adhoc_end --id probe98 --result "--tail オプションを非空基準へ" --workspace "$ws"
check_case "書き込み→check の往復: -- で始まる値で閉じた start は未終了に残らない" 0 - -- --workspace "$ws"

# ---------------------------------------------------------------------------
# 6. check: 対応する start が無い *_end と、同一キーへの *_end の重複（Issue #142）
# ---------------------------------------------------------------------------
# 未終了 start の「裏返し」。append は best-effort（環境要因の失敗は exit 0）である以上、
# start 側の欠落は仕様上ありうるのに、旧実装では閉じる相手の無い end がスタックに何も
# 起こさず黙って捨てられていた（＝完了済み作業の二重計上を観測面・reflect が検知できない）。
# 出力形式は `<種別ラベル><TAB><runs.jsonl の該当行>`、exit code は既存の未終了 start と
# 同じ 1（呼び出し側＝run-cycle 手順6 の「exit 1 なら実状態を確認する」扱いを変えないため）。
TAB="$(printf '\t')"

reset_ws
mkdir -p "$ws/.flywheel"
# Issue #142 の再現データ: 正常系 1 件・orphan end 1 件・duplicate end 1 件。
cat > "$RUNS" <<'EOF'
{"ts":"2026-09-01T10:00:00+09:00","event":"adhoc_start","id":"adhoc-A","title":"正常系: start と end が対応する"}
{"ts":"2026-09-01T10:30:00+09:00","event":"adhoc_end","id":"adhoc-A","result":"完了"}
{"ts":"2026-09-01T11:00:00+09:00","event":"adhoc_end","id":"adhoc-B","result":"対応する start が無い end"}
{"ts":"2026-09-01T12:00:00+09:00","event":"adhoc_start","id":"adhoc-C","title":"end が二重に打たれる"}
{"ts":"2026-09-01T12:30:00+09:00","event":"adhoc_end","id":"adhoc-C","result":"1回目"}
{"ts":"2026-09-01T12:40:00+09:00","event":"adhoc_end","id":"adhoc-C","result":"2回目（重複）"}
EOF
check_case "check: 対応する start が無い end を orphan_end として exit 1 で列挙" \
  1 "orphan_end${TAB}{\"ts\":\"2026-09-01T11:00:00+09:00\"" -- --workspace "$ws"
check_case "check: 同一 id への 2 回目の end を duplicate_end として列挙" \
  1 "duplicate_end${TAB}{\"ts\":\"2026-09-01T12:40:00+09:00\"" -- --workspace "$ws"

# 検出は「該当行だけ」であること。出力が入力を素通ししていれば正常系（adhoc-A）と
# duplicate の 1 回目も混ざるため、行数と非該当 id の不在まで固定する。
RUN_OUT="$(bash "$SCRIPT" check --workspace "$ws" 2>"$tmp/stderr")"
RUN_EXIT=$?
RUN_ERR="$(cat "$tmp/stderr")"
ok=1
[ "$RUN_EXIT" -eq 1 ] || ok=0
[ "$(printf '%s\n' "$RUN_OUT" | grep -c .)" -eq 2 ] || ok=0
printf '%s\n' "$RUN_OUT" | grep -F -q "adhoc-A" && ok=0
printf '%s\n' "$RUN_OUT" | grep -F -q "1回目" && ok=0
report "check: 正しく閉じた start/end は列挙しない（該当は 2 行のみ）" "$ok"

# 未終了 start にも種別ラベルが付く（3 種を同じ出力面に載せるため。既存の「該当行を列挙」
# という契約はラベルの後ろにそのまま残る）。
reset_ws
mkdir -p "$ws/.flywheel"
printf '%s\n' '{"ts":"2026-09-01T13:00:00+09:00","event":"adhoc_start","id":"adhoc-D","title":"閉じられていない差し込み"}' > "$RUNS"
check_case "check: 未終了 start には dangling_start ラベルが付く" \
  1 "dangling_start${TAB}{\"ts\":\"2026-09-01T13:00:00+09:00\"" -- --workspace "$ws"

# delegate_* 側（対応付けキーは session_id）でも同じ 2 種を検出する。
reset_ws
mkdir -p "$ws/.flywheel"
cat > "$RUNS" <<EOF
{"ts":"2026-09-01T14:00:00+09:00","event":"delegate_end","challenge":"C-044","repo":"net-config","session_id":"${UUID}","result":"start が無い end"}
EOF
check_case "check: delegate_end も start が無ければ orphan_end として列挙" \
  1 "orphan_end${TAB}{\"ts\":\"2026-09-01T14:00:00+09:00\"" -- --workspace "$ws"

# 別サイクルへ持ち越した --resume は同一キーの start が再登場する（runtime/README.md の
# 「再開（--resume）の扱い」）。start→end→start→end を duplicate_end と誤検出しないこと。
reset_ws
mkdir -p "$ws/.flywheel"
cat > "$RUNS" <<EOF
{"ts":"2026-09-01T15:00:00+09:00","event":"delegate_start","challenge":"C-044","repo":"net-config","session_id":"${UUID}"}
{"ts":"2026-09-01T15:30:00+09:00","event":"delegate_end","challenge":"C-044","repo":"net-config","session_id":"${UUID}","result":"1周目"}
{"ts":"2026-09-02T09:00:00+09:00","event":"delegate_start","challenge":"C-044","repo":"net-config","session_id":"${UUID}"}
{"ts":"2026-09-02T09:30:00+09:00","event":"delegate_end","challenge":"C-044","repo":"net-config","session_id":"${UUID}","result":"2周目"}
EOF
check_case "check: resume による同一キーの再登場（start→end→start→end）は異常なし" \
  0 - -- --workspace "$ws"

echo
echo "passed: $PASS / failed: $FAIL"
[ "$FAIL" -eq 0 ]
