import QtQuick
import Quickshell
import Quickshell.Io

// Package facts behind the details card — version, first install, last update,
// size, where the entry came from — gathered by appinfo.sh and kept for the
// rest of the shell session.
//
// One lookup runs at a time. Hovering across a row of tiles asks for each in
// turn, and only the last one asked for is still wanted, so a newer request
// replaces a queued one rather than lining up behind it. A failed or empty
// lookup is cached too: asking pacman again on the next hover would not make
// an AppImage any more packaged.
Item {
  id: root

  property int deadline: 3

  // id -> { file, source, pkg, version, installed, updated, size, url, exec }
  property var cache: ({})
  // Bumped on every arrival, so bindings that read `infoFor` re-run.
  property int revision: 0

  property string activeId: ""
  property string queuedId: ""

  readonly property string scriptPath: String(Qt.resolvedUrl("appinfo.sh")).replace(/^file:\/\//, "")
  readonly property string home: String(Quickshell.env("HOME") || "")

  function infoFor(id) {
    root.revision  // binding dependency
    return root.cache[String(id || "")] || null
  }

  function has(id) {
    return root.cache[String(id || "")] !== undefined
  }

  function request(id) {
    var key = String(id || "")
    if (key.length === 0 || root.has(key)) return
    if (proc.running) {
      if (key !== root.activeId) root.queuedId = key
      return
    }
    root.start(key)
  }

  function start(key) {
    root.activeId = key
    proc.command = ["/usr/bin/timeout", "-k", "1", String(root.deadline),
                    "/usr/bin/bash", root.scriptPath, "--", key]
    proc.running = true
  }

  function store(key, text) {
    var info = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length && i < 32; i++) {
      var at = lines[i].indexOf("=")
      if (at <= 0) continue
      info[lines[i].slice(0, at)] = lines[i].slice(at + 1).slice(0, 240)
    }
    var next = {}
    for (var k in root.cache) next[k] = root.cache[k]
    next[key] = info
    root.cache = next
    root.revision++
  }

  function finish(text) {
    var key = root.activeId
    root.activeId = ""
    if (key.length > 0) root.store(key, text)
    var queued = root.queuedId
    root.queuedId = ""
    if (queued.length > 0 && !root.has(queued)) root.start(queued)
  }

  Process {
    id: proc
    clearEnvironment: true
    environment: ({
      "PATH": root.home + "/.local/bin:/usr/local/bin:/usr/bin:/bin",
      "HOME": root.home,
      "LC_ALL": "C",
      "XDG_DATA_HOME": String(Quickshell.env("XDG_DATA_HOME") || ""),
      "XDG_DATA_DIRS": String(Quickshell.env("XDG_DATA_DIRS") || "")
    })
    workingDirectory: "/"
    stdout: StdioCollector {
      id: out
      waitForEnd: true
      onStreamFinished: root.finish(out.text)
    }
  }

  Component.onDestruction: proc.running = false
}
