#!/usr/bin/env bash
#
# cycle-lock.sh — run-cycle の多重起動を排他するロック（.flywheel/cycle.lock）を取得・解放する。
#
# 「存在確認 → 作成」の 2 段は TOCTOU を生むため、mkdir（既存なら失敗）1 回の原子的取得に
# 一本化する。取得時はロック内に所有者メタデータ（owner PID・その開始時刻・任意の session_id・
# 取得時刻）を書き、二重取得時は開始時刻照合（ps -o lstart。PID 再利用防御。他ユーザーの
# プロセスでも読める＝kill -0 の EPERM 誤判定を避ける）で生存判定する。
# 純シェル・依存なし（jq 不可）・macOS/Linux 両対応。
#
# 使い方:
#   scripts/cycle-lock.sh acquire [--session-id <id>] [--dry-run] [--workspace <dir>]
#   scripts/cycle-lock.sh release [--session-id <id>] [--workspace <dir>]
#
#   --session-id  この周の識別子（任意）。release は記録済み session_id との一致でも所有を認める。
#   --workspace   ロックを置くワークスペース（既定: .）。ロックは <workspace>/.flywheel/cycle.lock。
#   --dry-run     acquire のみ。ロックの取得・解放は実際に行うが、残骸回収時の runs.jsonl への
#                 abandoned 代筆（log-run-event.sh 呼び出し）だけスキップする（dry-run は状態
#                 ファイルに書かないため）。
#
# exit codes:
#   0 = 成功（acquire: 取得。stale 回収と abandoned 代筆は内包 / release: 解放）
#   2 = 並走検出（呼び出し側は「並走検出・今周スキップ」を報告して即終了する）
#   3 = release 所有者不一致（削除しない）
#   1 = 引数エラー等
#
# acquire の判定:
#   - 既存ロックの owner PID の実開始時刻（ps -o lstart）が取得でき、かつ記録済み開始時刻と
#     一致 → 並走 → exit 2（経過時間は見ない＝長時間の正常サイクルを stale 扱いしない）。
#   - プロセス不在・開始時刻不一致（PID 再利用）・メタデータ不能でロック mtime が 2 時間超
#     → 残骸。runs.jsonl 末尾に未終了の cycle_start が残っていれば log-run-event.sh で
#     cycle_end (result=abandoned) を代筆してから、ロックを削除し原子的取得を 1 回だけ再試行。
#   - メタデータ不能かつ mtime 2 時間以内 → 安全側で並走扱い → exit 2。
#
# 注意:
#   - owner PID は「最も近い祖先プロセスのうちコマンド名に claude を含むもの」（見つからなければ
#     親プロセス）。同じセッション（同じ claude プロセス配下）からの acquire / release で同一に
#     導出されることを所有者チェックに使う。
#   - abandoned 代筆は同ディレクトリの log-run-event.sh に委ねる（無ければ警告してスキップ＝
#     best-effort。観測が制御を阻害しない）。

set -euo pipefail

usage() {
  echo "usage: $0 acquire [--session-id <id>] [--dry-run] [--workspace <dir>]" >&2
  echo "       $0 release [--session-id <id>] [--workspace <dir>]" >&2
}

CMD="${1:-}"
case "$CMD" in
  acquire | release) shift ;;
  -h | --help) sed -n '2,/^$/p' "$0" | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
  *) usage; exit 1 ;;
esac

SESSION_ID=""
WORKSPACE="."
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --session-id)
      if [ $# -lt 2 ]; then echo "cycle-lock: --session-id に値がありません" >&2; exit 1; fi
      SESSION_ID="$2"; shift 2 ;;
    --workspace)
      if [ $# -lt 2 ]; then echo "cycle-lock: --workspace に値がありません" >&2; exit 1; fi
      WORKSPACE="$2"; shift 2 ;;
    --dry-run)
      DRY_RUN=1; shift ;;
    -h | --help)
      usage; exit 0 ;;
    *)
      echo "cycle-lock: 不明な引数: $1" >&2; usage; exit 1 ;;
  esac
done

LOCK="$WORKSPACE/.flywheel/cycle.lock"
OWNER_FILE="$LOCK/owner"

# 現在時刻を ISO 8601（タイムゾーンオフセットはコロン付き +09:00 形式）で返す。
iso_now() {
  t="$(date +%Y-%m-%dT%H:%M:%S%z)"
  printf '%s\n' "$t" | sed 's/\([0-9][0-9]\)$/:\1/'
}

# owner PID を導出する: 最も近い祖先プロセスのうちコマンド名に claude を含むもの。
# 見つからなければ本スクリプトの親プロセス（$PPID）。
derive_owner_pid() {
  pid="$PPID"
  i=0
  while [ "$pid" -gt 1 ] && [ "$i" -lt 50 ]; do
    comm="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
    case "$comm" in
      *claude*) printf '%s' "$pid"; return 0 ;;
    esac
    ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
    if [ -z "$ppid" ] || [ "$ppid" = "$pid" ]; then
      break
    fi
    pid="$ppid"
    i=$((i + 1))
  done
  printf '%s' "$PPID"
}

# PID の開始時刻（ps -o lstart=）を空白正規化して返す。プロセス不在なら空。
pid_lstart() {
  ps -o lstart= -p "$1" 2>/dev/null \
    | head -n1 \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/[[:space:]]\{1,\}/ /g' \
    || true
}

# owner メタデータ（key=value 行）から key の値を返す。読めなければ空。
meta_get() {
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n1 || true
}

# ロックの mtime（epoch 秒）。取得できなければ 0（macOS: stat -f / Linux: stat -c）。
lock_mtime() {
  stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK" 2>/dev/null || echo 0
}

