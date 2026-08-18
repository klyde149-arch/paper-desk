#!/usr/bin/env bash
# tick_alert.sh <unit> - OnFailure handler for the VPS tick units. Announces the one failure
# mode none of the in-tick watchdogs can ever report: the tick being killed as a whole.
#
# Why it is needed: every VPS-side guard lives INSIDE the tick. engine_watch fires only on a
# non-zero engine rc, and git_sync_watch runs from tick_finish - i.e. after the point of death.
# When systemd SIGTERMs the unit on TimeoutStartSec, none of them execute at all, so the tick
# dies mute. Incident 2026-08-18: three consecutive 15-minute publish marks were killed exactly
# that way (the candle bake used to run before the commit and blew the 110s budget when broker
# latency doubled), and the only signal that ever reached a human was the external Actions
# watchdog - 63 minutes later, claiming trade management had stopped when it never had.
#
# Same philosophy as the rest of deploy/: never fail. An OnFailure handler that fails itself
# would just add noise to journald, so every path exits 0.
set -u
unit="${1:-неизвестный юнит}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here/.." || exit 0
# tg_alert / tg_alert_all live here; the file is pure function definitions, safe to source.
# shellcheck disable=SC1091
. "$here/git_sync_watch.sh" 2>/dev/null || exit 0

result="$(systemctl show -p Result --value "$unit" 2>/dev/null)" || result=''
case "$result" in
  timeout) what='убит systemd по таймауту (не уложился в TimeoutStartSec)' ;;
  ''|success) what='завершился сбоем' ;;
  *)       what="завершился сбоем (Result=$result)" ;;
esac

# Deliberately does NOT claim positions are unmanaged: a killed tick usually means the engine
# already ran fine and only publication was lost. Pointing at the engine log first is what
# would have saved an hour of guessing on 2026-08-18.
msg="VPS: $unit $what. Состояние за этот цикл могло не опубликоваться, но движок при этом мог отработать штатно - сначала посмотрите хвост data/live_rf/tick_log.txt (фьючерсы) или data/live_real (крипта), потом journalctl -u $unit."

# Fan out to the futures chat only for the RF units, mirroring the fanout flag in live_watch.ps1.
case "$unit" in
  *rf*) tg_alert_all "$msg" ;;
  *)    tg_alert "$msg" ;;
esac
exit 0
