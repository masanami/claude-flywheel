#!/usr/bin/ruby
# frozen_string_literal: true

# reflect-backlog-check.rb — reflect（内省）が滞留しているかを機械的に判定する（読み取り専用）。
#
# run-cycle 手順0 が**ロック取得の後・取り込みの前**に呼び、滞留していれば一時停止して
# 「reflect を先に回す」か「見送ってこの周を続ける」かを人間に聞く（Issue #193）。
# 手順6 の reflect 実行推奨（`index.jsonl` の行数が N の倍数に達した周だけ出る）は、見逃すと
# 次の推奨が N 周後になり、滞留を知らせる経路が無かった。本判定は毎周、滞留そのものを見る。
#
# 使い方:
#   scripts/reflect-backlog-check.rb [--workspace <dir>]
#
#   --workspace   エージェント repo のルート（既定: `.`）。この直下の `memory/`・
#                 `journal/index.jsonl`・`.flywheel/cadence.json` を読む
#
# 滞留の定義（**どちらか**が成り立てば滞留）:
#   (a) 最後の reflect の後の周数が N 以上。N は `.flywheel/cadence.json` の
#       `reflect.every_n_cycles`（ファイル・フィールドが無い、または正の整数でない場合は既定 10。
#       run-cycle 手順6 の reflect 実行推奨と同じ補正）
#   (b) 未処理の experience のうち、`outcome: bad` かつ `recurrence` が 2 以上のものが 1 件以上ある
#
# 「最後の reflect」の読み方:
#   experience（`memory/<domain>/*.md` のうち frontmatter の `type: experience`）の
#   `reflected` の**最大日付**を、最後に reflect が走った日とみなす。reflect 手順5 は集計に使った
#   experience に**結果に関わらず** `reflected: <実行日>` を付けるため、reflect が 1 件でも処理した
#   回はこの最大日付に現れる。周数は `journal/index.jsonl` の非空行のうち、`date` がその日付より
#   **後**のものを数える（同じ日の周は reflect の前か後か区別できないため数えない＝滞留なし側）。
#   `reflected` の付いた experience が 1 件も無ければ、reflect は未実行として全行を数える。
#   限界: 未処理の experience が 0 件の状態で reflect を回しても日付が残らない（その場合も
#   (a) は前回の日付から数え続ける）。
#
# 「未処理」の判定は reflect スキルの「処理済みの判定」と同じ規則（**正本は
# skills/reflect/SKILL.md**。パターンの一致はテストが固定する）: `reflected` の値が
# REFLECTED_RE に完全一致し、かつ実在する日付のときだけ処理済み。それ以外（無い・空・語・
# プレースホルダ）は未処理。
#
# 終了コード（noop-check.rb / priority-policy-resolve.sh の 3 値規約に倣う）:
#   0 = 滞留なし（この周をそのまま続ける）
#   1 = 滞留あり（run-cycle は一時停止して人間に聞く。対話相手がいない起動と `--dry-run` は報告だけ）
#   2 = 判定不能（stderr に理由）。**呼び出し側は滞留なしとして扱い、周を止めない**
#       （起動自体の失敗＝exit 126/127 も同じ扱い。このとき stdout は空で `report=` が無い）
#   判定の片方が読めなくても、もう片方で滞留が確定すれば exit 1 を返す（滞留の事実を捨てない）。
#   滞留が確定せず、どちらかが読めなかったときだけ exit 2。
#
# stdout（exit 0/1/2 いずれでも出力する）:
#   backlog=yes|no|unknown         判定結果
#   every_n_cycles=<N>             適用した N
#   n_source=config|default        N の出どころ（default のときは補正した旨を report に含める）
#   last_reflected=<YYYY-MM-DD|none>   最後の reflect の日付（読めなかったときは出さない）
#   cycles_since_reflect=<n>       (a) の周数（読めなかったときは出さない）
#   recurring_bad=<n>              (b) の件数（読めなかったときは出さない）
#   recurring_bad_file=<path>      (b) に該当した experience（workspace からの相対。0 行以上）
#   report=<1行>                   サイクルレポートへ転記する文言（**常に出力**）

