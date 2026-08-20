#!/usr/bin/env bash
#
# noop-check.test.sh — scripts/noop-check.rb のテスト。
#
# 実行: bash scripts/tests/noop-check.test.sh
#   - 依存: bash（macOS 標準の 3.2 でも可）・/usr/bin/ruby（macOS 標準）・git。テストフレームワーク不使用。
#   - 書き込みはすべて一時ディレクトリ内で完結し、リポジトリの状態を変更しない。
#
# 検査の要（Issue #82）:
#   - **最悪の失敗様式を作らない**: 「変化があったのに no-op と判定し、成果がコミットされず
#     ワーキングツリーに滞留する」こと。7 条件それぞれについて、条件が崩れたら exit 0 に
#     ならないことを固定する。
#   - **パス集合の列挙漏れが「変化なし」に落ちない**: 監視はワーキングツリー全体で、
#     `contracts/cycle-commit-paths.txt` に無いパスも `out-of-scope-dirty` として変化扱い。
#     許可パスと監視範囲がずれても fail-closed に倒れることを固定する。
#   - **判定不能を「変化なし」に丸めない**: runs.jsonl 不在・末尾行が当周でない・スキーマ違反・
#     `.md` の構造破れ・不正 UTF-8・同名 cycle_start の多重は exit 2。判定不能と変化ありが
#     同時なら exit 2 が勝つ。判定を行わない経路（--help）も exit 0 を名乗らない。
#   - **`decisions` を判定に使わない**（⑤判断と根拠に記載があっても no-op のまま）: 判定に含めると
#     run-cycle は毎周何かを書き残すため本機能が一度も発火しない、という設計判断の回帰テスト。
#   - **まとめコミットの検証範囲**: `pending_index_lines` は非空レコード数（`--tail` と同じ規則）で、
#     そのまま validate-artifact.rb の `--tail` に渡すと保留分まで検証されること。

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/noop-check.rb"
VALIDATOR="$REPO_ROOT/scripts/validate-artifact.rb"
PATHS_FILE="$REPO_ROOT/contracts/cycle-commit-paths.txt"

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

# assert_absent_out <名前> <期待exit> <出てはいけない部分文字列> -- <引数...>
assert_absent_out() {
  name="$1"; want_exit="$2"; bad_out="$3"
  shift 3
  [ "$1" = "--" ] && shift
  got_out="$(/usr/bin/ruby "$SCRIPT" "$@" 2>/dev/null)"
  got_exit=$?
  ok=1
  [ "$got_exit" -eq "$want_exit" ] || ok=0
  case "$got_out" in
    *"$bad_out"*) ok=0 ;;
  esac
  if [ "$ok" -eq 1 ]; then
    PASS=$((PASS + 1)); echo "ok   - $name"
  else
    FAIL=$((FAIL + 1)); echo "FAIL - $name (exit: got=$got_exit want=$want_exit)"; echo "       stdout: $got_out"
  fi
}

