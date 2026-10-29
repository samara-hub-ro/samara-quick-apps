import QtQuick
import Quickshell
import Quickshell.Io

// What the open applications cost: CPU, memory and TCP traffic per
// application group (see procstats.sh for what a group is), sampled every few
// seconds, with a short history for the sparklines.
//
// CPU is a share of the whole machine — 100% is every core busy — because the
// question the panel answers is "what is loading this computer", not "is this
// one thread pegged".
//
// Traffic is cumulative. A TCP socket's counters cover its whole life, so a
// connection that was already open when sampling began is counted in full; one
// that opened and closed between two samples is not seen at all. Closed
// sockets are folded into a per-group running total the moment they vanish.
// `since` is when this monitor first saw the group — what "since opening"
// honestly means here.
Item {
  id: root

  property bool active: true
  property int interval: 3000
  property int historyLength: 60

  // group -> { mem, cpu, rx, tx, since, history: [cpu...] }
  property var groups: ({})
  // [{ cls, pid, group }]
  property var windows: []
  // Total CPU share of every windowed group, oldest first.
  property var totalHistory: []
  property int ncpu: 1
  property int revision: 0

  // Bookkeeping between samples.
  property var lastCpu: ({})      // group -> { usec, at }
  property var liveSockets: ({})  // group -> { key -> { rx, tx } }
  property var closedTraffic: ({}) // group -> { rx, tx }
  property var firstSeen: ({})    // group -> epoch ms
  property var histories: ({})    // group -> [cpu...]

  readonly property string scriptPath: String(Qt.resolvedUrl("procstats.sh")).replace(/^file:\/\//, "")

  function sample() {
    if (!root.active || proc.running) return
    proc.running = true
  }

  function push(list, value) {
    var next = (list || []).slice()
    next.push(value)
    while (next.length > root.historyLength) next.shift()
    return next
  }

  function ingest(text) {
    var at = Date.now()
    var lines = String(text || "").split("\n")
    var wins = []
    var raw = {}       // group -> { mem, usec }
    var socks = {}     // group -> { key -> { rx, tx } }

    for (var i = 0; i < lines.length && i < 4000; i++) {
      var f = lines[i].split("\t")
      if (f[0] === "ncpu") root.ncpu = Math.max(1, parseInt(f[1], 10) || 1)
      else if (f[0] === "win" && f.length >= 4) wins.push({ cls: f[1], pid: parseInt(f[2], 10) || 0, group: f[3] })
      else if (f[0] === "grp" && f.length >= 4) raw[f[1]] = { mem: Number(f[2]) || 0, usec: Number(f[3]) || 0 }
      else if (f[0] === "sock" && f.length >= 5) {
        if (!socks[f[1]]) socks[f[1]] = {}
        socks[f[1]][f[2]] = { rx: Number(f[3]) || 0, tx: Number(f[4]) || 0 }
      }
    }

    var nextGroups = {}
    var nextLastCpu = {}
    var nextLive = {}
    var nextClosed = {}
    var nextFirst = {}
    var nextHist = {}
    var total = 0

    for (var g in raw) {
      var prev = root.lastCpu[g]
      var cpu = 0
      if (prev && at > prev.at && raw[g].usec >= prev.usec)
        cpu = Math.min(100, (raw[g].usec - prev.usec) / ((at - prev.at) * 1000) / root.ncpu * 100)
      nextLastCpu[g] = { usec: raw[g].usec, at: at }

      // Sockets that were here last time and are gone now closed in between;
      // their last counters join the running total.
      var closed = root.closedTraffic[g] || { rx: 0, tx: 0 }
      var crx = closed.rx, ctx = closed.tx
      var before = root.liveSockets[g] || {}
      var now = socks[g] || {}
      for (var k in before) if (!now[k]) { crx += before[k].rx; ctx += before[k].tx }
      var lrx = 0, ltx = 0
      for (var k2 in now) { lrx += now[k2].rx; ltx += now[k2].tx }
      nextLive[g] = now
      nextClosed[g] = { rx: crx, tx: ctx }

      nextFirst[g] = root.firstSeen[g] || at
      nextHist[g] = root.push(root.histories[g], cpu)
      nextGroups[g] = {
        mem: raw[g].mem,
        cpu: cpu,
        rx: crx + lrx,
        tx: ctx + ltx,
        since: nextFirst[g],
        history: nextHist[g],
        primed: !!prev
      }
      total += cpu
    }

    root.lastCpu = nextLastCpu
    root.liveSockets = nextLive
    root.closedTraffic = nextClosed
    root.firstSeen = nextFirst
    root.histories = nextHist
    root.windows = wins
    root.groups = nextGroups
    if (Object.keys(root.lastCpu).length > 0) root.totalHistory = root.push(root.totalHistory, Math.min(100, total))
    root.revision++
  }

  Timer {
    interval: root.interval
    running: root.active
    repeat: true
    triggeredOnStart: true
    onTriggered: root.sample()
  }

  // Take a fresh sample straight away when the panel opens, rather than show
  // numbers up to one interval old.
  function refresh() { root.sample() }

  Process {
    id: proc
    clearEnvironment: true
    environment: ({
      "PATH": "/usr/bin:/bin",
      "HOME": String(Quickshell.env("HOME") || ""),
      "LC_ALL": "C",
      "XDG_RUNTIME_DIR": String(Quickshell.env("XDG_RUNTIME_DIR") || ""),
      "HYPRLAND_INSTANCE_SIGNATURE": String(Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "")
    })
    command: ["/usr/bin/timeout", "-k", "1", "4", "/usr/bin/bash", root.scriptPath]
    workingDirectory: "/"
    stdout: StdioCollector {
      id: out
      waitForEnd: true
      onStreamFinished: root.ingest(out.text)
    }
  }

  // ---- ending an application ----------------------------------------------

  readonly property string killPath: String(Qt.resolvedUrl("killapp.sh")).replace(/^file:\/\//, "")

  function signalGroup(group, sig) {
    var g = String(group || "")
    if (g.length === 0 || (sig !== "TERM" && sig !== "KILL")) return
    Quickshell.execDetached(["/usr/bin/timeout", "3", "/usr/bin/bash", root.killPath, "--", g, sig])
  }

  Component.onDestruction: proc.running = false
}
