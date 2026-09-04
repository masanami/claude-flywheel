#!/usr/bin/env bash
#
# quota-check.test.sh — scripts/quota-check.sh のテスト。
#
# 実行: bash scripts/tests/quota-check.test.sh
#   - 依存: bash（macOS 標準の 3.2 でも可）。テストフレームワーク不使用。
#   - すべて一時ディレクトリ内で完結し、リポジトリの状態を変更しない。
#
# 本テストが守る要（run-cycle 手順3【費用ガード】の枠超過判定をスクリプトへ移すにあたって）:
#
#   1. **先頭一致であって部分一致ではない**。`result` は子の自由記述の最終応答でもあるため、
#      部分一致にすると**この規定自体に言及した正当な報告**を枠超過と誤判定する（自己言及の
#      誤検知）。誤判定は課題を不当に保留し以後の委譲を止めるので、**自己言及ケース**
#      （判定規則そのものを引用した `result`）を専用に固定する。
#   2. **枠の名前を限定していない**。メッセージは名前部分を差し替えて組み立てられる
#      （`You've hit your ...` は CLI のソースに固定文字列として存在しない）。`weekly limit`
#      決め打ちの実装は session / モデル別 / クレジットの各枠を取りこぼすため、
#      **複数の枠名**で受理されることを固定する。
#   3. **判定不能なら「枠超過ではない」側へ倒す**。`result` が無い・空・先頭一致しない は
#      すべてこちら。誤って枠超過と判定すると課題を保留して自走が止まり人手が要るが、
#      誤って通常扱いにしても照合で成果の有無が分かり、次の起動で同じシグナルが再び返る。
#   4. **起動失敗経路の境界**（priority-policy-resolve.sh / cycle-commit.sh と同型）。
#      スクリプトが起動できない（exit 126/127）と stdout が空になり `report=` を取得できない。
#      `--list-exits` は**スクリプト自身が返す** 0/1/2 だけを宣言する。
#   5. **宣言と振る舞いの双方向一致**。理由分類（`--list-reasons`）と exit（`--list-exits`）は
#      片方向の検査（「宣言の各行が振る舞いに現れる」だけ）では、宣言を足して振る舞いを
#      書き忘れても通ってしまう。両方向＋空集合ガードで固定する。
#   6. **判定文字列の正本が 1 箇所**。`--list-prefix` が宣言する先頭一致文字列と、実際の
#      振る舞いが一致すること（宣言から組み立てた入力が受理され、1 文字削ると受理されない）。
#      テスト側に同じ文字列を第 2 のリストとして持たない。
#   7. **入力はシェル引数に載せない**。`result` は子の自由記述で引用符・バッククォート・
#      改行・`--` で始まる行を含みうる。stdin / `--result-file` の 2 経路だけを持ち、
#      オプション様の入力が引数として解釈されないことを固定する。

set -u
set -o pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
SCRIPT="$TESTS_DIR/../quota-check.sh"
SKILL_MD="$REPO_ROOT/skills/run-cycle/SKILL.md"

PASS=0
FAIL=0

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 振る舞いで観測した値の記録先（構造不変条件の双方向検査で使う）
OBSERVED_REASONS="$tmp/observed-reasons.txt"
OBSERVED_EXITS="$tmp/observed-exits.txt"
: > "$OBSERVED_REASONS"
: > "$OBSERVED_EXITS"

pass() { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; shift; for l in "$@"; do echo "       $l"; done; return 0; }

setup_fail() {
  FAIL=$((FAIL + 1))
  echo "FAIL - テスト準備に失敗: $1"
  echo
  echo "passed: $PASS / failed: $FAIL"
  exit 1
}

# --- 実行ヘルパ -------------------------------------------------------------
#
# **入力は必ずファイル経由で渡す**。`result` は子の自由記述であり、引数へ埋め込むと
# テスト自身が「引数に載せない」という被検体の契約を破る形になる。

# run_stdin <入力文字列> [追加引数...] — stdin から流して実行する
run_stdin() {
  printf '%s' "$1" > "$tmp/in.txt" || setup_fail "入力ファイルの書き出し"
  shift
  RUN_OUT="$(bash "$SCRIPT" "$@" < "$tmp/in.txt" 2>"$tmp/stderr")"
  RUN_EXIT=$?
  RUN_ERR="$(cat "$tmp/stderr")"
  echo "$RUN_EXIT" >> "$OBSERVED_EXITS"
  r="$(field reason)"; [ -n "$r" ] && echo "$r" >> "$OBSERVED_REASONS"
  return 0
}