# assert_stderr <名前> <期待exit> <期待stderr部分文字列> -- <引数...>
# 判定不能の理由は「どの検査が拾ったか」で診断が変わる。exit code だけを見ると別の検査に
# 吸収されて診断が失われても気づけないため、理由の文言まで固定する。
assert_stderr() {
  name="$1"; want_exit="$2"; want_err="$3"
  shift 3
  [ "$1" = "--" ] && shift
  got_err="$(/usr/bin/ruby "$SCRIPT" "$@" 2>&1 >/dev/null)"
  got_exit=$?
  ok=1
  [ "$got_exit" -eq "$want_exit" ] || ok=0
  case "$got_err" in
    *"$want_err"*) ;;
    *) ok=0 ;;
  esac
  if [ "$ok" -eq 1 ]; then
    PASS=$((PASS + 1)); echo "ok   - $name"
  else
    FAIL=$((FAIL + 1)); echo "FAIL - $name (exit: got=$got_exit want=$want_exit)"; echo "       stderr: $got_err"
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
JDIR="journal"   # journal ディレクトリ名（--journal-dir のテストで差し替える）

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
# `.gitignore` は flywheel-init が scaffold する実形（`.flywheel/*` ＋ cadence.json だけ追跡）。
reset_ws() {
  prev_approvals="${1:-[]}"
  rm -rf "$WS"
  mkdir -p "$WS/$JDIR" "$WS/.flywheel" "$WS/memory" "$WS/positions"
  git -C "$WS" init -q .
  git -C "$WS" config user.email tester@example.com
  git -C "$WS" config user.name tester
  printf '.flywheel/*\n!.flywheel/cadence.json\n' > "$WS/.gitignore"
  printf '# 課題台帳\n' > "$WS/challenge-ledger.md"
  printf '# 記憶\n' > "$WS/memory/note.md"
  printf '# ポジション\n' > "$WS/positions/harness.md"
  printf 'name\turl\n' > "$WS/repos.tsv"
  printf '# ソース宣言\n' > "$WS/challenge-sources.md"
  printf '# ベースライン\n' > "$WS/CLAUDE.md"
  printf '{}\n' > "$WS/.flywheel/cadence.json"
  printf '# journal\n' > "$WS/$JDIR/README.md"
  write_noop_md "$WS/$JDIR/2026-08-20-cycle.md"
  index_line 2026-08-20 1 "$prev_approvals" > "$WS/$JDIR/index.jsonl"
  git -C "$WS" add -A >/dev/null 2>&1
  git -C "$WS" commit -qm init >/dev/null 2>&1
  : > "$WS/.flywheel/runs.jsonl"
}

# 当周（未コミット）を足す。
add_cycle() { # add_cycle <cycle名> <date> <seq> [pending_approvals JSON配列]
  write_noop_md "$WS/$JDIR/$1.md"
  index_line "$2" "$3" "${4:-[]}" >> "$WS/$JDIR/index.jsonl"
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
assert_stderr "workspace が作業ツリーのトップでなければ exit 2（専用の診断）" 2 "作業ツリーのトップではありません" \
  -- --workspace "$WS/memory" --cycle "$CYCLE"
assert_case "--anchor-after-line が整数でなければ exit 2" 2 - -- --workspace "$WS" --cycle "$CYCLE" --anchor-after-line x
printf 'x\n' >> "$WS/challenge-ledger.md"   # 許可パス内に dirty を作ってから正本を欠かす
assert_stderr "パス正本ファイルが読めなければ exit 2（専用の診断）" 2 "パス正本ファイル" \
  -- --workspace "$WS" --cycle "$CYCLE" --paths-file "$tmp/no-such-paths.txt"
# 正本が読めないまま判定を続けると、許可パス内の dirty まで「未知のパス」として
# 誤分類される（空の集合で判定を続けてしまう）。早期に打ち切ることを固定する。
assert_absent_out "パス正本が読めないときは空の集合で判定を続けない" 2 "reason=out-of-scope-dirty" \
  -- --workspace "$WS" --cycle "$CYCLE" --paths-file "$tmp/no-such-paths.txt"
reset_ws; add_cycle "$CYCLE" 2026-08-21 1
# 判定を一切行わない経路が exit 0（=「保留可」）を名乗らない
assert_case "--help は exit 2（判定していない経路が exit 0 を名乗らない）" 2 - -- --help

# --- 基準ケース: 完全な no-op は exit 0（保留可） ---

check "完全な no-op は exit 0（保留可）" 0 "decision=defer"
check "no-op でも pending_index_lines を出す（検算の範囲指定に使う）" 0 "pending_index_lines=1"
check "no-op でも pending_md_file を出す" 0 "pending_md_file=journal/2026-08-21-cycle.md"
check "pending_cycles を出す（1:1 対応の照合に使う）" 0 "pending_cycles=1"
check "許可パスの正本を commit_path として出力する" 0 "commit_path=challenge-ledger.md"
check "許可パスに positions が含まれる（実運用のサイクルコミットに現れる）" 0 "commit_path=positions"

# --- 条件 1: 監視はワーキングツリー全体（許可パスの列挙漏れが「変化なし」に落ちない） ---

for p in challenge-ledger.md memory/note.md journal-unrelated.md positions/harness.md repos.tsv challenge-sources.md CLAUDE.md .flywheel/cadence.json; do
  case "$p" in journal-unrelated.md) continue ;; esac
  reset_ws; add_cycle "$CYCLE" 2026-08-21 1
  printf 'x\n' >> "$WS/$p"
  check "ワーキングツリーの変更を取りこぼさない: ${p}" 1 "dirty"
