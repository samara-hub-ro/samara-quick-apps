// Launch statistics for Quick Apps: how many times each application in the
// launcher has been opened from it, and since when.
//
// The counter is deliberately scoped to the launcher, not to the machine: it
// starts at zero the moment an application is added to a category and is
// dropped when it is taken out again, so "18" always means "eighteen times
// since you put this here" rather than an opaque lifetime total the user has
// no way to reason about. `sync` is what enforces that rule.
//
// Kept out of QML for the same reason as AppsModel.js — the shape of the file
// and the rules over it are one place, testable without a running shell.
.pragma library

var USAGE_VERSION = 1

// The counts file is derived data, but it is still a file on disk that
// somebody can put anything into, so it is bounded exactly like the categories
// are: a fixed ceiling on entries, on id length and on the timestamps, checked
// before the table is cloned, ranked or written back. `apps` above the ceiling
// cannot happen from the launcher — `sync` prunes to the ids actually in it —
// so a file that carries more of them is by definition not ours.

var LIMITS = {
  fileBytes: 262144,   // 256 KiB of JSON, before it is parsed
  apps: 4096,
  idChars: 255,
  stampChars: 40       // an ISO-8601 instant, with room to spare
}

function limits() {
  return LIMITS
}

function clampText(value, max) {
  var text = String(value || "")
  return text.length > max ? text.slice(0, max) : text
}

function emptyUsage() {
  return { version: USAGE_VERSION, apps: {} }
}

function clone(usage) {
  try {
    return JSON.parse(JSON.stringify(usage))
  } catch (e) {
    return emptyUsage()
  }
}

function normalizeCount(value) {
  var count = Math.round(Number(value) || 0)
  if (!isFinite(count) || count < 0) return 0
  return count
}

// A fixed-length array of counts: the hour-of-day and day-of-week histograms
// the "now" suggestions are read from. Anything else — missing, the wrong
// length, junk in a slot — becomes zeros of the right length, so a file
// written by 1.x simply starts its rhythm from today.
function normalizeBuckets(value, length) {
  var out = []
  var list = Array.isArray(value) && value.length === length ? value : null
  for (var i = 0; i < length; i++) out.push(list ? normalizeCount(list[i]) : 0)
  return out
}

function freshEntry(nowIso) {
  return { count: 0, since: String(nowIso || ""), last: "", hours: normalizeBuckets(null, 24), days: normalizeBuckets(null, 7) }
}

function normalizeEntry(raw, nowIso) {
  var entry = (raw && typeof raw === "object") ? raw : {}
  return {
    count: normalizeCount(entry.count),
    since: clampText(entry.since, LIMITS.stampChars) || clampText(nowIso, LIMITS.stampChars),
    last: clampText(entry.last, LIMITS.stampChars),
    hours: normalizeBuckets(entry.hours, 24),
    days: normalizeBuckets(entry.days, 7)
  }
}

function normalize(raw, nowIso) {
  var out = emptyUsage()
  if (!raw || typeof raw !== "object") return out
  var apps = raw.apps
  if (!apps || typeof apps !== "object") return out
  var kept = 0
  for (var id in apps) {
    if (kept >= LIMITS.apps) break
    if (String(id).length === 0 || String(id).length > LIMITS.idChars) continue
    out.apps[id] = normalizeEntry(apps[id], nowIso)
    kept++
  }
  return out
}

function tooLarge(text) {
  return String(text || "").length > LIMITS.fileBytes
}

function parse(text, nowIso) {
  var raw = null
  if (tooLarge(text)) return null
  try {
    raw = JSON.parse(String(text || ""))
  } catch (e) {
    return null
  }
  return normalize(raw, nowIso)
}

// ---------------------------------------------------------------- mutations
//
// Like AppsModel, every mutation returns a fresh object — or `null` when there
// was nothing to change, so the caller can skip a pointless file write.

// Reconcile the table with the ids actually in the launcher. A newly added
// application starts counting from now; one that has been removed loses its
// history, so putting it back later starts over rather than resurrecting a
// stale number.
function sync(usage, ids, nowIso) {
  var next = clone(usage)
  var wanted = {}
  var changed = false

  for (var i = 0; i < (ids || []).length; i++) {
    var id = String(ids[i] || "")
    if (id.length === 0) continue
    wanted[id] = true
    if (!next.apps[id]) {
      next.apps[id] = freshEntry(nowIso)
      changed = true
    }
  }

  for (var key in next.apps) {
    if (wanted[key]) continue
    delete next.apps[key]
    changed = true
  }

  return changed ? next : null
}

// `hour` (0-23) and `day` (0-6, Sunday first) are local time, passed in by the
// caller: this file has no business knowing the time zone.
function bump(entry, hour, day) {
  var h = Math.round(Number(hour))
  var d = Math.round(Number(day))
  if (h >= 0 && h < 24) entry.hours[h] = normalizeCount(entry.hours[h]) + 1
  if (d >= 0 && d < 7) entry.days[d] = normalizeCount(entry.days[d]) + 1
}

