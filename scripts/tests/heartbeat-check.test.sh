#!/usr/bin/env bash
#
# heartbeat-check.test.sh — scripts/heartbeat-check.sh のテスト。
#
# 実行: bash scripts/tests/heartbeat-check.test.sh
#   - 依存: bash（macOS 標準の 3.2 でも可）・date（GNU/BSD いずれか）。テストフレームワーク不使用。
#   - すべて一時ディレクトリ内で完結し、リポジトリの状態を変更しない。
#   - 判定を決定的にするため TZ=Asia/Tokyo と --now（現在時刻の注入）を使う。
#     2026-08-06=木 / 08-07=金 / 08-08=土 / 08-09=日 / 08-10=月 / 08-11=火。
#
# 検査の要（Issue #83）: 「検査不能≠0件」— runs.jsonl 不在・読めない・cycle_end 未記録を
# 「経過ゼロ・正常（exit 0）」と誤判定しないこと。

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$TESTS_DIR/../heartbeat-check.sh"
export TZ=Asia/Tokyo

PASS=0
FAIL=0

# assert_case <名前> <期待exit> <期待stdout部分文字列("-"なら検査しない)> -- <スクリプト引数...>
assert_case() {
  name="$1"; want_exit="$2"; want_out="$3"
  shift 3
  [ "$1" = "--" ] && shift
  got_out="$(bash "$SCRIPT" "$@" 2>/dev/null)"
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

ws="$tmp/ws"
mkdir -p "$ws/.flywheel"

# --- 検査不能（exit 2）: 「検査不能≠0件」の規律 ---

rmdir "$ws/.flywheel"
assert_case "runs.jsonl 不在は exit 2（0件・正常と誤判定しない）" 2 - -- --workspace "$ws"
mkdir -p "$ws/.flywheel"

: > "$ws/.flywheel/runs.jsonl"
assert_case "空の runs.jsonl（cycle_end 無し）は exit 2" 2 - -- --workspace "$ws"

printf '%s\n' '{"ts":"2026-08-06T10:00:00+09:00","event":"cycle_start","cycle":"2026-08-06-cycle"}' > "$ws/.flywheel/runs.jsonl"
assert_case "cycle_start のみ（cycle_end 未記録）は exit 2" 2 - -- --workspace "$ws"

printf '%s\n' '{"ts":"broken","event":"cycle_end","cycle":"x","result":"completed"}' > "$ws/.flywheel/runs.jsonl"
assert_case "ts が解析不能な cycle_end は exit 2" 2 - -- --workspace "$ws"

assert_case "workspace 不在は exit 2" 2 - -- --workspace "$tmp/no-such-dir"

# 未来時刻の cycle_end（時計補正・壊れたイベント）: gap_days=0 → exit 0 への
# フォールスルーで拍動喪失がマスクされないこと（「検査不能≠0件」の回帰テスト）
printf '%s\n' '{"ts":"2026-08-12T10:00:00+09:00","event":"cycle_end","cycle":"future","result":"completed"}' > "$ws/.flywheel/runs.jsonl"
assert_case "未来時刻の cycle_end は exit 2（空白なしと誤判定しない）" 2 - -- --workspace "$ws" --now 2026-08-11T10:00:00+09:00
assert_case "現在時刻と同時刻の cycle_end は fresh（未来扱いしない）" 0 - -- --workspace "$ws" --now 2026-08-12T10:00:00+09:00

if [ "$(id -u)" -ne 0 ]; then
  printf '%s\n' '{"ts":"2026-08-06T10:30:00+09:00","event":"cycle_end","cycle":"x","result":"completed"}' > "$ws/.flywheel/runs.jsonl"
  chmod 000 "$ws/.flywheel/runs.jsonl"
  assert_case "runs.jsonl 読み取り不可は exit 2" 2 - -- --workspace "$ws"
  chmod 644 "$ws/.flywheel/runs.jsonl"
else
  echo "ok   - (skip) runs.jsonl 読み取り不可は exit 2（root 実行のため権限テスト不可）"
  PASS=$((PASS + 1))
fi

# --- 引数エラー（exit 2） ---

printf '%s\n' '{"ts":"2026-08-06T10:30:00+09:00","event":"cycle_end","cycle":"x","result":"completed"}' > "$ws/.flywheel/runs.jsonl"
assert_case "不正な business-days は exit 2" 2 - -- --workspace "$ws" --business-days "8-9"
assert_case "不正な business-days（構文）は exit 2" 2 - -- --workspace "$ws" --business-days "mon-fri"
assert_case "しきい値 0 は exit 2" 2 - -- --workspace "$ws" --stale-after-business-days 0
assert_case "不明な引数は exit 2" 2 - -- --bogus
assert_case "解析不能な --now は exit 2" 2 - -- --workspace "$ws" --now "not-a-date"

# --- 空白なし（exit 0） ---

# 最終 cycle_end: 2026-08-06（木）10:30
assert_case "同日中は fresh" 0 - -- --workspace "$ws" --now 2026-08-06T17:00:00+09:00
assert_case "翌営業日（木→金）は fresh（間に営業日なし）" 0 - -- --workspace "$ws" --now 2026-08-07T10:00:00+09:00

printf '%s\n' '{"ts":"2026-08-07T18:00:00+09:00","event":"cycle_end","cycle":"y","result":"completed"}' >> "$ws/.flywheel/runs.jsonl"
assert_case "金曜終業→月曜朝は fresh（土日は営業日でない）" 0 - -- --workspace "$ws" --now 2026-08-10T10:00:00+09:00
assert_case "しきい値 2 なら金→火（空白は月の1営業日）も fresh" 0 - -- --workspace "$ws" --now 2026-08-11T10:00:00+09:00 --stale-after-business-days 2

# --- 拍動停止の疑い（exit 1） ---

assert_case "金→火（月曜が丸1営業日空白）は stale" 1 "営業日 1 日の空白" -- --workspace "$ws" --now 2026-08-11T10:00:00+09:00
assert_case "business-days 0-6 なら金→月（土日空白）も stale" 1 "営業日 2 日の空白" -- --workspace "$ws" --now 2026-08-10T10:00:00+09:00 --business-days 0-6

# Issue #83 の実シナリオ: 8/6（木）の cycle_end を最後に 8/11（火）まで停止。
# 未終了 delegate_start が放置されている。
cat > "$ws/.flywheel/runs.jsonl" <<'EOF'
{"ts":"2026-08-06T10:00:00+09:00","event":"cycle_start","cycle":"2026-08-06-cycle"}
{"ts":"2026-08-06T10:30:00+09:00","event":"cycle_end","cycle":"2026-08-06-cycle","result":"completed"}
{"ts":"2026-08-06T15:53:00+09:00","event":"delegate_start","challenge":"C-044","repo":"net-config","session_id":"550e8400-e29b-41d4-a716-446655440000","title":"放置された委譲"}
EOF
assert_case "Issue #83 再現（木→火・金月の2営業日空白）は stale" 1 "営業日 2 日の空白" -- --workspace "$ws" --now 2026-08-11T17:59:00+09:00
assert_case "stale 時に未終了 *_start の件数を出す" 1 "未終了の *_start: 1 件" -- --workspace "$ws" --now 2026-08-11T17:59:00+09:00
assert_case "stale 時に未終了 *_start の該当行を列挙する" 1 "550e8400-e29b-41d4-a716-446655440000" -- --workspace "$ws" --now 2026-08-11T17:59:00+09:00

# 未終了が無ければ 0 件と明示する
printf '%s\n' '{"ts":"2026-08-06T16:00:00+09:00","event":"delegate_end","challenge":"C-044","repo":"net-config","session_id":"550e8400-e29b-41d4-a716-446655440000","result":"done"}' >> "$ws/.flywheel/runs.jsonl"
assert_case "stale 時・未終了なしは 0 件と明示" 1 "未終了の *_start: 0 件" -- --workspace "$ws" --now 2026-08-11T17:59:00+09:00

# check が返す種別ラベル（Issue #142）の仕分け: **既知の 3 種を個別に**数え、該当行も
# 種別ごとに出す。ラベルを 1 枠へ束ねると、原因も対処も違う異常（start の記録漏れ /
# 二重に閉じた記録）が同じ数字に見えるうえ、取り違えが回帰テストを素通りする（PR #144
# のレビュー指摘）。全行を一律に数えると、完了済み作業の重複記録が「放置された委譲」に
# 化けて件数が水増しされる。
TAB="$(printf '\t')"
cat > "$ws/.flywheel/runs.jsonl" <<'EOF'
{"ts":"2026-08-06T10:00:00+09:00","event":"cycle_start","cycle":"2026-08-06-cycle"}
{"ts":"2026-08-06T10:30:00+09:00","event":"cycle_end","cycle":"2026-08-06-cycle","result":"completed"}
{"ts":"2026-08-06T15:53:00+09:00","event":"delegate_start","challenge":"C-044","repo":"net-config","session_id":"550e8400-e29b-41d4-a716-446655440000","title":"放置された委譲"}
{"ts":"2026-08-06T16:10:00+09:00","event":"adhoc_end","id":"adhoc-B","result":"対応する start が無い end"}
{"ts":"2026-08-06T16:20:00+09:00","event":"adhoc_start","id":"adhoc-C","title":"end が二重に打たれる"}
{"ts":"2026-08-06T16:30:00+09:00","event":"adhoc_end","id":"adhoc-C","result":"1回目"}
{"ts":"2026-08-06T16:40:00+09:00","event":"adhoc_end","id":"adhoc-C","result":"2回目（重複）"}
EOF
assert_case "未終了 *_start の件数に orphan_end / duplicate_end を混ぜない" 1 "未終了の *_start: 1 件" -- --workspace "$ws" --now 2026-08-11T17:59:00+09:00
# 2 種を「1 件ずつ」個別に固定する。束ねた 1 つの数字（2 件）では、orphan と duplicate の
# 取り違えが起きても合計が変わらないため検出できない。
assert_case "orphan_end の件数を個別に出す" 1 "対応する *_start が無い *_end: 1 件" -- --workspace "$ws" --now 2026-08-11T17:59:00+09:00
assert_case "duplicate_end の件数を個別に出す" 1 "重複した *_end: 1 件" -- --workspace "$ws" --now 2026-08-11T17:59:00+09:00
# 該当行も種別ごとに出す（どの行がどちらの異常かを、ラベル付きの行で確定させる）。
assert_case "orphan_end の該当行を orphan_end ラベル付きで列挙する" 1 "orphan_end${TAB}{\"ts\":\"2026-08-06T16:10:00+09:00\"" -- --workspace "$ws" --now 2026-08-11T17:59:00+09:00
assert_case "duplicate_end の該当行を duplicate_end ラベル付きで列挙する" 1 "duplicate_end${TAB}{\"ts\":\"2026-08-06T16:40:00+09:00\"" -- --workspace "$ws" --now 2026-08-11T17:59:00+09:00
# 既知ラベルは「その他」へ落ちない。既知ラベルの集合は emit_label の呼び出しから積み上げる
# 実装のため、その積み上げが壊れると既知の行が「その他」へ二重に現れる（種別を足したときに
# 「その他」側のリストを直し忘れる、という同型の故障も同じ形で出る）。
got_out="$(bash "$SCRIPT" --workspace "$ws" --now 2026-08-11T17:59:00+09:00 2>/dev/null)"
ok=1
case "$got_out" in *"その他の種別"*) ok=0 ;; esac
if [ "$ok" -eq 1 ]; then
  PASS=$((PASS + 1)); echo "ok   - 既知の 3 種は「その他」へ二重計上されない"
