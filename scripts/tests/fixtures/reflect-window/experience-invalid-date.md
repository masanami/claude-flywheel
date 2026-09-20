---
name: invalid-date
description: 書式は合うが実在しない日付が reflected に入った experience
domain: reflect-window-fixture
metadata:
  type: experience
  outcome: bad
  target: skill:reflect
  signal: 日付の打ち間違い
  confidence: low
  reflected: 2026-02-30
---
実在しない日付なので**未処理**として拾われなければならない（fail-closed）。