# run_file <入力文字列> — --result-file 経由で実行する
run_file() {
  printf '%s' "$1" > "$tmp/result.txt" || setup_fail "入力ファイルの書き出し"
  RUN_OUT="$(bash "$SCRIPT" --result-file "$tmp/result.txt" </dev/null 2>"$tmp/stderr")"
  RUN_EXIT=$?
  RUN_ERR="$(cat "$tmp/stderr")"
  echo "$RUN_EXIT" >> "$OBSERVED_EXITS"
  r="$(field reason)"; [ -n "$r" ] && echo "$r" >> "$OBSERVED_REASONS"
  return 0
}

# run_args <引数...> — 入力なしで引数だけを与えて実行する（引数エラー系）
run_args() {
  RUN_OUT="$(bash "$SCRIPT" "$@" </dev/null 2>"$tmp/stderr")"
  RUN_EXIT=$?
  RUN_ERR="$(cat "$tmp/stderr")"
  echo "$RUN_EXIT" >> "$OBSERVED_EXITS"
  r="$(field reason)"; [ -n "$r" ] && echo "$r" >> "$OBSERVED_REASONS"
  return 0
}

# field <key> — RUN_OUT から key=... の値を取り出す（無ければ空）
field() { printf '%s\n' "$RUN_OUT" | sed -n "s/^$1=//p"; }

assert_exit() {
  if [ "$RUN_EXIT" -eq "$2" ]; then pass "$1"
  else fail "$1 (exit: got=$RUN_EXIT want=$2)" "stdout: $RUN_OUT" "stderr: $RUN_ERR"; fi
}

assert_field() {
  got="$(field "$2")"
  if [ "$got" = "$3" ]; then pass "$1"
  else fail "$1 ($2: got='$got' want='$3')" "stdout: $RUN_OUT"; fi
}

assert_no_field() {
  got="$(field "$2")"
  if [ -z "$got" ]; then pass "$1"
  else fail "$1 ($2 が出力されている: '$got')" "stdout: $RUN_OUT"; fi
}

assert_nonempty_field() {
  got="$(field "$2")"
  if [ -n "$got" ]; then pass "$1"
  else fail "$1 ($2 が空)" "stdout: $RUN_OUT"; fi
}

# assert_all_kv <名前> — stdout の**全行**が `key=value` であること。
# `field` は `sed -n 's/^key=//p'` で最初の行だけを拾うため、値に改行が混ざって
# 行構造が壊れても**値の比較だけでは pass してしまう**（実際、limit= の 1 行化を
# 外す変異がこの穴で生き残った）。行構造そのものを別の目で固定する。
assert_all_kv() {
  bad="$(printf '%s\n' "$RUN_OUT" | grep -vc '^[a-z][a-z-]*=' || true)"
  if [ "$bad" -eq 0 ]; then pass "$1"
  else fail "$1" "key=value でない行が $bad 行ある" "stdout: $RUN_OUT"; fi
}

assert_contains() {
  if grep -qF -- "$3" "$2" 2>/dev/null; then pass "$1"
  else fail "$1" "'$3' が $2 に見つからない"; fi
}

assert_not_contains() {
  if grep -qF -- "$3" "$2" 2>/dev/null; then fail "$1" "'$3' が $2 に残っている"
  else pass "$1"; fi
}

# 先頭一致文字列の**正本はスクリプトの宣言**。テスト側に literal を第 2 のリストとして
# 持たないため、以降の入力はこの値から組み立てる。
NL=$'\n'   # コマンド置換は末尾の改行を落とすため、改行は変数で埋め込む

PREFIX="$(bash "$SCRIPT" --list-prefix 2>/dev/null)"
PREFIX_EXIT=$?

echo "== 0. 先頭一致文字列の宣言（正本） =="

if [ "$PREFIX_EXIT" -eq 0 ]; then pass "--list-prefix は exit 0 で終了する"
else fail "--list-prefix は exit 0 で終了する" "got=$PREFIX_EXIT"; fi

