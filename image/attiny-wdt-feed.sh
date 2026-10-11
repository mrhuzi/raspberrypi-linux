#!/bin/sh
# SmartEdge ATtiny hardware watchdog feeder.
# The attiny-wdt kernel driver starts the WDT at probe (faithful port of the
# Avnet BSP). User space must ping /dev/watchdog1 or the ATtiny resets the SoC.
#
# IMPORTANT: wait for the REAL character device. A plain shell redirection
# (exec 3>/dev/watchdog1) has O_CREAT semantics - if the driver has not probed
# yet, it would silently create a REGULAR FILE and the WDT would starve.
i=0
while [ ! -c /dev/watchdog1 ]; do
  sleep 1
  i=$((i + 1))
  if [ "$i" -gt 120 ]; then
    echo "attiny-wdt-feed: /dev/watchdog1 char device not present after 120s" >&2
    exit 1
  fi
done
exec 3>/dev/watchdog1
while :; do
  printf 'x' >&3 || exit 1
  sleep 15
done
