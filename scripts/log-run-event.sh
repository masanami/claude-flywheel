#!/usr/bin/env bash
#
# log-run-event.sh — 実行イベントログ（.flywheel/runs.jsonl）へ 1 イベントを append する。
#
# run-cycle / 差し込み作業の親セッションが呼ぶ「書き込みの参照実装」。判断はせず機械的に
# 書くだけ。スキーマの正本は利用先ワークスペースの runtime/README.md「実行イベントログ
# （runs.jsonl）」セクション（本スクリプトと食い違う場合はそちらが正）。
#
# 使い方:
#   scripts/log-run-event.sh <event> [--cycle <name>] [--challenge <id>] [--repo <name>]
#                            [--session-id <uuid>] [--result <text>] [--id <adhoc-id>]
#                            [--title <text>] [--dry-run] [--workspace <dir>]
#
#   event        cycle_start | cycle_end | delegate_start | delegate_end | adhoc_start | adhoc_end
#   --cycle      当周の journal ファイル名 basename（cycle_* 用）
#   --challenge  課題 ID（C-xxx。delegate_* 用）
#   --repo       repos.tsv の <name>
#   --session-id 事前採番した子セッションの UUID（delegate_* 用）
#   --result     結果 1 行（*_end 用。JSON エスケープはスクリプトが行う）
#   --id         adhoc_start / adhoc_end の対応付けキー
#   --title      差し込み作業の 1 行タイトル（adhoc_start 用）
#   --dry-run    何も書かず exit 0（journal と同じパリティ。dry-run は状態を変えないため）
#   --workspace  ワークスペースのルート（既定: .）。<workspace>/.flywheel/runs.jsonl に書く
#
# 注意:
#   - ts は自動付与する（ISO 8601・タイムゾーンオフセットはコロン付き +09:00 形式）。
#   - 1 イベント＝1 行の JSON を単一の printf で append する（並行 append でも実用上
#     行が交錯しないため。append 前に mkdir -p .flywheel を行う）。
#   - best-effort: 常に exit 0。不正なイベント名・引数エラー・書き込み失敗は stderr に
#     警告し、書かずに正常終了する（観測が制御を阻害しないため）。
#   - 秘密情報のチェックはしない（書き手の規律。本スクリプトは内容を解釈しない機械）。

set -euo pipefail

USAGE="usage: $0 <event> [--cycle <name>] [--challenge <id>] [--repo <name>] [--session-id <uuid>] [--result <text>] [--id <adhoc-id>] [--title <text>] [--dry-run] [--workspace <dir>]"

# 警告を stderr へ出す（best-effort 契約のため、警告してもスクリプトは exit 0 で終える）。
warn() {
  echo "log-run-event: $1" >&2
}

# 値を JSON 文字列として安全にする（バックスラッシュ→\\、二重引用符→\"、
# 制御文字・改行→スペース）。自由テキスト（--result / --title）向けだが全フィールドに適用する。
json_escape() {
  s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  # 制御文字（改行含む）はスペースへ潰す（1 イベント＝1 行の不変条件を守るため）。
  # tr の八進レンジは GNU/BSD 双方で動く。末尾の改行もスペースになるため
  # コマンド置換で失われない。
  s="$(printf '%s' "$s" | tr '\000-\037\177' ' ')"
  printf '%s' "$s"
}

if [ "$#" -ge 1 ]; then
  case "$1" in
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
  esac
fi

if [ "$#" -lt 1 ]; then
  warn "$USAGE"
  warn "イベント名がありません。書かずに終了します（best-effort）"
  exit 0
fi

EVENT="$1"
shift

case "$EVENT" in
  cycle_start|cycle_end|delegate_start|delegate_end|adhoc_start|adhoc_end) ;;
  *)
    warn "不正なイベント名: ${EVENT}（cycle_start | cycle_end | delegate_start | delegate_end | adhoc_start | adhoc_end のいずれか）。書かずに終了します（best-effort）"
    exit 0
    ;;
esac

CYCLE=""
CHALLENGE=""
REPO=""
SESSION_ID=""
RESULT=""
ADHOC_ID=""
TITLE=""
DRY_RUN=0
WORKSPACE="."

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      continue
      ;;
    --cycle|--challenge|--repo|--session-id|--result|--id|--title|--workspace)
      if [ "$#" -lt 2 ]; then
        warn "オプションに値がありません: ${1}。書かずに終了します（best-effort）"
        exit 0
      fi
      case "$2" in
        --*)
          warn "オプションに値がありません（次の引数もフラグ）: ${1} ${2}。書かずに終了します（best-effort）"
          exit 0
          ;;
      esac
      ;;
    *)
      warn "不明な引数: ${1}。書かずに終了します（best-effort）"
      warn "$USAGE"
      exit 0
      ;;
  esac
  case "$1" in
    --cycle)      CYCLE="$2" ;;
    --challenge)  CHALLENGE="$2" ;;
    --repo)       REPO="$2" ;;
    --session-id) SESSION_ID="$2" ;;
    --result)     RESULT="$2" ;;
    --id)         ADHOC_ID="$2" ;;
    --title)      TITLE="$2" ;;
    --workspace)  WORKSPACE="$2" ;;
  esac
  shift 2