done

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
printf '# アーカイブ\n' > "$WS/challenge-archive.md"
check "許可パスの新規作成（未追跡）は state-dirty" 1 "reason=state-dirty"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
printf '# 新規\n' > "$WS/memory/new.md"
check "許可パス配下の未追跡ファイルを検出（--untracked-files=all）" 1 "reason=state-dirty"

# **パス集合がずれたら落ちる**: 正本に無い新しいパスは out-of-scope-dirty（＝変化扱い）
reset_ws; add_cycle "$CYCLE" 2026-08-21 1
printf 'x\n' > "$WS/brand-new-thing.md"
check "正本に無い新しいパスは out-of-scope-dirty（黙って変化なしに落ちない）" 1 "reason=out-of-scope-dirty"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
printf 'x\n' >> "$WS/repos.tsv"
check "許可パス外の変更は state-dirty ではなく out-of-scope-dirty として区別する" 1 "reason=out-of-scope-dirty"
assert_absent_out "許可パス外の変更を state-dirty と誤分類しない" 1 "reason=state-dirty" \
  -- --workspace "$WS" --cycle "$CYCLE"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
printf 'active: normal\n' > "$WS/priority-policy.md"
check "priority-policy.md は [exclude] 宣言済みなので判定に影響しない" 0 "decision=defer"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
printf 'x\n' > "$WS/noise.tmp"
check "--exclude で既知ノイズを宣言的に黙らせられる" 0 "decision=defer" --exclude noise.tmp

# .flywheel のローカル実行状態は gitignore が無くても判定材料にしない
reset_ws; add_cycle "$CYCLE" 2026-08-21 1
rm -f "$WS/.gitignore"
git -C "$WS" rm -q --cached .gitignore >/dev/null 2>&1
git -C "$WS" commit -qm drop-ignore >/dev/null 2>&1
check ".gitignore が無くても runs.jsonl は判定材料にしない（[exclude] 宣言）" 0 "decision=defer"

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

# 比較キーは (gate, issue)。同一ゲートで対象課題だけ入れ替わる変化を取りこぼさない
reset_ws '[{"gate":"FR-13","issue":"C-001","summary":"s"}]'
add_cycle "$CYCLE" 2026-08-21 1 '[{"gate":"FR-13","issue":"C-002","summary":"s"}]'
check "同一ゲートで対象課題だけ入れ替わる変化を検出する（比較キーに issue を含む）" 1 "reason=approval-set-changed"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1 '[{"gate":"FR-22","issue":"C-003","summary":"昇格承認待ち"}]'
check "前周に無かった承認待ちが出たら exit 1（ステータス遷移を伴わない FR-22 ゲート）" 1 "reason=approval-set-changed"

# 比較対象は「直前の 1 行」であって先頭行ではない。既コミット行 A・保留行 B・当周行 B と並べ、
# 直前行（B）と比べれば変化なし／先頭行（A）と比べれば変化ありになる形で固定する。
reset_ws '[{"gate":"FR-13","issue":"C-001","summary":"s"}]'
add_cycle 2026-08-21-cycle-2 2026-08-21 2 '[{"gate":"FR-99","issue":"C-999","summary":"s"}]'
add_cycle "$CYCLE" 2026-08-21 1 '[{"gate":"FR-99","issue":"C-999","summary":"s"}]'
assert_absent_out "前周比較は直前行（先頭行と比べていない）" 0 "reason=approval-set-changed" \
  -- --workspace "$WS" --cycle "$CYCLE" --anchor-after-line 1