# 取得済みロックに所有者メタデータを書く。
write_owner() {
  owner_pid="$(derive_owner_pid)"
  {
    printf 'pid=%s\n' "$owner_pid"
    printf 'pid_start=%s\n' "$(pid_lstart "$owner_pid")"
    if [ -n "$SESSION_ID" ]; then
      printf 'session_id=%s\n' "$SESSION_ID"
    fi
    printf 'acquired_at=%s\n' "$(iso_now)"
  } > "$OWNER_FILE"
}

# 残骸回収時: runs.jsonl 末尾に未終了の cycle_start が残っていれば、その cycle 値で
# cycle_end (result=abandoned) を log-run-event.sh に代筆させる（best-effort・dry-run 時はスキップ）。
maybe_close_abandoned() {
  if [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi
  runs="$WORKSPACE/.flywheel/runs.jsonl"
  if [ ! -f "$runs" ]; then
    return 0
  fi
  last="$(grep -E '"event":"cycle_(start|end)"' "$runs" | tail -n1 || true)"
  case "$last" in
    *'"event":"cycle_start"'*) ;;
    *) return 0 ;;
  esac
  cycle="$(printf '%s\n' "$last" | sed -n 's/.*"cycle":"\([^"]*\)".*/\1/p' || true)"
  logger="$(dirname "$0")/log-run-event.sh"
  if [ -x "$logger" ]; then
    "$logger" cycle_end --cycle "$cycle" --result abandoned --workspace "$WORKSPACE" || true
  else
    echo "cycle-lock: log-run-event.sh が見つからないため abandoned の代筆をスキップします: $logger" >&2
  fi
}

do_acquire() {
  # ロック本体の mkdir は親ディレクトリが無いと失敗するため、先に -p で確保する
  # （ロック本体に -p は使わない＝既存でも成功してしまい原子性が壊れる）。
  mkdir -p "$WORKSPACE/.flywheel"
  if mkdir "$LOCK" 2>/dev/null; then
    # メタデータが書けないままロックだけ残ると、以後の acquire が最長 2 時間ブロックされる
    # （所有者不明・mtime 2 時間以内 → 並走扱い）ため、失敗時はロックを解除して中止する。
    if ! write_owner; then
      rm -rf "$LOCK"
      echo "cycle-lock: 所有者メタデータの書き込みに失敗したためロックを解除して中止します" >&2
      exit 2
    fi
    exit 0
  fi

  # 取得失敗（既存ロックあり）→ 保持者の生存判定。
  rec_pid="$(meta_get "$OWNER_FILE" pid)"
  rec_start="$(meta_get "$OWNER_FILE" pid_start)"

  if [ -n "$rec_pid" ] && [ -n "$rec_start" ]; then
    # 生存判定は kill -0 を使わない（別ユーザー所有だと EPERM で失敗し、生きたロックを
    # 残骸と誤判定して横取りするため）。lstart が取得できる＝プロセス存在、で判定する。
    cur_start="$(pid_lstart "$rec_pid")"
    if [ -n "$cur_start" ]; then
      if [ "$cur_start" = "$rec_start" ]; then
        echo "cycle-lock: 並走検出（保持者 PID=$rec_pid が生存・開始時刻一致）→ 今周スキップ" >&2
        exit 2
      fi
      # 生存しているが開始時刻が不一致 → PID 再利用（別プロセス）→ 残骸として回収へ。
    fi
    # プロセス不在（lstart 取得不能）→ 残骸として回収へ。
  else
    # メタデータ不能（owner ファイルが無い・読めない）→ mtime が 2 時間超のときだけ残骸とみなす。
    now="$(date +%s)"
    mt="$(lock_mtime)"
    if [ $((now - mt)) -le 7200 ]; then
      echo "cycle-lock: 既存ロックの所有者を特定できず、更新から 2 時間以内のため並走とみなします → 今周スキップ" >&2
      exit 2
    fi
  fi

  # 残骸回収: abandoned 代筆 → ロック削除 → 原子的取得を 1 回だけ再試行。
  echo "cycle-lock: 残骸ロックを回収します: $LOCK" >&2
  maybe_close_abandoned
  rm -rf "$LOCK"
  if mkdir "$LOCK" 2>/dev/null; then
    if ! write_owner; then
      rm -rf "$LOCK"
      echo "cycle-lock: 所有者メタデータの書き込みに失敗したためロックを解除して中止します" >&2
      exit 2
    fi
    exit 0
  fi
  echo "cycle-lock: 残骸回収後の再取得に失敗（別サイクルが先に取得）→ 今周スキップ" >&2
  exit 2
}

do_release() {
  if [ ! -d "$LOCK" ]; then
    echo "cycle-lock: ロックが存在しないため解放は不要です: $LOCK" >&2
    exit 0
  fi
  rec_pid="$(meta_get "$OWNER_FILE" pid)"
  rec_sid="$(meta_get "$OWNER_FILE" session_id)"

  if [ -n "$SESSION_ID" ] && [ -n "$rec_sid" ] && [ "$SESSION_ID" = "$rec_sid" ]; then
    rm -rf "$LOCK"
    exit 0
  fi
  cur_pid="$(derive_owner_pid)"
  if [ -n "$rec_pid" ] && [ "$cur_pid" = "$rec_pid" ]; then
    rm -rf "$LOCK"
    exit 0
  fi
  echo "cycle-lock: 所有者不一致のため解放しません（記録 pid=${rec_pid:-?} session_id=${rec_sid:-（なし）} / 現在 pid=$cur_pid session_id=${SESSION_ID:-（なし）}）" >&2
  exit 3
}

case "$CMD" in
  acquire) do_acquire ;;
  release) do_release ;;
esac
