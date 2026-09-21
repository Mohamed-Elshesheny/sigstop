#!/usr/bin/env bash
# Export the ten badges from the Swift source that defines them, so the landing
# site has something to vendor that cannot quietly disagree with the app.
#
# The site and the app now live in separate repositories and both print the same
# ten names. Nothing structural stopped them drifting, and a page advertising a
# badge the app does not have is exactly the kind of small lie this project is
# built to avoid. So:
#
#   1. Sources/SigstopCore/Badges/Badge.swift stays the single definition. It is
#      read here, never hand-transcribed.
#   2. Exports/badges.json is the machine-readable copy of it, committed, so the
#      site can vendor a file at a commit it can name instead of a paragraph it
#      has to trust.
#   3. `--check` diffs the two and fails. `make test` runs it, so renaming a
#      badge without regenerating the export stops the suite in this repository,
#      where the rename happened, rather than in the other one.
#
# Only the three fields that MUST be identical on both sides are exported: the
# stable id, the name as shown, and the motif the mark is drawn as. The prose
# around each badge is written twice on purpose, in each surface's own voice,
# and exporting it would turn deliberate difference into a false alarm.
#
#   ./Scripts/badges.sh            print the JSON
#   ./Scripts/badges.sh --check    fail if Exports/badges.json is out of date
#   make badges                    rewrite Exports/badges.json
set -uo pipefail

cd "$(dirname "$0")/.."

SOURCE="Sources/SigstopCore/Badges/Badge.swift"
EXPORT="Exports/badges.json"

[ -f "${SOURCE}" ] || { echo "error: ${SOURCE} not found" >&2; exit 1; }

# The two enums give `case name = "raw"` (or a bare case, whose raw value is the
# name). The catalogue gives `id:`, `title:` and `motif:` as Swift identifiers.
# Resolving one against the other is the whole job.
generate() {
  awk '
    function raw(line,   n, v) {
      if (line ~ /=/) {
        v = line
        sub(/^[^=]*=[ \t]*"/, "", v)
        sub(/".*$/, "", v)
        return v
      }
      n = line
      sub(/^[ \t]*case[ \t]+/, "", n)
      sub(/[ \t,].*$/, "", n)
      return n
    }
    function name(line,   n) {
      n = line
      sub(/^[ \t]*case[ \t]+/, "", n)
      sub(/[ \t]*=.*$/, "", n)
      sub(/[ \t,].*$/, "", n)
      return n
    }
    function esc(s) {
      gsub(/\\/, "\\\\", s)
      gsub(/"/, "\\\"", s)
      return s
    }

    /public enum BadgeID/  { section = "id";    next }
    /public enum BadgeMotif/ { section = "motif"; next }
    /public static let all: \[Badge\]/ { section = "catalogue"; next }
    /^}/ { if (section == "id" || section == "motif") section = "" }
    /^[ \t]*\][ \t]*$/ { if (section == "catalogue") section = "" }

    section == "id"    && /^[ \t]*case[ \t]/ { ids[name($0)]    = raw($0); next }
    section == "motif" && /^[ \t]*case[ \t]/ { motifs[name($0)] = raw($0); next }

    section == "catalogue" && /^[ \t]*id:[ \t]*\./ {
      v = $0; sub(/^[ \t]*id:[ \t]*\./, "", v); sub(/[ \t,].*$/, "", v)
      cur_id = v; next
    }
    section == "catalogue" && /^[ \t]*title:[ \t]*"/ {
      v = $0; sub(/^[ \t]*title:[ \t]*"/, "", v); sub(/".*$/, "", v)
      cur_title = v; next
    }
    section == "catalogue" && /^[ \t]*motif:[ \t]*\./ {
      v = $0; sub(/^[ \t]*motif:[ \t]*\./, "", v); sub(/[ \t,].*$/, "", v)
      if (cur_id == "" || cur_title == "") {
        print "badges.sh: a Badge( in the catalogue is missing an id or a title" > "/dev/stderr"
        exit 1
      }
      if (!(cur_id in ids)) {
        print "badges.sh: unknown BadgeID case ." cur_id > "/dev/stderr"
        exit 1
      }
      if (!(v in motifs)) {
        print "badges.sh: unknown BadgeMotif case ." v > "/dev/stderr"
        exit 1
      }
      n++
      out_id[n] = ids[cur_id]; out_title[n] = cur_title; out_motif[n] = motifs[v]
      cur_id = ""; cur_title = ""
      next
    }

    END {
      if (n == 0) { print "badges.sh: no badges found in the catalogue" > "/dev/stderr"; exit 1 }
      print "{"
      print "  \"schemaVersion\": 1,"
      print "  \"source\": \"app/Sources/SigstopCore/Badges/Badge.swift\","
      print "  \"badges\": ["
      for (i = 1; i <= n; i++) {
        printf "    { \"id\": \"%s\", \"name\": \"%s\", \"motif\": \"%s\" }%s\n", \
          esc(out_id[i]), esc(out_title[i]), esc(out_motif[i]), (i < n ? "," : "")
      }
      print "  ]"
      print "}"
    }
  ' "${SOURCE}"
}

if [ "${1:-}" = "--check" ]; then
  [ -f "${EXPORT}" ] || {
    echo "badges: ${EXPORT} does not exist. Run 'make badges'." >&2
    exit 1
  }
  if generate | diff -u "${EXPORT}" - >/dev/null; then
    echo "badges: ${EXPORT} matches ${SOURCE}"
    exit 0
  fi
  echo "badges: ${EXPORT} is out of date with respect to ${SOURCE}" >&2
  generate | diff -u "${EXPORT}" - >&2 || true
  cat >&2 <<'MSG'

The landing site vendors this file. Run 'make badges', commit the result, and
open the matching pull request on the site before the rename ships.
MSG
  exit 1
fi

generate
