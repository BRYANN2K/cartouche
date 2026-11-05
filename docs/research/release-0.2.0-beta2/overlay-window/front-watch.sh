#!/bin/zsh
# Logs every change of the frontmost app, with milliseconds
last=""
while true; do
  n=$(lsappinfo info -only name "$(lsappinfo front)" 2>/dev/null | head -1 | cut -d\" -f2)
  if [[ "$n" != "$last" ]]; then print -r -- "$(gdate +%H:%M:%S.%3N 2>/dev/null || date +%T) $n" >> ~/Library/Caches/cartouche-night/focus-probe/front.log; last=$n; fi
  sleep 0.02
done
