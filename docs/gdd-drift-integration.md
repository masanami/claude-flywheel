# GDD 意味ドリフト検知（`/guarantee-audit drift`）の run-cycle 接続設計

> **本ドキュメントのステータス: 確定（人間が決定済み。実装は本 PR [#84](https://github.com/masanami/claude-flywheel/pull/84) — main へは未マージ）。**
> 本ドキュメント中の日付はいずれも**このワークスペースのローカル日付**（決定・確証を行った時点は `2026-08-17`）。
> claude-harness の GDD 導入（[masanami/claude-harness#152](https://github.com/masanami/claude-harness/issues/152)）P4 が指定する flywheel 側の接続課題（[#81](https://github.com/masanami/claude-flywheel/issues/81) / 台帳 C-012）。4 つの検討事項に対する選択肢・比較・**決定**をまとめる。
> **本課題は claude-flywheel と claude-harness にまたがる横断課題**であり、設計分岐 Q-1〜Q-5 は人間が決定した（§7 の決定表）。**Q-3（機械生成エントリを課題台帳フォーマットとして許すか）は人間の明示承認を得ている**（2026-08-17）。
> §1〜§6 は決定に至った根拠（確証事実・制約・選択肢比較）であり、実装の正本ではない。**実装の正本は [audit-drift SKILL.md](../skills/audit-drift/SKILL.md)（監査の手順）と [challenge-ledger-format.md](./challenge-ledger-format.md)（台帳フォーマット）**。

## 1. 確証した前提（2026-08-17 時点・実コード確認済み）

harness 側の実装は **P2 が main にマージ済み**（`e699251` / PR #163）。以下はローカルクローン `.flywheel/repos/claude-harness`（`e699251`）の実コードで確認した事実であり、推論ではない。

| ID | 事実 | 確証方法 |
| --- | --- | --- |
| F-1 | `/guarantee-audit` は `bootstrap` / `drift` の 2 モード。`drift` は **検出のみで修正しない**（台帳の正本・テスト・実装のいずれも書き換えず、コミット・PR・Issue 起票も行わない） | `skills/guarantee-audit/SKILL.md` 冒頭の明示的な禁止リスト |
| F-2 | `drift` は機械可読 JSON（`{mode, scope, phase, index, semantic, reverse_check, gap_candidates, human_review_required}`）＋人間向けサマリーを返す | `references/drift-mode.md` Step D5 |
| F-3 | 各工程は `analyzed` / `partial` / `not_analyzed` の 3 値を持ち、**「0 件」「下限」「未解析」を書き分ける**ことが規律として課されている。`partial` の集約値は網羅ではなく**下限** | `SKILL.md`「共通規約 / 部分成功の扱い」・`drift-mode.md` Step D5 |
| F-4 | フェーズ判定は `detect-dev-phase.sh` の出力のみを正とし、**各スキルが `CLAUDE.md` を独自に grep することを禁止**している（判定規約の重複実装を防ぐ＝D-16） | `SKILL.md` Step 1・`scripts/specs/detect-dev-phase.md` |
| F-5 | `drift` は `phase: gdd` で実行、`sdd` は**台帳があれば警告付きで実行・無ければ停止**、`invalid` / スクリプト実行不能は**停止**（`sdd` に読み替えない） | `SKILL.md` Step 1 の分岐表 |
| F-6 | `/guarantee-audit` は **対象リポジトリのパスを引数に取らない**（`argument-hint: <bootstrap\|drift> [--scope <base>..<head>]`）。`detect-dev-phase.sh` は cwd の `CLAUDE.md`、`guarantee-index-check` は `docs/guarantees.md`、`list-test-files` は cwd 起点で列挙する＝**監査は cwd 束縛** | `SKILL.md` frontmatter・Step 1・`drift-mode.md` Step D2/D4 |
| F-7 | harness のスクリプトは**ランチャー `claude-harness-run` 経由の呼び出しのみが allowlist 可能**（`Bash(claude-harness-run:*)` の 1 行）。絶対パス直接実行は permission ルールで書けない（実測済み・Issue #154 で 4 回再発） | `docs/script-launcher.md` §1 の実測表 |
| F-8 | 本エージェントワークスペース（`/Users/masami/Tom`）に **`claude-harness-run` は PATH 上に存在しない**（`which` が exit 1）。親の `.claude/settings.json` の allow は `Bash(claude -p:*)` の 1 行のみ | `which claude-harness-run` / `cat .claude/settings.json` |
| F-9 | GAP は **人間の台帳 PR でのみ採番・追記される**。drift が検出した項目は「Issue を起こし通常の実装フローで対応」が harness 側の想定 | `drift-mode.md` Step D4-4・Step D5 末尾 |
| F-10 | D4（逆方向チェック）は対象ファイル**全件**に `guarantee-auditor` を fan-out する（ファイル単位の事前絞り込みを明示的に禁止）。コストは対象ファイル数に比例 | `drift-mode.md` Step D4-2 |

flywheel 側の確証事実:

| ID | 事実 | 確証方法 |
| --- | --- | --- |
| F-11 | flywheel に CI・lint・test 基盤は無い。決定的スクリプトは `scripts/` の 4 本のみ（`cycle-lock.sh` / `log-run-event.sh` / `sync-repos.sh` / `trust-clone.sh`） | `ls scripts/` |
| F-12 | run-cycle は「**ツール非依存**」を明示原則とし、実作業は接続ツールへ委譲する（`claude-harness` は開発例の 1 つ） | `skills/run-cycle/SKILL.md` 冒頭 |
| F-13 | 対象 repo での実作業は **step 3 の cwd＝作業用クローンの独立 `claude -p` セッション**で行う。step 0 は親ワークスペース cwd での観測に閉じる | `skills/run-cycle/SKILL.md` step 0 / step 3 |
| F-14 | reflect は run-cycle からは呼ばれず、**start-day の締めジョブ**が `journal/index.jsonl` の行数でしきい値判定して起動する（`reflect.every_n_cycles` 既定 10） | `skills/start-day/SKILL.md` 手順 5-3・`skills/reflect/SKILL.md`「起動タイミング」 |
| F-15 | `.flywheel/*` は gitignore 対象（`.flywheel/cadence.json` のみ negate で追跡）。`runtime/README.md`・`journal/` は追跡済み | `/Users/masami/Tom/.gitignore` / `git ls-files` |
| F-16 | ingest-challenges は「**入力＝外部（人間が課題を書く場所）、正本＝内部**」の ingestion であり、外部キー＋`fp`（人間記入欄の SHA-256 先頭 12 桁）で冪等マージする。分類欄は埋めない | `skills/ingest-challenges/SKILL.md` |

## 2. 前提から導かれる制約

F-6・F-13 から、本課題の設計空間はかなり強く絞られる。

*図: 監査の cwd 束縛（F-6）が組み込み位置を決める — 親セッションで直接起動すると誤った repo を監査する*

```mermaid
flowchart TD
  subgraph P["親セッション（cwd = エージェント repo）"]
    S0["run-cycle step 0（観測）"]
    NG["/guarantee-audit drift を直接起動"]
    S0 -.検討.-> NG
    NG -->|"detect-dev-phase.sh は cwd の CLAUDE.md を見る"| WRONG["エージェント repo のフェーズを判定<br/>＝対象 repo ではない（誤監査）"]
  end
  subgraph C["子セッション（cwd = .flywheel/repos/&lt;name&gt;）"]
    OK["/guarantee-audit drift"]
    OK --> RIGHT["対象 repo のフェーズ・台帳・テストを監査<br/>＝正しい対象"]
  end
  S0 -->|"claude -p 委譲（step 3 と同じ機構）"| OK
```

| ID | 制約 | 根拠 |
| --- | --- | --- |
| K-1 | **監査は cwd＝対象クローンで実行するほかない**。親セッションから `/guarantee-audit drift` を Skill 起動すると、`detect-dev-phase.sh` は親（エージェント repo）の `CLAUDE.md` を、`list-test-files` は親のファイル群を見る＝別の repo を監査してしまう | F-6 |
| K-2 | **親が `detect-dev-phase.sh` を直接呼ぶ経路は現状塞がっている**。ランチャーが PATH に無く（F-8）、絶対パス直接実行は allowlist できない（F-7）。仮に通しても、flywheel が harness プラグインの配置に依存することになりツール非依存原則（F-12）に反する | F-7・F-8・F-12 |
| K-3 | **flywheel 側に決定的スクリプトを足す判断基準は「実痛が出てから」**（[#46](https://github.com/masanami/claude-flywheel/issues/46) の抽出基準）。本課題のために新スクリプトを前倒しで作る理由は現時点で無い | F-11・start-day 手順 3 の注記 |
| K-4 | **`partial` / `not_analyzed` を「問題なし」へ切り上げてはならない**。検出結果を台帳・レポートへ流す際、この 3 値の区別を必ず保存する必要がある | F-3 |
| K-5 | **flywheel は台帳（`docs/guarantees.md`）を書き換えない**。GAP 採番は人間の台帳 PR のみ（F-9）。flywheel 側の出口は「起票」か「報告」に限られ、「自動修正」は選択肢に無い | F-1・F-9 |

## 3. 論点 1 — 組み込み位置

### 3.1 選択肢

| 案 | 内容 | 起動主体 |
| --- | --- | --- |
| **A: run-cycle step 0 内で条件付き実行** | 観測ステップにしきい値判定を置き、成立した周だけ対象 repo へ委譲する（設計ドラフトの字義どおりの接続点） | run-cycle |
| **B: 独立スキル＋締めジョブからのしきい値起動** | `reflect` と同型。新スキル（仮 `audit-drift`）を作り、start-day の締めジョブが `journal/index.jsonl` でしきい値判定して起動する | start-day 締めジョブ |
| **C: 独立スキル＋run-cycle step 0 からのしきい値起動** | スキルとしては独立（A の肥大化を回避）だが、起動点は run-cycle step 0 に置く（B より周回に密着） | run-cycle |

### 3.2 比較

| 観点 | A（step 0 内蔵） | B（独立＋締めジョブ） | C（独立＋step 0 起動） |
| --- | --- | --- | --- |
| 設計ドラフトとの整合 | ◎ 字義どおり（「step 0 から低頻度で呼ぶ」） | △ 接続点が締めジョブへずれる | ○ 起動点は step 0 のまま |
| step 0 の肥大化 | ✗ 観測ステップに LLM fan-out 委譲が入る（step 0 は現状すでに最長） | ◎ 影響なし | ◎ 影響なし |
| reflect との一貫性 | △ 低頻度処理の起動点が 2 種類に分かれる | ◎ 完全に同型（低頻度＝締めジョブ、が 1 箇所に集約） | △ 同上 |
| 委譲機構の再利用 | ○ step 3 の規律（`--session-id` 採番・`delegate_start/end`・trust 確認）を step 0 でも使う必要がある | ○ 同左（スキル内に再掲） | ○ 同左 |
| ロック・並走 | ◎ `cycle.lock` 保持下で直列化される | △ 締めジョブは run-cycle 外＝ロック外。長時間の fan-out が翌周と重なりうる | ◎ ロック保持下 |
| 失敗時の影響 | ✗ 観測失敗がサイクル全体を巻き込みうる | ◎ サイクルから隔離される | ○ 隔離しやすい |
| 実行頻度の自然さ | ○ N 周ごと | ◎ 1 日 1 回の判定＝「週 1」を素直に表現できる | ○ N 周ごと |

### 3.3 決定 — 案C（独立スキル＋ run-cycle step 0 起動）

**採用: 案C**（人間決定 2026-08-17）。理由:

1. **step 0 に置くべきではない実体がある**（A を退ける理由）。step 0 は「観測・取り込み」であり、現状すでにロック取得・ingest・`priority-policy.md` 検証で最も重い。そこへ**対象 repo ごとの `claude -p` 委譲と LLM fan-out**（F-10 によりコストはテストファイル数に比例）を入れると、観測ステップの責務と実行時間が質的に変わる。run-cycle 自身が「ハーネス改修は reflect に分離する（コストを抑えるための分離）」という分離原則を持っており、同じ論理が drift にも当てはまる。
2. **起動点は step 0 に残すべき**（B より C）。B の締めジョブ起動は reflect と完全に同型で魅力的だが、**締めジョブは `cycle.lock` の外**で走る。drift の fan-out は分単位で伸びうるため、締めジョブの drift と翌営業日朝の run-cycle が重なる余地がある（reflect はエージェント repo 内の集計で軽く、この問題が顕在化しない）。step 0 起動ならロック保持下で構造的に直列化される。
3. **不採用にした B の利点は記録に残す**。「低頻度処理の起動点を締めジョブに集約する」一貫性は本物であり、ロック問題を「締めジョブ内で drift を起動する前に `cycle-lock.sh acquire` を取る」で解けるなら B が再浮上しうる。将来 1 日の拍動を組み替える際の再検討材料とする。

## 4. 論点 2 — 対象 repo の選別（GDD 期の判定をどこで行うか）

### 4.1 「flywheel から `detect-dev-phase.sh` を呼べるか」への回答

**呼ぶべきではないし、現状の環境では呼べない**（K-2）。

- **呼べない（環境）**: `claude-harness-run` が PATH 上に無く（F-8）、絶対パス直接実行は Bash permission ルールとして記述不能（F-7 の実測表）。親の allow は `Bash(claude -p:*)` のみ。
- **呼ぶべきでない（設計）**: flywheel は**ツール非依存**を明示原則とする（F-12）。`detect-dev-phase.sh` は harness プラグイン配下のスクリプトであり、flywheel がそのパス解決・出力仕様に依存すると、harness のプラグイン配置変更やバージョン更新で flywheel が静かに壊れる。D-16 が「判定は `detect-dev-phase.sh` に一元化」と言っているのは**判定ロジックの重複実装を禁じている**のであって、**すべての呼び出し元が直接 exec すべき**という意味ではない。

### 4.2 選択肢

| 案 | 判定場所 | 内容 |
| --- | --- | --- |
| **a: 子セッションに委ねる（判定を持たない）** | 子（`/guarantee-audit` の Step 1） | 親は対象 repo を絞らず委譲し、フェーズ判定・停止判断は監査スキル自身の Step 1 に任せる。親は返ってきた JSON の `phase` / `phase_reason` を読むだけ |
| **b: 親が安価な事前フィルタを掛ける** | 親（ファイル存在確認）＋子（正式判定） | 親が `.flywheel/repos/<name>/docs/guarantees.md` の存在を確認し、無ければ委譲自体をスキップする。フェーズの正式判定は子に残す |
| **c: `repos.tsv` に GDD フラグ列を足す** | 人間（マニフェスト宣言） | 対象 repo を人間が明示的に opt-in する |

### 4.3 比較

| 観点 | a（子に委ねる） | b（事前フィルタ） | c（repos.tsv 宣言） |
| --- | --- | --- | --- |
| ツール非依存（F-12） | ◎ 保たれる | ○ `docs/guarantees.md` という harness 規約に薄く依存 | ◎ 保たれる |
| D-16 との整合 | ◎ 判定は 1 箇所（スクリプト）のまま | ○ 判定はしていない（存在確認のみ） | ✗ フェーズ宣言の二重管理＝宣言自体がドリフトする |
| コスト | ✗ 非 GDD repo にも毎回セッションを起動する | ◎ 台帳の無い repo を無料で除外 | ◎ 最小 |
| **運用前提の破れの検出** | ◎ 「GDD 宣言なのに台帳が無い」を子が検出し報告できる（F-5） | ✗ **その事故を静かに握りつぶす**（台帳が無い＝スキップ、で終わる） | ✗ 同左 |
| 人手の要否 | ◎ 不要 | ◎ 不要 | ✗ repo 追加のたびに人間が更新 |

### 4.4 決定 — 案a（子に委ねる・親側の事前フィルタなし）

**採用: 案a。b は不採用**（人間決定 2026-08-17）。

b の事前フィルタは一見コスト面で明らかに得だが、**除外する集合が「監査対象外」ではなく「最も危険な状態」を含む**。`phase: gdd` かつ `docs/guarantees.md` 不在は、harness 側が**運用前提の破れとして停止・要人間判定**に分類しているケース（F-5、`drift-mode.md` Step D1）であり、GDD を宣言したのに駆動文書が無い＝ゲート群が空回りしている状態である。b はこれをファイル存在確認だけで「対象なし」に丸めてしまい、検知したい事故そのものを隠す。K-4（`partial`/`not_analyzed` を「問題なし」に切り上げない）と同種の誤りである。

a のコスト問題（非 GDD repo にもセッションを起動する）は、実際には小さい: `/guarantee-audit drift` は Step 1 でフェーズ判定 → Step D1 で台帳確認と進み、`sdd` かつ台帳無しなら **fan-out に入る前に停止**する（F-5）。無駄になるのは短いセッション 1 本であり、fan-out コストは発生しない。現在の対象は 3 repo（`repos.tsv`）で、そのすべてが現時点では非 GDD 期である。

**再検討の契機**: repo 数が増えて「毎回全 repo に空振りセッションを起動する」コストが無視できなくなった場合は b を再検討してよい。その際は握りつぶし事故を別経路で拾う設計（例: 台帳不在でも `CLAUDE.md` に GDD 宣言があれば委譲する）を必ず併せて入れる。

## 5. 論点 3 — 検出結果の流し込み先

### 5.1 ingest-challenges は使えるか

**そのままでは使えない**。ingest-challenges は「**外部の共有課題ソース（人間が課題を書く場所）から、人間記入欄を冪等に取り込む**」ものであり（F-16）、drift 出力とは以下が構造的に噛み合わない:

| ingest-challenges の前提 | drift 出力の実態 |
| --- | --- |
| ソースは人間が書いた自由記述。`type` は `repo-file` / `mcp-doc` / `mcp-chat` / `github-issue` | 機械生成の JSON。既存 `type` のいずれでもない（新 `type` の追加が要る） |
| 外部キーはソース側の安定 ID | 安定キーを別途定義する必要がある（`semantic.drifted` は `guarantee_id`、`gap_candidates` は `test_ref` が候補。ただし `test_ref` は動的生成テストで不安定＝`drift-mode.md`「突き合わせの限界」） |
| `fp` は人間記入欄の SHA-256 | 人間記入欄に相当するものが無い（起票者＝エージェント） |
| 外部へは書き戻さない read-only | 同左（問題なし） |
| 「起票者 / 起票日」を外部から取得 | 「不明」または「エージェント」になる |

つまり ingest 経路を使うなら**新しいソース種別の設計が必要**であり、それは本課題のスコープを超える。

### 5.2 選択肢

| 案 | 出口 | 内容 |
| --- | --- | --- |
| **A: サイクルレポート＋journal 併記のみ** | 報告 | 台帳へは書かない。drift JSON の要約をサイクルレポートに出し、journal の「⑤ 判断と根拠」へ残す |
| **B: 台帳へ repo 単位のサマリ課題を 1 件起票** | 台帳 | repo ごとに 1 エントリ（キー＝repo 名）。個別 finding は本文に列挙し、詳細 JSON は journal へ。既存エントリがあれば内容を更新 |
| **C: finding ごとに台帳エントリを起票** | 台帳 | `guarantee_id` / `test_ref` ごとに 1 エントリ |
| **D: 対象 repo の GitHub Issue として起票** | 外部 | harness 側の想定（F-9「Issue を起こし通常の実装フローで対応」）に最も忠実 |

### 5.3 比較

| 観点 | A（報告のみ） | B（repo 単位サマリ） | C（finding 単位） | D（GitHub Issue） |
| --- | --- | --- | --- | --- |
| 検出が解決へ駆動されるか | ✗ 報告が流れて消える | ○ 台帳の通常フロー（分類→計画→承認→実行）に載る | ◎ 個別に追跡できる | ◎ 対象 repo の実装フローに直接載る |
| 台帳の肥大化 | ◎ なし | ○ 最大 repo 数ぶん | ✗ finding 数ぶん増える。`partial` の再実行で揺れる | ◎ 台帳は汚れない |
| 冪等性 | ◎ 自明 | ○ キー＝repo 名で安定 | ✗ `test_ref` が動的生成テストで不安定＝重複起票・消失を繰り返す | △ Issue 重複検知の実装が要る |
| K-4（3 値の保存） | ○ レポートに書けば保存できる | ○ サマリ本文に `analyzed`/`partial`/`not_analyzed` を明記できる | ✗ finding 単位に分解すると「未解析だった」情報が失われる | ○ 本文に書ける |
| FR-22（承認ゲート） | ◎ 抵触しない | ◎ 内部ファイルのみ＝可逆 | ◎ 同左 | ✗ **外部送信＝不可逆**。自律実行では起票できず人間承認待ちになる |
| harness 側の想定との整合 | △ | ○ | ○ | ◎ |

### 5.4 決定 — 案B（repo 単位のサマリ課題を台帳へ起票）

**採用: 案B**（人間決定 2026-08-17。機械生成エントリを台帳フォーマットとして許すことも同時に承認された）。理由:

1. **A は「検出したのに誰も直さない」で終わる**。harness 側が修正を明示的に責務外としている（F-1「監査と修正の分離」）以上、flywheel 側が検出を作業へ橋渡ししないと GDD のドリフト対策が閉じない。本課題の存在意義はまさにこの橋渡しにある。
2. **C は冪等性が壊れる**。`gap_candidates` のキー `test_ref` は「動的生成テストでは台帳に登録済みでも未登録として現れうる」と harness 側が明記している（`drift-mode.md`「突き合わせの限界」）。これを台帳エントリの外部キーにすると、監査のたびに現れたり消えたりするエントリが台帳に溜まる。さらに `partial`（下限）の結果を finding 単位に分解すると、K-4 が守れない。
3. **D は FR-22 に抵触する**。GitHub Issue 起票は組織外への外部送信に当たり、run-cycle の FR-22 は「送信済みは撤回困難＝不可逆」として人間承認ゲートの対象に置いている。自律サイクル内で起票できないため、結局「提案を残して保留」＝B に近い形になる。**ただし D は harness 側の想定に最も忠実**であり、「台帳に起票 → 承認後に対象 repo の Issue へ」という 2 段構成なら両立しうる（B の発展形）。
4. B のエントリは「人間記入欄＝機械生成」という台帳フォーマットの想定外の使い方になる。**この拡張は人間が明示承認した**（2026-08-17）。起票者を `drift 監査（機械生成）`（ツール中立な表記）と明記し、人間記入欄には監査サマリを置き、分類欄は run-cycle 手順1 に委ねる。冪等性を壊さないための契約（マーカーの排他・判定キー・照合範囲・承認ゲート・アーカイブ整合）は §7.1 と [challenge-ledger-format.md](./challenge-ledger-format.md) §監査元マーカーが正本。

## 6. 論点 4 — コスト管理

### 6.1 コストの実体

F-10 のとおり、D4（逆方向チェック）は**対象テストファイル全件**に `guarantee-auditor` を fan-out する（10 件チャンク・チャンク間バリア）。D3 も保証件数ぶん fan-out する。したがって 1 repo あたりのコストは概ね「保証件数 / 10 ＋ テストファイル数 / 10」チャンク分のサブエージェント起動であり、**中規模 repo でも数十エージェント規模**になりうる。毎周回すのは論外という Issue の前提は正しい。

### 6.2 しきい値の選択肢

| 案 | 判定 | 状態の置き場 |
| --- | --- | --- |
| **i: N 周ごと** | `journal/index.jsonl` の行数（reflect と同じ算式 `floor(T/N) > floor((T−t)/N)`） | 既存ファイルで足りる（追加状態なし） |
| **ii: 週 1（壁時計）** | 最終監査日からの経過日数 | 監査日を記録する追跡ファイルが要る |
| **iii: 対象 repo に変更があったときだけ** | 前回監査時の SHA と現在の `HEAD` を比較し、同一ならスキップ | repo ごとの `last_audited_sha` を記録する追跡ファイルが要る |

### 6.3 決定 — 案i のみ（`skip_if_unchanged` は見送り）

**採用: 案i（N 周ごと）のみ。案iii（前回監査 SHA との比較）は当面見送り**（人間決定 2026-08-17）。

- **i** は reflect と同じ算式・同じ入力（`journal/index.jsonl`）で実装でき、**追加の状態ファイルが要らない**。cadence.json に `drift.every_n_cycles`（例: 30。1 周 90 分・1 日 6 周として概ね週 1 に相当）を足すだけで済み、reflect との一貫性も保てる。**ii の「週 1」は i でほぼ表現できる**ため、壁時計を持ち込む必要は薄い。
- **iii** は本質的なコスト削減になる。前回監査から対象 repo に 1 コミットも入っていなければ、監査結果は原理的に変わらない（台帳もテストも実装も同じ）。空振りの fan-out を丸ごと避けられる。
- **iii は今回は採らない**（人間決定 2026-08-17）。iii は**永続状態を必要とし**、`.flywheel/` は gitignore 対象（F-15）でマシンをまたぐと失われるため、追跡対象の場所（`runtime/` 配下など）へ状態ファイルを 1 つ増やす判断が要る。i 単独でも運用は成立する（空振りの監査が走るだけで、正しさは損なわれない）ため、実コストが観測されてから再検討する。

GDD を採用したワークスペースが `.flywheel/cadence.json` へ**明示的に足す**設定（形式は既存 `reflect` ブロックに揃える）:

```json
{
  "reflect": { "every_n_cycles": 10 },
  "drift": { "every_n_cycles": 30 }
}
```

- 起動条件は `(T + 1) % N == 0`（`T` ＝ `journal/index.jsonl` の総行数、`T + 1` ＝ 当周の周回番号、`N` ＝ `drift.every_n_cycles`）。`index.jsonl` が無ければスキップする。
- start-day 手順 1 の値検証規律に従い、`drift.every_n_cycles` は正の整数、不正値は既定値 `30` へ補正して継続（`execution_mode` のような fail-closed 扱いにはしない＝隔離境界ではないため）。
- **`drift` ブロック自体が無い場合は「drift 監査を行わない」を既定とする**（opt-in。GDD を採用していないワークスペースで勝手にコストが発生しない）。この理由から**雛形 `templates/cadence.json` にはこのブロックを入れない**（雛形に入れると全ワークスペースで既定 ON になってしまう）。

## 7. 決定事項（2026-08-17・人間決定）

| ID | 問い | 決定 | 補足 |
| --- | --- | --- | --- |
| **Q-1** | 組み込み位置 | **案C: 独立スキル [audit-drift](../skills/audit-drift/SKILL.md) ＋ run-cycle 手順0 からのしきい値起動** | 案B（締めジョブ起動）は、締めジョブが `cycle.lock` の外で走り fan-out が翌周と重なりうるため不採用（§3.3） |
| **Q-2** | 対象 repo の選別 | **案a: 子に委ねる（親側の事前フィルタを入れない）** | 「GDD 宣言なのに台帳が無い」＝接続ツールが運用前提の破れとして扱う最も危険な状態を握りつぶさないため（§4.4） |
| **Q-3** | 検出結果の出口 / 機械生成エントリを台帳フォーマットとして許すか | **案B: repo 単位のサマリ課題を台帳へ起票。機械生成エントリを許容する（人間承認済み）** | 案C（finding 単位）はテスト参照が不安定で冪等性が壊れるため不採用。案D（GitHub Issue 化）は FR-22 の不可逆操作のため、必要なら人間承認後の 2 段目として別途（§5.4） |
| **Q-4** | コスト管理 | **案i（N 周ごと）のみ。`skip_if_unchanged`（前回監査 SHA 比較）は見送り** | 状態ファイルを増やす判断は保留。空振りが走るだけで正しさは損なわれない（§6.3） |
| **Q-5** | harness 側ドラフトとのずれの扱い | **PR 本文に列挙するに留め、Issue 起票はしない**（起票は親が別途行う） | §7.2 に列挙 |

### 7.1 機械生成エントリの契約（Q-3 を許容する条件）

Q-3 を許した以上、**既存 ingestion の冪等性を壊さないこと**が絶対条件になる。契約は次の 4 点。正本は [challenge-ledger-format.md](./challenge-ledger-format.md) §監査元マーカー、手順は [audit-drift SKILL.md](../skills/audit-drift/SKILL.md) §5。

| # | 要件 | 満たし方 |
| --- | --- | --- |
| 1 | **取り込み元マーカーと衝突しない** | 別ラベルの**監査元マーカー**（`- 監査元: … <!-- audit:drift:<repo名> afp:<12桁> -->`）を使い、指紋も `fp:` ではなく `afp:` にする。両マーカーは**同一エントリに共存させない（排他）**。drift エントリは `取り込み元:` 行を持たないため、ingest-challenges の「マーカー無しの手書きエントリは触らない」規約がそのまま効き、**新規判定・`fp` 更新・ポリシー不適合による取り込み解除（削除）のいずれの対象にもならない**。アーカイブ時に両マーカーとも原文保持する点は共通＝「マーカーの有無で運用を分岐させない」既存規約と整合する |
| 2 | **再実行で二重起票しない** | 判定キーは `audit:drift:<repo名>`（1 repo 1 エントリ）。照合範囲は**台帳のみ**（アーカイブは照合しない＝ドリフトは再発しうるため、解消済みの再検出は新規起票が正しい。ingest とは意図的に逆）。既登録時は**ステータス依存**で動作を分ける: 人間承認前（未分類／分類済／計画承認待ち〔未チェック〕）は `afp` 一致→スキップ・不一致→**説明のみ更新**、**着手中以降（承認済み含む）は台帳を一切変更しない**。`afp` はドリフト集合から決定的に算出し、**監査日・コミット SHA を含めない**（対象にコミットが入るたび「更新あり」になるのを防ぐ） |
| 3 | **人間記入欄と分類欄の扱い** | 人間記入欄は機械が書く（起票者 `drift 監査（機械生成）`＝**ツール中立な表記**／起票日は**初回検出日で固定**／説明は監査サマリ／完了条件は再監査でクリーンになること）。更新時に書き換えるのは**説明のみ**で、緊急度・完了条件・起票日は保持する。分類欄は空で起票しステータス `未分類` とし、以降は **run-cycle 手順1 が分類・手順2 が計画（FR-13）・手順4 が検証（FR-32）** と通常の課題とまったく同じ経路を通す。**「機械が起票したから承認不要」という例外は作らない**。再監査でクリーンになっても監査スキルはステータスを前進させず、「完了承認の候補」として報告するに留める |
| 4 | **アーカイブとの整合** | 完了時は既存の即アーカイブ規律（同一コミットでのアトミック移動・ステータス行のみ更新・原文保持・削除しない）にそのまま乗る。監査元マーカー行もアーカイブ側で保持する。ただし再監査の照合対象にはアーカイブを含めない（上記 2） |

あわせて、実運用で発生した事故（**行番号演算によるエントリ移動が隣接エントリのマーカーを破壊**・2026-08-17 検出）を踏まえ、**台帳を機械で編集するすべての手順**に次を課した（[challenge-ledger-format.md](./challenge-ledger-format.md) §台帳を機械で編集するときの規律）: エントリ境界は `^### \[` の見出しパターンで切る／編集前後に「各エントリのマーカーが高々 1 つ・エントリ総数が期待値と一致」を `awk` で検算する／検算に失敗したらコミットせず元に戻す。この規律は audit-drift だけでなく **§アーカイブのアトミック移動**からも参照させ、事故の再発経路を塞いだ。

### 7.2 harness へ戻すべき事項（Q-5・本 repo からは起票しない）

| # | 内容 |
| --- | --- |
| H-1 | `docs/gdd-design-draft.md` §3.2 は接続点を「run-cycle の観測ステップ（step 0）から低頻度で呼ぶ」と記載しているが、実装は**「step 0 はしきい値判定と起動のみ、実体は独立スキル audit-drift」**（案C）になった。記述の更新可否を判断されたい |
| H-2 | **A-1（flywheel 側で受け入れられる前提）は検証され、成立した**。flywheel は接続を受け入れ、実装済み |
| H-3 | **`claude-harness-run` ランチャーの配置が実質的な前提条件**になっている。未配置だと委譲先で監査が停止する（F-7・F-8）。定期実行を前提にするなら、ランチャー未解決時のフォールバックか、導入手順での明示が望ましい |
| H-4 | drift の機械可読 JSON に **`phase_reason` が骨格の例では出ているが、フィールド表には記載が無い**（`drift-mode.md` Step D5）。消費側が依存してよいフィールドか明確化されたい |
| H-5 | 定期実行側は `gap_candidates` を **`reverse_check.status` と必ずセットで**解釈している（`not_analyzed` の空配列を「候補なし」と読まない）。この読み方が想定どおりか確認されたい |

## 8. 実装（本 PR の変更）

| ファイル | 変更 |
| --- | --- |
| `skills/audit-drift/SKILL.md` | **新規**。しきい値判定 → 対象 repo 決定（事前フィルタなし）→ cwd＝クローンへの委譲 → 3値を保存した結果解釈 → 台帳への冪等な起票（マーカー検算つき）→ 報告 |
| `skills/run-cycle/SKILL.md` | 手順0 にしきい値判定と audit-drift 起動を追加（`--dry-run` パリティ・コミットは手順6・新規エントリは次周の手順1 へ）。手順6 のサイクルレポート項目に「ドリフト監査の結果」を追加 |
| `skills/start-day/SKILL.md` | 手順1 に `drift` ブロックの既定（**未設定＝OFF の opt-in**）と `drift.every_n_cycles` の値検証を追加 |
| `docs/challenge-ledger-format.md` | §監査元マーカー（機械生成エントリの冪等性）を新設。§台帳を機械で編集するときの規律（マーカー保全・検算）を新設。エントリ・テンプレートと §アーカイブに監査元マーカーを反映 |
| `docs/gdd-drift-integration.md` | 本ドキュメント（検討 → 確定） |
| `docs/README.md` | ドキュメント一覧・スキル一覧を更新 |
| `docs/architecture.md` | §4.1 のプラグイン構成に `audit-drift/` を追加 |
| `.claude-plugin/plugin.json` | マイナーバージョンを 0.16.0 へ |

**`templates/cadence.json` は意図的に変更していない**。`drift` ブロックは opt-in（不在＝OFF）であり、雛形に含めると全ワークスペースで既定 ON になってしまうため（GDD を採用していないワークスペースで監査コストを発生させない）。

### 8.1 レビュー反映（PR #84・2 巡目）

初版レビューを受けて次を追加・変更した。**いずれも §7 の決定を変えるものではない**（ツール中立化＝ AC-1〜AC-4 の最小契約と、永続データからのツール名除去は維持）。

| 論点 | 反映内容 |
| --- | --- |
| **読み取り専用の強制**（安全側） | 委譲先の権限を対象クローンの設定とブリーフの禁止文だけに委ねると、対象 repo 由来の指示で書き込み・push・外部送信が起こりうる。**事後の `git status` は検知であって防止ではない**（送信は取り消せない）ため、audit-drift に §読み取り専用の強制（RO-1〜RO-5）を新設し、**確認できなければ監査を起動しない fail-closed** にした。事後確認は 2 層目の検知として残す |
| **単体実行の契約**（未整備な経路） | ロック・journal・台帳更新・コミット範囲・`--dry-run` の副作用を**§実行コンテキストの契約の 1 表**に集約した。**単体実行は台帳を更新しない診断モード**とし（journal を作る案は `journal/index.jsonl` の行数を reflect と本スキルの両しきい値が数えているため副作用が大きく不採用）、**本スキルから Git コミット経路を削除**して run-cycle 手順6 の既存 pathspec 規律に一本化した。`--dry-run` では `sync-repos.sh` も実行しない |
| **台帳編集の失敗時復旧**（安全側） | §台帳を機械で編集するときの規律を**一時ファイル方式**へ変更。元ファイルを一度も書き換えないため復旧操作が不要になり、`git checkout -- challenge-ledger.md`（**人間の未コミット変更を巻き添えで破棄する**）を規律から排除した。この規律は行番号演算による事故を受けて入れたものであり、**規律自体が別の事故を生まない**形に整えた |
| **`afp` の直列化** | 区切り文字連結は要素内に同じ文字があると異なる集合が同じ文字列に潰れ（`["a,b"]` と `["a","b"]`）、**検出内容が変わったのに更新をスキップ**しうる。**canonical JSON**（キー順固定・空白なし・`items` 辞書順）へ変更して境界を保存した |
| **AC-4 未取得時の全体判定** | AC-4 を取得できなかった結果を「クリーン」に分類しない規則を §4.4 に明記（要人間判定が「無い」のか「読めていない」のか区別できないまま完了承認の候補として提示しないため） |
| **検証失敗の網羅性** | 説明欄テンプレートで「検証失敗」にも AC-2 の 3 値を併記する形に統一（他の工程だけ 3 値付きで、検証失敗だけ件数のみだった） |

## 9. 参照

- claude-harness: `docs/gdd-design-draft.md` §3.2（D-5 / D-6）・§2.1（D-16）・§7 の決定表・A-1
- claude-harness: `skills/guarantee-audit/SKILL.md`（Step 1 / 共通規約）・`references/drift-mode.md`（Step D1〜D5）
- claude-harness: `scripts/specs/detect-dev-phase.md`・`docs/script-launcher.md`
- claude-flywheel: `skills/run-cycle/SKILL.md`（step 0 / step 3 / FR-22）・`skills/reflect/SKILL.md`・`skills/start-day/SKILL.md`（手順 5-3）・`skills/ingest-challenges/SKILL.md`
- Issue: [claude-flywheel#81](https://github.com/masanami/claude-flywheel/issues/81)（台帳 C-012）・[claude-harness#152](https://github.com/masanami/claude-harness/issues/152)（GDD 親）・[claude-harness#163](https://github.com/masanami/claude-harness/pull/163)（P2 実装）
