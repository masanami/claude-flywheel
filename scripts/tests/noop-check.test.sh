#!/usr/bin/env bash
#
# noop-check.test.sh — scripts/noop-check.rb のテスト。
#
# 実行: bash scripts/tests/noop-check.test.sh
#   - 依存: bash（macOS 標準の 3.2 でも可）・/usr/bin/ruby（macOS 標準）・git。テストフレームワーク不使用。
#   - 書き込みはすべて一時ディレクトリ内で完結し、リポジトリの状態を変更しない。
#
# 検査の要（Issue #82）:
#   - **取りこぼしは fail-closed**: 「変化があったのにコミットされない」を作らない。7 条件それぞれに
#     ついて、条件が崩れたら exit 0（保留）にならないことを固定する。
#   - **判定不能を「変化なし」に丸めない**: runs.jsonl 不在・末尾行が当周でない・スキーマ違反等は
#     exit 2（判定不能）であり、exit 0 にはしない。判定不能と変化ありが同時なら exit 2 が勝つ。
#   - **`decisions` を判定に使わない**（⑤判断と根拠に記載があっても no-op のまま）: 判定に含めると
#     run-cycle は毎周何かを書き残すため本機能が一度も発火しない、という設計判断の回帰テスト。
#   - **まとめコミットの検証範囲**: `pending_index_lines` をそのまま validate-artifact.rb の
#     `--tail` に渡すと、保留中の周の追記行まで検証されて exit 0 になること（結線の固定）。

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/noop-check.rb"
VALIDATOR="$REPO_ROOT/scripts/validate-artifact.rb"

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

assert_true() { # assert_true <名前> <コマンド...>
  name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS + 1)); echo "ok   - $name"
  else
    FAIL=$((FAIL + 1)); echo "FAIL - $name"
  fi
}

