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

function normalizeEntry(raw, nowIso) {
  var entry = (raw && typeof raw === "object") ? raw : {}
  return {
    count: normalizeCount(entry.count),
    since: clampText(entry.since, LIMITS.stampChars) || clampText(nowIso, LIMITS.stampChars),
    last: clampText(entry.last, LIMITS.stampChars)
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
      next.apps[id] = { count: 0, since: String(nowIso || ""), last: "" }
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

function record(usage, appId, nowIso) {
  var id = String(appId || "")
  if (id.length === 0) return null
  var next = clone(usage)
  var entry = next.apps[id] || { count: 0, since: String(nowIso || ""), last: "" }
  entry.count = normalizeCount(entry.count) + 1
  entry.last = String(nowIso || "")
  if (!entry.since) entry.since = String(nowIso || "")
  next.apps[id] = entry
  return next
}

function reset(usage, nowIso) {
  var next = clone(usage)
  for (var id in next.apps) {
    next.apps[id] = { count: 0, since: String(nowIso || ""), last: "" }
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