# --- 条件 4: .md の構造検査 と ①〜④（⑤は判定に使わない） ---

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
write_md "$WS/journal/$CYCLE.md" "なし（台帳に課題エントリなし）" なし なし なし "初回サイクル"
check "理由を添えた「なし（…）」は該当なしの宣言（実運用 journal の実形）" 0 "decision=defer"

# 括弧の中へ実際の変化を書く形は取りこぼさない（数字・URL を含めば変化）
reset_ws; add_cycle "$CYCLE" 2026-08-21 1
write_md "$WS/journal/$CYCLE.md" "なし（C-035 は完了しアーカイブ済み）" なし なし なし "判断"
check "「なし（C-035 は…）」は変化として扱う（括弧内の課題 ID）" 1 "reason=journal-md-content"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
write_md "$WS/journal/$CYCLE.md" なし "なし（前周の session s1 を --resume で継続）" なし なし "判断"
check "「なし（… session s1 …）」は変化として扱う（括弧内の session 識別子）" 1 "reason=journal-md-content"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
write_md "$WS/journal/$CYCLE.md" なし なし "なし（既存 PR https://github.com/x/y/pull/1 に push）" なし "判断"
check "「なし（… https://… ）」は変化として扱う（括弧内の URL）" 1 "reason=journal-md-content"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
write_md "$WS/journal/$CYCLE.md" なし なし なし "なし（FR-22 は解消）" "判断"
check "「なし（FR-22 は解消）」は変化として扱う（括弧内のゲート名）" 1 "reason=journal-md-content"

# 構造が契約どおりでなければ判定不能（条件4 が空虚に真になるのを防ぐ）
reset_ws; add_cycle "$CYCLE" 2026-08-21 1
/usr/bin/ruby -e 's=File.read(ARGV[0],encoding:"UTF-8"); s=s.sub("## 触った課題","## 触った課題（ID とステータス遷移）").sub("- なし","- C-001: 分類済 → 着手中"); File.write(ARGV[0],s)' "$WS/journal/$CYCLE.md"
check "見出しがずれていれば exit 2（条件4 を空虚に真にしない）" 2 "decision=commit"

# セクションが「丸ごと欠落」する形（改名ではない）。改名検査に吸収されず、欠落検査自身が拾うこと。
reset_ws; add_cycle "$CYCLE" 2026-08-21 1
/usr/bin/ruby -e 's=File.read(ARGV[0],encoding:"UTF-8"); s=s.sub("## 委譲\n\n- なし\n\n",""); File.write(ARGV[0],s)' "$WS/journal/$CYCLE.md"
assert_stderr "定型セクションが欠落していれば exit 2（欠落検査が拾う）" 2 "定型セクションがありません" \
  -- --workspace "$WS" --cycle "$CYCLE"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
/usr/bin/ruby -e 's=File.read(ARGV[0],encoding:"UTF-8"); s=s.sub("## 委譲\n\n- なし","## 委譲\n\n<!-- 閉じない\n- repo: x / skill: y"); File.write(ARGV[0],s)' "$WS/journal/$CYCLE.md"
check "閉じない HTML コメントがあれば exit 2（全行の読み飛ばしを防ぐ）" 2 "decision=commit"
assert_stderr "閉じない HTML コメントは専用の診断で報告する（欠落検査に吸収されない）" 2 "閉じていない HTML コメント" \
  -- --workspace "$WS" --cycle "$CYCLE"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