require "json"
require "date"

EXIT_OK = 0
EXIT_BACKLOG = 1
EXIT_UNCHECKABLE = 2

DEFAULT_EVERY_N = 10

# reflect スキルの「処理済みの判定」のパターン（skills/reflect/SKILL.md と同一の文字列）。
REFLECTED_RE = Regexp.new("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")

USAGE = "usage: #{$PROGRAM_NAME} [--workspace <dir>]"

def valid_date?(value)
  return false unless REFLECTED_RE.match?(value)
  y, m, d = value.split("-").map(&:to_i)
  Date.valid_date?(y, m, d)
end

# frontmatter（先頭の `---` から次の `---` まで）から `key:` の値を 1 行だけ取り出す。
# 引用符と行末コメントを外す。キーが無ければ nil。
def fm_value(frontmatter, key)
  raw = frontmatter[/^[ \t]*#{Regexp.escape(key)}:[ \t]*(.*)$/, 1]
  return nil if raw.nil?
  v = raw.sub(/[ \t]+#.*\z/, "").strip
  v = v[1..-2] if v.length >= 2 && ((v.start_with?('"') && v.end_with?('"')) || (v.start_with?("'") && v.end_with?("'")))
  v
end

def read_cadence(ws)
  path = File.join(ws, ".flywheel/cadence.json")
  return [DEFAULT_EVERY_N, "default"] unless File.file?(path)
  data = JSON.parse(File.read(path, encoding: "UTF-8"))
  n = data.is_a?(Hash) && data["reflect"].is_a?(Hash) ? data["reflect"]["every_n_cycles"] : nil
  return [n, "config"] if n.is_a?(Integer) && n.positive?
  [DEFAULT_EVERY_N, "default"]
rescue JSON::ParserError, SystemCallError, ArgumentError, EncodingError
  [DEFAULT_EVERY_N, "default"]
end

# experience を走査する。戻り値: [最大の reflected 日付 or nil, (b) に該当したパス一覧, 読めなかった理由 or nil]
def scan_experiences(ws)
  mem = File.join(ws, "memory")
  return [nil, nil, "memory/ が無い"] unless File.directory?(mem)
  last = nil
  hits = []
  Dir.glob(File.join(mem, "*", "*.md")).sort.each do |path|
    src = File.read(path, encoding: "UTF-8")
    return [nil, nil, "#{path.delete_prefix("#{ws}/")} が UTF-8 として読めない"] unless src.valid_encoding?
    fm = src[/\A---[ \t]*\n(.*?)^---[ \t]*$/m, 1]
    next if fm.nil?
    next unless fm_value(fm, "type") == "experience"
    reflected = fm_value(fm, "reflected")
    if reflected && valid_date?(reflected)
      last = reflected if last.nil? || reflected > last
      next
    end
    next unless fm_value(fm, "outcome") == "bad"
    rec = fm_value(fm, "recurrence")
    hits << path.delete_prefix("#{ws}/") if rec&.match?(/\A[0-9]+\z/) && rec.to_i >= 2
  end
  [last, hits, nil]
rescue SystemCallError => e
  [nil, nil, "memory/ を読めない（#{e.message}）"]
end

# `journal/index.jsonl` の非空行のうち、date が last より後のものを数える。戻り値: [周数 or nil, 理由 or nil]
def count_cycles_since(ws, last)
  path = File.join(ws, "journal/index.jsonl")
  return [0, nil] unless File.exist?(path)
  src = File.read(path, encoding: "UTF-8")
  return [nil, "journal/index.jsonl が UTF-8 として読めない"] unless src.valid_encoding?
  count = 0
  src.each_line.with_index(1) do |line, no|
    next if line.strip.empty?
    rec = JSON.parse(line)
    date = rec.is_a?(Hash) ? rec["date"] : nil
    return [nil, "journal/index.jsonl の #{no} 行目の date が日付として読めない"] unless date.is_a?(String) && valid_date?(date)
    count += 1 if last.nil? || date > last
  end
  [count, nil]
rescue JSON::ParserError => e
  [nil, "journal/index.jsonl に JSON として読めない行がある（#{e.message.lines.first.to_s.strip}）"]
rescue SystemCallError => e
  [nil, "journal/index.jsonl を読めない（#{e.message}）"]
end

def main(argv)
  ws = "."
  until argv.empty?
    arg = argv.shift
    case arg
    when "--workspace"
      ws = argv.shift
      if ws.nil? || ws.empty?
        warn "--workspace に値が無い"
        warn USAGE
        puts "backlog=unknown"
        puts "report=reflect の滞留を判定できなかった（引数エラー）。滞留なしとして周を続ける"
        return EXIT_UNCHECKABLE
      end
    else
      warn "不明な引数: #{arg}"
      warn USAGE
      puts "backlog=unknown"
      puts "report=reflect の滞留を判定できなかった（引数エラー）。滞留なしとして周を続ける"
      return EXIT_UNCHECKABLE
    end
  end
  ws = ws.chomp("/") unless ws == "/"

  n, n_source = read_cadence(ws)
  last, hits, mem_err = scan_experiences(ws)
  since, idx_err = mem_err ? [nil, nil] : count_cycles_since(ws, last)

  a = since.nil? ? nil : since >= n
  b = hits.nil? ? nil : !hits.empty?
  errors = [mem_err, idx_err].compact

  backlog = if a || b then "yes" elsif a.nil? || b.nil? then "unknown" else "no" end

  puts "backlog=#{backlog}"
  puts "every_n_cycles=#{n}"
  puts "n_source=#{n_source}"
  puts "last_reflected=#{last || "none"}" unless mem_err
  puts "cycles_since_reflect=#{since}" unless since.nil?
  unless hits.nil?
    puts "recurring_bad=#{hits.size}"
    hits.each { |h| puts "recurring_bad_file=#{h}" }
  end

  parts = []
  if a
    parts << (last ? "最後の reflect（#{last}）の後 #{since} 周（しきい値 #{n}）" : "reflect の実行記録が無いまま #{since} 周（しきい値 #{n}）")
  end
  parts << "未処理の再発 bad（recurrence 2 以上）が #{hits.size} 件" if b
  note = n_source == "default" ? "（reflect.every_n_cycles が無い・不正のため既定 #{DEFAULT_EVERY_N} を使用）" : ""

  case backlog
  when "yes"
    unread = errors.empty? ? "" : "。一部は判定できなかった: #{errors.join("、")}"
    puts "report=reflect が滞留している: #{parts.join("、")}#{note}#{unread}"
    EXIT_BACKLOG
  when "no"
    since_text = last ? "最後の reflect（#{last}）の後 #{since} 周" : "reflect の実行記録なし・#{since} 周"
    puts "report=reflect の滞留なし（#{since_text}・しきい値 #{n}、未処理の再発 bad 0 件）#{note}"
    EXIT_OK
  else
    errors.each { |e| warn e }
    puts "report=reflect の滞留を判定できなかった（#{errors.join("、")}）。滞留なしとして周を続ける#{note}"
    EXIT_UNCHECKABLE
  end
end

begin
  exit main(ARGV.dup)
rescue StandardError => e
  warn "予期しないエラー: #{e.class}: #{e.message}"
  puts "backlog=unknown"
  puts "report=reflect の滞留を判定できなかった（予期しないエラー: #{e.class}）。滞留なしとして周を続ける"
  exit EXIT_UNCHECKABLE
end