# 宣言そのものは既知の値で 1 回だけ固定する（ここが唯一の literal）。
if [ "$PREFIX" = "You've hit your " ]; then pass "--list-prefix が宣言する文字列（末尾の半角スペースを含む）"
else fail "--list-prefix が宣言する文字列" "got='$PREFIX' want=\"You've hit your \""; fi

case "$PREFIX" in
  *' ') pass "宣言は半角スペースで終わる（枠名との境界を持つ）" ;;
  *)    fail "宣言は半角スペースで終わる" "got='$PREFIX'" ;;
esac

[ -n "$PREFIX" ] || setup_fail "--list-prefix が空を返した（以降の入力を組み立てられない）"

echo "== 1. 受理方向: 枠超過（先頭一致）=="

run_stdin "${PREFIX}weekly limit · resets 3pm"
assert_exit "先頭一致は exit 0" 0
assert_field "verdict" verdict quota-exhausted
assert_field "理由分類" reason prefix-match
assert_field "枠名と reset 時刻を limit= に出す" limit "weekly limit · resets 3pm"
assert_nonempty_field "枠超過でも report= を出す" report

# 前後の空白（改行・タブを含む）を除いた先頭で見る
run_stdin "   ${PREFIX}weekly limit"
assert_exit "先行する半角スペースを除いて判定する" 0
assert_field "先行スペースがあっても limit= は枠名だけ" limit "weekly limit"

run_stdin "${NL}${NL}$(printf '\t')${PREFIX}weekly limit${NL}"
assert_exit "先行する改行・タブを除いて判定する" 0
assert_field "後続の改行を落とした limit=" limit "weekly limit"

# 複数行の result（子の報告と同じ形）。判定は先頭行、limit= も 1 行に収める
run_stdin "${PREFIX}Opus limit · resets 5pm${NL}続きの行"
assert_exit "複数行でも先頭で判定する" 0
assert_field "limit= は 1 行に収める（key=value 行を壊さない）" limit "Opus limit · resets 5pm"
assert_all_kv "複数行の result でも stdout の全行が key=value のまま（行構造を壊さない）"

echo "== 2. 枠の名前を限定していない（weekly 決め打ちでない）=="

# `You've hit your ...` は CLI のソースに固定文字列として存在せず実行時に組み立てられる。
# `weekly limit` だけを見る実装は他の枠を取りこぼす。
for name in "weekly limit · resets 3pm" \
            "session limit · resets 5pm" \
            "Opus limit · resets Feb 3 at 10am" \
            "Sonnet limit" \
            "usage credit limit" \
            "5-hour limit · resets 2:00" \
            "組織の利用枠"; do
  run_stdin "${PREFIX}${name}"
  assert_exit "枠名を限定しない: ${name}" 0
  assert_field "枠名をそのまま limit= に出す: ${name}" limit "${name}"
done

echo "== 3. 先頭一致であって部分一致ではない（自己言及の誤検知を塞ぐ）=="

# **本テストの中心**。この規定自体を実装・文書化した課題の完了報告は、判定文字列を
# 引用する。部分一致で判定すると、この正当な報告が枠超過と誤判定され、課題が不当に
# 保留されて以後の委譲が止まる。
selfref1="run-cycle 手順3 の枠超過判定をスクリプト化しました。判定は \`${PREFIX}\` の先頭一致であって部分一致ではありません。PR: https://example.invalid/pull/1"
run_stdin "$selfref1"
assert_exit "自己言及（規定を引用した完了報告）は枠超過ではない" 1
assert_field "自己言及の verdict" verdict not-quota-exhausted
assert_field "自己言及の理由分類" reason no-prefix
assert_no_field "枠超過でないときは limit= を出さない" limit

# バッククォートで引用され行頭に来るケース。「前後の空白を除いた先頭」を
# 「記号も剥がした先頭」まで緩めると誤検知する。
selfref2="\`${PREFIX}\` を先頭一致で判定する判定器を追加しました。"
run_stdin "$selfref2"
assert_exit "行頭のバッククォート引用は枠超過ではない" 1
assert_field "バッククォート引用の理由分類" reason no-prefix