/usr/bin/ruby -e 's=File.read(ARGV[0],encoding:"UTF-8"); File.write(ARGV[0], "<!-- 雛形の説明\n複数行に渡る -->\n" + s)' "$WS/journal/$CYCLE.md"
check "閉じる HTML コメント（雛形の説明文）は正常に読み飛ばす" 0 "decision=defer"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
/usr/bin/ruby -e 's=File.read(ARGV[0],encoding:"UTF-8"); s=s.sub("## 委譲","## 追加の見出し"); File.write(ARGV[0],s)' "$WS/journal/$CYCLE.md"
check "定型 5 セクションに無い見出しがあれば exit 2" 2 "decision=commit"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
printf '\n## 委譲\n\n- なし\n' >> "$WS/journal/$CYCLE.md"
check "定型セクションが重複していれば exit 2" 2 "decision=commit"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
rm -f "$WS/journal/$CYCLE.md"
check "当周の .md が無ければ exit 2（判定不能）" 2 "decision=commit"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
printf '\xff\xfe invalid\n' >> "$WS/journal/$CYCLE.md"
check "当周の .md が不正 UTF-8 なら exit 2（未処理例外で exit 1 に化けない）" 2 "decision=commit"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
printf '\xff\xfe invalid\n' >> "$WS/journal/index.jsonl"
check "index.jsonl が不正 UTF-8 なら exit 2" 2 "decision=commit"

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
/usr/bin/ruby -e 'p=ARGV[0]; c=File.read(p); File.write(p, %q({"ts":"2026-08-20T18:00:00+09:00","event":"delegate_start","session_id":"old"})+"\n"+c)' "$WS/.flywheel/runs.jsonl"
check "当周の cycle_start より前のイベントは判定に影響しない" 0 "decision=defer"

# クラッシュ後のサイクル名再利用: 同名 cycle_start が 2 本
reset_ws; add_cycle "$CYCLE" 2026-08-21 1
cat > "$WS/.flywheel/runs.jsonl" <<'EOF'
{"ts":"2026-08-21T10:00:00+09:00","event":"cycle_start","cycle":"2026-08-21-cycle"}
{"ts":"2026-08-21T10:05:00+09:00","event":"delegate_start","challenge":"C-1","repo":"r","session_id":"s1"}
{"ts":"2026-08-21T10:40:00+09:00","event":"delegate_end","session_id":"s1","result":"done"}
{"ts":"2026-08-21T11:00:00+09:00","event":"cycle_start","cycle":"2026-08-21-cycle"}
EOF
check "同名 cycle_start が 2 本でアンカー未指定なら exit 2（挟まれた委譲を漏らさない）" 2 "decision=commit"
assert_stderr "同名 cycle_start の多重は専用の診断（--anchor-after-line の指示）で報告する" 2 "--anchor-after-line で当周の位置を指定" \
  -- --workspace "$WS" --cycle "$CYCLE"
check "アンカー 0 なら 1 本目が当周＝挟まれた委譲を検出する" 2 "reason=run-events" --anchor-after-line 0
check "アンカー 3 なら 2 本目が当周＝当周の範囲に委譲は無い" 0 "decision=defer" --anchor-after-line 3
check "アンカーがファイル行数を超えたら exit 2（append-only の前提破れ）" 2 "decision=commit" --anchor-after-line 99

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
rm -f "$WS/.flywheel/runs.jsonl"
check "runs.jsonl 不在は exit 2（「委譲なし」と読み替えない）" 2 "decision=commit"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
: > "$WS/.flywheel/runs.jsonl"
check "runs.jsonl に当周の cycle_start が無いのは exit 2" 2 "decision=commit"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
printf '{"ts":"2026-08-21T11:00:00+09:00","event":"cycle_start","cycle":"2026-08-21-cycle-2"}\n' >> "$WS/.flywheel/runs.jsonl"
check "当周範囲に別サイクルの cycle_start があれば exit 2" 2 "decision=commit"

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

