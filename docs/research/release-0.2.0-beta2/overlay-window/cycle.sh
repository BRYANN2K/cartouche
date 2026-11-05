#!/bin/zsh
# Opens and closes the menu N times; closing alternates Option-C and an Escape sent to Cartouche only
N=${1:-20}; D=${0:A:h}
C=$(pgrep -f "Cartouche.app/Contents/MacOS/Cartouche$")
for i in $(seq 1 $N); do
  print "$(gdate +%H:%M:%S.%3N) cycle $i open" >> $D/cycles.log
  osascript -e 'tell application "System Events" to keystroke "c" using option down'
  sleep 1.5
  if (( i % 2 )); then
    print "$(gdate +%H:%M:%S.%3N) cycle $i close optC" >> $D/cycles.log
    osascript -e 'tell application "System Events" to keystroke "c" using option down'
  else
    print "$(gdate +%H:%M:%S.%3N) cycle $i close esc" >> $D/cycles.log
    $D/esc $C
  fi
  sleep 2
done
print "$(gdate +%H:%M:%S.%3N) done" >> $D/cycles.log
