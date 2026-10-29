// Pure data helpers for Quick Apps: the on-disk config shape, the edits the
// panel performs on it, and the first-run seed. Kept out of QML so the rules
// about what a valid config is live in one place and can be reasoned about
// without a running shell.
.pragma library

var CONFIG_VERSION = 1

// ------------------------------------------------------------------ limits
//
// Everything that comes off disk is bounded before it is cloned, sorted,
// rendered or written back. The file is the user's to hand-edit, which is
// exactly why it is treated as input: a category list a hundred thousand deep,
// or a name a megabyte long, must cost the panel a truncation rather than the
// shell's memory. The caps are far above any hand-built launcher and far below
// anything that hurts.

var LIMITS = {
  fileBytes: 262144,     // 256 KiB of JSON, before it is parsed
  categories: 64,
  appsPerCategory: 256,
  totalApps: 1024,
  nameChars: 96,         // category name
  idChars: 96,           // category id, after slugging
  appIdChars: 255,       // a desktop-entry id; NAME_MAX bounds the real ones
  displayChars: 160      // any string taken from a desktop entry
}

function limits() {
  return LIMITS
}

// Trim, then cut to length. Used for everything that reaches a label.
function clampText(value, max) {
  var text = String(value || "").replace(/^\s+|\s+$/g, "")
  return text.length > max ? text.slice(0, max) : text
}

// Strings that arrive from a desktop entry rather than from our own file.
function clampDisplay(value) {
  return clampText(value, LIMITS.displayChars)
}

function emptyConfig() {
  return { version: CONFIG_VERSION, categories: [] }
}

function clone(config) {
  try {
    return JSON.parse(JSON.stringify(config))
  } catch (e) {
    return emptyConfig()
  }
}