# --- pending_index_lines の数え方（--tail と同じ非空レコード基準） ---

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
/usr/bin/ruby -e 'p=ARGV[0]; ls=File.readlines(p); ls.insert(-2, "\n"); File.write(p, ls.join)' "$WS/journal/index.jsonl"
check "保留区間に空行が混ざっても pending_index_lines は非空レコード数（1）" 0 "pending_index_lines=1"
n="$(/usr/bin/ruby "$SCRIPT" --workspace "$WS" --cycle "$CYCLE" 2>/dev/null | sed -n 's/^pending_index_lines=//p')"
assert_true "その値を --tail に渡すと既コミット行まで遡らない（恒久失敗を作らない）" \
  /usr/bin/ruby "$VALIDATOR" journal-index "$WS/journal/index.jsonl" --tail "$n" --expect-cycle "$CYCLE"

# --- 保留分の 1:1 対応（.md 1 件 ↔ index 1 レコード） ---

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
add_cycle 2026-08-21-cycle-2 2026-08-21 2
rm -f "$WS/journal/2026-08-21-cycle.md" # git clean -fd 相当（未追跡の保留 .md だけが消える）
assert_case "保留中に .md が失われたら exit 2（1:1 対応の破れ）" 2 "decision=commit" \
  -- --workspace "$WS" --cycle 2026-08-21-cycle-2

# --- index.jsonl 側の異常（append-only・当周行の同一性） ---

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
printf 'これはJSONではない\n' >> "$WS/journal/index.jsonl"
check "末尾レコードが JSON として壊れていれば exit 2" 2 "decision=commit"

reset_ws; add_cycle 2026-08-21-cycle-2 2026-08-21 2
check "末尾レコードが当周（seq 一致）でなければ exit 2" 2 "decision=commit"

# 上のケースは runs.jsonl 側（当周の cycle_start 不在）でも exit 2 になるため、
# 同一性照合だけを切り出したケースを別に持つ（他の検査に吸収されず単独で検出できること）:
# .md と index の件数は揃え（1:1 照合を通す）、runs には当周の cycle_start だけを置き
# （runs 検査を通す）、index の末尾レコードだけが当周でない状態にする。
reset_ws
add_cycle "$CYCLE" 2026-08-21 1
write_noop_md "$WS/$JDIR/2026-08-21-cycle-2.md"
index_line 2026-08-21 2 '[]' >> "$WS/$JDIR/index.jsonl"
assert_stderr "末尾レコードが当周でなければ exit 2（同一性照合の単独検出）" 2 "末尾レコードが当周の行ではありません" \
  -- --workspace "$WS" --cycle "$CYCLE"

reset_ws
check "当周の追記が無い（index.jsonl がコミット済みのまま）は exit 2" 2 "decision=commit"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
/usr/bin/ruby -e 'ls=File.readlines(ARGV[0]); ls.delete_at(0); File.write(ARGV[0], ls.join)' "$WS/journal/index.jsonl"
check "index.jsonl の既コミット行を削除したら exit 2（append-only の前方一致違反）" 2 "decision=commit"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
/usr/bin/ruby -e 'ls=File.readlines(ARGV[0]); ls[0]=ls[0].sub("2026-08-20","2026-08-19"); File.write(ARGV[0], ls.join)' "$WS/journal/index.jsonl"
check "index.jsonl の既コミット行を書き換えたら exit 2（append-only の前方一致違反）" 2 "decision=commit"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
printf '追記\n' >> "$WS/journal/2026-08-20-cycle.md"
check "コミット済みの .md を書き換えたら exit 1（append-only の破れ）" 1 "reason=journal-md-modified"
check "破れた既存 .md もまとめコミット前の検算対象に載る" 1 "pending_md_file=journal/2026-08-20-cycle.md"
check "破れた既存 .md は pending_cycles には数えない（1:1 の相手は新規分のみ）" 1 "pending_cycles=1"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
printf 'memo\n' > "$WS/journal/scratch.txt"
check "journal に想定外の未コミットファイルがあれば exit 1" 1 "reason=journal-unknown-file"

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
printf '# template\n' > "$WS/journal/cycle-template.md"
check "journal の cycle-template.md / README.md の未コミットは変化とみなさない" 0 "decision=defer"

