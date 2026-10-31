import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar label and data source for the Instabox panel.
//
// `instabox ls --json` is the single source of truth: every poll replaces the
// box list, and the panel renders whatever is here. Actions are fire-and-forget
// (`--no-wait`) so the panel can show the server's own transient states
// (starting/stopping) instead of freezing on a click; polling speeds up while
// the panel is open or something is in flight.
BarWidget {
  id: root
  moduleName: "ak.instabox"

  // ---------------------------------------------------------------- data
  property var boxes: []
  property var busyIds: ({})        // box id -> "start" | "stop" | "resume"
  property string lastError: ""
  property string notice: ""
  property bool loading: true

  readonly property bool opened: panelLoader.item
    ? panelLoader.item.opened === true
    : false

  readonly property int refreshIntervalSec: Math.max(5, Number(setting("refreshIntervalSec", 30)))
  readonly property string labelMode: String(setting("labelMode", "Count"))
  readonly property int liveIntervalMs: 2500

  readonly property int runningCount: countInState(["running"])
  readonly property int pausedCount: countInState(["paused"])
  readonly property bool hasBusy: Object.keys(busyIds).length > 0
  readonly property bool transitioning: {
    for (var i = 0; i < boxes.length; i++) {
      if (boxes[i].state === "starting" || boxes[i].state === "stopping") return true
    }
    return false
  }

  function countInState(states) {
    var count = 0
    for (var i = 0; i < boxes.length; i++)
      if (states.indexOf(boxes[i].state) !== -1) count++
    return count
  }

  function boxById(id) {
    for (var i = 0; i < boxes.length; i++)
      if (boxes[i].id === id) return boxes[i]
    return null
  }

  // ------------------------------------------------------------- bar label
  readonly property string barText: {
    var mark = "▣"
    if (lastError !== "" && boxes.length === 0) return mark + " !"
    if (loading && boxes.length === 0) return mark + " …"
    if (labelMode === "Icon") return mark
    if (boxes.length === 0) return mark + " –"
    return mark + " " + runningCount + "/" + boxes.length
  }

  readonly property string barTooltip: {
    if (lastError !== "" && boxes.length === 0) return "Instabox · " + lastError
    if (loading && boxes.length === 0) return "Instabox · checking…"
    if (boxes.length === 0) return "Instabox · no sandboxes"
    return "Instabox · " + runningCount + " of " + boxes.length + " running"
      + (pausedCount > 0 ? " · " + pausedCount + " paused" : "")
      + " · click to manage"
  }

  // --------------------------------------------------------------- refresh
  property bool refreshQueued: false

  function refresh() {
    if (listProcess.running) {
      refreshQueued = true
      return
    }
    listProcess.running = true
  }

  function scheduleRefresh() {
    refreshQueued = false
    Qt.callLater(root.refresh)
  }

  Timer {
    // Idle is cheap; an open panel or a state change needs to feel live.
    interval: root.opened || root.hasBusy || root.transitioning
      ? root.liveIntervalMs
      : root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: busyTimeout
    interval: 120000
    running: root.hasBusy
    repeat: false
    onTriggered: root.busyIds = ({})
  }

  Process {
    id: listProcess
    command: ["instabox", "ls", "--json"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyListing(text)
    }

    stderr: StdioCollector {
      id: listError
      waitForEnd: true
    }

    onExited: function(exitCode) {
      root.loading = false
      if (exitCode !== 0) {
        var message = String(listError.text || "").trim()
        root.lastError = message !== "" ? firstLine(message) : "instabox ls failed"
      }
      if (root.refreshQueued) root.scheduleRefresh()
    }
  }

  function firstLine(text) {
    var lines = String(text).split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (line !== "") return line
    }
    return ""
  }

  function applyListing(output) {
    var parsed = null
    try {
      parsed = JSON.parse(String(output || ""))
    } catch (error) {
      root.lastError = "Could not read instabox output"
      return
    }
    if (!Array.isArray(parsed)) {
      root.lastError = "Could not read instabox output"
      return
    }

    var next = []
    for (var i = 0; i < parsed.length; i++) {
      var raw = parsed[i] || {}
      var id = String(raw.id || "")
      if (id === "") continue
      var runtime = raw.runtime || ({})
      var template = raw.template || ({})
      next.push({
        id: id,
        name: String(raw.name || id),
        state: normalizeState(raw.state),
        template: String(template.id || ""),
        createdAt: String(raw.createdAt || ""),
        autoSuspendAfterSeconds: Number(raw.autoSuspendAfterSeconds || 0),
        ready: runtime.ready === true,
        vault: raw.vault !== false
      })
    }

    root.lastError = ""
    root.boxes = next
    root.pruneBusy()
  }

  function normalizeState(value) {
    var state = String(value || "").toLowerCase()
    if (state === "running") return "running"
    if (state === "starting" || state === "resuming" || state === "waking") return "starting"
    if (state === "stopping") return "stopping"
    if (state === "stopped") return "stopped"
    if (state === "suspended" || state === "paused" || state === "suspending") return "paused"
    return state === "" ? "unknown" : state
  }

  // --------------------------------------------------------------- actions
  function isBusy(id) {
    return busyIds[id] !== undefined
  }

  function actionLabel(box) {
    if (isBusy(box.id)) {
      var verb = busyIds[box.id]
      if (verb === "stop") return "Stopping…"
      if (verb === "resume") return "Resuming…"
      return "Starting…"
    }
    if (box.state === "running") return "Stop"
    if (box.state === "paused") return "Resume"
    if (box.state === "starting") return "Starting…"
    if (box.state === "stopping") return "Stopping…"
    return "Start"
  }

  function canAct(box) {
    if (isBusy(box.id)) return false
    return box.state !== "starting" && box.state !== "stopping"
  }

  function actionVerb(box) {
    if (box.state === "running") return "stop"
    if (box.state === "paused") return "resume"
    return "start"
  }

  function runPrimary(box) {
    if (!box || !canAct(box)) return
    runAction(box, actionVerb(box))
  }

  property var actionQueue: []
  property bool actionRunning: false

  function runAction(box, verb) {
    if (!box) return
    enqueueAction(verb, box.id, box.name)
  }

  // Queue one CLI call. Busy state is keyed by the target so repeated clicks
  // and scripted calls collapse into one action per box.
  function enqueueAction(verb, id, name) {
    var target = String(id || "")
    if (target === "" || isBusy(target)) return false
    var busy = clone(busyIds)
    busy[target] = verb
    busyIds = busy
    actionQueue = actionQueue.concat([{ id: target, name: String(name || target), verb: verb }])
    pumpActions()
    return true
  }

  function pumpActions() {
    if (actionRunning || actionQueue.length === 0) return
    var job = actionQueue[0]
    actionRunning = true
    actionProcess.command = ["instabox", job.verb, "--no-wait", job.id]
    actionProcess.running = true
  }

  function finishAction(job, ok, message) {
    actionRunning = false
    if (!ok) {
      clearBusy(job.id)
      notice = message !== "" ? message : "Could not " + job.verb + " " + job.name
      noticeTimer.restart()
    } else {
      notice = ""
      // Keep the row busy until the server reports the target state, or drop
      // it right away when the target is not one of the listed boxes (a
      // scripted call with an unknown name).
      if (boxById(job.id) === null || targetReached(job)) clearBusy(job.id)
    }
    scheduleRefresh()
    pumpActions()
  }

  function targetReached(job) {
    var box = boxById(job.id)
    if (!box) return true
    if (job.verb === "stop") return box.state === "stopped" || box.state === "paused"
    return box.state === "running"
  }


  function clearBusy(id) {
    if (busyIds[id] === undefined) return
    var busy = clone(busyIds)
    delete busy[id]
    busyIds = busy
  }

  // A box leaves the busy set as soon as the server reports the state the
  // action was aiming at. The timeout only covers a lost or wedged request.
  function pruneBusy() {
    var keys = Object.keys(busyIds)
    if (keys.length === 0) return
    var busy = clone(busyIds)
    var changed = false
    for (var i = 0; i < keys.length; i++) {
      var id = keys[i]
      var box = boxById(id)
      var done = box === null
      if (box !== null) {
        done = busyIds[id] === "stop"
          ? (box.state === "stopped" || box.state === "paused")
          : box.state === "running"
      }
      if (done) {
        delete busy[id]
        changed = true
      }
    }
    if (changed) busyIds = busy
  }

  function clone(value) {
    var copy = {}
    for (var key in (value || {})) copy[key] = value[key]
    return copy
  }

  Timer {
    id: noticeTimer
    interval: 6000
    onTriggered: root.notice = ""
  }

  Process {
    id: actionProcess
    running: false

    stderr: StdioCollector {
      id: actionError
      waitForEnd: true
    }

    onExited: function(exitCode) {
      var job = root.actionQueue.length > 0 ? root.actionQueue[0] : null
      root.actionQueue = root.actionQueue.slice(1)
      if (!job) {
        root.actionRunning = false
        return
      }
      var message = String(actionError.text || "").trim()
      root.finishAction(job, exitCode === 0, message !== "" ? firstLine(message) : "")
    }
  }

  // -------------------------------------------------------------- panel
  function toggle() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  // Scriptable entry point, matching the first-party panel convention:
  //   omarchy-shell shell call ak.instabox toggle
  //   omarchy-shell shell call ak.instabox status
  IpcHandler {
    target: "ak.instabox"

    function open(): void { if (panelLoader.item) panelLoader.item.open() }
    function close(): void { root.close() }
    function show(): void { if (panelLoader.item) panelLoader.item.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function status(): string { return JSON.stringify(root.boxes) }
    function start(target: string): string { return root.enqueueAction("start", target, target) ? "ok" : "unknown" }
    function stop(target: string): string { return root.enqueueAction("stop", target, target) ? "ok" : "unknown" }
    function resume(target: string): string { return root.enqueueAction("resume", target, target) ? "ok" : "unknown" }
  }

  function injectPanel() {
    if (!panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
  }

  onBarChanged: injectPanel()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText
    // Nothing running anywhere is a real, quiet state: no errors, no work.
    dimmed: root.runningCount === 0
      || (root.boxes.length > 0 && root.runningCount === 0)
    tooltipText: root.barTooltip
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
      else if (buttonCode === Qt.MiddleButton) root.refresh()
    }
  }
}
