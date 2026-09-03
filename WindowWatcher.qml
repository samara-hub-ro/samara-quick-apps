import QtQuick
import Quickshell
import Quickshell.Wayland
import "WindowMatch.js" as Match

// Counts applications opened from outside the panel — a keybinding, the
// Omarchy menu, a terminal, another launcher — by watching windows appear.
//
// There is no way to be told about those launches directly: the shell's own
// `AppLibrary.launch` emits no signal, and nothing else on the bus announces
// "someone started an app". What a Wayland compositor *does* announce is a new
// toplevel, so that is what this listens to, and it maps the window's `appId`
// back to a desktop entry the launcher holds.
//
// That mapping is the whole difficulty, and it is not perfect. Read
// `resolve` for the rules and the deliberate decision to credit nothing rather
// than credit the wrong application when a window is ambiguous.
Item {
  id: root

  property bool enabled: true
  // Ids the launcher holds. Windows are only ever resolved against these:
  // it keeps the matching cheap, and an application the user has not put in
  // the panel can never be mistaken for one they have.
  property var appIds: []

  // Some applications map a splash or a helper window a moment before their
  // real one. Crediting the same id twice inside this window is almost always
  // that rather than the user genuinely opening two.
  property int debounceMs: 1500
  // How long a launch made *by the panel* keeps the matching window from being
  // counted a second time. The panel counts its own launches the instant it
  // makes them, which is the one case we know for certain.
  property int suppressMs: 12000
  // A toplevel's appId is often still empty at the moment it is inserted, so
  // each one is looked at again a few times before being given up on.
  property int settleMs: 300
  property int settleTries: 8

  signal launched(string appId)

  // Windows that already existed when the shell started are not launches. They
  // reach us as inserts all the same, because the compositor enumerates every
  // open toplevel when the shell connects — and that enumeration can land well
  // after this component is created, so a plain "ignore the first two seconds"
  // does not cover it. Instead the burst pushes the arming out ahead of itself:
  // every insert while unarmed restarts the timer, so we go live only once the
  // model has been quiet, whenever that turns out to be.
  property bool armed: false
  // ...but never later than this, so a machine that opens a window every
  // second cannot keep the watcher asleep forever.
  property int armFloorMs: 1500
  property int armCeilingMs: 20000

  property var lastCounted: ({})   // appId -> epoch ms
  property var suppressed: ({})    // appId -> epoch ms
  property var pending: []         // [{ toplevel, tries }]

  function now() { return Date.now() }

  // Called by the panel when it launches something itself.
  function suppress(appId) {
    var id = String(appId || "")
    if (id.length === 0) return
    var next = {}
    for (var key in root.suppressed) next[key] = root.suppressed[key]
    next[id] = root.now()
    root.suppressed = next
  }

  // The matching rules live in WindowMatch.js so they can be run against a
  // real machine's entries and window classes without a shell; this only feeds
  // them the desktop-entry index.
  function entryFor(id) {
    var entry = null
    try { entry = DesktopEntries.byId(id) } catch (e) { entry = null }
    if (!entry) return null
    return { startupClass: String(entry.startupClass || ""), name: String(entry.name || "") }
  }

  function resolve(rawClass) {
    return Match.resolve(rawClass, root.appIds, function(id) { return root.entryFor(id) })
  }

  function credit(appId) {
    var id = String(appId || "")
    if (id.length === 0) return

    var at = root.now()

    var heldSince = root.suppressed[id]
    if (heldSince !== undefined && at - heldSince < root.suppressMs) {
      // The panel launched this and has already counted it. Spend the
      // suppression rather than leaving it to expire, so a second launch from
      // a keybinding moments later still registers.
      var stillHeld = {}
      for (var key in root.suppressed) if (key !== id) stillHeld[key] = root.suppressed[key]
      root.suppressed = stillHeld
      return
    }

    var previous = root.lastCounted[id]
    if (previous !== undefined && at - previous < root.debounceMs) return

    var next = {}
    for (var k in root.lastCounted) next[k] = root.lastCounted[k]
    next[id] = at
    root.lastCounted = next

    root.launched(id)
  }

  function queue(toplevel) {
    if (!root.enabled || !toplevel) return
    if (!root.armed) {
      arming.restart()
      return
    }
    var list = root.pending.slice()
    list.push({ toplevel: toplevel, tries: 0 })
    root.pending = list
    settle.start()
  }

  // A toplevel arrives before its appId does, so each one is revisited until
  // it has a class or has clearly not going to get one.
  function drain() {
    var keep = []
    for (var i = 0; i < root.pending.length; i++) {
      var item = root.pending[i]
      var appId = ""
      var alive = true
      try { appId = String(item.toplevel.appId || "") } catch (e) { alive = false }
      if (!alive) continue

      if (appId.length > 0) {
        root.credit(root.resolve(appId))
        continue
      }

      item.tries++
      if (item.tries < root.settleTries) keep.push(item)
    }
    root.pending = keep
    if (keep.length === 0) settle.stop()
  }

  Timer {
    id: settle
    interval: root.settleMs
    repeat: true
    onTriggered: root.drain()
  }

  Timer {
    id: arming
    interval: root.armFloorMs
    running: true
    onTriggered: root.armed = true
  }

  Timer {
    id: armCeiling
    interval: root.armCeilingMs
    running: true
    onTriggered: root.armed = true
  }

  Connections {
    target: ToplevelManager.toplevels
    enabled: root.enabled

    function onObjectInsertedPost(object, index) { root.queue(object) }
  }
}
