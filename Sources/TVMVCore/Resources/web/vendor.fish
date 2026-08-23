#!/usr/bin/env fish
#
# vendor.fish — download every asset listed in vendor.json into ./vendor/
# so tvmv renders fully offline. Reads vendor.json next to this script.
#
# Usage:  ./vendor.fish        (run from anywhere; paths are resolved relative
#                               to the script's own directory)
#
# Requires: curl, and one JSON reader — jq (preferred) or python3.

set -l script_dir (dirname (status --current-filename))
set -l manifest "$script_dir/vendor.json"
set -l vendor_dir "$script_dir/vendor"

if not test -f "$manifest"
    echo "error: manifest not found at $manifest" >&2
    exit 1
end

# Build a flat list of "src<TAB>dest" lines from the manifest.
set -l pairs
if type -q jq
    set pairs (jq -r '.[].files[] | "\(.src)\t\(.dest)"' "$manifest")
else if type -q python3
    set pairs (python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for pkg in data:
    for entry in pkg["files"]:
        print(entry["src"] + "\t" + entry["dest"])
' "$manifest")
else
    echo "error: need either jq or python3 to parse vendor.json" >&2
    exit 1
end

mkdir -p "$vendor_dir"

set -l total (count $pairs)
set -l ok 0
set -l failed

echo "Downloading $total files into $vendor_dir"

for line in $pairs
    set -l src (string split -m1 \t -- $line)[1]
    set -l dest (string split -m1 \t -- $line)[2]
    set -l out "$vendor_dir/$dest"

    mkdir -p (dirname "$out")

    # -f: fail on HTTP error; -L: follow redirects; --retry for transient errors.
    if curl -fsSL --retry 3 --retry-delay 1 -o "$out" -- "$src"
        set ok (math $ok + 1)
        echo "  ok   $dest"
    else
        set -a failed "$dest"
        echo "  FAIL $dest  <- $src" >&2
    end
end

echo "Done: $ok/$total downloaded."

if test (count $failed) -gt 0
    echo "Failed files:" >&2
    for f in $failed
        echo "  $f" >&2
    end
    exit 1
end
