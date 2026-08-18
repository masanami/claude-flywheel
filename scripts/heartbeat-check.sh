#!/usr/bin/env bash
#
# heartbeat-check.sh — 拍動停止（run-cycle の空白期間）の検知（読み取り専用）。
#
# runs.jsonl の最終 `cycle_end` からの経過を**営業日ベース**で算出し、しきい値を超えて
# いれば「拍動停止の疑い」として警告し、あわせて未終了の `*_start`（対応する `*_end` の
# 無い delegate_start / adhoc_start）の件数・該当行を列挙する（Issue #83 の最小緩和。
# 「検算の仕組みはあるが、拍動が無いと働かない」構造への警報として、run-cycle 手順0 /
# start-day 経由の初回 run-cycle が呼ぶ）。runs.jsonl のスキーマの正本は利用先ワーク
# スペースの runtime/README.md「実行イベントログ（runs.jsonl）」セクション。本スクリプトは
# 書き込みを一切行わない。
#
# 使い方:
#   scripts/heartbeat-check.sh [--workspace <dir>] [--business-days <cron曜日式>]
#                              [--stale-after-business-days <N>] [--now <ISO8601>]
#
#   --workspace                 ワークスペースのルート（既定: .）。
#                               <workspace>/.flywheel/runs.jsonl を読む
#   --business-days             営業日の cron 曜日式（既定: 1-5＝月〜金。`0`/`7`＝日曜、
#                               `6`＝土曜。cadence.json の `business_days` を呼び出し側が渡す）
#   --stale-after-business-days 警告しきい値（既定: 1）。最終 cycle_end の日付と本日の
#                               **間に挟まる営業日**（両端の日付は含まない）が N 日以上なら
#                               「拍動停止の疑い」とする（cadence.json の
#                               `heartbeat.stale_after_business_days` を呼び出し側が渡す）
#   --now                       「現在時刻」の注入（ISO 8601。テスト・検証用。省略時は実時刻）
#
# 判定の意味論:
#   - 拍動 = `cycle_end` イベント（`result` が completed / abandoned いずれでも 1 拍と数える。
#     abandoned の代筆は生きているサイクルのロック回収時に行われるため、直後に本物の
#     cycle_end が続く）。
#   - 「営業日 1 日の空白」= 最終 cycle_end の日付と本日の間に、cycle_end の無い営業日が
#     丸 1 日挟まった状態。金曜終業→月曜朝の再開は挟まる営業日が 0 のため警告しない
#     （固定時間しきい値だと週明けに毎回誤警報になるのを避ける。Issue #83 の
#     「業務日ベースで1日以上」に対応）。同日内の停滞（朝から夕方まで無拍動等）は
#     検知対象外（意図した制限。対話割り込みによる発火遅延は正常動作のため）。
#
# 終了コード（cycle-lock.sh の複数終了コード規約に倣う）:
#   - 0 = 空白なし（何も出力しない）
#   - 1 = 拍動停止の疑い（stdout に警告レポート＝最終 cycle_end・経過・未終了 *_start）
#   - 2 = 検査不能（runs.jsonl 不在・読み取り不可・`cycle_end` 未記録・ts 解析不能・
#         引数/環境エラー。stderr に理由）。**検査不能を「空白なし・正常」と読み替えない**
#         のが本スクリプトの要（runs.jsonl 不在は初回サイクルなら正常だが、--workspace の
#         指定ミスと区別できないため exit 0 にはしない。log-run-event.sh check の
#         「不在 = exit 0＋警告」より安全側に倒す＝本スクリプトの目的が「止まっていること
#         に気づく」ことそのものであるため）
#
# 注意:
#   - 判定は警告のみ（サイクルを止めない・runs.jsonl に書かない）。未終了 delegate_start の
#     回収は run-cycle 手順6 の既存の検算・事後補記が担う。
#   - 未終了 *_start の列挙は同ディレクトリの log-run-event.sh check に委譲する（ペアリング
#     意味論の実装を一本化するため。無ければ「検算不能」と出力し、警告自体は継続する）。

