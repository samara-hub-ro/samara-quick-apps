import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "AppsModel.js" as Model

// Quick Apps — the apps you actually use, grouped into your own categories,
// one hover away from the bar.
//
// Three things shape the implementation:
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
  readonly property string configPath: {
    var custom = String(setting("configPath", "")).replace(/^\s+|\s+$/g, "")
    if (custom.length > 0) return custom.replace(/^~/, Quickshell.env("HOME"))
    return Quickshell.env("HOME") + "/.config/omarchy/quick-apps.json"
  }

  // ------------------------------------------------------------------- state

  property var config: Model.emptyConfig()
  property bool configLoaded: false
  property bool savingConfig: false
  property bool seedAttempted: false

  property bool keyboardMode: false
  property bool editMode: false
  property string filterText: ""
  property string pickerCategory: ""
  property int selectedIndex: -1
  property bool cursorActive: false

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
    }
  }

  Timer {
    id: saveGuard
    interval: 600
    onTriggered: root.savingConfig = false
  }

  // ------------------------------------------------------------- open/close

  function beforeOpen() {
    root.filterText = ""
    root.pickerCategory = ""
    root.editMode = false
    root.selectedIndex = -1
    root.cursorActive = false
    root.pointerEngaged = false
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
      return
    }
    // Every close path lands here: the shortcut, Escape, a launch, the pointer
    // leaving, or another bar popup taking over.
    root.hoverArmed = false
    root.keyboardMode = false
    root.editMode = false
    root.pickerCategory = ""
    root.filterText = ""
    root.selectedIndex = -1
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
  readonly property int gridWidth: root.columns * root.tileWidth + (root.columns - 1) * root.tileSpacing

  // ------------------------------------------------------------------- edits

  function addAppTo(categoryId, appId) { root.saveConfig(Model.addApp(root.config, categoryId, appId)) }
  function removeAppFrom(categoryId, appId) { root.saveConfig(Model.removeApp(root.config, categoryId, appId)) }
  function moveAppIn(categoryId, appId, direction) { root.saveConfig(Model.moveApp(root.config, categoryId, appId, direction)) }
  function addCategory() { root.saveConfig(Model.addCategory(root.config, "New category")) }
  function renameCategory(categoryId, name) { root.saveConfig(Model.renameCategory(root.config, categoryId, name)) }
  function removeCategory(categoryId) { root.saveConfig(Model.removeCategory(root.config, categoryId)) }
  function moveCategory(categoryId, direction) { root.saveConfig(Model.moveCategory(root.config, categoryId, direction)) }

  function appsIn(categoryId) {
    var index = Model.categoryIndex(root.config, categoryId)
    return index === -1 ? [] : root.config.categories[index].apps
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
    contentWidth: panel.fittedContentWidth(root.gridWidth)
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
                : "Editing — add, remove and reorder"
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
              if (!root.editMode) root.pickerCategory = ""
            }
          }
        }

        PanelSeparator { width: parent.width }

        Flickable {
          width: parent.width
          height: Math.min(sectionsColumn.implicitHeight, root.maxBodyHeight)
          contentWidth: width
          contentHeight: sectionsColumn.implicitHeight
          clip: true
          interactive: contentHeight > height
          boundsBehavior: Flickable.StopAtBounds

          Column {
            id: sectionsColumn
            width: parent.width
            spacing: Style.space(10)

            Repeater {
              model: root.sections

              delegate: Column {
                id: section
                required property var modelData
                required property int index

                readonly property bool first: section.index === 0
                readonly property bool last: section.index === root.sections.length - 1

                width: sectionsColumn.width
                spacing: Style.space(4)
                visible: root.editMode || section.modelData.apps.length > 0

                Item {
                  width: parent.width
                  implicitHeight: Math.max(sectionTitle.implicitHeight, sectionTools.implicitHeight)

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
                    width: Math.min(Style.space(160), parent.width - sectionTools.width - Style.space(8))
                    anchors.left: parent.left
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
                      iconText: "‹"
                      tooltipText: "Move category up"
                      enabled: !section.first
                      foreground: root.panelForeground
                      fontFamily: root.fontFamily
                      fontSize: Style.font.bodySmall
                      size: Style.space(20)
                      onClicked: root.moveCategory(section.modelData.id, -1)
                    }

                    PanelActionButton {
                      iconText: "›"
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
                      color: addMouse.containsMouse ? Qt.rgba(root.panelForeground.r, root.panelForeground.g, root.panelForeground.b, 0.09) : "transparent"
                      border.width: 1
                      border.color: Qt.rgba(root.panelForeground.r, root.panelForeground.g, root.panelForeground.b, 0.22)
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
  // caps it after that.
  readonly property int maxBodyHeight: Math.max(Style.space(120),
    Math.min(root.maxHeight, Math.round(panel.availableCardHeight - Style.space(110))))

  onPickerOpenChanged: {
    if (root.pickerOpen) Qt.callLater(function() { if (root.pickerOpen) picker.focusSearch() })
    else Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
  }
}