# 判定文字列が複数行の報告の途中（2 行目以降の行頭）に現れるケース。
# 「いずれかの行の行頭に一致」まで緩めると誤検知する。
selfref3="実装が完了しました。変更点:${NL}${PREFIX}への先頭一致で枠超過を判定します。"
run_stdin "$selfref3"
assert_exit "2 行目以降の行頭一致では枠超過にしない" 1
assert_field "行頭一致（2 行目）の理由分類" reason no-prefix

echo "== 4. 境界（1 文字ずれ・大小・引用符の異体字）は安全側へ倒す =="

# 宣言から 1 文字削った文字列は受理しない（末尾の半角スペースが境界であること）
short="${PREFIX% }"
run_stdin "${short}weekly limit"
assert_exit "末尾スペースを欠くと一致しない（枠名との境界）" 1
assert_field "境界欠落の理由分類" reason no-prefix

# 大小の違い（CLI 側の表記揺れは判定不能として安全側へ）
lower="$(printf '%s' "$PREFIX" | tr 'A-Z' 'a-z')"
run_stdin "${lower}weekly limit"
assert_exit "大小が異なる場合は一致させない（判定不能は安全側）" 1
assert_field "大小差の理由分類" reason no-prefix

# アポストロフィの異体字（U+2019）。CLI が ASCII 以外を出した場合も安全側へ倒れる
run_stdin "You’ve hit your weekly limit"
assert_exit "アポストロフィの異体字は一致させない（安全側）" 1
assert_field "異体字の理由分類" reason no-prefix

echo "== 5. 判定不能は「枠超過ではない」側へ倒す =="

run_stdin ""
assert_exit "result が空（フィールドが無い場合も同じ）は exit 1" 1
assert_field "空の verdict" verdict not-quota-exhausted
assert_field "空の理由分類" reason empty
assert_no_field "空では limit= を出さない" limit
assert_nonempty_field "空でも report= を出す" report
assert_all_kv "枠超過でない周も stdout の全行が key=value"

run_stdin "  ${NL}$(printf '\t')${NL}  "
assert_exit "空白のみも exit 1" 1
assert_field "空白のみの理由分類" reason empty

run_stdin "実装が完了しました。PR を作成済みです。"
assert_exit "無関係な完了報告は exit 1" 1
assert_field "無関係な報告の理由分類" reason no-prefix

# 返り値 JSON をまるごと流し込む誤用も安全側（`{` で始まり先頭一致しない）へ倒れる
run_stdin '{"type":"result","subtype":"success","result":"'"${PREFIX}"'weekly limit"}'
assert_exit "返り値 JSON をそのまま流す誤用も安全側へ倒れる" 1
assert_field "JSON 誤用の理由分類" reason no-prefix

echo "== 6. 入力経路（stdin / --result-file）と引数の非解釈 =="

run_file "${PREFIX}session limit · resets 5pm"
assert_exit "--result-file 経由でも判定できる" 0
assert_field "--result-file 経由の limit=" limit "session limit · resets 5pm"

run_file ""
assert_exit "--result-file が空ファイルなら exit 1" 1
assert_field "空ファイルの理由分類" reason empty

# `result` は子の自由記述であり `--` で始まる行を含みうる。stdin から来た内容が
# 引数として解釈されないこと（引数に載せない契約の裏付け）。
run_stdin "--result-file /etc/passwd"
assert_exit "オプション様の入力を引数として解釈しない" 1
assert_field "オプション様の入力の理由分類" reason no-prefix

run_args --result-file "$tmp/no-such-file.txt"
assert_exit "読めない --result-file は exit 2（検査不能）" 2
assert_no_field "検査不能では reason を出さない（分類は exit 1 のみ）" reason
assert_nonempty_field "検査不能でも report= を出す" report
if [ -n "$RUN_ERR" ]; then pass "検査不能は stderr に理由を書く"
else fail "検査不能は stderr に理由を書く" "stderr が空"; fi

run_args --result-file "$tmp"
assert_exit "ディレクトリを --result-file に渡すと exit 2" 2

run_args --result-file
assert_exit "--result-file の値欠落は exit 2" 2

run_args --unknown-option
assert_exit "不明な引数は exit 2" 2
assert_no_field "不明な引数でも reason を出さない" reason
assert_nonempty_field "不明な引数でも report= を出す" report

