#!/bin/zsh
set -u

app_path="${HERDR_APP_PATH:-/Applications/Herdr.app}"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist" 2>/dev/null)"
bundle_id="${bundle_id:-org.herdr.companion.macos}"
if [[ "$bundle_id" != [A-Za-z0-9]* || "$bundle_id" == *[^A-Za-z0-9.-]* ]]; then
  print 'Invalid app bundle identifier.' >&2
  exit 1
fi
log_predicate="subsystem == \"$bundle_id\""
timestamp="$(date +%Y%m%d-%H%M%S)"
folder="$HOME/Library/Logs/Herdr/hang-$timestamp"
mkdir -p "$folder"

pid="$(pgrep -f 'herdr-harness-mac.app/Contents/MacOS' | head -1)"
if [[ "${1:-}" == "--post-mortem" || -z "$pid" ]]; then
  diagnostics_dir="$HOME/Library/Containers/$bundle_id/Data/Library/Logs/Herdr"
  if [[ -d "$diagnostics_dir" ]]; then
    cp -R "$diagnostics_dir" "$folder/container-logs" || print 'Container diagnostics copy failed (non-fatal).' >> "$folder/container-logs-copy.txt"
  else
    print 'No container diagnostics directory found (non-fatal).' > "$folder/container-logs-copy.txt"
  fi
  /usr/bin/log show --last 30m --predicate "$log_predicate" --style compact > "$folder/perf-log-30m.txt" 2>&1 || print 'Log capture failed (non-fatal).' >> "$folder/perf-log-30m.txt"
  print "Post-mortem hang capture written to: $folder"
  exit 0
fi

sample "$pid" 10 -file "$folder/sample.txt"
footprint "$pid" > "$folder/footprint.txt" 2>&1
vmmap -summary "$pid" > "$folder/vmmap-summary.txt" 2>&1
heap "$pid" -sortBySize 2>&1 | head -60 > "$folder/heap.txt" || print 'heap capture failed (this is non-fatal).' >> "$folder/heap.txt"
/usr/bin/log show --last 15m --predicate "$log_predicate" --style compact > "$folder/perf-log.txt" 2>&1

if sudo -n true 2>/dev/null; then
  sudo -n spindump "$pid" 5 -file "$folder/spindump.txt"
else
  print 'Skipped spindump: passwordless sudo is unavailable.' > "$folder/spindump.txt"
fi

print "Hang capture written to: $folder"
print 'Main thread hint:'
awk '/Call graph:/ { found = 1; next } found && count < 15 { print; count++ }' "$folder/sample.txt"
