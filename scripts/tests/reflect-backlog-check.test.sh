#!/usr/bin/env bash
#
# reflect-backlog-check.test.sh — scripts/reflect-backlog-check.rb のテスト（Issue #193）。
#
# 実行: bash scripts/tests/reflect-backlog-check.test.sh
#   - 依存: bash（macOS 標準の 3.2 でも可）・/usr/bin/ruby（macOS 標準）。テストフレームワーク不使用。
#   - 書き込みはすべて mktemp -d の一時ディレクトリ内で完結し、リポジトリの状態を変更しない。
#
# 検査の要:
#   - **滞留の 2 条件をそれぞれ単独で成立させ、exit 1 になることを固定する**: (a) 最後の reflect の
#     後の周数が N 以上 (b) 未処理で recurrence 2 以上の bad がある。境界（N−1 周・同じ日の周・
#     recurrence 1・処理済みの bad・good）は滞留にならない。
#   - **「未処理」の規則は reflect スキルと同じ**: 日付として読めない reflected（語・プレース
#     ホルダ・実在しない日付）は未処理へ倒す。パターンの文字列が skills/reflect/SKILL.md の
#     正本と一致することも固定する（ずれると reflect が拾う記録と本判定が拾う記録が食い違う）。
#   - **判定不能は滞留なし側（exit 2）に倒し、滞留の事実は捨てない**: index.jsonl が壊れていても
#     (b) が成立すれば exit 1。どちらも確定しないときだけ exit 2。
#   - **N の補正は手順6 と同じ**: cadence.json が無い・不正なら既定 10。
#   - run-cycle SKILL.md 手順0 が本スクリプトを呼び、手順6 が終了案内を reflect に置き換えること。

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/reflect-backlog-check.rb"
REFLECT_MD="$REPO_ROOT/skills/reflect/SKILL.md"
RUN_CYCLE_MD="$REPO_ROOT/skills/run-cycle/SKILL.md"
RUBY="/usr/bin/ruby"
command -v "$RUBY" >/dev/null 2>&1 || RUBY="ruby"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

pass() { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; [ -n "${2:-}" ] && echo "       $2"; }

# --- フィクスチャ組み立て --------------------------------------------------

# new_ws → 空のワークスペース（memory/harness と journal を持つ）を作り、パスを出力する
new_ws() {
  ws="$(mktemp -d "$TMP_ROOT/ws.XXXXXX")"
  mkdir -p "$ws/memory/harness" "$ws/journal" "$ws/.flywheel"
  echo "$ws"
}

# exp <ws> <slug> <outcome> <recurrence|-> <reflected|-> : experience を 1 件書く（- は行を置かない）
exp() {
  f="$1/memory/harness/experience-$2.md"
  {
    echo "---"
    echo "name: $2"
    echo "description: test"
    echo "domain: harness"
    echo "metadata:"
    echo "  type: experience"
    echo "  outcome: $3"
    echo "  target: brief"
    echo "  signal: test"
    [ "$4" != "-" ] && echo "  recurrence: $4"
    echo "  confidence: high"
    [ "$5" != "-" ] && echo "  reflected: $5"
    echo "---"
    echo "body"
  } > "$f"
}

# cycles <ws> <date> <count> : index.jsonl に date の行を count 行追記する
cycles() {
  i=0
  while [ "$i" -lt "$3" ]; do
    i=$((i + 1))
    echo "{\"date\":\"$2\",\"seq\":$i,\"touched_issues\":[],\"delegations\":[],\"pr_urls\":[],\"pending_approvals\":[],\"decisions\":[]}" >> "$1/journal/index.jsonl"
  done
}

cadence() { echo "$2" > "$1/.flywheel/cadence.json"; }