# --- --journal-dir（既定以外の置き場でも同じ規則が効く） ---

JDIR="diary"
reset_ws; add_cycle "$CYCLE" 2026-08-21 1
assert_case "--journal-dir を尊重する（既定 journal 固定になっていない）" 0 "pending_md_file=diary/2026-08-21-cycle.md" \
  -- --workspace "$WS" --cycle "$CYCLE" --journal-dir diary
assert_case "--journal-dir 未指定なら diary は journal 扱いされない（判定不能）" 2 "decision=commit" \
  -- --workspace "$WS" --cycle "$CYCLE"
JDIR="journal"

# --- git status の rename/copy トークン（元パスを誤ってエントリ化しない） ---

reset_ws; add_cycle "$CYCLE" 2026-08-21 1
git -C "$WS" mv memory/note.md memory/renamed.md >/dev/null 2>&1
check "rename されたファイルを検出する" 1 "reason=state-dirty"
assert_absent_out "rename の元パスを未知パスとして二重計上しない" 1 "reason=out-of-scope-dirty" \
  -- --workspace "$WS" --cycle "$CYCLE"

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
printf '.flywheel/*\n!.flywheel/cadence.json\n' > "$WS/.gitignore"
printf '# 課題台帳\n' > "$WS/challenge-ledger.md"
git -C "$WS" add -A >/dev/null 2>&1
git -C "$WS" commit -qm init >/dev/null 2>&1
: > "$WS/.flywheel/runs.jsonl"
add_cycle "$CYCLE" 2026-08-21 1
check "初回サイクル（index.jsonl が未追跡）でも全レコードを未コミットとして数える" 0 "pending_index_lines=1"

rm -rf "$WS"
mkdir -p "$WS/journal" "$WS/.flywheel"
git -C "$WS" init -q .
git -C "$WS" config user.email tester@example.com
git -C "$WS" config user.name tester
printf '.flywheel/*\n!.flywheel/cadence.json\n' > "$WS/.gitignore"
printf '# 課題台帳\n' > "$WS/challenge-ledger.md"
git -C "$WS" add -A >/dev/null 2>&1
git -C "$WS" commit -qm init >/dev/null 2>&1
: > "$WS/.flywheel/runs.jsonl"
add_cycle "$CYCLE" 2026-08-21 1 '[{"gate":"FR-13","issue":"C-001","summary":"s"}]'
check "前周行が無く承認待ちが非空なら exit 1（比較対象が無いときは変化扱い）" 1 "reason=approval-set-changed"

# --- 規定・実装・ドキュメントの結線（規則の横展開の取りこぼし検出） ---

SKILL_MD="$REPO_ROOT/skills/run-cycle/SKILL.md"
JOURNAL_README="$REPO_ROOT/templates/journal/README.md"
CONTRACTS_MD="$REPO_ROOT/contracts/README.md"
DOCS_README="$REPO_ROOT/docs/README.md"
DESIGN_DOC="$REPO_ROOT/docs/noop-cycle-batching.md"