set -euo pipefail

USAGE="usage: $0 [--workspace <dir>] [--business-days <cron曜日式>] [--stale-after-business-days <N>] [--now <ISO8601>]"

warn() {
  echo "heartbeat-check: $1" >&2
}

# JSON 1 行 ($1) から "<field>":"<value>" の値を抜き出す（log-run-event.sh の同名関数と
# 同じ実装・同じ前提＝log-run-event.sh 自身が書く平坦フィールドが対象）。結果はグローバル
# 変数 FIELD_VALUE へ（行ごとのサブシェル fork を避ける）。
extract_field() {
  needle="\"$2\":\""
  rest="${1#*"$needle"}"
  if [ "$rest" = "$1" ]; then
    FIELD_VALUE=""
    return
  fi
  FIELD_VALUE="${rest%%\"*}"
}

# ---- 日時ユーティリティ（GNU date / BSD date の方言を吸収する）----

DATE_FLAVOR=""
detect_date_flavor() {
  if date -u -d @0 +%s >/dev/null 2>&1; then
    DATE_FLAVOR=gnu
  elif date -u -r 0 +%s >/dev/null 2>&1; then
    DATE_FLAVOR=bsd
  else
    warn "date コマンドの方言（GNU/BSD）を判別できません"
    exit 2
  fi
}

# ISO 8601（例: 2026-08-06T15:53:00+09:00 / +0900 / Z）→ epoch 秒。失敗時は非 0。
epoch_from_iso() {
  ts="$1"
  norm="$ts"
  # 末尾 Z は +0000 へ、オフセットのコロン（+09:00）は除去（BSD の %z は +0900 形式のため）
  case "$norm" in
    *Z) norm="${norm%Z}+0000" ;;
    *[+-][0-9][0-9]:[0-9][0-9]) norm="${norm%:*}${norm##*:}" ;;
  esac
  if [ "$DATE_FLAVOR" = "gnu" ]; then
    date -d "$norm" +%s 2>/dev/null
  else
    date -j -f "%Y-%m-%dT%H:%M:%S%z" "$norm" +%s 2>/dev/null
  fi
}

# epoch 秒 → 指定フォーマット（ローカルタイム）。
fmt_epoch() {
  if [ "$DATE_FLAVOR" = "gnu" ]; then
    date -d "@$1" "+$2"
  else
    date -r "$1" "+$2"
  fi
}

# ローカル日付（YYYY-MM-DD）の正午の epoch 秒（DST 跨ぎでも 86400 秒刻みで日付が
# 飛ばないようにするためのアンカー）。失敗時は非 0。
noon_epoch_of_date() {
  if [ "$DATE_FLAVOR" = "gnu" ]; then
    date -d "$1 12:00" +%s 2>/dev/null
  else
    date -j -f "%Y-%m-%d %H:%M" "$1 12:00" +%s 2>/dev/null
  fi
}

# ---- 営業日（cron 曜日式）----

# cron 曜日式（例: 1-5 / 0,6 / 1,3-5 / *。0 と 7 は日曜）を曜日番号の集合
# （BUSINESS_SET: 0-6 の数字列）へ展開する。不正な式は非 0 を返す。
expand_business_days() {
  spec="$1"
  BUSINESS_SET=""
  if [ "$spec" = "*" ]; then
    BUSINESS_SET="0123456"
    return 0
  fi
  case "$spec" in
    ''|*[!0-9,-]*) return 1 ;;
  esac
  local part a b d
  IFS=',' read -r -a _parts <<<"$spec"
  [ "${#_parts[@]}" -eq 0 ] && return 1
  for part in "${_parts[@]}"; do
    case "$part" in
      [0-7])
        a="$part"; b="$part" ;;
      [0-7]-[0-7])
        a="${part%-*}"; b="${part#*-}"
        [ "$a" -le "$b" ] || return 1 ;;
      *)
        return 1 ;;
    esac
    for ((d = a; d <= b; d++)); do
      w=$((d % 7))
      case "$BUSINESS_SET" in
        *"$w"*) ;;
        *) BUSINESS_SET="${BUSINESS_SET}${w}" ;;
      esac
    done
  done
  return 0
}