# check <名前> <ws> <期待exit> [<stdout に含むべき文字列>...]
check() {
  name="$1"; ws="$2"; want="$3"; shift 3
  out="$("$RUBY" "$SCRIPT" --workspace "$ws" 2>/dev/null)"
  got=$?
  ok=1
  [ "$got" -eq "$want" ] || ok=0
  for s in "$@"; do
    case "$out" in *"$s"*) ;; *) ok=0 ;; esac
  done
  case "$out" in *"report="*) ;; *) ok=0 ;; esac
  if [ "$ok" -eq 1 ]; then pass "$name"; else fail "$name" "exit got=$got want=$want / stdout: $(echo "$out" | tr '\n' ' ')"; fi
}

# --- (a) 最後の reflect の後の周数 ------------------------------------------

ws="$(new_ws)"; exp "$ws" a1 good - 2026-10-01; cycles "$ws" 2026-10-02 10
check "(a) reflect の後 N 周で滞留" "$ws" 1 "backlog=yes" "cycles_since_reflect=10" "last_reflected=2026-10-01"

ws="$(new_ws)"; exp "$ws" a1 good - 2026-10-01; cycles "$ws" 2026-10-02 9
check "(a) reflect の後 N−1 周は滞留なし" "$ws" 0 "backlog=no" "cycles_since_reflect=9"

ws="$(new_ws)"; exp "$ws" a1 good - 2026-10-01; cycles "$ws" 2026-09-20 30; cycles "$ws" 2026-10-01 5; cycles "$ws" 2026-10-02 3
check "(a) reflect の日以前の周は数えない（同じ日の周も数えない）" "$ws" 0 "cycles_since_reflect=3"

ws="$(new_ws)"; exp "$ws" a1 good - 2026-09-01; exp "$ws" a2 bad 1 2026-10-01; cycles "$ws" 2026-09-15 12; cycles "$ws" 2026-10-02 2
check "(a) 最後の reflect は reflected の最大日付" "$ws" 0 "last_reflected=2026-10-01" "cycles_since_reflect=2"

ws="$(new_ws)"; exp "$ws" a1 good - -; cycles "$ws" 2026-10-02 10
check "(a) reflect の記録が無ければ全行を数える" "$ws" 1 "last_reflected=none" "cycles_since_reflect=10"

ws="$(new_ws)"; exp "$ws" a1 good - 2026-10-01
check "(a) index.jsonl が無ければ 0 周" "$ws" 0 "cycles_since_reflect=0"

ws="$(new_ws)"; exp "$ws" a1 good - 2026-10-01; cycles "$ws" 2026-10-02 3; echo "" >> "$ws/journal/index.jsonl"
check "(a) 空行は数えない" "$ws" 0 "cycles_since_reflect=3"

ws="$(new_ws)"; exp "$ws" a1 good - 2026-10-01; cycles "$ws" 2026-10-02 3; cadence "$ws" '{"reflect":{"every_n_cycles":3}}'
check "(a) N は cadence.json の reflect.every_n_cycles" "$ws" 1 "every_n_cycles=3" "n_source=config"

for bad_n in '{"reflect":{"every_n_cycles":0}}' '{"reflect":{"every_n_cycles":"3"}}' '{"reflect":{"every_n_cycles":3.0}}' '{"reflect":{}}' 'not json'; do
  ws="$(new_ws)"; exp "$ws" a1 good - 2026-10-01; cycles "$ws" 2026-10-02 9; cadence "$ws" "$bad_n"
  check "(a) 不正な N は既定 10 へ補正: $bad_n" "$ws" 0 "every_n_cycles=10" "n_source=default" "既定 10"
done

ws="$(new_ws)"; rm -rf "$ws/.flywheel"; exp "$ws" a1 good - 2026-10-01; cycles "$ws" 2026-10-02 10
check "(a) cadence.json が無ければ既定 10" "$ws" 1 "every_n_cycles=10" "n_source=default"

# --- (b) 未処理の再発 bad ---------------------------------------------------

ws="$(new_ws)"; exp "$ws" b1 bad 2 -
check "(b) 未処理で recurrence 2 の bad は滞留" "$ws" 1 "recurring_bad=1" "recurring_bad_file=memory/harness/experience-b1.md"