assert_contains "SKILL 手順6 が noop-check.rb を呼ぶ規定を持つ" "$SKILL_MD" 'scripts/noop-check.rb'
assert_contains "SKILL 手順6 が --anchor-after-line を渡す規定を持つ" "$SKILL_MD" '--anchor-after-line'
assert_contains "SKILL 手順6 が「保留してよいのは exit 0 のときだけ」を明記する" "$SKILL_MD" "保留してよいのは exit 0 のときだけ"
assert_contains "SKILL 手順6 が起動失敗を判定不能として扱う縮退規定を持つ" "$SKILL_MD" "exit 126/127 等＝ruby 未導入・実行不能"
assert_contains "SKILL 手順6 が判定後に判明する事象の取り消し条件を持つ" "$SKILL_MD" "保留の取り消し条件"
assert_contains "SKILL 手順6 が検算の範囲を pending_index_lines で広げる規定を持つ" "$SKILL_MD" 'pending_index_lines'
assert_contains "SKILL 手順6 が保留分を含むコミットのメッセージ規定を持つ" "$SKILL_MD" "束ねたサイクル名をコミットメッセージ本文に列挙する"
assert_contains "SKILL 出力節が「書き出しは毎周・コミットは変化のあった周」を明記する" "$SKILL_MD" "Git コミットは変化のあった周にまとめる"
assert_contains "SKILL 手順6 の許可パスがパス正本ファイルを出典にしている" "$SKILL_MD" 'contracts/cycle-commit-paths.txt'
assert_contains "SKILL 手順6 が commit_path の利用を規定する" "$SKILL_MD" 'commit_path=<path>'
assert_contains "journal README が保留の規則を持つ" "$JOURNAL_README" "書き出しは毎周・Git コミットは変化のあった周にまとめる"
assert_contains "contracts README の --tail 規定が保留分まで広がっている" "$CONTRACTS_MD" 'pending_index_lines'
assert_contains "contracts README にパス正本が構成物として載っている" "$CONTRACTS_MD" 'cycle-commit-paths.txt'
assert_contains "docs README にスクリプトが載っている" "$DOCS_README" "noop-check.rb"
assert_contains "docs README に設計ドキュメントが載っている" "$DOCS_README" "noop-cycle-batching.md"
assert_contains "設計ドキュメントが decisions を判定に使わない理由を持つ" "$DESIGN_DOC" "decisions"
assert_contains "設計ドキュメントが実データによる発火率の再評価を持つ" "$DESIGN_DOC" "発火率の見積もりと、それでも入れる理由"

# **許可パスと判定が単一正本から導かれている**ことの固定:
# 正本ファイルの [commit] 全件が commit_path として出力され、SKILL の許可パス記述にも現れること。
reset_ws; add_cycle "$CYCLE" 2026-08-21 1
commit_out="$(/usr/bin/ruby "$SCRIPT" --workspace "$WS" --cycle "$CYCLE" 2>/dev/null | sed -n 's/^commit_path=//p')"
paths_listed="$(/usr/bin/ruby -e '
sec = nil; out = []
File.readlines(ARGV[0], encoding: "UTF-8").each do |l|
  t = l.strip
  next if t.empty? || t.start_with?("#")
  if t == "[commit]" then sec = :c; next end
  if t == "[exclude]" then sec = :x; next end
  out << t if sec == :c
end
puts out' "$PATHS_FILE")"
if [ "$commit_out" = "$paths_listed" ]; then
  PASS=$((PASS + 1)); echo "ok   - commit_path 出力がパス正本の [commit] と一致する"
else
  FAIL=$((FAIL + 1)); echo "FAIL - commit_path 出力がパス正本の [commit] と一致する"
  echo "       script: $(echo "$commit_out" | tr '\n' ' ')"
  echo "       file:   $(echo "$paths_listed" | tr '\n' ' ')"
fi
while IFS= read -r p; do
  [ -n "$p" ] || continue
  assert_contains "SKILL の許可パス記述に正本の [commit] が現れる: ${p}" "$SKILL_MD" "\`$p\`"
done <<EOF
$paths_listed
EOF

# .md のセクション見出しは validate-artifact.rb（契約）と同一の文字列でなければならない
# （どちらかだけを改名すると、条件4 の検査が静かに素通しになる）。
for sec in "## 触った課題" "## 委譲" "## 作成した PR・ブランチの URL" "## 承認待ちゲート一覧" "## 判断と根拠"; do
  assert_contains "契約バリデータがセクション見出しを持つ: ${sec}" "$VALIDATOR" "\"${sec}\","
  assert_contains "noop-check がセクション見出しを持つ: ${sec}" "$SCRIPT" "\"${sec}\","
done

echo
echo "passed: $PASS / failed: $FAIL"
[ "$FAIL" -eq 0 ]
