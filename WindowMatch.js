// Mapping a window's class back to a desktop entry the launcher holds.
//
// This is the guesswork at the heart of counting launches the panel did not
// make itself: a Wayland compositor announces a new window and its `app_id`,
// and nothing anywhere states which `.desktop` entry started it. The rules
// below are what recovers that, and the one that matters most is the last:
// when a window looks like two different applications, this credits neither.
// A count quietly attributed to the wrong application is worse than a count
// not taken, because the user has no way to notice the first and no way to
// correct it afterwards.
//
// Kept out of QML so the rules can be run against a real machine's desktop
// entries and window classes without a shell.
.pragma library

function flatten(value) {
  return String(value || "").toLowerCase().replace(/[^a-z0-9]+/g, "")
}

// Chromium's packaged entry ships the literal template placeholder
// `@@startup_wm_class`, and it is not the only one — anything still carrying
// the markers is a packaging bug, not a class.
function startupClassOf(entry) {
  var value = entry ? String(entry.startupClass || "") : ""
  return value.indexOf("@@") !== -1 ? "" : value
}

function suffixOf(id) {
  var value = String(id || "")
  var dot = value.lastIndexOf(".")
  return dot === -1 ? "" : value.slice(dot + 1)
}

// `ids` are the launcher's own application ids — nothing else is ever a
// candidate, which keeps the search small and means an application the user
// has not put in the panel can never be mistaken for one they have.
//
// `lookup` resolves an id to { startupClass, name } or null.
//
// Returns the matching id, or "" for "cannot tell".
function resolve(rawClass, ids, lookup) {
  var cls = String(rawClass || "").replace(/^\s+|\s+$/g, "")
  if (cls.length === 0) return ""

  var lower = cls.toLowerCase()
  var flat = flatten(cls)
  var list = ids || []

  // Strongest first: the entry's own declared window class, then its id, then
  // the last segment of a reverse-DNS id (`org.kde.kate` maps a window whose
  // class is just `kate`), then a loose comparison with case and punctuation
  // thrown away (`LM-Studio` for "LM Studio").
  var byStartupClass = []
  var byId = []
  var bySuffix = []
  var loosely = []

  for (var i = 0; i < list.length; i++) {
    var id = String(list[i])
    var entry = lookup ? lookup(id) : null
    var startup = startupClassOf(entry)
    var name = entry ? String(entry.name || "") : ""

    if (startup.length > 0 && startup.toLowerCase() === lower) byStartupClass.push(id)
    if (id.toLowerCase() === lower) byId.push(id)

    var suffix = suffixOf(id)
    if (suffix.length > 0 && suffix.toLowerCase() === lower) bySuffix.push(id)

    if ((name.length > 0 && flatten(name) === flat)
        || flatten(id) === flat
        || (startup.length > 0 && flatten(startup) === flat)) loosely.push(id)
  }

  var tiers = [byStartupClass, byId, bySuffix, loosely]
  for (var t = 0; t < tiers.length; t++) {
    if (tiers[t].length === 1) return tiers[t][0]
    // Ambiguous at the strongest tier that matched at all: two applications
    // both look like this window, so there is no honest way to pick one.
    if (tiers[t].length > 1) return ""
  }
  return ""
}