else
  FAIL=$((FAIL + 1)); echo "FAIL - 既知の 3 種は「その他」へ二重計上されない"; echo "       stdout: $got_out"
fi

# 該当が無い種別の行は出さない（毎周のノイズにしない）。未終了 *_start だけは 0 件でも
# 明示する（既存契約）。
cat > "$ws/.flywheel/runs.jsonl" <<'EOF'
{"ts":"2026-08-06T10:00:00+09:00","event":"cycle_start","cycle":"2026-08-06-cycle"}
{"ts":"2026-08-06T10:30:00+09:00","event":"cycle_end","cycle":"2026-08-06-cycle","result":"completed"}
{"ts":"2026-08-06T15:53:00+09:00","event":"delegate_start","challenge":"C-044","repo":"net-config","session_id":"550e8400-e29b-41d4-a716-446655440000","title":"放置された委譲"}
EOF
got_out="$(bash "$SCRIPT" --workspace "$ws" --now 2026-08-11T17:59:00+09:00 2>/dev/null)"
ok=1
case "$got_out" in *"が無い *_end"*) ok=0 ;; esac
case "$got_out" in *"重複した *_end"*) ok=0 ;; esac
case "$got_out" in *"未終了の *_start: 1 件"*) ;; *) ok=0 ;; esac
if [ "$ok" -eq 1 ]; then
  PASS=$((PASS + 1)); echo "ok   - 該当 0 件の種別は行を出さない（未終了 *_start は出す）"
