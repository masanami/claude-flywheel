#!/usr/bin/env ruby
# frozen_string_literal: true
#
# ledger-index.rb — 課題台帳（challenge-ledger.md）から**索引を投影**して stdout に出す。
#
# run-cycle 手順0 が呼ぶ。手順0 は台帳を全文ロードせず、まず本スクリプトの出力（索引）だけを
# 読み、各手順は `contracts/ledger-read-scope.tsv` の経路表が指す範囲だけを追加で開く
# （docs/ledger-load-strategy.md §7 の採否「案 2」）。
#
# 使い方:
#   scripts/ledger-index.rb <challenge-ledger.md>
#   scripts/ledger-index.rb --list-columns | --list-exits
#
#   --list-columns  出力する列名を 1 行 1 件で出力して終了（exit 0）。
#   --list-exits    本スクリプト自身が返す終了コードの**宣言**（0 / 2）。
#                   いずれもテストが「宣言」と「振る舞い」の一致を双方向で固定するために使う。
#                   126/127 は含めない（シェルが返す「起動できなかった」の値であり、
#                   このとき stdout は空＝索引を取得できない）。
#
# **ファイルを作らない（本スクリプトの要）**:
#   索引は台帳から**毎回投影する**射影であって、第二の正本ではない。索引をファイルとして
#   持つと「索引と本体を同期させる」構図になり、必ずずれる（sync-free 不変条件）。
#   本スクリプトは読み取り専用で、書き込み先は stdout だけ。したがって
#   `contracts/cycle-commit-paths.txt` に足すパスも無く、`noop-check.rb` の判定に
#   新しい dirty パスも現れない。
#
# 出力（TSV・10 列・1 行目はヘッダ）:
#   id         課題 ID（見出し `### [<id>] <title>` の `<id>`）
#   status     ステータス（`（未分類 → …）` のような遷移説明は落とす）
#   prio       優先度（P0 / P1 / P2）
#   pos        担当ポジション
#   svc        関連サービス          … domain-bootstrap モードの着手順判定に要る
#   opened     起票日                … normal モードの「同一優先度内は起票日順」に要る
#   repos      関連リポジトリ        … improvement-first の「同一リポジトリは 1 委譲に束ねる」
#   approvals  承認チェック 2 個の状態を `x` / `-` の 2 文字で（計画→完了の順・1-f の承認検出）
#   ingested   取り込み元マーカーの**有無**だけを `y` / `-` で（2-d。値そのものは載せない）
#   title      見出しのタイトル
#
#   説明・完了条件・備考・タスク案は**載せない**。索引に載せた時点で「索引である」という
#   前提が失われる（テスト T5 が否定検査で固定する）。判定基準は**フィールドの役割**であって
#   長さではない: 説明は #130 の要約化で新規エントリぶんは短くなるが、既存エントリと
#   アーカイブには原文引用（実測で 1 件 1,179〜4,856 文字）が残り続けるうえ、**要約でも
#   「索引から本体を引く」という構図は変わらない**。長さを根拠にすると、短くなった時点で
#   載せてよいことになり射影が本体化する。
#   エントリ 0 件でもヘッダ行は出す（呼び出し側の解析を一様にするため）。
#
# 終了コード（heartbeat-check.sh / noop-check.rb / priority-policy-resolve.sh の 3 値規約に倣う。
# ただし本スクリプトに「違反」の概念は無いため 1 は使わない）:
#   0 = 投影した（エントリ 0 件でも 0）
#   2 = 検査不能（引数不正・対象不在・読み取り不可・UTF-8 として解釈不能）。stderr に理由。
#       **呼び出し側は台帳を読めなかったものとして扱う**（空の索引を「課題 0 件」と読み替えない）。
#
# **エントリ境界と除外は validate-artifact.rb と同じ意味論**（2 箇所で違う切り方をすると、
# バリデータが受理する台帳を索引が取りこぼす）:
#   - エントリ境界は `^### \[` にマッチする行（行番号のオフセットでは切らない）
#   - ``` フェンス内の行は除外（台帳先頭の「記入例」はここで落ちる）
#   - 複数行 HTML コメントは除外。同一行で開閉するインラインコメント
#     （取り込み元マーカーの `<!-- fp:... -->` 等）は行ごと対象のまま

COLUMNS = %w[id status prio pos svc opened repos approvals ingested title].freeze
EXITS = [0, 2].freeze

PROGRAM = File.basename($PROGRAM_NAME)
USAGE = "usage: #{PROGRAM} <challenge-ledger.md>\n       #{PROGRAM} --list-columns | --list-exits"

