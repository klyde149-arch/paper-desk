#!/usr/bin/env bash
# ИИ-агент (бумага): тик диспетчера раз в 5 минут. Канон: docs/strategy/rf_ai_agent_design_2026-09.md,
# установка: deploy/README_AI_AGENT.md.
#
# Git только под замком RF-тика (/run/lock/live-rf-tick.lock), как мгновенный пуш ассистента:
# pull и commit не должны драться за index.lock с минутными тиками. Сам вызов модели идёт БЕЗ
# замка — он может длиться минуты. Не закоммиченное сейчас уедет следующим запуском через 5 минут.
set -u
source "$(dirname "$0")/lib_tick.sh"
tick_init || exit 0

exec 9>/run/lock/live-rf-tick.lock
if flock -w 50 9; then
  tick_pull
  flock -u 9
else
  echo "WARN: замок RF-тика занят - тик агента на локальном состоянии" >&2
fi

python3 -m ai_agent tick || echo "WARN: ai_agent tick rc=$?" >&2

if flock -w 50 9; then
  tick_commit_paths "ai-agent $(date -u '+%Y-%m-%d %H:%M') UTC" data/ai_agent agent_memory || true
  flock -u 9
else
  echo "WARN: замок RF-тика занят - публикация следующим запуском" >&2
fi
exit 0
