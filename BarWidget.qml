import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "AppsModel.js" as Model
import "UsageModel.js" as Usage

// Quick Apps — the apps you actually use, grouped into your own categories,
// one hover away from the bar.
//
// Four things shape the implementation:
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
  readonly property real surfaceOpacity: Util.clampAlpha(Number(setting("backgroundOpacity", 82)) / 100)
  readonly property int iconSize: Math.max(16, Math.round(Number(setting("iconSize", 34))))
  readonly property int columns: Math.max(2, Math.round(Number(setting("columns", 5))))
  readonly property bool showLabels: setting("showLabels", true) === true
  readonly property int maxHeight: Math.max(Style.space(160), Math.round(Number(setting("maxHeight", 480))))
  readonly property string barIcon: String(setting("icon", "󰀻"))
  readonly property bool seedOnFirstRun: setting("seedOnFirstRun", true) === true

  readonly property bool showMostUsed: setting("showMostUsed", true) === true
  readonly property int mostUsedCount: Math.max(1, Math.min(6, Math.round(Number(setting("mostUsedCount", 5)))))
  readonly property bool showUsageChart: setting("showUsageChart", true) === true
  readonly property bool showLaunchCounts: setting("showLaunchCounts", true) === true
  readonly property string countIcon: String(setting("countIcon", ""))
  // Alpha of each category's background wash, in percent. 30 is the default —
  // 70% transparent, present enough to group the tiles under it and far too
  // faint to fight the icons.
  readonly property real categoryTint: Util.clampAlpha(Math.max(0, Math.min(70, Number(setting("categoryTint", 30)))) / 100)

  readonly property string configPath: {
    var custom = String(setting("configPath", "")).replace(/^\s+|\s+$/g, "")
    if (custom.length > 0) return custom.replace(/^~/, Quickshell.env("HOME"))
    return Quickshell.env("HOME") + "/.config/omarchy/quick-apps.json"
  }

  // Counts live beside the categories rather than inside them: they change on
  // every launch, and a rewrite-per-launch of the file the user hand-edits is
  // a good way to lose a hand edit.
  readonly property string usagePath: root.configPath.replace(/\.json$/i, "") + "-usage.json"

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

  // Category whose colour swatches are currently unfolded, "" for none.
  property string paletteCategory: ""

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

  readonly property color panelForeground: Color.popups.text
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
  Component.onCompleted: appLibrary = resolveAppLibrary()

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
    if (!entry) return { id: id, name: id, detail: "", icon: "", missing: true }
    return {
      id: id,
      name: String(entry.name || id),
      detail: String(entry.genericName || entry.comment || ""),
      icon: String(entry.icon || ""),
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
      rows.push({
        id: Model.normalizeAppId(entry.id),
        name: String(entry.name || entry.id),
        detail: String(entry.genericName || entry.comment || ""),
        icon: String(entry.icon || ""),
        categories: entry.categories ? Array.prototype.slice.call(entry.categories) : [],
        noDisplay: false
      })
    }

    rows.sort(function(a, b) { return a.name.localeCompare(b.name) })
    return rows
  }

  function launchApp(app) {
    if (!app || !app.id) return
    root.recordLaunch(app.id)
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

  readonly property var sections: Model.buildSections(root.config, root.filterText, function(id) { return root.describe(id) })
  readonly property var flatApps: Model.flatten(root.sections)

  // Deliberately a function, not a `readonly property var` bound to `config`.
  // `syncUsage` runs from `onConfigChanged`, and a signal handler is not
  // ordered against the re-evaluation of bindings on the same property — a
  // derived property read from there hands back the *previous* config, which
  // inverts every add and remove. A call is always current.
  function currentAppIds() { return Model.allAppIds(root.config) }

  function applyConfigText(text) {
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

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.applyConfigText(text())
    onFileChanged: if (!root.savingConfig) reload()
    onLoadFailed: {
      // No file yet is the normal first-run state, not an error.
      root.configLoaded = true
      root.configAuthoritative = true
    }
  }

  Timer {
    id: saveGuard
    interval: 600
    onTriggered: root.savingConfig = false
  }

  // ------------------------------------------------------------------- usage

  readonly property var topApps: {
    if (!root.showMostUsed) return []
    var rows = Usage.ranked(root.usage, root.currentAppIds(), root.mostUsedCount)
    var out = []
    for (var i = 0; i < rows.length; i++) {
      var app = root.describe(rows[i].id)
      out.push({
        id: rows[i].id,
        name: app.name,
        icon: app.icon,
        missing: app.missing,
        count: rows[i].count,
        color: Model.colorForApp(root.config, rows[i].id)
      })
    }
    return out
  }

  readonly property int usageTotal: Usage.totalOf(root.usage, root.currentAppIds())
  readonly property int maxUsage: root.topApps.length > 0 ? root.topApps[0].count : 1

  function launchCountOf(appId) { return Usage.countOf(root.usage, appId) }

  function applyUsageText(text) {
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
    var next = Usage.record(root.usage, id, root.nowIso())
    if (next === null) return
    root.saveUsage(next)
  }

  function resetUsage() {
    if (!root.usageLoaded) return
    root.saveUsage(Usage.reset(root.usage, root.nowIso()))
  }

  onConfigChanged: root.syncUsage()
  onConfigAuthoritativeChanged: root.syncUsage()

  FileView {
    id: usageFile
    path: root.usagePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.applyUsageText(text())
    onFileChanged: if (!root.savingUsage) reload()
    onLoadFailed: {
      root.usageLoaded = true
      root.syncUsage()
    }
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
    root.paletteCategory = ""
    root.editMode = false
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
      // The arcs sweep out on every open, not once per shell session.
      chart.replay()
      return
    }
    // Every close path lands here: the shortcut, Escape, a launch, the pointer
    // leaving, or another bar popup taking over.
    root.hoverArmed = false
    root.keyboardMode = false
    root.editMode = false
    root.pickerCategory = ""
    root.paletteCategory = ""
    root.filterText = ""
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
    function resetCounts(): void { root.resetUsage() }
  }

  // ------------------------------------------------------------------- hover

  readonly property bool pointerOnButton: button.tooltipHovered
  readonly property bool pointerOnPanel: panel.hovered

  // Read from the two sources rather than from a derived property: a binding
  // that depends on `pointerOnButton` is not guaranteed to have been
  // re-evaluated by the time this property's own change handler runs, and a
  // stale "the pointer is nowhere near" reading skips the open entirely.
  function pointerIsNear() {
    return root.pointerOnButton || root.pointerOnPanel
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

  function activateCursor() {
    var current = root.flatApps[root.selectedIndex]
    if (current) root.launchApp(current.app)
  }

  function handleKey(event) {
    if (event.key === Qt.Key_Escape) {
      if (root.pickerOpen) root.pickerCategory = ""
      else if (root.paletteCategory.length > 0) root.paletteCategory = ""
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
      root.activateCursor()
      event.accepted = true
      return
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
    root.selectedIndex = root.filterText.length > 0 && root.flatApps.length > 0 ? 0 : -1
    root.cursorActive = root.selectedIndex >= 0
  }

  // ------------------------------------------------------------------ layout

  readonly property int tileSpacing: Style.space(6)
  readonly property int tileWidth: Math.max(root.iconSize + Style.space(18), root.showLabels ? Style.space(74) : root.iconSize + Style.space(18))
  readonly property int categoryPadding: Style.space(8)
  // The card has to be wide enough for `columns` tiles *inside* a category's
  // padded block — otherwise turning the tint on would quietly cost a column.
  readonly property int gridWidth: root.columns * root.tileWidth
    + (root.columns - 1) * root.tileSpacing
    + root.categoryPadding * 2

  // ---- most-used strip -------------------------------------------------

  // Whether the strip has anything to say at all. Kept separate from whether
  // it is on screen right now, because the panel's width is derived from it
  // and a card that changes width as you start typing is a card that jumps.
  readonly property bool heroAvailable: root.showMostUsed && root.topApps.length > 0
  // Editing is about the categories, and a filtered grid is about one search —
  // the ranking is noise in both.
  readonly property bool heroVisible: root.heroAvailable && !root.editMode && root.filterText.length === 0

  readonly property int heroIconSize: Math.max(Style.space(16), Math.min(Style.space(24), Math.round(root.iconSize * 0.6)))
  readonly property int heroRowHeight: Math.max(root.heroIconSize, Style.font.body) + Style.space(6)
  readonly property int heroRowsHeight: root.topApps.length > 0
    ? root.topApps.length * root.heroRowHeight + (root.topApps.length - 1) * Style.space(2)
    : 0
  readonly property int chartSize: root.showUsageChart
    ? Math.max(Style.space(72), Math.min(Style.space(112), root.heroRowsHeight))
    : 0
  readonly property int heroHeight: Math.max(root.chartSize, root.heroRowsHeight)
  // A ranking squeezed into a two-column panel is unreadable, so the strip
  // sets a floor on the card's width when it can appear.
  readonly property int heroWidth: Style.space(320)

  // ------------------------------------------------------------------- edits

  function addAppTo(categoryId, appId) { root.saveConfig(Model.addApp(root.config, categoryId, appId)) }
  function removeAppFrom(categoryId, appId) { root.saveConfig(Model.removeApp(root.config, categoryId, appId)) }
  function moveAppIn(categoryId, appId, direction) { root.saveConfig(Model.moveApp(root.config, categoryId, appId, direction)) }
  function addCategory() { root.saveConfig(Model.addCategory(root.config, "New category")) }
  function renameCategory(categoryId, name) { root.saveConfig(Model.renameCategory(root.config, categoryId, name)) }
  function removeCategory(categoryId) { root.saveConfig(Model.removeCategory(root.config, categoryId)) }
  function moveCategory(categoryId, direction) { root.saveConfig(Model.moveCategory(root.config, categoryId, direction)) }
  function moveCategoryTo(categoryId, index) { root.saveConfig(Model.moveCategoryTo(root.config, categoryId, index)) }
  function setCategoryColor(categoryId, color) { root.saveConfig(Model.setCategoryColor(root.config, categoryId, color)) }

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

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barIcon
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
    contentWidth: panel.fittedContentWidth(Math.max(root.gridWidth, root.heroAvailable ? root.heroWidth : 0))
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

      // ---- grid ------------------------------------------------------------

      Column {
        id: body
        visible: !root.pickerOpen
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(10)

        Item {
          width: parent.width
          implicitHeight: Math.max(heading.implicitHeight, editButton.implicitHeight)

          Column {
            id: heading
            anchors.left: parent.left
            anchors.right: editButton.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: "Quick Apps"
              color: root.panelForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              visible: root.filterText.length > 0 || root.editMode
              textFormat: Text.PlainText
              text: root.filterText.length > 0
                ? "Filter: " + root.filterText
                : "Editing — drag a category by its handle to reorder"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              width: parent.width
            }
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
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            onClicked: {
              // Editing means typing, and typing means this surface has to own
              // the keyboard even when the panel came up from a hover.
              root.openForKeyboard()
              root.editMode = !root.editMode
              if (!root.editMode) {
                root.pickerCategory = ""
                root.paletteCategory = ""
              }
            }
          }
        }

        PanelSeparator { width: parent.width }

        // ---- most used ------------------------------------------------------

        Item {
          id: hero
          width: parent.width
          visible: root.heroVisible
          height: root.heroVisible ? root.heroHeight : 0

          Column {
            id: heroRows
            anchors.left: parent.left
            anchors.right: chart.left
            anchors.rightMargin: root.showUsageChart ? Style.space(10) : 0
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Repeater {
              model: root.topApps

              delegate: UsageRow {
                required property var modelData
                required property int index

                width: heroRows.width
                rank: index + 1
                label: modelData.name
                iconUrl: root.iconFor(modelData.icon)
                count: modelData.count
                countIcon: root.countIcon
                missing: modelData.missing
                accent: modelData.color
                foreground: root.panelForeground
                fontFamily: root.fontFamily
                iconSize: root.heroIconSize

                onActivated: root.launchApp(modelData)
              }
            }
          }

          UsageChart {
            id: chart
            visible: root.showUsageChart && root.heroVisible
            width: root.chartSize
            height: root.chartSize
            series: root.topApps
            maxCount: root.maxUsage
            total: root.usageTotal
            foreground: root.panelForeground
            fontFamily: root.fontFamily
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        PanelSeparator {
          width: parent.width
          visible: root.heroVisible
        }

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

          Column {
            id: sectionsColumn
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.sections

              delegate: Item {
                id: section
                required property var modelData
                required property int index

                // Read by the drag snapshot walking this Column's children.
                readonly property bool isCategorySection: true
                readonly property int sectionIndex: section.index

                readonly property bool first: section.index === 0
                readonly property bool last: section.index === root.sections.length - 1
                readonly property color accentColor: section.modelData.color
                readonly property bool dragging: root.dragActive && root.dragCategoryId === section.modelData.id
                readonly property bool paletteOpen: root.editMode && root.paletteCategory === section.modelData.id

                width: sectionsColumn.width
                height: sectionBody.implicitHeight + root.categoryPadding * 2
                visible: root.editMode || section.modelData.apps.length > 0
                opacity: section.dragging ? 0.45 : 1

                Behavior on opacity { NumberAnimation { duration: 110 } }

                // The category's own colour, laid on thin. This is what makes
                // the panel read as groups rather than as one long grid.
                Rectangle {
                  anchors.fill: parent
                  radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(8)
                  color: Qt.rgba(section.accentColor.r, section.accentColor.g, section.accentColor.b, root.categoryTint)

                  Behavior on color { ColorAnimation { duration: 140 } }
                }

                // A firmer edge on the left, so the block has a spine to read
                // the heading against even at a very low tint.
                Rectangle {
                  width: Math.max(2, Style.space(3))
                  height: parent.height - root.categoryPadding
                  radius: width / 2
                  color: Qt.rgba(section.accentColor.r, section.accentColor.g, section.accentColor.b, 0.75)
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(2)
                  anchors.verticalCenter: parent.verticalCenter
                }

                // Insertion line for a drag heading here.
                Rectangle {
                  visible: root.dropIndicatorAt(section.sectionIndex)
                  height: Math.max(2, Style.space(2))
                  radius: height / 2
                  color: Color.accent
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.topMargin: -Style.space(4)
                }

                Column {
                  id: sectionBody
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.leftMargin: root.categoryPadding
                  anchors.rightMargin: root.categoryPadding
                  anchors.topMargin: root.categoryPadding
                  spacing: Style.space(4)

                  Item {
                    width: parent.width
                    implicitHeight: Math.max(sectionTitle.implicitHeight, sectionTools.implicitHeight, Style.space(20))

                    // Grab handle. Press and drag it to move the whole
                    // category; the ‹ › buttons remain for one-step nudges and
                    // for anyone who would rather not drag at all.
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

                    // Colour swatch: click it to unfold the palette below.
                    Rectangle {
                      id: swatch
                      visible: root.editMode
                      width: root.editMode ? Style.space(14) : 0
                      height: Style.space(14)
                      radius: width / 2
                      color: section.accentColor
                      border.width: section.paletteOpen ? 2 : 0
                      border.color: root.panelForeground
                      anchors.left: dragGrip.right
                      anchors.leftMargin: root.editMode ? Style.space(6) : 0
                      anchors.verticalCenter: parent.verticalCenter

                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.paletteCategory = section.paletteOpen ? "" : section.modelData.id
                      }
                    }

                    PanelSectionHeader {
                      id: sectionTitle
                      visible: !root.editMode
                      text: section.modelData.name.toUpperCase()
                      // Blended rather than the raw colour: a saturated hue at
                      // heading weight is a lot of shouting for a launcher.
                      foreground: Qt.tint(root.panelForeground, Qt.rgba(section.accentColor.r, section.accentColor.g, section.accentColor.b, 0.65))
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
                      width: Math.max(Style.space(60), Math.min(Style.space(160),
                        parent.width - swatch.x - swatch.width - sectionTools.width - Style.space(14)))
                      anchors.left: swatch.right
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
                        iconText: "↑"
                        tooltipText: "Move category up"
                        enabled: !section.first
                        foreground: root.panelForeground
                        fontFamily: root.fontFamily
                        fontSize: Style.font.bodySmall
                        size: Style.space(20)
                        onClicked: root.moveCategory(section.modelData.id, -1)
                      }

                      PanelActionButton {
                        iconText: "↓"
                        tooltipText: "Move category down"
                        enabled: !section.last
                        foreground: root.panelForeground
                        fontFamily: root.fontFamily
                        fontSize: Style.font.bodySmall
                        size: Style.space(20)
                        onClicked: root.moveCategory(section.modelData.id, 1)
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

                  // ---- palette ---------------------------------------------

                  Flow {
                    id: palette
                    visible: section.paletteOpen
                    width: parent.width
                    spacing: Style.space(4)

                    Repeater {
                      model: Model.PALETTE

                      delegate: Rectangle {
                        required property var modelData

                        readonly property bool current: Qt.colorEqual(section.accentColor, modelData)

                        width: Style.space(15)
                        height: Style.space(15)
                        radius: width / 2
                        color: modelData
                        border.width: current ? 2 : 0
                        border.color: root.panelForeground
                        opacity: swatchMouse.containsMouse || current ? 1 : 0.72

                        MouseArea {
                          id: swatchMouse
                          anchors.fill: parent
                          hoverEnabled: true
                          cursorShape: Qt.PointingHandCursor
                          onClicked: {
                            root.setCategoryColor(section.modelData.id, modelData)
                            root.paletteCategory = ""
                          }
                        }
                      }
                    }

                    // Back to following the palette by position, which is what
                    // a category that has never been given a colour does.
                    Rectangle {
                      width: Style.space(15)
                      height: Style.space(15)
                      radius: width / 2
                      color: "transparent"
                      border.width: 1
                      border.color: Qt.rgba(root.panelForeground.r, root.panelForeground.g, root.panelForeground.b, autoMouse.containsMouse ? 0.9 : 0.5)

                      Text {
                        anchors.centerIn: parent
                        textFormat: Text.PlainText
                        text: "A"
                        color: root.panelForeground
                        opacity: autoMouse.containsMouse ? 0.9 : 0.55
                        font.family: root.fontFamily
                        font.pixelSize: Math.max(7, Math.round(Style.font.caption * 0.85))
                        font.bold: true
                      }

                      MouseArea {
                        id: autoMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                          root.setCategoryColor(section.modelData.id, "")
                          root.paletteCategory = ""
                        }
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
                        launchCount: root.launchCountOf(modelData.id)
                        showCount: root.showLaunchCounts
                        countIcon: root.countIcon
                        accent: section.accentColor
                        foreground: root.panelForeground
                        fontFamily: root.fontFamily
                        width: root.tileWidth

                        onActivated: root.launchApp(modelData)
                        onPointerEntered: {
                          root.cursorActive = false
                          root.selectedIndex = -1
                        }
                        onRemoveRequested: root.removeAppFrom(section.modelData.id, modelData.id)
                        onMoveRequested: function(direction) { root.moveAppIn(section.modelData.id, modelData.id, direction) }
                      }
                    }

                    // The add tile keeps the "+" where the eye already is — at
                    // the end of the row it belongs to.
                    Item {
                      visible: root.editMode
                      width: root.tileWidth
                      height: Style.space(8) + root.iconSize + (root.showLabels ? Style.space(4) + Math.ceil(Style.font.caption * 2.4) : 0) + Style.space(8)

                      Rectangle {
                        anchors.fill: parent
                        radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(6)
                        color: addMouse.containsMouse ? Qt.rgba(section.accentColor.r, section.accentColor.g, section.accentColor.b, 0.18) : "transparent"
                        border.width: 1
                        border.color: Qt.rgba(section.accentColor.r, section.accentColor.g, section.accentColor.b, 0.45)
                      }

                      Text {
                        anchors.centerIn: parent
                        textFormat: Text.PlainText
                        text: "＋"
                        color: root.panelForeground
                        opacity: 0.75
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
                color: Color.accent
              }
            }

            // ---- empty states ------------------------------------------------

            Text {
              width: parent.width
              visible: root.sections.length > 0 && root.flatApps.length === 0 && root.filterText.length > 0
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: "Nothing matches “" + root.filterText + "”. Backspace to clear."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              width: parent.width
              visible: root.sections.length === 0
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: "No categories yet. Hit Edit, add one, then drop your apps into it."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
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

  readonly property string pickerCategoryName: {
    var index = Model.categoryIndex(root.config, root.pickerCategory)
    return index === -1 ? "" : root.config.categories[index].name
  }

  // A launcher that fills the screen is not a discreet launcher: the grid
  // scrolls past `maxHeight` instead of growing, and the screen's own room
  // caps it after that. The most-used strip is above the scroll, so it comes
  // out of the same budget.
  readonly property int maxBodyHeight: Math.max(Style.space(120),
    Math.min(root.maxHeight, Math.round(panel.availableCardHeight - Style.space(110)))
      - (root.heroVisible ? root.heroHeight + Style.space(16) : 0))

  onPickerOpenChanged: {
    if (root.pickerOpen) Qt.callLater(function() { if (root.pickerOpen) picker.focusSearch() })
    else Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
  }
}