def uncheckable(msg)
  warn "#{PROGRAM}: #{msg}"
  exit 2
end

# --- 引数 -------------------------------------------------------------------
file = nil
ARGV.each do |a|
  case a
  when "--list-columns" then puts COLUMNS; exit 0
  when "--list-exits"   then puts EXITS;   exit 0
  when /\A--/           then uncheckable("不明なオプション: #{a}\n#{USAGE}")
  else
    uncheckable("対象ファイルを 2 つ以上指定しています: #{file} / #{a}\n#{USAGE}") if file
    file = a
  end
end
uncheckable("対象ファイルが指定されていません\n#{USAGE}") if file.nil?
uncheckable("対象が存在しません: #{file}") unless File.exist?(file)
uncheckable("対象がファイルではありません: #{file}") unless File.file?(file)
uncheckable("読み取れません: #{file}") unless File.readable?(file)

begin
  content = File.read(file, encoding: "UTF-8")
rescue SystemCallError => e
  uncheckable("読み取りに失敗しました: #{file}（#{e.message}）")
end
uncheckable("UTF-8 として解釈できません: #{file}") unless content.valid_encoding?

lines = content.split("\n", -1)
lines.pop if lines.last == "" # 末尾改行によるダミー要素を除く

# --- フェンス・HTML コメントの除外（validate-artifact.rb の annotate_exclusions と同一）---
def annotate_exclusions(lines)
  in_fence = false
  in_comment = false
  lines.map do |line|
    included = true
    if in_comment
      included = false
      in_comment = false if line.include?("-->")
    elsif line =~ /^```/
      in_fence = !in_fence
      included = false
    elsif in_fence
      included = false
    else
      opens = line.rindex("<!--")
      in_comment = true if opens && !line.index("-->", opens)
      included = false if line.strip.start_with?("<!--") && in_comment
    end
    [line, included]
  end
end

# --- エントリへ分割（見出し `^### \[` で切る）-------------------------------
entries = [] # [id, title, body_lines]
annotate_exclusions(lines).each do |text, included|
  next unless included
  if (m = /\A### \[([^\]]*)\] *(.*)\z/.match(text))
    entries << [m[1].strip, m[2].strip, []]
  elsif !entries.empty?
    entries.last[2] << text
  end
  # 最初の見出しより前（前文）は捨てる。索引はエントリの射影であり前文は対象外。
end

# --- 値の取り出し -----------------------------------------------------------
# TSV の列がずれないよう、値からタブ・制御文字を除き前後空白を落とす。
# 値そのものを削るのではなく「1 行 1 セルへ正規化する」ための最小限の処理。
def cell(value)
  value.to_s.gsub(/[\t\r\n]/, " ").gsub(/[[:cntrl:]]/, "").strip.squeeze(" ")
end

# フィールド行 `- <ラベル>: <値>` の値。**同じエントリ内の最初の 1 つ**を採る
# （見出し破損で別エントリの本文を吸収した場合に、隣の値へ化けないため。破損自体の
# 検出は validate-artifact.rb の責務であり、索引は「自分の値か、無ければ空」を返す）。
def field(body, label)
  re = /\A- #{Regexp.escape(label)}: ?(.*)\z/
  body.each do |l|
    m = re.match(l)
    return m[1] if m
  end
  nil
end

# 承認チェックボックス `  - [x] 計画を承認 …` の状態。**ラベルで引く**（ファイル中の
# 出現順に依存すると、順序が入れ替わった台帳で計画と完了が入れ替わる）。
def approval(body, label)
  re = /\A {2}- \[([ xX])\] #{Regexp.escape(label)}/
  body.each do |l|
    m = re.match(l)
    next unless m
    return m[1].strip.empty? ? "-" : "x"
  end
  "-"
end

rows = entries.map do |id, title, body|
  status = cell(field(body, "ステータス")).sub(/（.*\z/, "").strip
  opened = cell(field(body, "起票者 / 起票日")).split("/").last.to_s.strip
  ingested = cell(field(body, "取り込み元")).empty? ? "-" : "y"
  [
    cell(id),
    status,
    cell(field(body, "優先度")),
    cell(field(body, "担当ポジション")),
    cell(field(body, "関連サービス")),
    cell(opened),
    cell(field(body, "関連リポジトリ")),
    approval(body, "計画を承認") + approval(body, "完了を承認"),
    ingested,
    cell(title),
  ]
end

$stdout.puts COLUMNS.join("\t")
rows.each { |r| $stdout.puts r.join("\t") }
exit 0
