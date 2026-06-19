# 自己改善（内省）ループ 運用方針

> エージェントが、**自身のハーネス（スキル・サブエージェントのブリーフ・ポジション・recall）を継続的に改善**するための内省ループを定義する。
> 「実行ループ（[run-cycle](../skills/run-cycle/SKILL.md)）」と「自己改善ループ（[reflect](../skills/reflect/SKILL.md)）」を**分離**し、run-cycle は軽量な信号採取だけを担い、改修判断は reflect に切り出す。
>
> - ステータス: ドラフト（検討中）
> - 関連: [requirements.md FR-43〜45](requirements.md)（自己改善）, [agent-memory.md](agent-memory.md)（experience 型）, [run-cycle](../skills/run-cycle/SKILL.md)

## 1. なぜ分離するか

- skill / サブエージェント / ブリーフの改修を **run-cycle 内で毎周やると重い**（1 周のコストが膨らみ、自走の拍動が鈍る）。
- 改修の判断には**複数周ぶんの傾向**（同じ失敗が再発しているか、何が安定して効くか）が要る。1 周だけ見ても局所最適になりやすい。
- → run-cycle には「**軽量な信号採取**（評価ではなく append のみ）」だけを置き、傾向の集計と改修提案は**低頻度の別ループ**で行う。

この分離は AI エージェント研究の定石に沿う:

- **Reflexion**: 実行（actor）と内省（self-reflection）を分離し、内省結果を episodic memory に言語で残して次回に効かせる（重み更新なし・軽量）。
- **Voyager**: タスク実行とは別に skill library を持ち、self-verify を通った挙動だけを再利用可能 skill として蓄積・改修する。
- **MUSE 等の self-evolution 系**: Skill の Creation → Memory → Management → **Evaluation** を独立サイクルとして回す。

## 2. good も bad も記録する（使い方は非対称）

bad だけ記録すると「何を避けるか」しか残らず、「何を伸ばすか／改修で壊してはいけないか」が失われる。**両方記録し、用途を分ける**。

| 信号 | 例 | 主な使い道 |
| --- | --- | --- |
| **bad** | 失敗・手戻り・レビュー指摘・人間による手動修正 | 改修トリガー。同種が **N 回再発**で skill/サブエージェント/ブリーフを直す |
| **good** | 効いた手順・一発で通った・有効だったレビュー観点 | ① **再利用資産化**（skill/パターンへ昇格）② **回帰ガード**（改修で壊さない基準）③ recall の正例 |

## 3. 2 層の設計

### 層1: run-cycle 内の「信号採取」（軽量・改修しない）

run-cycle の学習ステップ（[step 5](../skills/run-cycle/SKILL.md)）で、**信号を append するだけ**。評価も改修もしない。既存の `experience` 記憶型を再利用し、frontmatter にフィールドを足す（運用は [agent-memory.md §2.1](agent-memory.md)）。

```yaml
metadata:
  type: experience
  outcome: good | bad           # この経験の評価
  target: skill:run-cycle | subagent:<name> | brief | position | recall | other
  signal: <何が効いた/詰まったか 1行>
  recurrence: <同種が何回目か（任意。reflect が集計時に更新してもよい）>
```

- 1 周あたり数行・コストほぼゼロ。冪等（同じ経験を二重記録しない）。
- `target` は「どの資産を直せば再発防止/再現できるか」の当たりを付けるためのタグ。

### 層2: reflect スキル（内省・改修提案、低頻度）

run-cycle とは独立に起動し、蓄積した信号を集計してパターンを抽出 → 改修を**提案する**（自動では適用しない）。詳細手順は [reflect](../skills/reflect/SKILL.md)。

```
1. 集計   直近の experience(outcome) を集める
2. 抽出   再発 bad（recurrence ≥ 2）と、再利用価値のある good を選ぶ
3. 分類   改修対象を target 別に仕分け（下表）
4. 提案   具体的な diff 案を作る（承認ゲート：人間承認まで適用しない）
5. 記録   採用された改善を experience に「適用済み」で記録（二重提案防止＝冪等）
```

## 4. 改修対象とスコープの線引き（重要）

reflect が直接編集してよいのは、**エージェントrepo 側のローカル資産**だけ。**プラグイン本体の共通スキルは読み取り専用**なので直接編集せず、改善は **upstream（claude-flywheel）への Issue 起票**に倒す。

| target | 実体 | reflect の扱い |
| --- | --- | --- |
| `position` | `positions/<domain>.md` | 直接 diff 提案（承認後に適用） |
| `recall` | `CLAUDE.md` の recall ヒント / INDEX の引き方 | 直接 diff 提案 |
| `brief` | サブエージェント／別セッションへ渡すブリーフ雛形 | 直接 diff 提案 |
| ローカル skill | エージェントrepo 内に持つ独自スキル | 直接 diff 提案 |
| `skill:run-cycle` 等 | **プラグイン本体の共通スキル** | **編集不可** → upstream Issue を起票 |

- good の資産化先も同じ仕分け（再現したい手順を position/brief/ローカル skill に昇格、recall の正例として INDEX に反映）。
- どの改修も **承認ゲート**を通す（ハーネスの自己書き換えは影響が大きいため）。

## 5. 起動頻度

毎周は回さない。次のいずれかで起動する。

- **N サイクルごと**（例: 週次／一定周回ごと）。`runtime/` のスケジュールで定義。
- **しきい値到達時**: 同種 bad の `recurrence ≥ 2`。
- **手動**: `/claude-flywheel:reflect`。

## 6. ライフサイクル（run-cycle と reflect の関係）

```
 run-cycle（毎周・軽量）                         reflect（低頻度・内省）
   実行→検証→学習                                  集計→抽出→分類→提案→記録
        │ 信号採取（append のみ）                       ▲           │
        ▼                                              │           ▼
   experience(outcome/target/signal) ──蓄積──▶ 傾向を読む    改修 diff 提案
                                                                   │ 人間承認（承認ゲート）
                                                                   ▼
                                          ローカル資産を更新 / プラグイン改善は upstream Issue
                                                                   │
                                          └─ 次の run-cycle が改善後の資産で回る（弾み車）
```

## 7. 検討中の論点（Open Questions）

- **しきい値**: 再発回数 N（既定 2）や good 昇格の基準をどう調整するか。
- **集計範囲**: reflect が見る experience の窓（直近 N 周 / 期間）と、適用済み信号の扱い。
- **upstream 連携**: プラグイン改善 Issue の粒度・テンプレ。fleet 全体で共通課題が出たときの集約。
- **回帰ガードの実体**: good を「壊さない基準」としてどう機械的に効かせるか（チェックリスト化 / テスト化）。