function slug(name) {
  var value = String(name || "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "")
  if (value.length > LIMITS.idChars) value = value.replace(/-+$/g, "").slice(0, LIMITS.idChars).replace(/-+$/g, "")
  return value.length > 0 ? value : "category"
}

function uniqueId(base, taken) {
  var candidate = slug(base)
  var suffix = 2
  while (taken.indexOf(candidate) !== -1) {
    candidate = slug(base) + "-" + suffix
    suffix++
  }
  return candidate
}

function normalizeAppId(value) {
  var id = String(value || "").trim()
  if (id.slice(-8) === ".desktop") id = id.slice(0, -8)
  // Dropped rather than truncated: a cut id would silently name a different
  // application, and no desktop entry is this long in the first place.
  if (id.length > LIMITS.appIdChars) return ""
  return id
}

function isHexColor(value) {
  return /^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/.test(String(value || ""))
}

// Anything the user (or a hand-edited file) throws at us becomes a config with
// the shape the panel expects: named categories, unique ids, no duplicate or
// empty app ids.
function normalize(raw) {
  var out = emptyConfig()
  if (!raw || typeof raw !== "object") return out

  var categories = Array.isArray(raw.categories) ? raw.categories : []
  var takenIds = []
  var total = 0

  for (var i = 0; i < categories.length && out.categories.length < LIMITS.categories; i++) {
    var category = categories[i]
    if (!category || typeof category !== "object") continue

    var name = clampText(category.name, LIMITS.nameChars)
    if (name.length === 0) continue

    var apps = []
    var list = Array.isArray(category.apps) ? category.apps : []
    for (var j = 0; j < list.length && apps.length < LIMITS.appsPerCategory && total < LIMITS.totalApps; j++) {
      var appId = normalizeAppId(list[j])
      if (appId.length > 0 && apps.indexOf(appId) === -1) {
        apps.push(appId)
        total++
      }
    }

    var id = slug(category.id || name)
    if (takenIds.indexOf(id) !== -1) id = uniqueId(id, takenIds)
    takenIds.push(id)

    // 2.0 draws in the theme's two colours only, but a colour set by 1.x is
    // carried through untouched rather than silently stripped from the file.
    var color = isHexColor(category.color) ? String(category.color) : ""
    out.categories.push({ id: id, name: name, color: color, apps: apps })
  }

  return out
}

// True for a file too big to be a launcher's category list. Checked before
// JSON.parse, because the parse is itself the expensive part.
function tooLarge(text) {
  return String(text || "").length > LIMITS.fileBytes
}

function parse(text) {
  var raw = null
  if (tooLarge(text)) return null
  try {
    raw = JSON.parse(String(text || ""))
  } catch (e) {
    return null
  }
  return normalize(raw)
}

function isEmpty(config) {
  if (!config || !Array.isArray(config.categories)) return true
  for (var i = 0; i < config.categories.length; i++) {
    if (config.categories[i].apps.length > 0) return false
  }
  return config.categories.length === 0
}

function countApps(config) {
  var categories = (config && config.categories) || []
  var total = 0
  for (var i = 0; i < categories.length; i++) total += (categories[i].apps || []).length
  return total
}

function categoryIndex(config, categoryId) {
  var categories = (config && config.categories) || []
  for (var i = 0; i < categories.length; i++) {
    if (categories[i].id === categoryId) return i
  }
  return -1
}

// ---------------------------------------------------------------- mutations
//
// Every mutation returns a fresh config object rather than editing in place:
// QML only re-evaluates bindings when the property is reassigned.

function addCategory(config, name) {
  var next = clone(config)
  if (next.categories.length >= LIMITS.categories) return next
  var taken = next.categories.map(function(c) { return c.id })
  var label = clampText(name, LIMITS.nameChars) || "New category"
  next.categories.push({ id: uniqueId(label, taken), name: label, color: "", apps: [] })
  return next
}

function renameCategory(config, categoryId, name) {
  var next = clone(config)
  var index = categoryIndex(next, categoryId)
  if (index === -1) return next
  var label = clampText(name, LIMITS.nameChars)
  if (label.length === 0) return next
  next.categories[index].name = label
  return next
}

function removeCategory(config, categoryId) {
  var next = clone(config)
  var index = categoryIndex(next, categoryId)
  if (index !== -1) next.categories.splice(index, 1)
  return next
}

function moveCategory(config, categoryId, direction) {
  var next = clone(config)
  var index = categoryIndex(next, categoryId)
  var target = index + (direction < 0 ? -1 : 1)
  if (index === -1 || target < 0 || target >= next.categories.length) return next
  var moved = next.categories.splice(index, 1)[0]
  next.categories.splice(target, 0, moved)
  return next
}

// Drag-and-drop reordering. `targetIndex` is an insertion point in the list as
// it stands *before* the move — "put it in front of the category currently at
// this position", with `categories.length` meaning "at the end" — because that
// is what a drop indicator between two rows actually means.
function moveCategoryTo(config, categoryId, targetIndex) {
  var next = clone(config)
  var index = categoryIndex(next, categoryId)
  if (index === -1) return next
  var to = Math.max(0, Math.min(next.categories.length, Math.round(Number(targetIndex) || 0)))
  // Removing the dragged category first shifts everything after it up by one.
  if (to > index) to -= 1
  if (to === index) return next
  var moved = next.categories.splice(index, 1)[0]
  next.categories.splice(to, 0, moved)
  return next
}

function addApp(config, categoryId, appId) {
  var next = clone(config)
  var index = categoryIndex(next, categoryId)
  var id = normalizeAppId(appId)
  if (index === -1 || id.length === 0) return next
  if (next.categories[index].apps.length >= LIMITS.appsPerCategory) return next
  if (countApps(next) >= LIMITS.totalApps) return next
  if (next.categories[index].apps.indexOf(id) === -1) next.categories[index].apps.push(id)
  return next
}

function removeApp(config, categoryId, appId) {
  var next = clone(config)
  var index = categoryIndex(next, categoryId)
  if (index === -1) return next
  var apps = next.categories[index].apps
  var at = apps.indexOf(normalizeAppId(appId))
  if (at !== -1) apps.splice(at, 1)
  return next
}

function moveApp(config, categoryId, appId, direction) {
  var next = clone(config)
  var index = categoryIndex(next, categoryId)
  if (index === -1) return next
  var apps = next.categories[index].apps
  var at = apps.indexOf(normalizeAppId(appId))
  var target = at + (direction < 0 ? -1 : 1)
  if (at === -1 || target < 0 || target >= apps.length) return next
  var moved = apps.splice(at, 1)[0]
  apps.splice(target, 0, moved)
  return next
}

// ------------------------------------------------------------------ queries

// How well `entry` answers `query`, 0 for not at all. Graded so the best
// answer is first and Enter can take it without looking:
//
//   100  the name starts with it          "fir"  → Firefox
//    85  a word in the name starts with it "code" → Visual Studio Code
//    75  it spells the words' initials     "vsc"  → Visual Studio Code
//    60  it is inside the name
//    40  it is inside the id or the description
//    20  its letters appear in order in the name  "obsd" → Obsidian
function matchScore(entry, query) {
  var needle = String(query || "").trim().toLowerCase()
  if (needle.length === 0) return 1
  var name = String(entry.name || "").toLowerCase()
  var words = name.split(/[^a-z0-9]+/).filter(function(w) { return w.length > 0 })

  if (name.indexOf(needle) === 0) return 100
  for (var i = 0; i < words.length; i++) if (words[i].indexOf(needle) === 0) return 85
  if (needle.length >= 2) {
    var initials = words.map(function(w) { return w.charAt(0) }).join("")
    if (initials.indexOf(needle) === 0) return 75
  }
  if (name.indexOf(needle) !== -1) return 60
  var rest = [entry.id, entry.detail].join(" ").toLowerCase()
  if (rest.indexOf(needle) !== -1) return 40
  if (needle.length >= 3) {
    var at = 0
    for (var j = 0; j < name.length && at < needle.length; j++) if (name.charAt(j) === needle.charAt(at)) at++
    if (at === needle.length) return 20
  }
  return 0
}

function matchesQuery(entry, query) {
  return matchScore(entry, query) > 0
}

// Turns the stored ids into rows the panel can render. `describe` resolves an
// id to { id, name, detail, icon, missing } against the desktop-entry index;
// entries whose .desktop file is gone still appear (greyed out) so the user
// can see what to remove instead of silently losing a tile. A search does not
// come through here — see `searchSections`.
//
// `rankOf`, when given, is a function from an id to a number that sorts each
// category's tiles high-to-low — the launch count, in practice. Ties keep the
// stored order, so switching the sort on does not scramble a category whose
// applications have never been opened.
function buildSections(config, describe, rankOf) {
  var sections = []
  var categories = (config && config.categories) || []
  var ranked = typeof rankOf === "function"
  var offset = 0

  for (var i = 0; i < categories.length; i++) {
    var category = categories[i]
    var rows = []
    for (var j = 0; j < category.apps.length; j++) {
      rows.push({ app: describe(category.apps[j]), order: j })
    }

    if (ranked) {
      rows.sort(function(a, b) {
        return (rankOf(b.app.id) - rankOf(a.app.id)) || (a.order - b.order)
      })
    }

    var apps = []
    for (var k = 0; k < rows.length; k++) apps.push(rows[k].app)
    // `offset` is where this section starts in the flattened list, so a tile
    // can tell whether the keyboard cursor is on it without a second walk.
    sections.push({
      id: category.id,
      name: category.name,
      apps: apps,
      total: category.apps.length,
      offset: offset
    })
    offset += apps.length
  }

  return sections
}

// A search is one ranked list, not the categories filtered: when you are
// typing, the question is "which one", and the answer belongs first, where
// Enter will take it. It reaches past the launcher into everything installed,
// so a search never dead-ends on an application you have not filed yet —
// yours rank above the rest at an equal match.
function searchSections(config, installed, query, describe, limit) {
  var rows = []
  var seen = {}
  var mine = allAppIds(config)
  for (var i = 0; i < mine.length; i++) {
    var entry = describe(mine[i])
    var score = matchScore(entry, query)
    seen[mine[i]] = true
    if (score > 0) rows.push({ app: entry, score: score + 15, order: i })
  }
  var list = installed || []
  for (var j = 0; j < list.length; j++) {
    if (seen[list[j].id]) continue
    var other = matchScore(list[j], query)
    if (other > 0) rows.push({ app: { id: list[j].id, name: list[j].name, detail: list[j].detail, icon: list[j].icon, missing: false, external: true }, score: other, order: mine.length + j })
  }
  rows.sort(function(a, b) { return (b.score - a.score) || (a.order - b.order) })
  var max = Math.max(1, Math.round(Number(limit) || 30))
  var apps = rows.slice(0, max).map(function(r) { return r.app })
  if (apps.length === 0) return []
  return [{ id: "__results", name: "Results", apps: apps, total: apps.length, offset: 0 }]
}

function flatten(sections) {
  var flat = []
  for (var i = 0; i < sections.length; i++) {
    for (var j = 0; j < sections[i].apps.length; j++) {
      flat.push({ categoryId: sections[i].id, app: sections[i].apps[j] })
    }
  }
  return flat
}

// Every application in the launcher, in panel order, de-duplicated: the input
// the usage table is reconciled against and the ranking is drawn from.
function allAppIds(config) {
  var ids = []
  var categories = (config && config.categories) || []
  for (var i = 0; i < categories.length; i++) {
    var apps = categories[i].apps || []
    for (var j = 0; j < apps.length; j++) {
      if (ids.indexOf(apps[j]) === -1) ids.push(apps[j])
    }
  }
  return ids
}

// --------------------------------------------------------------------- seed
//
// First-run content. An empty launcher is a dead end for someone who just
// installed the plugin, so the first open fills it from what is actually
// installed, using each entry's own XDG categories. Everything here is
// ordinary config afterwards — rename, remove, re-group at will.

var SEED_BUCKETS = [
  { name: "Internet", match: ["WebBrowser", "Email", "InstantMessaging", "Chat", "Network"] },
  { name: "Development", match: ["Development", "IDE", "TerminalEmulator"] },
  { name: "Media", match: ["AudioVideo", "Audio", "Video", "Player", "Graphics", "Photography"] },
  { name: "Office", match: ["Office", "WordProcessor", "Spreadsheet", "Presentation"] },
  { name: "System", match: ["Settings", "System", "FileManager", "Utility", "Security"] }
]

function bucketFor(categories) {
  var list = categories || []
  for (var i = 0; i < SEED_BUCKETS.length; i++) {
    for (var j = 0; j < list.length; j++) {
      if (SEED_BUCKETS[i].match.indexOf(String(list[j])) !== -1) return i
    }
  }
  return -1
}

function seed(entries, perCategory) {
  var limit = Math.max(1, Number(perCategory) || 6)
  var buckets = SEED_BUCKETS.map(function(bucket) { return { name: bucket.name, apps: [] } })
  var sorted = (entries || []).slice().sort(function(a, b) {
    return String(a.name || a.id).localeCompare(String(b.name || b.id))
  })

  for (var i = 0; i < sorted.length; i++) {
    var entry = sorted[i]
    if (!entry || entry.noDisplay) continue
    var index = bucketFor(entry.categories)
    if (index === -1) continue
    if (buckets[index].apps.length >= limit) continue
    buckets[index].apps.push(normalizeAppId(entry.id))
  }

  var config = emptyConfig()
  var taken = []
  for (var k = 0; k < buckets.length; k++) {
    if (buckets[k].apps.length === 0) continue
    var id = uniqueId(buckets[k].name, taken)
    taken.push(id)
    config.categories.push({ id: id, name: buckets[k].name, color: "", apps: buckets[k].apps })
  }

  // A machine with no categorised entries at all still gets a home to put
  // things in, rather than an empty panel with no way forward.
  if (config.categories.length === 0)
    config.categories.push({ id: "favourites", name: "Favourites", color: "", apps: [] })

  return config
}
