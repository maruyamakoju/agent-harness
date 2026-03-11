# Autoresearch Arena — 運用ガイド

## この arena が解く問題

通常の product loop は「全 feature を一度に実装しようとする」問題がある。
Autoresearch arena はループを「仮説 → 実験 → keep/discard 判定」に変え、
**スコアが改善した変更だけを蓄積する**。

---

## PROGRAM.md の書き方

各ワークスペースに配置される `PROGRAM.md` が arena のルールを定義する。

### Mutation Scope（1ループあたりの変更上限）

```markdown
## Mutation Scope
- Max files changed per loop: 5
- Max files created per loop: 4
- Max diff lines per loop: 300
```

- **小さく設定するほど**エージェントが 1 feature に集中しやすい
- Python では `__init__.py` + モジュール + テスト = 最低 3 ファイル必要なので 3 以上を推奨
- 大きすぎると CODE_AUDIT が意味をなさない

### Eval Protocol（スコアの重み）

```markdown
## Eval Protocol
weights:
  tests: 0.45
  lint: 0.25
  typecheck: 0.20
  coverage: 0.05
  security: 0.05
```

- `tests` が最重要（通らないコードは意味がない）
- `security` は pip-audit が PATH 上にないと常に 0 → max score = 0.95

### Stop Conditions（停止判定）

```markdown
## Stop Conditions
- target_score: 1.00          # この score に達したら正常停止
- min_improvement_delta: 0.01 # これ未満の改善が続いたら plateau とみなす
- max_plateau_loops: 2        # plateau が N ループ続いたら停止
- consecutive_discards >= max_discards_in_a_row  # safety net
```

---

## 停止理由の読み方

| 停止理由 | 意味 | 次の一手 |
|---------|------|---------|
| `target_score_reached` | score >= target_score に到達 | そのままマージ |
| `plateau_stop` | 改善余地がなくなった | score ceiling を調査、または target_score を下げる |
| `consecutive_discard_stop` | N ループ連続で失敗 | hypothesis の質か CODE_AUDIT の cap を見直す |
| `max_loops_reached` | ループ上限到達 | max_loops を増やす、または範囲を絞る |

**plateau vs discard の違い:**
- `plateau` = 改善余地がないから止まる（健全）
- `discard` = たまたま外れた（safety net として必要だが本来は少ない方が良い）

---

## ledger.jsonl の見方

`EVALS/ledger.jsonl` に各ループの実験記録が残る。

```json
{"loop": 1, "score_before": "0.2500", "score_after": "0.9500", "kept": true, "verdict": "keep"}
{"loop": 2, "score_before": "0.9500", "score_after": "0.9500", "kept": false, "verdict": "discard_regression"}
```

良い実験の特徴:
- Loop 1 で大幅 keep（scaffold 実装）
- その後 plateau_stop（score ceiling を正しく検出）
- `discard_audit` が多い場合 → cap が厳しすぎるか、エージェントが実装を詰め込みすぎ

---

## keep/discard の見方（JUDGE）

| 条件 | verdict | CONSECUTIVE_DISCARDS | PLATEAU_COUNT |
|------|---------|---------------------|---------------|
| SCORE_AFTER > SCORE_BEFORE | keep | 0 にリセット | 0 にリセット |
| SCORE_AFTER <= SCORE_BEFORE | discard_regression | +1 | +1（delta < min_delta なら） |
| CODE_AUDIT 違反 | discard_audit | +1 | 変更なし |

---

## どんな product が autoresearch 向きか

**向いている:**
- 明確なテスト・lint・typecheck がある（スコアが数値化できる）
- 機能が独立した feature に分割できる（1 ループ 1 feature）
- Python / TypeScript など静的解析が充実した言語

**向いていない:**
- UI/UX の改善（数値スコアにしにくい）
- 外部 API 依存が強い（テストが不安定）
- 全体を一度に書かないと動かない設計

---

## 推奨 PROGRAM.md 値（TaskForge CLI 型プロジェクト）

```markdown
## Mutation Scope
- Max files changed per loop: 5
- Max files created per loop: 4
- Max diff lines per loop: 300
- Max endpoint/route changes per loop: 1

## Eval Protocol
weights:
  tests: 0.45
  lint: 0.25
  typecheck: 0.20
  coverage: 0.05
  security: 0.05

## Keep/Discard Policy
- keep_threshold: score_after > score_before
- tie_policy: discard

## Budget
- max_loops: 5
- max_discards_in_a_row: 3

## Stop Conditions
- target_score: 1.00
- min_improvement_delta: 0.01
- max_plateau_loops: 2
- consecutive_discards >= max_discards_in_a_row
```

---

## scoring 天井の対処

現状: pip-audit が Python の Store 版では PATH で検出されず → security score = 0 → max = 0.95

対処法（どちらか）:
1. `target_score: 0.95` に下げる（pip-audit なし環境用）
2. `python -m pip-audit` ではなく `pip-audit` の PATH を直す

---

## 実験ログ確認コマンド（Windows Git Bash）

```bash
# stop reason を確認
grep "plateau_stop\|target_score_reached\|consecutive_discard_stop" logs/*.log

# ledger を読む（jq が PATH にある場合）
PATH="$HOME/bin:$PATH" jq . workspaces/<job-id>/EVALS/ledger.jsonl

# スコア推移
grep "SCORE_" logs/*.log | grep -E "BEFORE|AFTER"
```

---

*このガイドは Experiment #6 (plateau_stop 確認済み) の結果を元に作成。*
*Round 15 — 2026-03-11*