ws="$(new_ws)"; exp "$ws" b1 bad 1 -; exp "$ws" b2 bad - -; exp "$ws" b3 good 5 -; exp "$ws" b4 bad 3 2026-10-01
check "(b) recurrence 1・無し・good・処理済みは数えない" "$ws" 0 "recurring_bad=0"

for v in '未処理' '<YYYY-MM-DD>' '2026-02-30' '""' "2026-10-01x"; do
  ws="$(new_ws)"; exp "$ws" b1 bad 2 "$v"
  check "(b) 日付として読めない reflected は未処理: $v" "$ws" 1 "recurring_bad=1"
done

ws="$(new_ws)"; exp "$ws" b1 bad 2 '"2026-10-01"'
check "(b) 引用符付きの日付は処理済み" "$ws" 0 "recurring_bad=0" "last_reflected=2026-10-01"

ws="$(new_ws)"; exp "$ws" b1 bad abc -
check "(b) 数値でない recurrence は数えない（滞留なし側）" "$ws" 0 "recurring_bad=0"

ws="$(new_ws)"; exp "$ws" b1 bad 2 -; printf -- '---\nname: x\nmetadata:\n  type: tacit\n  outcome: bad\n  recurrence: 9\n---\n' > "$ws/memory/harness/tacit-x.md"; rm "$ws/memory/harness/experience-b1.md"
check "(b) experience 以外の記憶は数えない" "$ws" 0 "recurring_bad=0"

# --- 判定不能と、滞留の事実を捨てないこと -------------------------------------

ws="$(new_ws)"; exp "$ws" a1 good - 2026-10-01; cycles "$ws" 2026-10-02 3; echo "{broken" >> "$ws/journal/index.jsonl"
check "index.jsonl が壊れていて (b) も不成立なら判定不能" "$ws" 2 "backlog=unknown" "滞留なしとして周を続ける"

ws="$(new_ws)"; exp "$ws" a1 good - 2026-10-01; cycles "$ws" 2026-10-02 3; echo '{"date":"10/03"}' >> "$ws/journal/index.jsonl"
check "index.jsonl の date が読めなければ判定不能" "$ws" 2 "backlog=unknown"

ws="$(new_ws)"; exp "$ws" b1 bad 2 -; echo "{broken" >> "$ws/journal/index.jsonl"
check "index.jsonl が壊れていても (b) が成立すれば滞留" "$ws" 1 "backlog=yes" "一部は判定できなかった"

ws="$(new_ws)"; rm -rf "$ws/memory"
check "memory/ が無ければ判定不能" "$ws" 2 "backlog=unknown"

out="$("$RUBY" "$SCRIPT" --bogus 2>/dev/null)"; got=$?
if [ "$got" -eq 2 ] && echo "$out" | grep -q '^report='; then pass "不明な引数は exit 2 と report="; else fail "不明な引数は exit 2 と report=" "got=$got"; fi

# --- 正本との一致・SKILL.md の配線 ------------------------------------------

reflect_re="$("$RUBY" -e 'print File.read(ARGV[0], encoding: "UTF-8")[/`(\^[^`\n]+\$)`/, 1].to_s' "$REFLECT_MD")"
if [ -n "$reflect_re" ] && grep -qF "Regexp.new(\"$reflect_re\")" "$SCRIPT"; then
  pass "reflected のパターンが reflect スキルの正本と一致 ($reflect_re)"
else
  fail "reflected のパターンが reflect スキルの正本と一致" "reflect=$reflect_re"
fi

if grep -q 'scripts/reflect-backlog-check.rb' "$RUN_CYCLE_MD"; then pass "run-cycle が滞留判定スクリプトを呼ぶ"; else fail "run-cycle が滞留判定スクリプトを呼ぶ"; fi
if grep -q '新しいセッションで `/claude-flywheel:reflect` を実行してください' "$RUN_CYCLE_MD"; then
  pass "run-cycle 手順6 にしきい値到達周の reflect 案内がある"
else
  fail "run-cycle 手順6 にしきい値到達周の reflect 案内がある"
fi

echo
echo "passed: $PASS / failed: $FAIL"
[ "$FAIL" -eq 0 ]