# ---- 引数解析 ----

WORKSPACE="."
BUSINESS_DAYS="1-5"
STALE_AFTER=1
NOW_ISO=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      echo "$USAGE"
      exit 0
      ;;
    --workspace|--business-days|--stale-after-business-days|--now)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        warn "オプションに値がありません: $1"
        echo "$USAGE" >&2
        exit 2
      fi
      case "$2" in
        --*)
          warn "オプションに値がありません（次の引数もフラグ）: $1 $2"
          echo "$USAGE" >&2
          exit 2
          ;;
      esac
      case "$1" in
        --workspace)                 WORKSPACE="$2" ;;
        --business-days)             BUSINESS_DAYS="$2" ;;
        --stale-after-business-days) STALE_AFTER="$2" ;;
        --now)                       NOW_ISO="$2" ;;
      esac
      shift 2
      ;;
    *)
      warn "不明な引数: $1"
      echo "$USAGE" >&2
      exit 2
      ;;
  esac
done

case "$STALE_AFTER" in
  ''|*[!0-9]*|0)
    warn "--stale-after-business-days は正の整数を指定してください: $STALE_AFTER"
    exit 2
    ;;
esac

if ! expand_business_days "$BUSINESS_DAYS"; then
  warn "--business-days が有効な cron 曜日式ではありません: $BUSINESS_DAYS"
  exit 2
fi

detect_date_flavor

# ---- ワークスペース・runs.jsonl の検査（log-run-event.sh check と同じ fail-closed 規律）----

if [ ! -d "$WORKSPACE" ]; then
  warn "workspace ディレクトリが存在しません: $WORKSPACE"
  exit 2
fi
if [ ! -x "$WORKSPACE" ]; then
  warn "workspace ディレクトリを走査できません（権限不足の可能性）: $WORKSPACE"
  exit 2
fi

flywheel_dir="$WORKSPACE/.flywheel"
if [ -d "$flywheel_dir" ] && [ ! -x "$flywheel_dir" ]; then
  warn ".flywheel ディレクトリを走査できません（権限不足の可能性）: $flywheel_dir"
  exit 2
fi

file="$flywheel_dir/runs.jsonl"
if [ ! -e "$file" ]; then
  # 初回サイクルなら正常な状態だが、--workspace の指定ミスと区別できず経過時間も
  # 算出できない。「検査不能」であり「空白なし」ではないため exit 0 にしない。
  warn "runs.jsonl が見つかりません（初回サイクルなら正常。--workspace の指定に誤りがないか確認）: $file"
  warn "経過時間は検査不能です（「空白なし・正常」とは扱わないこと）"
  exit 2
fi
if [ ! -r "$file" ]; then
  warn "runs.jsonl を読み取れません（権限不足の可能性）: $file"
  exit 2
fi

# ---- 最終 cycle_end の探索 ----

last_ts=""
while IFS= read -r line || [ -n "$line" ]; do
  [ -z "$line" ] && continue
  extract_field "$line" "event"
  if [ "$FIELD_VALUE" = "cycle_end" ]; then
    extract_field "$line" "ts"
    [ -n "$FIELD_VALUE" ] && last_ts="$FIELD_VALUE"
  fi
done < "$file"

if [ -z "$last_ts" ]; then
  warn "runs.jsonl に cycle_end が見つかりません（初回サイクル完了前なら正常）: $file"
  warn "経過時間は検査不能です（「空白なし・正常」とは扱わないこと）"
  exit 2
fi

