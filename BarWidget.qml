import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import Quickshell.Wayland
import "AppsModel.js" as Model
import "UsageModel.js" as Usage
import "WindowMatch.js" as Match

// Quick Apps — the apps you actually use, grouped into your own categories,
// one hover away from the bar.
//
// Five things shape the implementation:
//
//   * It opens on hover, so the popup surface must leave the bar's own hover
//     alone. AppsPanel narrows the layer-shell input region to the card for
//     exactly that reason; this widget then decides "open" from the union of
//     the icon's hover and the card's, with a short delay on each edge so
//     crossing the gap between them doesn't flicker.
//   * It also opens from a keybinding, over IPC. That open claims keyboard
//     focus and lights up arrow-key navigation and type-to-filter; the hover
//     open deliberately does not, so a stray cursor never eats a keystroke.
//   * The app list is the user's, edited in place. It lives in its own JSON
//     file rather than in shell.json, because it is content rather than
//     configuration and the panel rewrites it as you add and remove tiles.
//   * It counts what it launches, in a second file beside the first. The count
//     is scoped to the launcher — it starts when an application is added to a
//     category — which is what lets the panel put the ones you reach for most
//     at the top without pretending to know anything about the rest of your
//     session.
//   * It draws in two colours, both the theme's: popup text and accent. The
//     accent is reserved for what is live or chosen — an application that is
//     already open, the keyboard cursor, the "now" row — so it always means
//     something when it appears.
Panel {
  id: root

  moduleName: "samara-hub-ro.quick-apps"
  // The IPC surface is ours: `toggle` from a keybinding has to arrive as a
  // keyboard open, which the base Panel's generic handler knows nothing about.
  manageIpc: false

  // Panel is a bare Item with no intrinsic size; the bar would lay this out as
  // 0x0. Take the size from the button, like the first-party popup widgets.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---------------------------------------------------------------- settings

  readonly property bool openOnHover: setting("openOnHover", true) === true
  readonly property int hoverOpenDelay: Math.max(0, Math.round(Number(setting("hoverOpenDelay", 140))))
  readonly property int hoverCloseDelay: Math.max(0, Math.round(Number(setting("hoverCloseDelay", 280))))
  readonly property real surfaceOpacity: Util.clampAlpha(Number(setting("backgroundOpacity", 100)) / 100)
  readonly property int iconSize: Math.max(16, Math.round(Number(setting("iconSize", 30))))
  readonly property int columns: Math.max(2, Math.round(Number(setting("columns", 5))))
  readonly property bool showLabels: setting("showLabels", true) === true
  readonly property int maxHeight: Math.max(Style.space(160), Math.round(Number(setting("maxHeight", 520))))
  // Empty means the drawn mark: a downward triangle with an S cut out of it.
  // Any glyph put here replaces it, which is how the old default is restored.
  readonly property string barIcon: String(setting("icon", ""))
  readonly property bool seedOnFirstRun: setting("seedOnFirstRun", true) === true

  readonly property bool showSuggestions: setting("showSuggestions", true) === true
  readonly property int suggestionCount: Math.max(1, Math.min(8, Math.round(Number(setting("suggestionCount", 5)))))
  readonly property bool sortByUsage: setting("sortByUsage", true) === true
  readonly property bool countExternalLaunches: setting("countExternalLaunches", true) === true
  readonly property bool showDetails: setting("showDetails", true) === true
  readonly property int detailsDelay: Math.max(0, Math.round(Number(setting("detailsDelay", 450))))
  readonly property bool showRunning: setting("showRunning", true) === true
  readonly property bool showMonitor: setting("showMonitor", true) === true
  readonly property bool focusRunning: setting("focusRunning", true) === true

  // Both files live inside Omarchy's own config directory, and the setting
  // names one of them rather than pointing anywhere. A widget that rewrites a
  // file on every launch has no business following an arbitrary path: a name
  // cannot traverse out of the directory, cannot select a file that is not
  // ours, and leaves nothing to check for ownership or a symlinked ancestor
  // that QML has no way to check for anyway. Anything else falls back to the
  // default instead of being honoured half-way.
  readonly property string configDir: Quickshell.env("HOME") + "/.config/omarchy"
  readonly property string defaultConfigName: "quick-apps.json"

  // A bare name ("work.json") or, because that is the value the settings
  // dialog shows, the full path of a file in that same directory.
  function configNameFor(value) {
    var raw = String(value || "").replace(/^\s+|\s+$/g, "")
    if (raw.length === 0) return root.defaultConfigName

    var name = raw
    if (name.charAt(0) === "~") name = Quickshell.env("HOME") + name.slice(1)
    var prefix = root.configDir + "/"
    if (name.indexOf(prefix) === 0) name = name.slice(prefix.length)

    // One path segment, no dot-file, no traversal, a name we recognise, and
    // never the `-usage.json` suffix — that one belongs to the counts, and
    // keeping the two namespaces disjoint is what makes it impossible for a
    // count write to land on the categories.
    var ok = name.length > 0 && name.length <= 64
      && /^[A-Za-z0-9][A-Za-z0-9._-]*\.json$/.test(name)
      && name.indexOf("..") === -1
      && !/-usage\.json$/i.test(name)

    if (!ok) {
      console.warn("quick-apps: ignoring the categories file setting " + JSON.stringify(raw)
        + " — it has to be the name of a .json file in " + root.configDir
        + ", so " + root.defaultConfigName + " is being used instead")
      return root.defaultConfigName
    }
    return name
  }

  readonly property string configName: root.configNameFor(setting("configPath", ""))
  readonly property string configPath: root.configDir + "/" + root.configName

  // Counts live beside the categories rather than inside them: they change on
  // every launch, and a rewrite-per-launch of the file the user hand-edits is
  // a good way to lose a hand edit. `configName` can never carry the
  // `-usage.json` suffix, so the two are distinct by construction; the guard
  // is there because "distinct by construction" is worth failing loudly over.
  readonly property string usagePath: {
    var candidate = root.configDir + "/" + root.configName.replace(/\.json$/i, "") + "-usage.json"
    if (candidate === root.configPath) {
      console.warn("quick-apps: refusing to use the categories file for the counts")
      return root.configDir + "/quick-apps-usage.json"
    }
    return candidate
  }

  // ------------------------------------------------------------------- state

  property var config: Model.emptyConfig()
  property bool configLoaded: false
  // Set only once we have actually read an authoritative config — a file that
  // parsed, or one that is genuinely not there yet. A file we failed to parse
  // leaves this false, which is what stops the usage table from being pruned
  // against a config we do not really know.
  property bool configAuthoritative: false
  property bool savingConfig: false
  property bool seedAttempted: false

  property var usage: Usage.emptyUsage()
  property bool usageLoaded: false
  property bool savingUsage: false

  property bool keyboardMode: false
  property bool editMode: false
  property string filterText: ""
  property string pickerCategory: ""
  property int selectedIndex: -1
  property bool cursorActive: false

  // Drag-to-reorder bookkeeping. The move is committed on release rather than
  // live: rewriting the config mid-drag rebuilds the Repeater, which destroys
  // the very delegate holding the pressed pointer.
  property string dragCategoryId: ""
  property int dragFromIndex: -1
  property int dragToIndex: -1
  property bool dragActive: false
  property var dragRows: []

  // Hover bookkeeping. `hoverArmed` goes down after a deliberate close so the
  // panel doesn't spring straight back up under a cursor that never moved;
  // `pointerEngaged` records that the cursor has actually been on the panel,
  // which is what makes a keyboard-summoned panel closeable by moving away.
  property bool hoverArmed: true
  property bool pointerEngaged: false

  // Bumped when the desktop-entry set changes so name/icon lookups re-run.
  property int appsRevision: 0

  // The whole palette: the theme's popup text and its accent. Both are live
  // bindings to the current Omarchy theme, so switching themes recolours the
  // panel with it and nothing here ever names a colour of its own.
  readonly property color panelForeground: Color.popups.text
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(panelForeground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property bool pickerOpen: pickerCategory !== ""
  readonly property bool busyEditing: editMode || pickerOpen

  // ------------------------------------------------------- desktop entries

  // The shell's own app library, when the running bar exposes it: it gives us
  // the same icon resolution and launch path as the Omarchy menu, including
  // the launch OSD. Third-party bars may not, so every use has a fallback.
  property var appLibrary: null

  function resolveAppLibrary() {
    try {
      if (bar && bar.shell && bar.shell.appLibrary) return bar.shell.appLibrary
    } catch (e) {}
    return null
  }

  onBarChanged: appLibrary = resolveAppLibrary()
  Component.onCompleted: {
    appLibrary = resolveAppLibrary()
    // Nothing reads either file until this runs: with `blockAllReads` the
    // views never load one on their own.
    configReader.reload()
    usageReader.reload()
  }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { root.appsRevision++ }
  }

  function iconFor(name) {
    var value = String(name || "")
    if (root.appLibrary) return root.appLibrary.iconSource(value)
    if (value.length === 0) return Quickshell.iconPath("application-x-executable", true)
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    var themed = Quickshell.iconPath(value, true)
    return themed.length > 0 ? themed : Quickshell.iconPath("application-x-executable", true)
  }

  // Resolves a stored id for display. Entries whose .desktop file is gone are
  // still returned, flagged, so a tile for an uninstalled app is visible and
  // removable instead of silently vanishing.
  function describe(id) {
    root.appsRevision  // binding dependency
    var entry = null
    try { entry = DesktopEntries.byId(id) } catch (e) { entry = null }
    if (!entry) return { id: id, name: Model.clampDisplay(id), detail: "", icon: "", missing: true }
    // Clamped for the same reason the config is: a .desktop file is somebody
    // else's text, and every one of these strings ends up in a label.
    return {
      id: id,
      name: Model.clampDisplay(entry.name || id),
      detail: Model.clampDisplay(entry.genericName || entry.comment || ""),
      icon: Model.clampDisplay(entry.icon || ""),
      missing: false
    }
  }

  function installedEntries() {
    root.appsRevision  // binding dependency
    var values = []
    try { values = DesktopEntries.applications.values || [] } catch (e) { values = [] }

    var rows = []
    for (var i = 0; i < values.length; i++) {
      var entry = values[i]
      if (!entry || entry.noDisplay) continue
      if (root.appLibrary && typeof root.appLibrary.isHiddenEntry === "function" && root.appLibrary.isHiddenEntry(entry)) continue
      var appId = Model.normalizeAppId(entry.id)
      if (appId.length === 0) continue
      rows.push({
        id: appId,
        name: Model.clampDisplay(entry.name || entry.id),
        detail: Model.clampDisplay(entry.genericName || entry.comment || ""),
        icon: Model.clampDisplay(entry.icon || ""),
        categories: entry.categories ? Array.prototype.slice.call(entry.categories, 0, 32) : [],
        noDisplay: false
      })
    }

    rows.sort(function(a, b) { return a.name.localeCompare(b.name) })
    return rows
  }

  // A click on an application that is already open switches to it instead of
  // starting a second copy — the common case for a launcher you reach for all
  // day. With several windows open, each click moves on to the next one.
  // Middle-click (`launchNew`) always starts a new one.
  function activateApp(app) {
    if (!app || !app.id) return
    var windows = root.focusRunning ? root.windowsOf(app.id) : []
    if (windows.length === 0) {
      root.launchNew(app)
      return
    }
    var next = 0
    for (var i = 0; i < windows.length; i++) {
      if (windows[i].activated) { next = (i + 1) % windows.length; break }
    }
    root.recordIntent(app.id)
    root.close()
    try { windows[next].activate() } catch (e) { root.launchNew(app) }
  }

  function launchNew(app) {
    if (!app || !app.id) return
    root.recordLaunch(app.id)
    // The window this is about to open would otherwise be counted again when
    // it maps. The panel's own count is the certain one; the watcher's is the
    // inference, so the inference stands down.
    windowWatcher.suppress(app.id)
    root.close()

    if (root.appLibrary && typeof root.appLibrary.launch === "function") {
      root.appLibrary.launch(app.id, app.name)
      return
    }

    var entry = null
    try { entry = DesktopEntries.byId(app.id) } catch (e) { entry = null }
    if (entry && typeof entry.execute === "function") {
      entry.execute()
      return
    }

    Quickshell.execDetached(["gtk-launch", app.id + ".desktop"])
  }

  // ------------------------------------------------------------------ config

  // Sorting is a live binding on the counts, not a rewrite of the config: the
  // stored order stays exactly as the user arranged it, and turning the sort
  // off puts it straight back.
  readonly property var sections: root.filterText.length > 0
    ? Model.searchSections(root.config, root.installedEntries(), root.filterText,
        function(id) { return root.describe(id) }, root.columns * 4)
    : Model.buildSections(root.config,
        function(id) { return root.describe(id) },
        root.sortByUsage ? function(id) { return Usage.countOf(root.usage, id) } : null)
  readonly property var flatApps: Model.flatten(root.sections)

  // Deliberately a function, not a `readonly property var` bound to `config`.
  // `syncUsage` runs from `onConfigChanged`, and a signal handler is not
  // ordered against the re-evaluation of bindings on the same property — a
  // derived property read from there hands back the *previous* config, which
  // inverts every add and remove. A call is always current.
  function currentAppIds() { return Model.allAppIds(root.config) }

  function applyConfigText(text) {
    if (Model.tooLarge(text)) {
      // Bounded before the parse, which is the expensive half. Left on disk
      // untouched, and the panel keeps what it already has.
      console.warn("quick-apps: " + root.configPath + " is larger than "
        + Math.round(Model.limits().fileBytes / 1024) + " KiB, ignoring it")
      root.configLoaded = true
      return
    }
    var parsed = Model.parse(text)
    if (parsed === null) {
      // Unreadable file: keep whatever is on screen rather than wiping the
      // panel, and leave the file alone so the user can fix it by hand.
      console.warn("quick-apps: " + root.configPath + " is not valid JSON, ignoring it")
      root.configLoaded = true
      return
    }
    root.config = parsed
    root.configLoaded = true
    root.configAuthoritative = true
  }

  // A file the reader refused. "missing" is the ordinary first-run state — no
  // file yet, so an empty launcher is the truth rather than a failure to read
  // one. Anything else is a file that is there and is not ours to trust, which
  // leaves the config non-authoritative; that is what stops the counts from
  // being pruned against a config we do not actually know.
  function configUnavailable(reason) {
    root.configLoaded = true
    if (reason !== "missing")
      return
    root.configAuthoritative = true
    root.syncUsage()
  }

  function saveConfig(next) {
    root.config = next
    root.savingConfig = true
    saveGuard.restart()
    configFile.setText(JSON.stringify(next, null, 2) + "\n")
  }

  // First open on a fresh install: build a starting set from what is actually
  // installed instead of showing an empty card with no way forward.
  function ensureSeeded() {
    if (!root.seedOnFirstRun || root.seedAttempted) return
    if (!root.configLoaded || !Model.isEmpty(root.config)) return
    var entries = root.installedEntries()
    if (entries.length === 0) return
    root.seedAttempted = true
    root.saveConfig(Model.seed(entries, 6))
  }

  // The file is written here and read through the bounded reader beside it.
  // `blockAllReads` is what keeps those two apart: a FileView that reads opens
  // the path and materialises whatever is there before QML can check anything,
  // which is no boundary against a file that is not the one we wrote. What is
  // left is the write, which needs no read, and the change notification, which
  // is what tells the reader to run.
  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    blockAllReads: true
    onFileChanged: if (!root.savingConfig) configReader.reload()
  }

  BoundedFile {
    id: configReader
    path: root.configPath
    limit: Model.limits().fileBytes
    printErrors: true
    onLoaded: function(text) { root.applyConfigText(text) }
    onFailed: function(reason) { root.configUnavailable(reason) }
  }

  Timer {
    id: saveGuard
    interval: 600
    onTriggered: root.savingConfig = false
  }

  // ------------------------------------------------------------------- usage

  // Local hour and weekday, refreshed each time the panel opens: the "now"
  // row is a question about this moment, and a binding to the clock would
  // reshuffle it under the pointer.
  property int nowHour: 0
  property int nowDay: 0

  function refreshClock() {
    var d = new Date()
    root.nowHour = d.getHours()
    root.nowDay = d.getDay()
  }

  readonly property var suggestions: {
    if (!root.showSuggestions) return []
    var rows = Usage.predict(root.usage, root.currentAppIds(), root.nowHour, root.nowDay, root.suggestionCount)
    var out = []
    for (var i = 0; i < rows.length; i++) out.push(root.describe(rows[i].id))
    return out
  }

  readonly property string nowLabel: {
    var d = new Date()
    d.setHours(root.nowHour, 0, 0, 0)
    var days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    return days[root.nowDay] + ", " + d.toLocaleTimeString(Qt.locale(), "HH:mm")
  }

  function applyUsageText(text) {
    if (Usage.tooLarge(text)) {
      console.warn("quick-apps: " + root.usagePath + " is larger than "
        + Math.round(Usage.limits().fileBytes / 1024) + " KiB, starting the counts over")
      root.usage = Usage.emptyUsage()
      root.usageLoaded = true
      root.syncUsage()
      return
    }
    var parsed = Usage.parse(text, root.nowIso())
    if (parsed === null) {
      // Counts are derived data, not something the user wrote — a file that
      // does not parse is rebuilt from zero rather than left to rot silently.
      console.warn("quick-apps: " + root.usagePath + " is not valid JSON, starting the counts over")
      root.usage = Usage.emptyUsage()
      root.usageLoaded = true
      root.syncUsage()
      return
    }
    root.usage = parsed
    root.usageLoaded = true
    root.syncUsage()
  }

  function usageUnavailable(reason) {
    root.usage = Usage.emptyUsage()
    root.usageLoaded = true
    root.syncUsage()
  }

  function saveUsage(next) {
    root.usage = next
    root.savingUsage = true
    usageGuard.restart()
    usageFile.setText(JSON.stringify(next, null, 2) + "\n")
  }

  function nowIso() {
    try { return new Date().toISOString() } catch (e) { return "" }
  }

  // Keeps the table and the launcher in step: a newly added application starts
  // counting from now, a removed one loses its history. `sync` returns null
  // when nothing moved, so the ordinary case writes no file at all.
  function syncUsage() {
    if (!root.usageLoaded || !root.configAuthoritative) return
    var next = Usage.sync(root.usage, root.currentAppIds(), root.nowIso())
    if (next === null) return
    root.saveUsage(next)
  }

  function recordLaunch(appId) {
    if (!root.usageLoaded) return
    var id = Model.normalizeAppId(appId)
    if (root.currentAppIds().indexOf(id) === -1) return
    var d = new Date()
    var next = Usage.record(root.usage, id, root.nowIso(), d.getHours(), d.getDay())
    if (next === null) return
    root.saveUsage(next)
  }

  function recordIntent(appId) {
    if (!root.usageLoaded) return
    var d = new Date()
    var next = Usage.recordIntent(root.usage, Model.normalizeAppId(appId), root.nowIso(), d.getHours(), d.getDay())
    if (next === null) return
    root.saveUsage(next)
  }

  function resetUsage() {
    if (!root.usageLoaded) return
    root.saveUsage(Usage.reset(root.usage, root.nowIso()))
  }

  onConfigChanged: root.syncUsage()
  onConfigAuthoritativeChanged: root.syncUsage()

  // Applications opened from anywhere else — a keybinding, the Omarchy menu, a
  // terminal — reach the counter through here.
  WindowWatcher {
    id: windowWatcher
    enabled: root.countExternalLaunches
    appIds: root.currentAppIds()

    onLaunched: function(appId) { root.recordLaunch(appId) }
  }

  // ----------------------------------------------------------------- running

  // Which launcher applications have a window open right now, as
  // id -> [Toplevel]. Worked out only while the panel is up, from the same
  // window-class rules the counter uses — including their refusal to guess
  // when a window could belong to two applications.
  property int toplevelRevision: 0

  Connections {
    target: ToplevelManager.toplevels
    function onObjectInsertedPost() { root.toplevelRevision++ }
    function onObjectRemovedPost() { root.toplevelRevision++ }
  }

  readonly property var runningMap: {
    root.toplevelRevision  // binding dependency
    if (!root.opened || (!root.showRunning && !root.focusRunning)) return ({})
    var values = []
    try { values = ToplevelManager.toplevels.values || [] } catch (e) { values = [] }
    var ids = root.currentAppIds()
    var map = {}
    for (var i = 0; i < values.length; i++) {
      var cls = ""
      try { cls = String(values[i].appId || "") } catch (e) { cls = "" }
      var id = Match.resolve(cls, ids, function(x) { return windowWatcher.entryFor(x) })
      if (id.length === 0) continue
      if (!map[id]) map[id] = []
      map[id].push(values[i])
    }
    return map
  }

  function windowsOf(appId) { return root.runningMap[appId] || [] }
  function windowCountOf(appId) { return root.showRunning ? root.windowsOf(appId).length : 0 }

  // ----------------------------------------------------------------- details

  AppInfo { id: appInfo }

  // The tile the details card is about, and where it sits on screen. Set on
  // hover (and on keyboard selection), shown after `detailsDelay`.
  //
  // Once the card is up it can be reached with the pointer — it carries the
  // Force quit button — and the way there crosses the other tiles in the row.
  // So a card that is already showing does not jump to every tile it passes:
  // it retargets only once the pointer has rested on a new tile for
  // `retargetDelay` — and not at all while the pointer is still travelling
  // inside the triangle between where it left its tile and the card's near
  // edge (the "safe triangle" of nested menus). Stopping on a tile, anywhere,
  // retargets; heading for the card never does.
  property var detailsApp: null
  property string detailsCategory: ""
  property real detailsAnchorY: 0
  property bool detailsShown: false

  property var pendingApp: null
  property string pendingCategory: ""
  property real pendingAnchorY: 0
  readonly property int retargetDelay: 220
  property point aimFrom: Qt.point(-1, -1)

  readonly property bool detailsVisible: root.showDetails && root.detailsShown && root.detailsApp !== null
    && root.opened && !root.busyEditing
  readonly property bool pointerOnDetails: root.detailsVisible && details.hovered

  function showDetailsFor(app, item, categoryName) {
    if (!root.showDetails || !app || !item || root.busyEditing) return
    detailsHideTimer.stop()
    var y = item.mapToItem(panel.overlayLayer, 0, item.height / 2).y
    if (!app.missing) appInfo.request(app.id)

    if (!root.detailsShown || !root.detailsApp) {
      root.setDetails(app, categoryName, y)
      detailsShowTimer.restart()
      return
    }
    if (root.detailsApp.id === app.id) {
      retargetTimer.stop()
      return
    }
    root.pendingApp = app
    root.pendingCategory = String(categoryName || "")
    root.pendingAnchorY = y
    retargetTimer.restart()
  }

  function setDetails(app, categoryName, y) {
    if (!root.detailsApp || root.detailsApp.id !== app.id) root.resetQuit()
    root.detailsApp = app
    root.detailsCategory = String(categoryName || "")
    root.detailsAnchorY = y
  }

  function leaveDetailsFor(app) {
    if (root.detailsShown && root.detailsApp && app && root.detailsApp.id === app.id) root.aimFrom = panel.pointer
    if (root.pendingApp && app && root.pendingApp.id === app.id) {
      retargetTimer.stop()
      root.pendingApp = null
    }
    if (!root.detailsShown) detailsShowTimer.stop()
    detailsHideTimer.restart()
  }

  function hideDetails() {
    detailsShowTimer.stop()
    detailsHideTimer.stop()
    retargetTimer.stop()
    root.pendingApp = null
    root.detailsShown = false
    root.detailsApp = null
    root.resetQuit()
  }

  onPointerOnDetailsChanged: {
    if (root.pointerOnDetails) {
      detailsHideTimer.stop()
      retargetTimer.stop()
      root.pendingApp = null
    } else if (root.detailsShown) {
      detailsHideTimer.restart()
    }
  }

  Timer {
    id: detailsShowTimer
    interval: root.detailsDelay
    onTriggered: if (root.detailsApp) root.detailsShown = true
  }

  function aimingAtDetails(p) {
    if (!root.detailsVisible || root.aimFrom.x < 0) return false
    var nearX = details.onRight ? details.x : details.x + details.width
    var ax = root.aimFrom.x, ay = root.aimFrom.y
    var bx = nearX, by = details.y - Style.space(12)
    var cx = nearX, cy = details.y + details.height + Style.space(12)
    function side(x1, y1, x2, y2, x3, y3) { return (x1 - x3) * (y2 - y3) - (x2 - x3) * (y1 - y3) }
    var d1 = side(p.x, p.y, ax, ay, bx, by)
    var d2 = side(p.x, p.y, bx, by, cx, cy)
    var d3 = side(p.x, p.y, cx, cy, ax, ay)
    var neg = d1 < 0 || d2 < 0 || d3 < 0
    var pos = d1 > 0 || d2 > 0 || d3 > 0
    return !(neg && pos)
  }

  // Every pointer move inside the triangle holds a pending retarget off.
  Connections {
    target: panel
    function onPointerChanged() {
      if (root.pendingApp && root.aimingAtDetails(panel.pointer)) retargetTimer.restart()
    }
  }

  Timer {
    id: retargetTimer
    interval: root.retargetDelay
    onTriggered: {
      if (!root.pendingApp) return
      root.setDetails(root.pendingApp, root.pendingCategory, root.pendingAnchorY)
      root.pendingApp = null
    }
  }

  // Grace for crossing the gaps — between tiles, and from a tile to the card.
  Timer {
    id: detailsHideTimer
    interval: 260
    onTriggered: if (!root.pointerOnDetails) root.hideDetails()
  }

  // ----------------------------------------------------------------- monitor

  ProcMonitor {
    id: procMonitor
    // Sampled in the background too, not only while the panel is open: the
    // traffic totals only mean "since opening" if connections are seen while
    // they are alive, and the sparkline has three minutes of history the
    // moment the panel appears.
    active: root.showMonitor
  }

  // Launcher id (or "class:<window class>" for anything else) -> the groups
  // its windows live in.
  readonly property var monitorApps: {
    procMonitor.revision  // binding dependency
    var ids = root.currentAppIds()
    var wins = procMonitor.windows
    var map = {}
    for (var i = 0; i < wins.length; i++) {
      var id = Match.resolve(wins[i].cls, ids, function(x) { return windowWatcher.entryFor(x) })
      var key = id.length > 0 ? id : "class:" + wins[i].cls
      // Not in the launcher: still worth a real name and icon in the list.
      var other = id.length > 0 ? "" : root.installedIdForClass(wins[i].cls)
      if (!map[key]) map[key] = { id: id, other: other, cls: wins[i].cls, groups: [] }
      if (map[key].groups.indexOf(wins[i].group) === -1) map[key].groups.push(wins[i].group)
    }
    return map
  }

  // Window class -> an installed desktop id, for windows of applications that
  // are not in the launcher. Same matching rules; remembered per class, since
  // the installed set is large and a class does not change its answer.
  // Mutated in place, never reassigned: it is read from inside the
  // `monitorApps` binding, and a reassignment there would be a binding loop.
  readonly property var classIdCache: ({})

  function installedIdForClass(cls) {
    var key = String(cls || "")
    if (key.length === 0) return ""
    if (root.classIdCache[key] !== undefined) return root.classIdCache[key]
    var ids = root.installedEntries().map(function(e) { return e.id })
    var id = Match.resolve(key, ids, function(x) { return windowWatcher.entryFor(x) })
    root.classIdCache[key] = id
    return id
  }

  function sumGroups(groups) {
    var found = []
    for (var i = 0; i < groups.length; i++) {
      var g = procMonitor.groups[groups[i]]
      if (g) found.push(g)
    }
    if (found.length === 0) return null

    var out = { cpu: 0, mem: 0, rx: 0, tx: 0, since: 0, history: [], primed: true }
    var longest = 0
    for (var j = 0; j < found.length; j++) longest = Math.max(longest, (found[j].history || []).length)
    for (var k = 0; k < longest; k++) out.history.push(0)

    for (var n = 0; n < found.length; n++) {
      var f = found[n]
      out.cpu += f.cpu
      out.mem += f.mem
      out.rx += f.rx
      out.tx += f.tx
      out.since = out.since === 0 ? f.since : Math.min(out.since, f.since)
      out.primed = out.primed && f.primed
      // Histories are right-aligned: the newest samples line up.
      var h = f.history || []
      var offset = longest - h.length
      for (var m = 0; m < h.length; m++) out.history[offset + m] += h[m]
    }
    return out
  }

  function statsFor(appId) {
    procMonitor.revision  // binding dependency
    var entry = root.monitorApps[appId]
    return entry ? root.sumGroups(entry.groups) : null
  }

  function groupsFor(appId) {
    var entry = root.monitorApps[appId]
    return entry ? entry.groups.slice() : []
  }

  readonly property var monitorRows: {
    var rows = []
    for (var key in root.monitorApps) {
      var entry = root.monitorApps[key]
      var stats = root.sumGroups(entry.groups)
      if (!stats) continue
      var app = entry.id.length > 0 ? root.describe(entry.id) : null
      var known = !app && entry.other.length > 0 ? root.describe(entry.other) : null
      rows.push({
        key: key,
        app: app,
        name: app ? app.name : (known ? known.name : entry.cls),
        icon: app ? app.icon : (known ? known.icon : entry.cls.toLowerCase()),
        stats: stats
      })
    }
    rows.sort(function(a, b) { return (b.stats.cpu - a.stats.cpu) || (b.stats.mem - a.stats.mem) })
    return rows
  }

  // Totals over groups, not rows: two applications sharing one scope are one
  // cost, not two.
  readonly property var monitorTotals: {
    procMonitor.revision  // binding dependency
    var cpu = 0, mem = 0
    for (var g in procMonitor.groups) { cpu += procMonitor.groups[g].cpu; mem += procMonitor.groups[g].mem }
    return { cpu: cpu, mem: mem }
  }

  readonly property real monitorMaxMem: {
    var m = 1
    for (var i = 0; i < root.monitorRows.length; i++) m = Math.max(m, root.monitorRows[i].stats.mem)
    return m
  }

  readonly property bool monitorVisible: root.showMonitor && !root.editMode && root.filterText.length === 0
    && root.monitorRows.length > 0

  function formatBytes(n) {
    var v = Number(n) || 0
    if (v < 1024) return Math.round(v) + " B"
    var units = ["KB", "MB", "GB", "TB"]
    var i = -1
    do { v /= 1024; i++ } while (v >= 1024 && i < units.length - 1)
    return (v >= 100 ? Math.round(v) : v.toFixed(1)) + " " + units[i]
  }

  function formatPercent(n) {
    var v = Number(n) || 0
    return (v > 0 && v < 0.1 ? "<0.1" : (v >= 10 ? Math.round(v) : v.toFixed(1))) + "%"
  }

  // ---- force quit ------------------------------------------------------
  //
  // First click arms, second sends SIGTERM to the application's whole scope.
  // If a window is still there three seconds later the button offers SIGKILL,
  // which is what a truly hung application needs.

  property string quitAppId: ""
  property string quitState: ""

  function resetQuit() {
    quitArmTimer.stop()
    quitCheckTimer.stop()
    root.quitAppId = ""
    root.quitState = ""
  }

  function quitClicked(app) {
    if (!app || !app.id) return
    var groups = root.groupsFor(app.id)
    if (groups.length === 0) return
    if (root.quitAppId !== app.id || root.quitState === "") {
      root.quitAppId = app.id
      root.quitState = "armed"
      quitArmTimer.restart()
      return
    }
    if (root.quitState === "armed" || root.quitState === "stubborn") {
      var sig = root.quitState === "armed" ? "TERM" : "KILL"
      quitArmTimer.stop()
      for (var i = 0; i < groups.length; i++) procMonitor.signalGroup(groups[i], sig)
      root.quitState = "ending"
      quitCheckTimer.restart()
    }
  }

  // An armed button that is not confirmed disarms itself.
  Timer {
    id: quitArmTimer
    interval: 3500
    onTriggered: if (root.quitState === "armed") root.resetQuit()
  }

  Timer {
    id: quitCheckTimer
    interval: 3000
    onTriggered: {
      root.toplevelRevision++
      procMonitor.refresh()
      if (root.windowsOf(root.quitAppId).length > 0) root.quitState = "stubborn"
      else root.resetQuit()
    }
  }

  FileView {
    id: usageFile
    path: root.usagePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    blockAllReads: true
    onFileChanged: if (!root.savingUsage) usageReader.reload()
  }

  BoundedFile {
    id: usageReader
    path: root.usagePath
    limit: Usage.limits().fileBytes
    printErrors: true
    onLoaded: function(text) { root.applyUsageText(text) }
    onFailed: function(reason) { root.usageUnavailable(reason) }
  }


  Timer {
    id: usageGuard
    interval: 600
    onTriggered: root.savingUsage = false
  }

  // ------------------------------------------------------------- open/close

  function beforeOpen() {
    root.filterText = ""
    root.pickerCategory = ""
    root.editMode = false
    root.refreshClock()
    root.toplevelRevision++
    root.hideDetails()
    procMonitor.refresh()
    root.selectedIndex = -1
    root.cursorActive = false
    root.pointerEngaged = false
    root.cancelCategoryDrag()
    root.ensureSeeded()
    if (root.appLibrary && typeof root.appLibrary.refreshIcons === "function") root.appLibrary.refreshIcons()
  }

  // Pointer open — hover or a click on the icon. The panel takes no keyboard
  // focus and keeps its input region narrow, so the bar goes on seeing the
  // pointer and the panel can follow it back and forth.
  function openForPointer() {
    if (root.opened) return
    root.keyboardMode = false
    root.beforeOpen()
    root.open()
  }

  // Keyboard open — the keybinding, or anything that needs typing (edit mode,
  // the application picker). Claims focus, and with it the whole screen as an
  // input region; see AppsPanel for why the two go together.
  function openForKeyboard() {
    if (!root.opened) {
      root.keyboardMode = true
      root.beforeOpen()
      root.open()
      return
    }
    root.keyboardMode = true
  }

  function togglePointer() {
    if (root.opened) root.close()
    else root.openForPointer()
  }

  function toggleKeyboard() {
    if (root.opened) root.close()
    else root.openForKeyboard()
  }

  onOpenedChanged: {
    if (root.opened) {
      button.hideOwnTooltip()
      // The tiles cascade in on every open, not once per shell session.
      root.revealToken++
      return
    }
    // Every close path lands here: the shortcut, Escape, a launch, the pointer
    // leaving, or another bar popup taking over.
    //
    // Hover stays armed unless the pointer is on the icon right now. Only a
    // close *under the pointer* — clicking the icon to dismiss — must wait for
    // the pointer to leave before hover may reopen. Disarming on every close
    // was the 1.x bug: after launching from the panel the pointer is not on
    // the icon, so the re-arm that waited for it to leave the icon never came,
    // and the next hover did nothing until the icon was clicked.
    root.hoverArmed = !button.tooltipHovered
    root.keyboardMode = false
    root.editMode = false
    root.pickerCategory = ""
    root.filterText = ""
    root.hideDetails()
    root.selectedIndex = -1
    root.cancelCategoryDrag()
    hoverOpenTimer.stop()
    hoverCloseTimer.stop()
  }

  IpcHandler {
    target: "samara-hub-ro.quick-apps"

    function open(): void { root.openForKeyboard() }
    function show(): void { root.openForKeyboard() }
    function close(): void { root.close() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggleKeyboard() }
    // Straight into the editor, for a second keybinding.
    function edit(): void { root.openForKeyboard(); root.editMode = true }
    // Launch the Nth "now" suggestion (1-based) without showing anything.
    function launchSuggestion(n: int): void {
      root.refreshClock()
      var app = root.shownSuggestions[n - 1]
      if (app) root.activateApp(app)
    }
    function resetCounts(): void { root.resetUsage() }
  }

  // ------------------------------------------------------------------- hover

  readonly property bool pointerOnButton: button.tooltipHovered
  // The details card counts as part of the panel: it carries a button, and
  // moving onto it must not read as leaving.
  readonly property bool pointerOnPanel: panel.hovered || root.pointerOnDetails

  // Read from the two sources rather than from a derived property: a binding
  // that depends on `pointerOnButton` is not guaranteed to have been
  // re-evaluated by the time this property's own change handler runs, and a
  // stale "the pointer is nowhere near" reading skips the open entirely.
  function pointerIsNear() {
    return button.tooltipHovered || panel.hovered || (root.detailsVisible && details.hovered)
  }

  onPointerOnButtonChanged: {
    // Leaving the icon re-arms hover: a click-to-close followed by a deliberate
    // return should open again, an unmoved cursor should not.
    if (!pointerOnButton) root.hoverArmed = true
    root.evaluateHover()
  }

  onPointerOnPanelChanged: root.evaluateHover()

  function evaluateHover() {
    if (root.pointerIsNear()) {
      hoverCloseTimer.stop()
      if (root.opened) root.pointerEngaged = true
      if (!root.opened && root.openOnHover && root.hoverArmed && root.pointerOnButton) hoverOpenTimer.restart()
      return
    }

    hoverOpenTimer.stop()
    if (!root.opened) return
    // A panel the user is editing stays put: they may be reaching for the
    // keyboard, and losing a half-typed search would be worse than a stale
    // panel. Escape, the shortcut and the bar icon all still close it.
    if (root.busyEditing) return
    // A keyboard-summoned panel only answers to the pointer once the pointer
    // has actually visited it.
    if (root.keyboardMode && !root.pointerEngaged) return
    hoverCloseTimer.restart()
  }

  Timer {
    id: hoverOpenTimer
    interval: root.hoverOpenDelay
    onTriggered: if (root.pointerOnButton && !root.opened) root.openForPointer()
  }

  Timer {
    id: hoverCloseTimer
    interval: root.hoverCloseDelay
    onTriggered: if (!root.pointerIsNear() && root.opened && !root.busyEditing) root.close()
  }

  // --------------------------------------------------------------- keyboard

  function moveCursor(dx, dy) {
    var count = root.flatApps.length
    if (count === 0) return
    if (!root.cursorActive || root.selectedIndex < 0) {
      root.cursorActive = true
      root.selectedIndex = 0
      return
    }
    var step = dx !== 0 ? dx : dy * root.columns
    root.selectedIndex = Math.max(0, Math.min(count - 1, root.selectedIndex + step))
  }

  function activateCursor(fresh) {
    var current = root.flatApps[root.selectedIndex]
    if (!current) return
    if (fresh) root.launchNew(current.app)
    else root.activateApp(current.app)
  }

  function handleKey(event) {
    if (event.key === Qt.Key_Escape) {
      if (root.pickerOpen) root.pickerCategory = ""
      else if (root.editMode) root.editMode = false
      else if (root.filterText.length > 0) root.setFilter("")
      else root.close()
      event.accepted = true
      return
    }

    if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      root.switchPanel((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1)
      event.accepted = true
      return
    }

    if (event.key === Qt.Key_Left) { root.moveCursor(-1, 0); event.accepted = true; return }
    if (event.key === Qt.Key_Right) { root.moveCursor(1, 0); event.accepted = true; return }
    if (event.key === Qt.Key_Up) { root.moveCursor(0, -1); event.accepted = true; return }
    if (event.key === Qt.Key_Down) { root.moveCursor(0, 1); event.accepted = true; return }

    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      // Shift+Enter is the keyboard's middle-click: always a new window.
      root.activateCursor((event.modifiers & Qt.ShiftModifier) !== 0)
      event.accepted = true
      return
    }

    // 1-9 launch the "now" row straight away — the one-keystroke path from
    // the shortcut to the application you most likely want at this hour.
    if (root.heroVisible && !root.editMode && event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
      var pick = root.shownSuggestions[event.key - Qt.Key_1]
      if (pick) {
        root.activateApp(pick)
        event.accepted = true
        return
      }
    }

    if (event.key === Qt.Key_Backspace) {
      root.setFilter(root.filterText.slice(0, -1))
      event.accepted = true
      return
    }

    // Everything else printable narrows the grid. Letters are not bound to
    // navigation here on purpose: type-to-filter is the faster path once the
    // panel is up, and the arrows already cover movement.
    if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 0x20) {
      root.setFilter(root.filterText + event.text)
      event.accepted = true
    }
  }

  function setFilter(value) {
    root.filterText = value
    root.hideDetails()
    root.selectedIndex = root.filterText.length > 0 && root.flatApps.length > 0 ? 0 : -1
    root.cursorActive = root.selectedIndex >= 0
  }

  // ------------------------------------------------------------------ layout

  readonly property int tileSpacing: Style.space(4)
  readonly property int minTileWidth: Math.max(root.iconSize + Style.space(18),
    root.showLabels ? Style.space(74) : root.iconSize + Style.space(18))

  readonly property int gridWidth: root.columns * root.minTileWidth + (root.columns - 1) * root.tileSpacing
  readonly property int cardWidth: Math.max(root.gridWidth, Style.space(300))

  // A card wider than the grid strictly needs (the floor above, or a narrow
  // tile) hands the slack to the tiles: `columns` still means columns.
  readonly property int tileWidth: Math.max(root.minTileWidth,
    Math.floor((panel.innerWidth - (root.columns - 1) * root.tileSpacing) / root.columns))

  // ---- now row ---------------------------------------------------------

  // On as soon as there is anything in the launcher at all, not only once
  // something has been launched: a row that stays invisible until the counts
  // fill up is a feature nobody discovers on the day they install it.
  readonly property bool heroAvailable: root.showSuggestions && root.currentAppIds().length > 0
  // Editing is about the categories, and a search is about one answer — the
  // suggestions are noise in both.
  readonly property bool heroVisible: root.heroAvailable && !root.editMode && root.filterText.length === 0
  readonly property bool heroIdle: root.shownSuggestions.length === 0
  // One row, never wrapped: the row is a glance, not a second grid.
  readonly property var shownSuggestions: root.suggestions.slice(0, root.columns)

  // Bumped on every open; the tiles cascade in when it changes.
  property int revealToken: 0

  function categoryNameOf(appId) {
    var categories = root.config.categories || []
    for (var i = 0; i < categories.length; i++) {
      if (categories[i].apps.indexOf(appId) !== -1) return categories[i].name
    }
    return ""
  }

  // ------------------------------------------------------------------- edits

  function addAppTo(categoryId, appId) { root.saveConfig(Model.addApp(root.config, categoryId, appId)) }
  function removeAppFrom(categoryId, appId) { root.saveConfig(Model.removeApp(root.config, categoryId, appId)) }
  function moveAppIn(categoryId, appId, direction) { root.saveConfig(Model.moveApp(root.config, categoryId, appId, direction)) }
  function addCategory() { root.saveConfig(Model.addCategory(root.config, "New category")) }
  function renameCategory(categoryId, name) { root.saveConfig(Model.renameCategory(root.config, categoryId, name)) }
  function removeCategory(categoryId) { root.saveConfig(Model.removeCategory(root.config, categoryId)) }
  function moveCategory(categoryId, direction) { root.saveConfig(Model.moveCategory(root.config, categoryId, direction)) }
  function moveCategoryTo(categoryId, index) { root.saveConfig(Model.moveCategoryTo(root.config, categoryId, index)) }

  function appsIn(categoryId) {
    var index = Model.categoryIndex(root.config, categoryId)
    return index === -1 ? [] : root.config.categories[index].apps
  }

  // ---- drag to reorder categories --------------------------------------
  //
  // The geometry is snapshotted once, on press, and the drop point derived
  // from it: the sections do not move until the pointer is released, so a
  // snapshot stays true for the whole gesture and the delegate under the
  // pointer is never destroyed out from under it.

  function beginCategoryDrag(categoryId, index) {
    var rows = []
    for (var i = 0; i < sectionsColumn.children.length; i++) {
      var child = sectionsColumn.children[i]
      if (!child || child.isCategorySection !== true || !child.visible) continue
      rows.push({ index: child.sectionIndex, top: child.y, bottom: child.y + child.height })
    }
    rows.sort(function(a, b) { return a.top - b.top })
    root.dragRows = rows
    root.dragCategoryId = categoryId
    root.dragFromIndex = index
    root.dragToIndex = index
    root.dragActive = false
  }

  // `y` is in sectionsColumn coordinates. The answer is an insertion point:
  // "in front of the category at this index", with sections.length for the end.
  function updateCategoryDrag(y) {
    var rows = root.dragRows
    if (!rows || rows.length === 0) return
    var target = root.sections.length
    for (var i = 0; i < rows.length; i++) {
      if (y < (rows[i].top + rows[i].bottom) / 2) { target = rows[i].index; break }
    }
    root.dragActive = true
    root.dragToIndex = target
  }

  function endCategoryDrag() {
    var moved = root.dragActive && root.dragCategoryId.length > 0 && root.dragToIndex !== root.dragFromIndex
    var categoryId = root.dragCategoryId
    var target = root.dragToIndex
    root.cancelCategoryDrag()
    if (moved) root.moveCategoryTo(categoryId, target)
  }

  function cancelCategoryDrag() {
    root.dragCategoryId = ""
    root.dragFromIndex = -1
    root.dragToIndex = -1
    root.dragActive = false
    root.dragRows = []
  }

  // Whether to draw the insertion line in front of `index`. Dropping a
  // category back where it already was is not a move, so it gets no promise
  // of one.
  function dropIndicatorAt(index) {
    if (!root.dragActive) return false
    if (root.dragToIndex !== index) return false
    if (index === root.dragFromIndex || index === root.dragFromIndex + 1) return false
    return true
  }

  // -------------------------------------------------------------- bar button

  Component {
    id: brandMark

    BrandMark {
      color: button.active && button.useActiveColor ? button.activeColor : button.foreground
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barIcon
    iconComponent: root.barIcon.length > 0 ? null : brandMark
    // The tooltip would land on top of the panel it just opened, so it only
    // exists while the panel is shut.
    tooltipText: root.opened ? "" : "Quick Apps"
    active: root.opened
    onPressed: function(b) {
      if (b === Qt.RightButton) {
        root.openForKeyboard()
        root.editMode = true
        return
      }
      root.togglePointer()
    }
  }

  // ------------------------------------------------------------------- panel

  AppsPanel {
    id: panel

    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    keyboardMode: root.keyboardMode
    focusTarget: keyCatcher
    surfaceOpacity: root.surfaceOpacity
    extraInputItem: details
    extraInputActive: root.detailsVisible
    contentWidth: panel.fittedContentWidth(root.cardWidth)
    contentHeight: panel.fittedContentHeight(root.pickerOpen ? Style.space(340) : body.implicitHeight)

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      // The picker owns the keyboard while it is up: its search field needs
      // every keystroke, including the ones that would otherwise filter the
      // grid or close the panel.
      Keys.enabled: !root.pickerOpen
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) { root.handleKey(event) }

      Column {
        id: body
        visible: !root.pickerOpen
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(10)

        // ---- header --------------------------------------------------------

        Item {
          width: parent.width
          implicitHeight: Math.max(titleText.implicitHeight, editButton.implicitHeight)

          Text {
            id: titleText
            textFormat: Text.PlainText
            text: root.editMode ? "Edit Quick Apps" : "Quick Apps"
            color: root.panelForeground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
            elide: Text.ElideRight
            anchors.left: parent.left
            anchors.right: headerTools.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
          }

          Row {
            id: headerTools
            spacing: Style.space(4)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            // A hover-opened panel does not own the keyboard; this hands it
            // over, so typing searches without reaching for the shortcut.
            PanelActionButton {
              visible: !root.keyboardMode && !root.editMode
              iconText: ""
              tooltipText: "Search"
              foreground: root.panelForeground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              size: Style.space(22)
              anchors.verticalCenter: parent.verticalCenter
              onClicked: root.openForKeyboard()
            }

            Button {
              id: editButton
              text: root.editMode ? "Done" : "Edit"
              foreground: root.panelForeground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              verticalPadding: Style.space(4)
              horizontalPadding: Style.space(9)
              selected: root.editMode
              anchors.verticalCenter: parent.verticalCenter
              onClicked: {
                // Editing means typing, and typing means this surface has to
                // own the keyboard even when the panel came up from a hover.
                root.openForKeyboard()
                root.editMode = !root.editMode
                if (!root.editMode) root.pickerCategory = ""
              }
            }
          }
        }

        // ---- search line ---------------------------------------------------
        //
        // Present whenever typing would do something: the panel owns the
        // keyboard, or a search is already running.

        Rectangle {
          id: searchLine
          visible: !root.editMode && (root.keyboardMode || root.filterText.length > 0)
          width: parent.width
          height: Style.space(30)
          radius: Style.cornerRadius
          color: Util.alpha(root.panelForeground, Style.normalFillAlpha)
          border.width: 1
          border.color: root.filterText.length > 0 ? Util.alpha(root.accent, 0.6) : Util.alpha(root.panelForeground, 0.12)

          Text {
            id: searchGlyph
            textFormat: Text.PlainText
            text: ""
            color: root.filterText.length > 0 ? root.accent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            anchors.left: parent.left
            anchors.leftMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: queryText
            textFormat: Text.PlainText
            text: root.filterText.length > 0 ? root.filterText : "Search, or press 1–9 for a suggestion"
            color: root.filterText.length > 0 ? root.panelForeground : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideLeft
            anchors.left: searchGlyph.right
            anchors.leftMargin: Style.space(8)
            anchors.right: resultCount.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
          }

          // Caret, after the typed text. Only while the keyboard is ours.
          Rectangle {
            visible: root.keyboardMode && root.filterText.length > 0
            width: Math.max(1, Style.space(1))
            height: queryText.font.pixelSize + Style.space(2)
            color: root.accent
            x: queryText.x + Math.min(queryText.contentWidth, queryText.width) + Style.space(1)
            anchors.verticalCenter: parent.verticalCenter

            SequentialAnimation on opacity {
              running: root.opened && root.keyboardMode
              loops: Animation.Infinite
              NumberAnimation { to: 0; duration: 530; easing.type: Easing.InOutQuad }
              NumberAnimation { to: 1; duration: 530; easing.type: Easing.InOutQuad }
            }
          }

          Text {
            id: resultCount
            visible: root.filterText.length > 0
            textFormat: Text.PlainText
            text: root.flatApps.length === 0 ? "none" : (root.flatApps.length === 1 ? "1 app" : root.flatApps.length + " apps")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            anchors.right: parent.right
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        Text {
          visible: root.editMode
          width: parent.width
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          text: "Drag a category by its handle to reorder it. Hover an app to remove it."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        // ---- now -----------------------------------------------------------

        Column {
          id: nowBlock
          visible: root.heroVisible
          width: parent.width
          spacing: Style.space(4)

          Row {
            spacing: Style.space(6)

            Text {
              textFormat: Text.PlainText
              text: "NOW"
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: Style.space(1)
            }

            Text {
              textFormat: Text.PlainText
              text: root.heroIdle ? "learns what you open, and when" : root.nowLabel
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // Before anything has been opened there is nothing to suggest; say
          // what will appear here instead of leaving an empty band.
          Text {
            visible: root.heroIdle
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: "Open a few apps and the ones you reach for at this hour of the day will line up here."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Row {
            visible: !root.heroIdle
            spacing: root.tileSpacing

            Repeater {
              model: root.shownSuggestions

              delegate: AppTile {
                id: nowTile
                required property var modelData
                required property int index

                appId: modelData.id
                label: modelData.name
                iconUrl: root.iconFor(modelData.icon)
                iconSize: root.iconSize
                showLabel: root.showLabels
                missing: modelData.missing
                windows: root.windowCountOf(modelData.id)
                hint: root.keyboardMode ? String(index + 1) : ""
                accent: root.accent
                foreground: root.panelForeground
                fontFamily: root.fontFamily
                width: root.tileWidth
                revealOrder: index
                revealToken: root.revealToken

                onActivated: root.activateApp(modelData)
                onNewInstanceRequested: root.launchNew(modelData)
                onPointerEntered: {
                  root.cursorActive = false
                  root.selectedIndex = -1
                  root.showDetailsFor(modelData, nowTile, root.categoryNameOf(modelData.id))
                }
                onPointerExited: root.leaveDetailsFor(modelData)
              }
            }
          }
        }

        PanelSeparator {
          width: parent.width
          visible: root.heroVisible
        }

        // ---- categories ----------------------------------------------------

        Flickable {
          width: parent.width
          height: Math.min(sectionsColumn.implicitHeight, root.maxBodyHeight)
          contentWidth: width
          contentHeight: sectionsColumn.implicitHeight
          clip: true
          // A drag that scrolled the list under itself would invalidate the
          // geometry snapshot the drop point is computed from.
          interactive: contentHeight > height && !root.dragActive
          boundsBehavior: Flickable.StopAtBounds
          onContentYChanged: root.hideDetails()

          Column {
            id: sectionsColumn
            width: parent.width
            // Room for the edit-mode name field's frame, which the clip would
            // otherwise shave off the first category.
            topPadding: Style.space(2)
            spacing: Style.space(10)

            Repeater {
              model: root.sections

              delegate: Item {
                id: section
                required property var modelData
                required property int index

                // Read by the drag snapshot walking this Column's children.
                readonly property bool isCategorySection: true
                readonly property int sectionIndex: section.index
                readonly property bool dragging: root.dragActive && root.dragCategoryId === section.modelData.id

                width: sectionsColumn.width
                height: sectionBody.implicitHeight
                visible: root.editMode || section.modelData.apps.length > 0
                opacity: section.dragging ? 0.45 : 1

                Behavior on opacity { NumberAnimation { duration: 110 } }

                // Insertion line for a drag heading here.
                Rectangle {
                  visible: root.dropIndicatorAt(section.sectionIndex)
                  height: Math.max(2, Style.space(2))
                  radius: height / 2
                  color: root.accent
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.topMargin: -Style.space(6)
                }

                Column {
                  id: sectionBody
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                  spacing: Style.space(4)

                  Item {
                    width: parent.width
                    implicitHeight: Math.max(sectionTitle.implicitHeight, sectionTools.implicitHeight, Style.space(18))

                    // Grab handle. Press and drag it to move the whole
                    // category.
                    Item {
                      id: dragGrip
                      visible: root.editMode
                      width: root.editMode ? Style.space(18) : 0
                      height: Style.space(20)
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter

                      Text {
                        anchors.centerIn: parent
                        textFormat: Text.PlainText
                        text: "󰇜"
                        color: root.panelForeground
                        opacity: gripMouse.containsMouse || section.dragging ? 1 : 0.5
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }

                      MouseArea {
                        id: gripMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: section.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                        acceptedButtons: Qt.LeftButton
                        preventStealing: true

                        onPressed: root.beginCategoryDrag(section.modelData.id, section.sectionIndex)
                        onPositionChanged: function(event) {
                          if (root.dragCategoryId !== section.modelData.id) return
                          var point = mapToItem(sectionsColumn, event.x, event.y)
                          root.updateCategoryDrag(point.y)
                        }
                        onReleased: root.endCategoryDrag()
                        onCanceled: root.cancelCategoryDrag()
                      }
                    }

                    PanelSectionHeader {
                      id: sectionTitle
                      visible: !root.editMode
                      text: section.modelData.name.toUpperCase()
                      foreground: root.panelForeground
                      fontFamily: root.fontFamily
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    TextField {
                      id: nameField
                      visible: root.editMode
                      text: section.modelData.name
                      foreground: root.panelForeground
                      verticalPadding: Style.space(3)
                      font.pixelSize: Style.font.bodySmall
                      width: Math.max(Style.space(60), Math.min(Style.space(180),
                        parent.width - dragGrip.width - sectionTools.width - Style.space(14)))
                      anchors.left: dragGrip.right
                      anchors.leftMargin: Style.space(6)
                      anchors.verticalCenter: parent.verticalCenter
                      onEditingFinished: if (text !== section.modelData.name) root.renameCategory(section.modelData.id, text)
                    }

                    Row {
                      id: sectionTools
                      visible: root.editMode
                      spacing: Style.space(2)
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter

                      PanelActionButton {
                        iconText: "＋"
                        tooltipText: "Add an application"
                        foreground: root.panelForeground
                        fontFamily: root.fontFamily
                        fontSize: Style.font.bodySmall
                        size: Style.space(20)
                        onClicked: root.pickerCategory = section.modelData.id
                      }

                      PanelActionButton {
                        iconText: "✕"
                        tooltipText: "Delete category"
                        foreground: root.panelForeground
                        hoverColor: Color.urgent
                        fontFamily: root.fontFamily
                        fontSize: Style.font.bodySmall
                        size: Style.space(20)
                        onClicked: root.removeCategory(section.modelData.id)
                      }
                    }
                  }

                  // ---- tiles -----------------------------------------------

                  Flow {
                    width: parent.width
                    spacing: root.tileSpacing

                    Repeater {
                      model: section.modelData.apps

                      delegate: AppTile {
                        id: tile
                        required property var modelData
                        required property int index

                        readonly property int flatIndex: section.modelData.offset + index

                        appId: modelData.id
                        label: modelData.name
                        iconUrl: root.iconFor(modelData.icon)
                        iconSize: root.iconSize
                        showLabel: root.showLabels
                        missing: modelData.missing
                        editing: root.editMode
                        selected: root.cursorActive && root.selectedIndex === flatIndex
                        canMoveLeft: index > 0
                        canMoveRight: index < section.modelData.apps.length - 1
                        canReorder: !root.sortByUsage
                        windows: root.windowCountOf(modelData.id)
                        accent: root.accent
                        foreground: root.panelForeground
                        fontFamily: root.fontFamily
                        width: root.tileWidth
                        revealOrder: flatIndex + (root.heroVisible ? root.shownSuggestions.length : 0)
                        revealToken: root.revealToken

                        readonly property string categoryName: section.modelData.id === "__results"
                          ? root.categoryNameOf(modelData.id) : section.modelData.name

                        onActivated: root.activateApp(modelData)
                        onNewInstanceRequested: root.launchNew(modelData)
                        onPointerEntered: {
                          root.cursorActive = false
                          root.selectedIndex = -1
                          root.showDetailsFor(modelData, tile, tile.categoryName)
                        }
                        onPointerExited: root.leaveDetailsFor(modelData)
                        // The keyboard cursor gets the details card too —
                        // including a tile that is born selected, which is
                        // every top search result as the query changes.
                        onSelectedChanged: if (selected) root.showDetailsFor(modelData, tile, tile.categoryName)
                        Component.onCompleted: if (selected) Qt.callLater(function() {
                          if (tile.selected) root.showDetailsFor(tile.modelData, tile, tile.categoryName)
                        })
                        onRemoveRequested: root.removeAppFrom(section.modelData.id, modelData.id)
                        onMoveRequested: function(direction) { root.moveAppIn(section.modelData.id, modelData.id, direction) }
                      }
                    }

                    // The add tile keeps the "+" where the eye already is — at
                    // the end of the row it belongs to.
                    Item {
                      visible: root.editMode
                      width: root.tileWidth
                      height: Style.space(8) + root.iconSize + Style.space(6) + (root.showLabels ? Math.ceil(Style.font.caption * 2.4) : 0) + Style.space(4)

                      Rectangle {
                        anchors.fill: parent
                        radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(6)
                        color: addMouse.containsMouse ? Util.alpha(root.panelForeground, Style.hoverFillAlpha) : "transparent"
                        border.width: 1
                        border.color: Util.alpha(root.panelForeground, addMouse.containsMouse ? 0.45 : 0.2)
                      }

                      Text {
                        anchors.centerIn: parent
                        textFormat: Text.PlainText
                        text: "＋"
                        color: root.panelForeground
                        opacity: 0.7
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.iconLarge
                      }

                      MouseArea {
                        id: addMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.pickerCategory = section.modelData.id
                      }
                    }
                  }
                }
              }
            }

            // Insertion line for a drop past the last category.
            Item {
              width: parent.width
              height: visible ? Math.max(2, Style.space(2)) : 0
              visible: root.dropIndicatorAt(root.sections.length)

              Rectangle {
                anchors.fill: parent
                radius: height / 2
                color: root.accent
              }
            }

            // ---- empty states ------------------------------------------------

            Text {
              width: parent.width
              visible: root.flatApps.length === 0 && root.filterText.length > 0
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: "Nothing installed matches “" + root.filterText + "”. Backspace to change it."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              width: parent.width
              visible: root.filterText.length === 0 && root.sections.length === 0
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: "No categories yet. Hit Edit, add one, then drop your apps into it."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
        }

        // ---- running -------------------------------------------------------
        //
        // What the open applications are costing: one line of totals, the
        // CPU of all of them over the last three minutes, and the heaviest few
        // by name. The bar beside each is its memory against the heaviest's.

        PanelSeparator {
          width: parent.width
          visible: monitorBlock.visible
        }

        Column {
          id: monitorBlock
          visible: root.monitorVisible
          width: parent.width
          spacing: Style.space(6)

          Item {
            width: parent.width
            implicitHeight: monitorTitle.implicitHeight

            PanelSectionHeader {
              id: monitorTitle
              text: "RUNNING · " + root.monitorRows.length + (root.monitorRows.length === 1 ? " APP" : " APPS")
              foreground: root.panelForeground
              fontFamily: root.fontFamily
              anchors.left: parent.left
            }

            Text {
              textFormat: Text.PlainText
              text: "CPU " + root.formatPercent(root.monitorTotals.cpu) + "   RAM " + root.formatBytes(root.monitorTotals.mem)
              color: root.panelForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.right: parent.right
              anchors.verticalCenter: monitorTitle.verticalCenter
            }
          }

          Sparkline {
            width: parent.width
            height: Style.space(34)
            values: procMonitor.totalHistory
            capacity: procMonitor.historyLength
            color: root.accent
          }

          Repeater {
            model: root.monitorRows.slice(0, 4)

            delegate: Item {
              id: monRow
              required property var modelData
              width: monitorBlock.width
              height: Style.space(22)

              readonly property bool hot: rowMouse.containsMouse

              Rectangle {
                anchors.fill: parent
                anchors.leftMargin: -Style.space(4)
                anchors.rightMargin: -Style.space(4)
                radius: Style.cornerRadius
                color: monRow.hot ? Util.alpha(root.panelForeground, Style.hoverFillAlpha) : "transparent"
              }

              Image {
                id: monIcon
                width: Style.space(16)
                height: Style.space(16)
                fillMode: Image.PreserveAspectFit
                sourceSize.width: width * Screen.devicePixelRatio
                sourceSize.height: height * Screen.devicePixelRatio
                source: root.iconFor(monRow.modelData.icon)
                asynchronous: true
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                textFormat: Text.PlainText
                text: monRow.modelData.name
                color: root.panelForeground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                anchors.left: monIcon.right
                anchors.leftMargin: Style.space(8)
                anchors.right: memTrack.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
              }

              Rectangle {
                id: memTrack
                width: Style.space(64)
                height: Math.max(2, Style.space(3))
                radius: height / 2
                color: Util.alpha(root.panelForeground, 0.1)
                anchors.right: monValue.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter

                Rectangle {
                  width: Math.max(parent.height, parent.width * Math.min(1, monRow.modelData.stats.mem / Math.max(1, root.monitorMaxMem)))
                  height: parent.height
                  radius: parent.radius
                  color: root.accent

                  Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                }
              }

              Text {
                id: monValue
                width: Style.space(92)
                horizontalAlignment: Text.AlignRight
                textFormat: Text.PlainText
                text: root.formatPercent(monRow.modelData.stats.cpu) + "  " + root.formatBytes(monRow.modelData.stats.mem)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: monRow.modelData.app ? Qt.PointingHandCursor : Qt.ArrowCursor
                onEntered: if (monRow.modelData.app) root.showDetailsFor(monRow.modelData.app, monRow, root.categoryNameOf(monRow.modelData.app.id))
                onExited: if (monRow.modelData.app) root.leaveDetailsFor(monRow.modelData.app)
                onClicked: if (monRow.modelData.app) root.activateApp(monRow.modelData.app)
              }
            }
          }
        }

        Item {
          width: parent.width
          visible: root.editMode
          implicitHeight: addCategoryButton.implicitHeight

          Button {
            id: addCategoryButton
            text: "＋ Category"
            foreground: root.panelForeground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            verticalPadding: Style.space(4)
            horizontalPadding: Style.space(9)
            bordered: true
            anchors.left: parent.left
            onClicked: root.addCategory()
          }

          Text {
            textFormat: Text.PlainText
            text: "Saved in " + root.configPath.replace(Quickshell.env("HOME"), "~")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideLeft
            anchors.left: addCategoryButton.right
            anchors.leftMargin: Style.space(10)
            anchors.right: parent.right
            anchors.verticalCenter: addCategoryButton.verticalCenter
          }
        }
      }

      // ---- picker ----------------------------------------------------------

      AppPicker {
        id: picker
        anchors.fill: parent
        visible: root.pickerOpen
        categoryName: root.pickerCategoryName
        entries: root.pickerOpen ? root.installedEntries() : []
        takenIds: root.pickerOpen ? root.appsIn(root.pickerCategory) : []
        iconFor: function(name) { return root.iconFor(name) }
        foreground: root.panelForeground
        fontFamily: root.fontFamily

        onPicked: function(appId) { root.addAppTo(root.pickerCategory, appId) }
        onCancelled: root.pickerCategory = ""
      }
    }
  }

  // ----------------------------------------------------------- details card

  // The last application the card was about. Kept after the card is told to
  // go, so it fades out showing what it showed rather than blanking first.
  property var detailsLastApp: null
  onDetailsAppChanged: if (root.detailsApp) root.detailsLastApp = root.detailsApp

  AppDetails {
    id: details
    parent: panel.overlayLayer

    readonly property real gap: panel.gap
    // Beside the panel, on whichever side has room; the right by preference.
    readonly property bool onRight: panel.cardOrigin.x + panel.contentWidth + gap + width <= panel.screenW - panel.margin
    readonly property var subject: root.detailsLastApp

    visible: opacity > 0.01
    opacity: root.detailsVisible ? 1 : 0
    x: (onRight ? panel.cardOrigin.x + panel.contentWidth + gap : panel.cardOrigin.x - gap - width)
      + (root.detailsVisible ? 0 : (onRight ? -Style.space(10) : Style.space(10)))
    y: Math.round(Math.max(panel.margin, Math.min(panel.screenH - height - panel.margin, root.detailsAnchorY - height / 2)))

    Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
    Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    // Glides from tile to tile once it is up; appears in place when it is not.
    Behavior on y { enabled: details.opacity > 0.9; NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

    app: subject
    iconUrl: subject ? root.iconFor(subject.icon) : ""
    info: subject ? appInfo.infoFor(subject.id) : null
    loading: subject !== null && !subject.missing
    launchCount: subject ? Usage.countOf(root.usage, subject.id) : 0
    lastLaunch: subject ? Usage.lastOf(root.usage, subject.id) : ""
    windows: subject ? root.windowsOf(subject.id).length : 0
    category: root.detailsCategory
    focusRunning: root.focusRunning
    stats: subject && root.showMonitor ? root.statsFor(subject.id) : null
    sampleCapacity: procMonitor.historyLength
    quitState: subject && root.quitAppId === subject.id ? root.quitState : ""
    foreground: root.panelForeground
    accent: root.accent
    fontFamily: root.fontFamily
    surfaceOpacity: root.surfaceOpacity

    onQuitClicked: root.quitClicked(subject)
  }

  readonly property string pickerCategoryName: {
    var index = Model.categoryIndex(root.config, root.pickerCategory)
    return index === -1 ? "" : root.config.categories[index].name
  }

  // A launcher that fills the screen is not a discreet launcher: the grid
  // scrolls past `maxHeight` instead of growing, and the screen's own room
  // caps it after that. `maxHeight` is the scrolling grid's own budget — the
  // now row sits above it and is charged to the screen, not to the setting,
  // so turning the row on does not silently shorten the grid.
  readonly property int maxBodyHeight: Math.max(Style.space(120),
    Math.min(root.maxHeight,
      Math.round(panel.availableCardHeight - Style.space(120)
        - (root.heroVisible ? nowBlock.implicitHeight + Style.space(20) : 0)
        - (searchLine.visible ? searchLine.height + Style.space(10) : 0)
        - (monitorBlock.visible ? monitorBlock.implicitHeight + Style.space(20) : 0))))

  onPickerOpenChanged: {
    if (root.pickerOpen) Qt.callLater(function() { if (root.pickerOpen) picker.focusSearch() })
    else Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
  }
}