echo "== 7. 構造不変条件: 理由分類の行の完全性（双方向）=="

listed_reasons="$(bash "$SCRIPT" --list-reasons 2>/dev/null)"
listed_reasons_exit=$?

if [ "$listed_reasons_exit" -eq 0 ]; then pass "--list-reasons は exit 0 で終了する"
else fail "--list-reasons は exit 0 で終了する" "got=$listed_reasons_exit"; fi

expected_reasons="prefix-match
empty
no-prefix"

if [ "$listed_reasons" = "$expected_reasons" ]; then
  pass "--list-reasons が 3 分類を宣言順どおり返す"
else
  fail "--list-reasons が 3 分類を宣言順どおり返す" \
       "got:  $(echo "$listed_reasons" | tr '\n' ' ')" "want: $(echo "$expected_reasons" | tr '\n' ' ')"
fi

n_lr="$(printf '%s\n' "$listed_reasons" | grep -c . || true)"
if [ "$n_lr" -eq 3 ]; then pass "理由分類はちょうど 3 種類（増減したら落ちる）"
else fail "理由分類はちょうど 3 種類" "got=$n_lr"; fi

obs_reasons="$(sort -u "$OBSERVED_REASONS")"
lr_sorted="$(printf '%s\n' "$listed_reasons" | grep . | sort -u)"

n_or="$(printf '%s\n' "$obs_reasons" | grep -c . || true)"
if [ "$n_or" -eq 3 ]; then
  pass "振る舞いで観測した理由分類がちょうど 3 種類（空集合で下の比較が空虚に真になるのを防ぐ）"
else
  fail "振る舞いで観測した理由分類がちょうど 3 種類" "got=$n_or: $(echo "$obs_reasons" | tr '\n' ' ')"
fi

miss_r_behavior="$(comm -23 <(printf '%s\n' "$lr_sorted") <(printf '%s\n' "$obs_reasons"))"
if [ -z "$miss_r_behavior" ]; then
  pass "(a) 宣言した理由分類すべてが振る舞いテストで観測されている"
else
  fail "(a) 宣言した理由分類すべてが振る舞いテストで観測されている" \
       "観測されなかった: $(echo "$miss_r_behavior" | tr '\n' ' ')"
fi

miss_r_list="$(comm -13 <(printf '%s\n' "$lr_sorted") <(printf '%s\n' "$obs_reasons"))"
if [ -z "$miss_r_list" ]; then
  pass "(b) 振る舞いが返す理由分類はすべて宣言に載っている"
else
  fail "(b) 振る舞いが返す理由分類はすべて宣言に載っている" \
       "宣言に無い分類が返された: $(echo "$miss_r_list" | tr '\n' ' ')"
fi

echo "== 8. 起動失敗（スクリプトが実行されない）経路 =="

# **この経路では stdout が一切出ない**＝`report=` を取得できない。
# 「どの exit でも report= を転記する」と書くと、この経路で実行不能な規定になる。
nonexistent="$tmp/no-such-checker.sh"
out127="$(bash "$nonexistent" </dev/null 2>/dev/null)"; ec127=$?
if [ "$ec127" -eq 127 ]; then pass "スクリプト不在は exit 127"
else fail "スクリプト不在は exit 127" "got=$ec127"; fi
if [ -z "$out127" ]; then pass "スクリプト不在では stdout が空（report= を取得できない）"
else fail "スクリプト不在では stdout が空" "stdout: $out127"; fi

noexec="$tmp/noexec-quota.sh"
cp "$SCRIPT" "$noexec" && chmod 000 "$noexec"
out126="$("$noexec" </dev/null 2>/dev/null)"; ec126=$?
chmod 644 "$noexec"
if [ "$ec126" -eq 126 ]; then pass "実行権限なしの直接起動は exit 126"
else fail "実行権限なしの直接起動は exit 126" "got=$ec126"; fi
if [ -z "$out126" ]; then pass "実行不能では stdout が空（report= を取得できない）"
else fail "実行不能では stdout が空" "stdout: $out126"; fi

echo "== 9. 構造不変条件: スクリプトが返す exit の行の完全性（双方向）=="

listed_exits="$(bash "$SCRIPT" --list-exits 2>/dev/null)"
listed_exits_exit=$?