else
  FAIL=$((FAIL + 1)); echo "FAIL - 該当 0 件の種別は行を出さない（未終了 *_start は出す）"; echo "       stdout: $got_out"
fi

# 未知のラベルを黙って捨てない（前方互換）。check が将来種別を増やしても行が消えないこと。
# log-run-event.sh は $(dirname "$0") 相対で解決されるため、スタブを隣に置いて注入する。
stubdir="$tmp/stub"
mkdir -p "$stubdir"
cp "$SCRIPT" "$stubdir/heartbeat-check.sh"
cat > "$stubdir/log-run-event.sh" <<'EOF'
#!/usr/bin/env bash
# テスト用スタブ: 本スクリプトが知らない種別ラベルを 1 行返して exit 1。
printf 'future_label\t{"ts":"2026-08-06T16:50:00+09:00","event":"adhoc_end","id":"adhoc-Z"}\n'
exit 1
EOF
assert_case_stub() {
  name="$1"; want_out="$2"
  got_out="$(bash "$stubdir/heartbeat-check.sh" --workspace "$ws" --now 2026-08-11T17:59:00+09:00 2>/dev/null)"
  ok=1
  case "$got_out" in *"$want_out"*) ;; *) ok=0 ;; esac
  if [ "$ok" -eq 1 ]; then
    PASS=$((PASS + 1)); echo "ok   - $name"
  else
    FAIL=$((FAIL + 1)); echo "FAIL - $name"; echo "       stdout: $got_out"
  fi
}
assert_case_stub "未知の種別ラベルは「その他」として件数を出す" "その他の種別: 1 件"
assert_case_stub "未知の種別ラベルの該当行も捨てずに列挙する" "adhoc-Z"


# 最新の cycle_end を使う（result=abandoned も 1 拍と数える）
printf '%s\n' '{"ts":"2026-08-11T09:00:00+09:00","event":"cycle_end","cycle":"z","result":"abandoned"}' >> "$ws/.flywheel/runs.jsonl"
assert_case "最新の cycle_end（abandoned 含む）を拍動とみなす" 0 - -- --workspace "$ws" --now 2026-08-11T17:59:00+09:00

echo
echo "passed: $PASS / failed: $FAIL"
[ "$FAIL" -eq 0 ]