if ! last_epoch="$(epoch_from_iso "$last_ts")"; then
  warn "最終 cycle_end の ts を解析できません: $last_ts"
  exit 2
fi

if [ -n "$NOW_ISO" ]; then
  if ! now_epoch="$(epoch_from_iso "$NOW_ISO")"; then
    warn "--now を解析できません: $NOW_ISO"
    exit 2
  fi
else
  now_epoch="$(date +%s)"
fi

# 最終 cycle_end が未来時刻の場合は検査不能とする（ホスト時計の補正後・壊れたイベント等。
# そのまま進めると gap_days=0 → exit 0〔空白なし〕にフォールスルーし、拍動喪失が記録日時に
# 追いつくまでマスクされる＝「検査不能≠0件」の規律違反になるため fail-closed に倒す）。
if [ "$last_epoch" -gt "$now_epoch" ]; then
  warn "最終 cycle_end の ts が現在時刻より未来です（時計補正・壊れたイベントの可能性）: ${last_ts}"
  warn "経過時間は検査不能です（「空白なし・正常」とは扱わないこと）"
  exit 2
fi

# ---- 空白営業日の算出（最終 cycle_end の日付と本日の間・両端の日付は含まない）----

last_date="$(fmt_epoch "$last_epoch" %F)"
now_date="$(fmt_epoch "$now_epoch" %F)"

gap_days=0
if [[ "$last_date" < "$now_date" ]]; then
  if ! d_epoch="$(noon_epoch_of_date "$last_date")"; then
    warn "日付の解析に失敗しました: $last_date"
    exit 2
  fi
  guard=0
  while :; do
    d_epoch=$((d_epoch + 86400))
    guard=$((guard + 1))
    if [ "$guard" -gt 40000 ]; then
      warn "空白期間の走査が上限を超えました（ts が異常な過去の可能性）: $last_ts"
      exit 2
    fi
    d_date="$(fmt_epoch "$d_epoch" %F)"
    [[ "$d_date" < "$now_date" ]] || break
    w="$(fmt_epoch "$d_epoch" %w)"
    case "$BUSINESS_SET" in
      *"$w"*) gap_days=$((gap_days + 1)) ;;
    esac
  done
fi

if [ "$gap_days" -lt "$STALE_AFTER" ]; then
  exit 0
fi

# ---- 警告レポート（stdout）----

elapsed=$((now_epoch - last_epoch))
cal_days=$((elapsed / 86400))
cal_hours=$(((elapsed % 86400) / 3600))

# 変数は必ず ${var} のブレース形式で全角文字と隣接させる（macOS 標準の bash 3.2 は
# マルチバイト文字直前の $var 形式の展開で変数名の解釈を誤り unbound variable になるため）。
echo "heartbeat-check: 拍動停止の疑い: 最終 cycle_end（${last_ts}）から、間に営業日 ${gap_days} 日の空白（暦日換算 ${cal_days} 日 ${cal_hours} 時間経過。しきい値: 営業日 ${STALE_AFTER} 日）"

logger="$(dirname "$0")/log-run-event.sh"
if [ -f "$logger" ]; then
  check_status=0
  check_out="$(bash "$logger" check --workspace "$WORKSPACE" 2>/dev/null)" || check_status=$?
  case "$check_status" in
    0)
      echo "heartbeat-check: 未終了の *_start: 0 件"
      ;;
    1)
      open_count="$(printf '%s\n' "$check_out" | grep -c .)"
      echo "heartbeat-check: 未終了の *_start: ${open_count} 件（空白期間中に放置された委譲・差し込みの可能性）"
      printf '%s\n' "$check_out"
      ;;
    *)
      echo "heartbeat-check: 未終了の *_start は検算不能でした（log-run-event.sh check が exit ${check_status}）"
      ;;
  esac
else
  echo "heartbeat-check: 未終了の *_start は検算不能でした（log-run-event.sh が見つかりません: ${logger}）"
fi

exit 1