if [ "$listed_exits_exit" -eq 0 ]; then pass "--list-exits は exit 0 で終了する"
else fail "--list-exits は exit 0 で終了する" "got=$listed_exits_exit"; fi

expected_exits="0
1
2"

if [ "$listed_exits" = "$expected_exits" ]; then
  pass "--list-exits がスクリプト自身の返す exit を宣言順どおり返す"
else
  fail "--list-exits がスクリプト自身の返す exit を宣言順どおり返す" \
       "got:  $(echo "$listed_exits" | tr '\n' ' ')" "want: $(echo "$expected_exits" | tr '\n' ' ')"
fi

n_le="$(printf '%s\n' "$listed_exits" | grep -c . || true)"
if [ "$n_le" -eq 3 ]; then pass "スクリプトが返す exit はちょうど 3 種類（増減したら落ちる）"
else fail "スクリプトが返す exit はちょうど 3 種類" "got=$n_le"; fi

# 126/127 は**シェルが返す**値であってスクリプトの返り値ではない
case "$listed_exits" in
  *12[67]*) fail "--list-exits に 126/127 を含めない（シェル由来でありスクリプトの返り値ではない）" \
                 "got: $(echo "$listed_exits" | tr '\n' ' ')" ;;
  *) pass "--list-exits に 126/127 を含めない（シェル由来でありスクリプトの返り値ではない）" ;;
esac

obs_exits="$(sort -u "$OBSERVED_EXITS")"
le_sorted="$(printf '%s\n' "$listed_exits" | grep . | sort -u)"

n_oe="$(printf '%s\n' "$obs_exits" | grep -c . || true)"
if [ "$n_oe" -eq 3 ]; then
  pass "振る舞いで観測した exit がちょうど 3 種類（空集合で下の比較が空虚に真になるのを防ぐ）"
else
  fail "振る舞いで観測した exit がちょうど 3 種類" "got=$n_oe: $(echo "$obs_exits" | tr '\n' ' ')"
fi

miss_e_behavior="$(comm -23 <(printf '%s\n' "$le_sorted") <(printf '%s\n' "$obs_exits"))"
if [ -z "$miss_e_behavior" ]; then
  pass "(a) 宣言した exit すべてが振る舞いテストで観測されている"
else
  fail "(a) 宣言した exit すべてが振る舞いテストで観測されている" \
       "観測されなかった: $(echo "$miss_e_behavior" | tr '\n' ' ')"
fi

miss_e_list="$(comm -13 <(printf '%s\n' "$le_sorted") <(printf '%s\n' "$obs_exits"))"
if [ -z "$miss_e_list" ]; then
  pass "(b) 振る舞いが返す exit はすべて宣言に載っている"
else
  fail "(b) 振る舞いが返す exit はすべて宣言に載っている" \
       "宣言に無い exit が返された: $(echo "$miss_e_list" | tr '\n' ' ')"
fi

echo "== 10. 規定・実装の結線 =="

assert_contains "SKILL 手順3 が判定器スクリプトを呼ぶ規定を持つ" "$SKILL_MD" 'scripts/quota-check.sh'
assert_contains "SKILL 手順3 が exit の読み分けを持つ" "$SKILL_MD" 'exit 2'
assert_contains "SKILL 手順3 が report= の転記を規定する" "$SKILL_MD" 'report='
assert_contains "SKILL 手順3 が枠超過時の扱い（親の行動）を残している" "$SKILL_MD" '即座に再委譲しない'

# 第 2 のリストを作らない: 判定規則の逐語（先頭一致文字列・枠名の列挙・判定不能時の
# 倒し方）を SKILL 側へ残さない。正本はスクリプトであり、複製すると必ずずれる。
assert_not_contains "SKILL に先頭一致文字列の逐語が残っていない" "$SKILL_MD" "You've hit your"
assert_not_contains "SKILL に枠名の逐語列挙が残っていない" "$SKILL_MD" 'usage credit limit'
assert_not_contains "SKILL に先頭一致条件の逐語が残っていない" "$SKILL_MD" '前後の空白を除いた先頭が'

echo
echo "passed: $PASS / failed: $FAIL"
[ "$FAIL" -eq 0 ]
