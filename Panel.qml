import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The Instabox panel. Rendering only: the bar widget owns polling and actions
// so the bar label and the panel can never disagree about what is running.
Panel {
  id: root
  moduleName: "ak.instabox"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  readonly property var w: hostWidget
  readonly property var boxes: w ? (w.boxes || []) : []
  readonly property string errorText: w ? String(w.lastError || "") : ""
  readonly property string noticeText: w ? String(w.notice || "") : ""
  readonly property bool loading: w ? w.loading === true : true

  readonly property color foreground: barForeground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: bar ? bar.foreground : Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property int cursorIndex: -1
  property bool cursorActive: false

  // ---------------------------------------------------------------- palette
  //
  // State is carried by a short rail and a word rather than a dot buried in a
  // sentence: the rail reads at a glance, the word removes the guesswork.
  // Everything derives from the bar foreground, so light and dark themes both
  // keep their contrast; only a running box gets full strength, which leaves a
  // list of sleeping boxes quiet.
  function alpha(color, value) {
    return Qt.rgba(color.r, color.g, color.b, value)
  }

  function stateRailColor(box) {
    if (!box) return alpha(foreground, 0.22)
    if (box.state === "running") return foreground
    if (box.state === "starting" || box.state === "stopping") return alpha(foreground, 0.85)
    if (box.state === "paused") return alpha(foreground, 0.5)
    return alpha(foreground, 0.26)
  }

  function stateWordColor(box) {
    if (!box) return alpha(foreground, 0.6)
    if (box.state === "running") return foreground
    if (box.state === "starting" || box.state === "stopping") return alpha(foreground, 0.9)
    if (box.state === "paused") return alpha(foreground, 0.78)
    return alpha(foreground, 0.6)
  }

  // Counts every state that is actually present. A zero count never earns a
  // slot ("0 running" was the loudest thing in the panel and said nothing),
  // and the total lives in the bar label and in the rows themselves.
  readonly property string summaryText: {
    if (boxes.length === 0) return ""
    var order = ["running", "paused", "stopped", "starting", "stopping"]
    var counts = ({})
    var extras = []
    for (var i = 0; i < boxes.length; i++) {
      var state = String(boxes[i].state || "unknown")
      counts[state] = (counts[state] || 0) + 1
      if (order.indexOf(state) < 0 && extras.indexOf(state) < 0) extras.push(state)
    }
    var labels = order.concat(extras)
    var parts = []
    for (var j = 0; j < labels.length; j++) {
      var count = counts[labels[j]] || 0
      if (count > 0) parts.push(count + " " + labels[j])
    }
    return parts.join(" · ")
  }

  function open() {
    controller.show()
  }

  function close() {
    controller.hide()
  }

  function refresh() {
    if (hostWidget) hostWidget.refresh()
  }

  function boxAt(index) {
    return index >= 0 && index < boxes.length ? boxes[index] : null
  }

  function runFor(box) {
    if (hostWidget && box) hostWidget.runPrimary(box)
  }

  function moveCursor(delta) {
    if (boxes.length === 0) return
    cursorActive = true
    if (cursorIndex < 0) cursorIndex = 0
    else cursorIndex = Math.max(0, Math.min(boxes.length - 1, cursorIndex + delta))
    Qt.callLater(scrollToCursor)
  }

  function scrollToCursor() {
    var row = rows.itemAt(cursorIndex)
    if (!row || !panelFlick) return
    var top = row.y
    var bottom = row.y + row.height
    if (top < panelFlick.contentY) panelFlick.contentY = top
    else if (bottom > panelFlick.contentY + panelFlick.height)
      panelFlick.contentY = Math.min(bottom - panelFlick.height,
                                    Math.max(0, panelFlick.contentHeight - panelFlick.height))
  }

  function stateLabel(box) {
    if (!box) return ""
    if (box.state === "running") return "Running"
    if (box.state === "paused") return "Paused"
    if (box.state === "stopped") return "Stopped"
    if (box.state === "starting") return "Starting"
    if (box.state === "stopping") return "Stopping"
    return "Unknown"
  }

  function durationLabel(seconds) {
    var value = Number(seconds)
    if (!isFinite(value) || value <= 0) return ""
    var minutes = Math.round(value / 60)
    if (minutes < 60) return minutes + "m"
    var hours = Math.floor(minutes / 60)
    var rest = minutes % 60
    return rest === 0 ? hours + "h" : hours + "h " + rest + "m"
  }

  // The template is the useful context; the auto-pause window only matters
  // while a box is awake. Putting the disposable detail last means narrow
  // panels elide the timer rather than the state or the template.
  function metaDetail(box) {
    if (!box) return ""
    var parts = []
    if (String(box.template || "") !== "") parts.push(box.template)
    if (box.state === "running") {
      var pause = durationLabel(box.autoSuspendAfterSeconds)
      parts.push(pause === "" ? "always on" : "auto-pause " + pause)
    }
    return parts.join("  ·  ")
  }

  function detailLine(box) {
    if (!box) return ""
    var parts = [box.name]
    if (box.createdAt !== "") {
      var created = new Date(box.createdAt)
      if (isFinite(created.getTime())) parts.push("created " + Qt.formatDate(created, "d MMM yyyy"))
    }
    var pause = durationLabel(box.autoSuspendAfterSeconds)
    if (pause !== "") parts.push("auto-pause " + pause)
    if (box.vault) parts.push("vault on")
    return parts.join("  ·  ")
  }

  // The footer teaches the one key that matters most right now. "enter stop"
  // on a running box, "enter resume" on a paused one — the hint doubles as a
  // confirmation of what the cursor is pointed at.
  readonly property string cursorVerb: {
    var box = boxAt(cursorIndex)
    return (w && box) ? w.actionVerb(box) : ""
  }

  readonly property string footerHint: {
    if (boxes.length === 0) return "r refresh"
    if (cursorVerb === "") return "↑↓ move · r refresh"
    return "↑↓ move · enter " + cursorVerb + " · r refresh"
  }

  onOpenedChanged: {
    if (!opened) return
    cursorActive = false
    cursorIndex = boxes.length > 0 ? 0 : -1
    if (panelFlick) panelFlick.contentY = 0
    refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // A poll can add or remove the box the cursor is sitting on.
  onBoxesChanged: {
    if (cursorIndex >= boxes.length) cursorIndex = boxes.length > 0 ? boxes.length - 1 : -1
    else if (cursorIndex < 0 && boxes.length > 0) cursorIndex = 0
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(370))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.moveCursor(dx)
      }
      onActivateRequested: root.runFor(root.boxAt(root.cursorIndex))
      onCloseRequested: root.close()
      onTabRequested: function(direction) {
        if (root.switchPanel(direction)) return
      }
      onTextKey: function(text) {
        if (text === "r" || text === "R") root.refresh()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Instabox"
            meta: root.summaryText
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          PanelSeparator { foreground: root.foreground }

          // ------------------------------------------------------- status
          StatusBanner {
            visible: root.errorText !== ""
            tone: root.urgent
            category: "ERROR"
            message: root.errorText
          }

          StatusBanner {
            visible: root.errorText === "" && root.noticeText !== ""
            tone: root.dim
            category: "NOTICE"
            message: root.noticeText
          }

          // -------------------------------------------------------- boxes
          Column {
            id: rowsColumn
            visible: root.boxes.length > 0
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              id: rows
              model: root.boxes

              delegate: CursorSurface {
                id: row
                required property var modelData
                required property int index

                width: rowsColumn.width
                implicitHeight: Math.max(labels.implicitHeight, action.implicitHeight) + Style.space(18)
                hasCursor: root.cursorActive && index === root.cursorIndex
                foreground: root.foreground
                accent: root.accent

                MouseArea {
                  id: rowMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  onClicked: {
                    root.cursorActive = true
                    root.cursorIndex = row.index
                  }
                  onEntered: {
                    root.cursorActive = true
                    root.cursorIndex = row.index
                  }
                }

                PanelToolTip {
                  visible: rowMouse.containsMouse
                  text: root.detailLine(row.modelData)
                  fontFamily: root.fontFamily
                }

                Rectangle {
                  width: Style.space(3)
                  height: Style.space(26)
                  radius: width / 2
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.stateRailColor(row.modelData)

                  Behavior on color {
                    ColorAnimation { duration: 200 }
                  }
                }

                Column {
                  id: labels
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(12)
                  anchors.right: action.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(3)

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: row.modelData.name
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  Row {
                    width: parent.width
                    spacing: Style.space(8)

                    Text {
                      id: stateWord
                      textFormat: Text.PlainText
                      text: root.stateLabel(row.modelData).toUpperCase()
                      color: root.stateWordColor(row.modelData)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      font.letterSpacing: 0.8
                    }

                    Text {
                      textFormat: Text.PlainText
                      width: Math.max(0, parent.width - stateWord.width - parent.spacing)
                      text: root.metaDetail(row.modelData)
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }
                }

                Button {
                  id: action
                  readonly property bool destructive: root.w
                    ? root.w.actionVerb(row.modelData) === "stop"
                    : false

                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.w ? root.w.actionLabel(row.modelData) : ""
                  enabled: root.w ? root.w.canAct(row.modelData) : false
                  // The kit's buttons have no disabled palette; a flat dim and
                  // no border at rest reads as text, not as a form control.
                  bordered: false
                  foreground: !enabled
                    ? root.alpha(root.foreground, 0.45)
                    : (destructive ? root.urgent : root.foreground)
                  accent: root.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  iconSize: Style.font.bodySmall
                  horizontalPadding: Style.space(8)
                  verticalPadding: Style.space(4)
                  onHovered: function(isHovered) {
                    if (!isHovered) return
                    root.cursorActive = true
                    root.cursorIndex = row.index
                  }
                  onClicked: root.runFor(row.modelData)
                }
              }
            }
          }

          // ------------------------------------------------------- empty
          Item {
            id: emptyState
            visible: root.boxes.length === 0 && root.errorText === ""
            width: parent.width
            implicitHeight: emptyColumn.implicitHeight + Style.space(12)

            Column {
              id: emptyColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.topMargin: Style.space(8)
              spacing: Style.space(6)

              PanelSectionHeader {
                width: parent.width
                text: root.loading ? "CHECKING INSTABOX…" : "NO SANDBOXES"
                horizontalAlignment: Text.AlignHCenter
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                textFormat: Text.PlainText
                visible: !root.loading
                width: parent.width
                text: "Create one from the terminal:"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                horizontalAlignment: Text.AlignHCenter
              }

              Item {
                visible: !root.loading
                width: parent.width
                implicitHeight: emptyCommand.implicitHeight

                BorderSurface {
                  id: emptyCommand
                  anchors.horizontalCenter: parent.horizontalCenter
                  implicitWidth: emptyCommandText.implicitWidth + Style.space(16)
                  implicitHeight: emptyCommandText.implicitHeight + Style.space(10)
                  color: "transparent"
                  borderSpec: Border.controlSpec("normal", root.foreground, root.accent)
                  radius: Style.cornerRadius

                  Text {
                    id: emptyCommandText
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    text: "instabox create --name work"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }

          // With no rows, the footer is the only way to retry a failed
          // listing from the mouse, so the error state keeps it. A healthy
          // empty panel does not need it and keeps its quiet centre.
          PanelSeparator {
            visible: root.boxes.length > 0 || root.errorText !== ""
            foreground: root.foreground
          }

          // ------------------------------------------------------- footer
          Row {
            visible: root.boxes.length > 0 || root.errorText !== ""
            width: parent.width
            spacing: Style.space(8)

            Text {
              width: parent.width - refreshAction.width - parent.spacing
              anchors.verticalCenter: parent.verticalCenter
              text: root.footerHint
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            PanelActionButton {
              id: refreshAction
              iconText: "󰑓"
              tooltipText: "Refresh (r)"
              foreground: root.dim
              hoverColor: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.body
              size: Style.space(22)
              anchors.verticalCenter: parent.verticalCenter
              onClicked: root.refresh()
            }
          }
        }
      }
    }
  }

  // Inline status banner: an eyebrow that names the kind of message and the
  // message itself. Errors borrow the urgent tone, notices stay neutral, so
  // the two states are recognisable without a second colour system.
  component StatusBanner: BorderSurface {
    id: banner
    property color tone: root.foreground
    property string category: ""
    property string message: ""

    width: parent ? parent.width : 0
    implicitHeight: bannerColumn.implicitHeight + Style.space(20)
    color: root.alpha(tone, 0.08)
    borderSpec: Border.flat(root.alpha(tone, 0.30), 1)
    radius: Style.cornerRadius

    Column {
      id: bannerColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        textFormat: Text.PlainText
        visible: banner.category !== ""
        text: banner.category
        color: banner.tone
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1.2
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: banner.message
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
  }
}