assert_contains() { # assert_contains <名前> <ファイル> <部分文字列>
  name="$1"; file="$2"; needle="$3"
  if grep -qF -- "$needle" "$file"; then
    PASS=$((PASS + 1)); echo "ok   - $name"
  else
    FAIL=$((FAIL + 1)); echo "FAIL - ${name} / 見つからない: ${needle}"
  fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

WS="$tmp/ws"

# 5 セクションの内容を引数で受ける journal .md を書く（日本語は printf の %s 経由で渡し、
# bash 3.2 の「全角文字直前の変数展開」の罠に触れない）。
write_md() { # write_md <path> <触った課題> <委譲> <PR> <承認待ち> <判断と根拠>
  {
    printf '# サイクルジャーナル\n\n'
    printf '## 触った課題\n\n- %s\n\n' "$2"
    printf '## 委譲\n\n- %s\n\n' "$3"
    printf '## 作成した PR・ブランチの URL\n\n- %s\n\n' "$4"
    printf '## 承認待ちゲート一覧\n\n- %s\n\n' "$5"
    printf '## 判断と根拠\n\n- %s\n' "$6"
  } > "$1"
}

write_noop_md() { write_md "$1" なし なし なし なし "承認待ちのみで新規作業なし"; }

NOOP_LINE_PREFIX='"touched_issues":[],"delegations":[],"pr_urls":[]'

index_line() { # index_line <date> <seq> <pending_approvals JSON配列>
  printf '{"date":"%s","seq":%s,%s,"pending_approvals":%s,"decisions":["承認待ちのみ"]}\n' \
    "$1" "$2" "$NOOP_LINE_PREFIX" "$3"
}

# 直前周（committed）＋当周（未コミット）を持つワークスペースを作り直す。
# 直前周の pending_approvals は $1（既定は空配列）。
reset_ws() {
  prev_approvals="${1:-[]}"
  rm -rf "$WS"
  mkdir -p "$WS/journal" "$WS/.flywheel" "$WS/memory"
  git -C "$WS" init -q .
  git -C "$WS" config user.email tester@example.com
  git -C "$WS" config user.name tester
  printf '# 課題台帳\n' > "$WS/challenge-ledger.md"
  printf '# 記憶\n' > "$WS/memory/note.md"
  printf '# journal\n' > "$WS/journal/README.md"
  write_noop_md "$WS/journal/2026-08-20-cycle.md"
  index_line 2026-08-20 1 "$prev_approvals" > "$WS/journal/index.jsonl"
  git -C "$WS" add -A >/dev/null 2>&1
  git -C "$WS" commit -qm init >/dev/null 2>&1
  : > "$WS/.flywheel/runs.jsonl"
}

# 当周（未コミット）を足す。
add_cycle() { # add_cycle <cycle名> <date> <seq> [pending_approvals JSON配列]
  write_noop_md "$WS/journal/$1.md"
  index_line "$2" "$3" "${4:-[]}" >> "$WS/journal/index.jsonl"
  printf '{"ts":"%sT10:00:00+09:00","event":"cycle_start","cycle":"%s"}\n' "$2" "$1" \
    >> "$WS/.flywheel/runs.jsonl"
}

check() { # check <名前> <期待exit> <期待stdout|-> [追加引数...]
  name="$1"; want="$2"; out="$3"; shift 3
  assert_case "$name" "$want" "$out" -- --workspace "$WS" --cycle "$CYCLE" "$@"
}

CYCLE=2026-08-21-cycle

# --- 引数・環境（すべて判定不能 = exit 2。「変化なし」に丸めない） ---

reset_ws
add_cycle "$CYCLE" 2026-08-21 1

assert_case "--cycle 未指定は exit 2" 2 - -- --workspace "$WS"
assert_case "--cycle が不正な形式は exit 2" 2 - -- --workspace "$WS" --cycle bogus
assert_case "--cycle に値が無いのは exit 2" 2 - -- --workspace "$WS" --cycle
assert_case "不明な引数は exit 2" 2 - -- --workspace "$WS" --cycle "$CYCLE" --bogus x
assert_case "workspace 不在は exit 2" 2 - -- --workspace "$tmp/no-such-dir" --cycle "$CYCLE"
assert_case "Git 作業ツリーでないディレクトリは exit 2" 2 "decision=commit" -- --workspace "$tmp" --cycle "$CYCLE"

# --- 基準ケース: 完全な no-op は exit 0（保留可） ---

check "完全な no-op は exit 0（保留可）" 0 "decision=defer"
check "no-op でも pending_index_lines を出す（検算の範囲指定に使う）" 0 "pending_index_lines=1"
check "no-op でも pending_md_file を出す" 0 "pending_md_file=journal/2026-08-21-cycle.md"

# --- 条件 1: 台帳・アーカイブ・記憶の未コミット差分 ---

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
printf '追記\n' >> "$WS/challenge-ledger.md"
check "台帳に未コミットの変更があれば exit 1" 1 "reason=state-dirty"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
printf '# 新規\n' > "$WS/memory/new.md"
check "記憶に未追跡ファイルがあれば exit 1（--untracked-files=all）" 1 "reason=state-dirty"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
printf '# アーカイブ\n' > "$WS/challenge-archive.md"
check "アーカイブの新規作成（未追跡）があれば exit 1" 1 "reason=state-dirty"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
printf 'active: normal\n' > "$WS/priority-policy.md"
check "priority-policy.md はサイクルコミット対象外なので判定にも影響しない" 0 "decision=defer"
check "--path で追加すれば priority-policy.md も変化とみなせる" 1 "reason=state-dirty" --path priority-policy.md

# --- 条件 2: touched_issues / delegations / pr_urls ---

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
/usr/bin/ruby -e 'ls=File.readlines(ARGV[0]); r=JSON.parse(ls[-1]); r["touched_issues"]=[{"id"=>"C-001","from"=>"分類済","to"=>"着手中"}]; ls[-1]=JSON.generate(r)+"\n"; File.write(ARGV[0], ls.join)' -rjson "$WS/journal/index.jsonl"
check "touched_issues が非空なら exit 1" 1 "reason=journal-activity"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
/usr/bin/ruby -e 'ls=File.readlines(ARGV[0]); r=JSON.parse(ls[-1]); r["delegations"]=[{"repo"=>"r","skill"=>"s","session_id"=>"i","result"=>"ok"}]; ls[-1]=JSON.generate(r)+"\n"; File.write(ARGV[0], ls.join)' -rjson "$WS/journal/index.jsonl"
check "delegations が非空なら exit 1" 1 "reason=journal-activity"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
/usr/bin/ruby -e 'ls=File.readlines(ARGV[0]); r=JSON.parse(ls[-1]); r["pr_urls"]=["https://example.com/pull/1"]; ls[-1]=JSON.generate(r)+"\n"; File.write(ARGV[0], ls.join)' -rjson "$WS/journal/index.jsonl"
check "pr_urls が非空なら exit 1" 1 "reason=journal-activity"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
/usr/bin/ruby -e 'ls=File.readlines(ARGV[0]); r=JSON.parse(ls[-1]); r["touched_issues"]="壊れた形"; ls[-1]=JSON.generate(r)+"\n"; File.write(ARGV[0], ls.join)' -rjson "$WS/journal/index.jsonl"
check "touched_issues が配列でない（スキーマ違反）は exit 2" 2 "decision=commit"

# --- 条件 3: pending_approvals の (gate, issue) 集合 ---

reset_ws '[{"gate":"FR-13","issue":"C-001","summary":"承認待ち"}]'
add_cycle "$CYCLE" 2026-08-21 1 '[{"gate":"FR-13","issue":"C-001","summary":"承認待ち（別の言い回し）"}]'
check "承認待ちが前周と同じ (gate, issue) なら summary が違っても no-op" 0 "decision=defer"

reset_ws '[{"gate":"FR-13","issue":"C-001","summary":"承認待ち"}]'
add_cycle "$CYCLE" 2026-08-21 1 '[{"gate":"FR-13","issue":"C-001","summary":"s"},{"gate":"FR-32","issue":"C-002","summary":"s"}]'
check "承認待ちが新規に増えたら exit 1" 1 "reason=approval-set-changed"

reset_ws '[{"gate":"FR-13","issue":"C-001","summary":"承認待ち"}]'
add_cycle "$CYCLE" 2026-08-21 1 '[]'
check "承認待ちが解消されたら exit 1" 1 "reason=approval-set-changed"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1 '[{"gate":"FR-22","issue":"C-003","summary":"昇格承認待ち"}]'
check "前周に無かった承認待ちが出たら exit 1（ステータス遷移を伴わない FR-22 ゲート）" 1 "reason=approval-set-changed"

# --- 条件 4: .md の ①〜④（`なし` 以外の記載）と ⑤（判定に使わない） ---

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
write_md "$WS/journal/$CYCLE.md" "C-001: 分類済 → 着手中" なし なし なし "判断"
check "① 触った課題に記載があれば exit 1（index.jsonl が空でも取りこぼさない）" 1 "reason=journal-md-content"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
write_md "$WS/journal/$CYCLE.md" なし "repo: x / skill: y" なし なし "判断"
check "② 委譲に記載があれば exit 1" 1 "reason=journal-md-content"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
write_md "$WS/journal/$CYCLE.md" なし なし "https://example.com/pull/1" なし "判断"
check "③ PR・ブランチ URL に記載があれば exit 1" 1 "reason=journal-md-content"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
write_md "$WS/journal/$CYCLE.md" なし なし なし "FR-13 — C-001 — 承認待ち" "判断"
check "④ 承認待ちゲート一覧に記載があれば exit 1" 1 "reason=journal-md-content"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
write_md "$WS/journal/$CYCLE.md" なし なし なし なし "適用方針モード=normal を確認。承認待ちのみで前進不可"
check "⑤ 判断と根拠に記載があっても no-op のまま（decisions は判定に使わない）" 0 "decision=defer"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
write_md "$WS/journal/$CYCLE.md" "特になし" なし なし なし "判断"
check "「なし」で始まらない言い回し（特になし）は変化として扱う（fail-closed）" 1 "reason=journal-md-content"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
write_md "$WS/journal/$CYCLE.md" "なし（台帳に課題エントリなし）" "なし" "なし" "なし" "初回サイクル"
check "理由を添えた「なし（…）」は該当なしの宣言として扱う（実運用 journal の実形）" 0 "decision=defer"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
rm -f "$WS/journal/$CYCLE.md"
check "当周の .md が無ければ exit 2（判定不能）" 2 "decision=commit"

# --- 条件 5: runs.jsonl（当周の委譲・差し込み・事後補記） ---

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
printf '{"ts":"2026-08-21T10:05:00+09:00","event":"delegate_start","challenge":"C-1","repo":"r","session_id":"s"}\n' >> "$WS/.flywheel/runs.jsonl"
check "当周に delegate_start があれば exit 1" 1 "reason=run-events"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
printf '{"ts":"2026-08-21T10:05:00+09:00","event":"adhoc_start","id":"a1","title":"差し込み"}\n' >> "$WS/.flywheel/runs.jsonl"
check "当周に adhoc_start があれば exit 1" 1 "reason=run-events"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
printf '{"ts":"2026-08-21T10:05:00+09:00","event":"delegate_end","session_id":"s","result":"done"}\n' >> "$WS/.flywheel/runs.jsonl"
check "当周の delegate_end（事後補記）があれば exit 1" 1 "reason=run-events"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
printf '{"ts":"2026-08-20T18:00:00+09:00","event":"delegate_start","session_id":"old"}\n' > "$WS/.flywheel/runs.jsonl.new"
cat "$WS/.flywheel/runs.jsonl" >> "$WS/.flywheel/runs.jsonl.new"
mv "$WS/.flywheel/runs.jsonl.new" "$WS/.flywheel/runs.jsonl"
check "当周の cycle_start より前のイベントは判定に影響しない" 0 "decision=defer"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
rm -f "$WS/.flywheel/runs.jsonl"
check "runs.jsonl 不在は exit 2（「委譲なし」と読み替えない）" 2 "decision=commit"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
: > "$WS/.flywheel/runs.jsonl"
check "runs.jsonl に cycle_start が無いのは exit 2" 2 "decision=commit"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
printf '{"ts":"2026-08-21T11:00:00+09:00","event":"cycle_start","cycle":"2026-08-21-cycle-2"}\n' >> "$WS/.flywheel/runs.jsonl"
check "最後の cycle_start が別サイクルなら exit 2（前周の stale な start で誤証明しない）" 2 "decision=commit"

if [ "$(id -u)" -ne 0 ]; then
  reset_ws; add_cycle "$CYCLE" 2026-08-21 1
  chmod 000 "$WS/.flywheel/runs.jsonl"
  check "runs.jsonl 読み取り不可は exit 2" 2 "decision=commit"
  chmod 644 "$WS/.flywheel/runs.jsonl"
fi

# --- 条件 6: --notable ---

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
check "--notable が 1 件でもあれば exit 1" 1 "reason=notable: heartbeat exit 1" --notable "heartbeat exit 1"
check "--notable が複数でも全件が理由に出る" 1 "reason=notable: periodic-audit 起動" \
  --notable "heartbeat exit 1" --notable "periodic-audit 起動"

# --- 条件 7: 保留は当日内に限る（日跨ぎはフラッシュ） ---

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
add_cycle 2026-08-21-cycle-2 2026-08-21 2
assert_case "同日の 2 周目は保留可（pending_index_lines=2）" 0 "pending_index_lines=2" \
  -- --workspace "$WS" --cycle 2026-08-21-cycle-2
assert_case "同日の 2 周目は保留中の .md をすべて列挙する" 0 "pending_md=2" \
  -- --workspace "$WS" --cycle 2026-08-21-cycle-2

add_cycle 2026-08-22-cycle 2026-08-22 1
assert_case "翌日の周は前日分の保留をフラッシュする（exit 1）" 1 "reason=stale-batch" \
  -- --workspace "$WS" --cycle 2026-08-22-cycle
assert_case "フラッシュ時の pending_index_lines は保留分を含む（3）" 1 "pending_index_lines=3" \
  -- --workspace "$WS" --cycle 2026-08-22-cycle

# まとめコミットの検証範囲: pending_index_lines をそのまま --tail に渡すと検証が通ること（結線の固定）
assert_true "pending_index_lines を --tail に渡すとバリデータが保留分まで検証して exit 0" \
  /usr/bin/ruby "$VALIDATOR" journal-index "$WS/journal/index.jsonl" --tail 3 --expect-cycle 2026-08-22-cycle
assert_true "保留中の .md はそれぞれ journal-md 検査を通る" \
  /usr/bin/ruby "$VALIDATOR" journal-md "$WS/journal/2026-08-21-cycle-2.md"

# --- index.jsonl 側の異常（append-only・当周行の同一性） ---

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
printf 'これはJSONではない\n' >> "$WS/journal/index.jsonl"
check "末尾行が JSON として壊れていれば exit 2" 2 "decision=commit"

reset_ws; add_cycle 2026-08-21-cycle-2 2026-08-21 2
check "末尾行が当周（seq 一致）でなければ exit 2" 2 "decision=commit"

# 上のケースは runs.jsonl 側（最後の cycle_start が別サイクル）でも exit 2 になるため、
# index.jsonl の同一性照合だけを切り出したケースを別に持つ（片方だけ壊れても検出できること）。
reset_ws; add_cycle "$CYCLE" 2026-08-21 1
index_line 2026-08-21 2 '[]' >> "$WS/journal/index.jsonl"
check "runs は当周でも index.jsonl の末尾行が当周でなければ exit 2（同一性照合の単独検出）" 2 "decision=commit"

reset_ws
check "当周の追記が無い（index.jsonl がコミット済みのまま）は exit 2" 2 "decision=commit"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
/usr/bin/ruby -e 'ls=File.readlines(ARGV[0]); ls.delete_at(0); File.write(ARGV[0], ls.join)' "$WS/journal/index.jsonl"
check "index.jsonl に削除行がある（append-only 違反の疑い）は exit 2" 2 "decision=commit"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
printf '追記\n' >> "$WS/journal/2026-08-20-cycle.md"
check "コミット済みの .md を書き換えたら exit 1（append-only の破れ）" 1 "reason=journal-md-modified"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
printf 'memo\n' > "$WS/journal/scratch.txt"
check "journal に想定外の未コミットファイルがあれば exit 1" 1 "reason=journal-unknown-file"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
printf '# template\n' > "$WS/journal/cycle-template.md"
check "journal の cycle-template.md / README.md の未コミットは変化とみなさない" 0 "decision=defer"

# --- 判定不能と変化ありが同時なら判定不能が勝つ（丸め込みの禁止） ---

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
printf '追記\n' >> "$WS/challenge-ledger.md"
rm -f "$WS/.flywheel/runs.jsonl"
check "判定不能と変化ありが同時なら exit 2（かつ decision=commit）" 2 "decision=commit"
check "判定不能でも変化の理由は出力する" 2 "reason=state-dirty"

# --- 初回サイクル（index.jsonl が未追跡・前周行なし） ---

rm -rf "$WS"
mkdir -p "$WS/journal" "$WS/.flywheel" "$WS/memory"
git -C "$WS" init -q .
git -C "$WS" config user.email tester@example.com
git -C "$WS" config user.name tester
printf '# 課題台帳\n' > "$WS/challenge-ledger.md"
git -C "$WS" add challenge-ledger.md >/dev/null 2>&1
git -C "$WS" commit -qm init >/dev/null 2>&1
: > "$WS/.flywheel/runs.jsonl"
add_cycle "$CYCLE" 2026-08-21 1
check "初回サイクル（index.jsonl が未追跡）でも全行を未コミットとして数える" 0 "pending_index_lines=1"

reset_ws
rm -rf "$WS/journal"; mkdir -p "$WS/journal"
git -C "$WS" rm -r --cached journal >/dev/null 2>&1
git -C "$WS" commit -qm drop >/dev/null 2>&1
: > "$WS/.flywheel/runs.jsonl"
add_cycle "$CYCLE" 2026-08-21 1
add_cycle "$CYCLE" 2026-08-21 1 '[{"gate":"FR-13","issue":"C-001","summary":"s"}]'
check "前周行が無く承認待ちが非空なら exit 1（比較対象が無いときは変化扱い）" 1 "reason=approval-set-changed"

# --- 規定・実装・ドキュメントの結線（規則の横展開の取りこぼし検出） ---

SKILL_MD="$REPO_ROOT/skills/run-cycle/SKILL.md"
JOURNAL_README="$REPO_ROOT/templates/journal/README.md"
CONTRACTS_MD="$REPO_ROOT/contracts/README.md"
DOCS_README="$REPO_ROOT/docs/README.md"
DESIGN_DOC="$REPO_ROOT/docs/noop-cycle-batching.md"

assert_contains "SKILL 手順6 が noop-check.rb を呼ぶ規定を持つ" "$SKILL_MD" 'scripts/noop-check.rb'
assert_contains "SKILL 手順6 が「保留してよいのは exit 0 のときだけ」を明記する" "$SKILL_MD" "保留してよいのは exit 0 のときだけ"
assert_contains "SKILL 手順6 が起動失敗を判定不能として扱う縮退規定を持つ" "$SKILL_MD" "exit 126/127 等＝ruby 未導入・実行不能"
assert_contains "SKILL 手順6 が判定後に判明する事象の取り消し条件を持つ" "$SKILL_MD" "保留の取り消し条件"
assert_contains "SKILL 手順6 が検算の範囲を pending_index_lines で広げる規定を持つ" "$SKILL_MD" 'pending_index_lines'
assert_contains "SKILL 手順6 が保留分を含むコミットのメッセージ規定を持つ" "$SKILL_MD" "束ねたサイクル名をコミットメッセージ本文に列挙する"
assert_contains "SKILL 出力節が「書き出しは毎周・コミットは変化のあった周」を明記する" "$SKILL_MD" "Git コミットは変化のあった周にまとめる"
assert_contains "journal README が保留の規則を持つ" "$JOURNAL_README" "書き出しは毎周・Git コミットは変化のあった周にまとめる"
assert_contains "contracts README の --tail 規定が保留分まで広がっている" "$CONTRACTS_MD" 'pending_index_lines'
assert_contains "docs README にスクリプトが載っている" "$DOCS_README" "noop-check.rb"
assert_contains "docs README に設計ドキュメントが載っている" "$DOCS_README" "noop-cycle-batching.md"
assert_contains "設計ドキュメントが decisions を判定に使わない理由を持つ" "$DESIGN_DOC" "decisions"

# .md のセクション見出しは validate-artifact.rb（契約）と同一の文字列でなければならない
# （どちらかだけを改名すると、①〜④の検査が静かに素通しになる）。
for sec in "## 触った課題" "## 委譲" "## 作成した PR・ブランチの URL" "## 承認待ちゲート一覧"; do
  assert_contains "契約バリデータがセクション見出しを持つ: ${sec}" "$VALIDATOR" "\"${sec}\","
  assert_contains "noop-check がセクション見出しを持つ: ${sec}" "$SCRIPT" "\"${sec}\","
done
# ⑤ 判断と根拠は契約側にはあり、noop-check の判定対象にはない（decisions を使わない設計の固定）
assert_contains "契約バリデータは ⑤ 判断と根拠を検査対象に持つ" "$VALIDATOR" '"## 判断と根拠",'
if grep -qF -- '"## 判断と根拠",' "$SCRIPT"; then
  FAIL=$((FAIL + 1))
  echo "FAIL - noop-check の判定対象セクションに ⑤ 判断と根拠が入っていない"
else
  PASS=$((PASS + 1))
  echo "ok   - noop-check の判定対象セクションに ⑤ 判断と根拠が入っていない"
fi

echo
echo "passed: $PASS / failed: $FAIL"
[ "$FAIL" -eq 0 ]