function record(usage, appId, nowIso, hour, day) {
  var id = String(appId || "")
  if (id.length === 0) return null
  var next = clone(usage)
  var entry = next.apps[id] ? normalizeEntry(next.apps[id], nowIso) : freshEntry(nowIso)
  entry.count = normalizeCount(entry.count) + 1
  entry.last = String(nowIso || "")
  if (!entry.since) entry.since = String(nowIso || "")
  bump(entry, hour, day)
  next.apps[id] = entry
  return next
}

// Switching to a window that is already open is not a launch — the count
// stays honest — but it is still "I wanted this, now", which is exactly what
// the rhythm is meant to learn.
function recordIntent(usage, appId, nowIso, hour, day) {
  var id = String(appId || "")
  if (id.length === 0 || !usage || !usage.apps || !usage.apps[id]) return null
  var next = clone(usage)
  var entry = normalizeEntry(next.apps[id], nowIso)
  bump(entry, hour, day)
  next.apps[id] = entry
  return next
}

function reset(usage, nowIso) {
  var next = clone(usage)
  for (var id in next.apps) {
    next.apps[id] = freshEntry(nowIso)
  }
  return next
}

// ------------------------------------------------------------------ queries

function entryOf(usage, appId) {
  if (!usage || !usage.apps) return null
  return usage.apps[String(appId || "")] || null
}

function countOf(usage, appId) {
  var entry = entryOf(usage, appId)
  return entry ? normalizeCount(entry.count) : 0
}

function lastOf(usage, appId) {
  var entry = entryOf(usage, appId)
  return entry ? String(entry.last || "") : ""
}

function sinceOf(usage, appId) {
  var entry = entryOf(usage, appId)
  return entry ? String(entry.since || "") : ""
}

function totalOf(usage, ids) {
  var total = 0
  for (var i = 0; i < (ids || []).length; i++) total += countOf(usage, ids[i])
  return total
}

// Most-launched first. Ties keep the order the ids arrived in — which is the
// order they sit in the panel — so a row of equal counts does not reshuffle
// itself every time the panel opens.
function ranked(usage, ids, limit) {
  var rows = []
  for (var i = 0; i < (ids || []).length; i++) {
    var id = String(ids[i] || "")
    if (id.length === 0) continue
    var count = countOf(usage, id)
    if (count <= 0) continue
    rows.push({ id: id, count: count, order: i })
  }
  rows.sort(function(a, b) { return (b.count - a.count) || (a.order - b.order) })
  var max = Math.max(1, Math.round(Number(limit) || 5))
  return rows.slice(0, max)
}

// ---------------------------------------------------------------- rhythm
//
// What you are most likely to want *now*. Each launch lands in an hour-of-day
// and a day-of-week bucket; the score for the current moment reads the hour
// histogram through a circular Gaussian (so 08:55 still benefits from a habit
// at 09:00) and scales it by how much this weekday favours the application.
// The all-time count is a small tie-breaker — and the whole answer for a file
// that predates the histograms, so an upgrade does not start from a blank row.

var RHYTHM_SIGMA = 1.25   // hours

function hourAffinity(hours, hour) {
  var total = 0
  for (var h = 0; h < 24; h++) {
    var n = Number(hours[h]) || 0
    if (n <= 0) continue
    var d = Math.abs(h - hour)
    d = Math.min(d, 24 - d)
    total += n * Math.exp(-(d * d) / (2 * RHYTHM_SIGMA * RHYTHM_SIGMA))
  }
  return total
}

function dayAffinity(days, day) {
  var sum = 0
  for (var i = 0; i < 7; i++) sum += Number(days[i]) || 0
  if (sum < 7) return 1   // not enough to say anything about weekdays yet
  var share = (Number(days[day]) || 0) * 7 / sum
  return Math.max(0.5, Math.min(2, share))
}

function scoreAt(entry, hour, day) {
  if (!entry) return 0
  var hours = Array.isArray(entry.hours) ? entry.hours : []
  var days = Array.isArray(entry.days) ? entry.days : []
  return hourAffinity(hours, hour) * dayAffinity(days, day) + 0.05 * normalizeCount(entry.count)
}

// Ids ranked for this moment, highest first, zero scores left out. Ties keep
// panel order, like `ranked`.
function predict(usage, ids, hour, day, limit) {
  var rows = []
  for (var i = 0; i < (ids || []).length; i++) {
    var id = String(ids[i] || "")
    if (id.length === 0) continue
    var score = scoreAt(entryOf(usage, id), hour, day)
    if (score <= 0) continue
    rows.push({ id: id, score: score, order: i })
  }
  rows.sort(function(a, b) { return (b.score - a.score) || (a.order - b.order) })
  var max = Math.max(1, Math.round(Number(limit) || 5))
  return rows.slice(0, max)
}