done

# 空の --workspace は出力先が /.flywheel（ルート直下）に化けるため拒否する。
if [ -z "$WORKSPACE" ]; then
  warn "--workspace が空です。書かずに終了します（best-effort）"
  exit 0
fi

# イベント別の必須フィールド検証（仕様の正本 templates/runtime/README.md のフィールド表に従う）。
# 欠落したまま書くと消費者（観測プレーン）が対応付けできないため、警告して書かずに終了する。
require_nonempty() {
  if [ -z "$1" ]; then
    warn "必須オプションがありません: ${2}（event=${EVENT}）。書かずに終了します（best-effort）"
    exit 0
  fi
}

case "$EVENT" in
  cycle_start)
    require_nonempty "$CYCLE" "--cycle" ;;
  cycle_end)
    require_nonempty "$CYCLE" "--cycle"
    require_nonempty "$RESULT" "--result" ;;
  delegate_start)
    require_nonempty "$CHALLENGE" "--challenge"
    require_nonempty "$REPO" "--repo"
    require_nonempty "$SESSION_ID" "--session-id" ;;
  delegate_end)
    require_nonempty "$CHALLENGE" "--challenge"
    require_nonempty "$REPO" "--repo"
    require_nonempty "$SESSION_ID" "--session-id"
    require_nonempty "$RESULT" "--result" ;;
  adhoc_start)
    require_nonempty "$ADHOC_ID" "--id"
    require_nonempty "$TITLE" "--title" ;;
  adhoc_end)
    require_nonempty "$ADHOC_ID" "--id"
    require_nonempty "$RESULT" "--result" ;;
esac

# ts の自動付与。date +%z は +0900 形式を返すため、末尾 2 桁の前にコロンを挿入して
# +09:00 形式（ISO 8601）へ変換する（GNU/BSD 双方で動く %z のみ使用）。
if ! ts_raw="$(date +%Y-%m-%dT%H:%M:%S%z)"; then
  warn "日時の取得に失敗しました。書かずに終了します（best-effort）"
  exit 0
fi
TS="${ts_raw%??}:${ts_raw#"${ts_raw%??}"}"

# 1 行 JSON を組み立てる。フィールド順は ts, event, cycle, challenge, repo,
# session_id, id, title, result（与えられたものだけ出力する）。
json="{\"ts\":\"$(json_escape "$TS")\",\"event\":\"$(json_escape "$EVENT")\""
if [ -n "$CYCLE" ]; then      json="${json},\"cycle\":\"$(json_escape "$CYCLE")\""; fi
if [ -n "$CHALLENGE" ]; then  json="${json},\"challenge\":\"$(json_escape "$CHALLENGE")\""; fi
if [ -n "$REPO" ]; then       json="${json},\"repo\":\"$(json_escape "$REPO")\""; fi
if [ -n "$SESSION_ID" ]; then json="${json},\"session_id\":\"$(json_escape "$SESSION_ID")\""; fi
if [ -n "$ADHOC_ID" ]; then   json="${json},\"id\":\"$(json_escape "$ADHOC_ID")\""; fi
if [ -n "$TITLE" ]; then      json="${json},\"title\":\"$(json_escape "$TITLE")\""; fi
if [ -n "$RESULT" ]; then     json="${json},\"result\":\"$(json_escape "$RESULT")\""; fi
json="${json}}"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "log-run-event: dry-run（書き込みなし）: $json"
  exit 0
fi

# append 前にディレクトリを確保し、1 行を単一の printf で append する。
# 失敗しても警告のみで exit 0（best-effort。set -e を壊さないよう条件文の中で評価する）。
outdir="$WORKSPACE/.flywheel"
if ! mkdir -p "$outdir" 2>/dev/null; then
  warn "ディレクトリを作成できません: ${outdir}。書かずに終了します（best-effort）"
  exit 0
fi
if ! printf '%s\n' "$json" >> "$outdir/runs.jsonl" 2>/dev/null; then
  warn "append に失敗しました: $outdir/runs.jsonl（best-effort につき正常終了します）"
  exit 0
fi

exit 0
