import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "ChannelsModel.js" as Model

// Oma TV — free live channels in a taskbar popup. One shared mpv player is
// driven entirely by scripts/oma-tv-ctl (Hyprland window modes + mpv IPC), so
// this widget only parses channel lists and issues controller commands.
BarWidget {
  id: root

  moduleName: "user.oma-tv"

  readonly property url ctlUrl: Qt.resolvedUrl("scripts/oma-tv-ctl")
  readonly property url parseUrl: Qt.resolvedUrl("scripts/parse-m3u.sh")
  readonly property string ctlPath: root.localPath(ctlUrl)
  readonly property string parsePath: root.localPath(parseUrl)

  readonly property var builtinServices: [
    { id: "roku", label: "Roku", file: "roku.m3u" }
  ]
  property var services: []

  property bool opened: false
  property string activeService: "roku"
  property string filterText: ""
  property string selectedGroup: "All"
  property int selectedIndex: 0
  property bool cursorActive: false
  property var channels: []
  property var filteredChannels: []
  property var groups: []
  property var serviceData: ({})
  property int dataRevision: 0

  property bool running: false
  property string nowService: ""
  property int nowIndex: 0
  property int nowCount: 0
  property string nowTitle: ""
  property string mode: "pip"
  property bool paused: false
  property bool refreshing: false
  property bool awaitingReload: false
  property string statusMessage: ""
  property bool statusError: false
  property var ctlQueue: []
  property var parseQueue: []
  property bool statusRefreshPending: false
  property bool addMode: false
  property string addUrl: ""
  property string pendingAdd: ""
  property string pendingRemove: ""
  property bool svcPending: false

  readonly property bool ctlBusy: {
    root.dataRevision
    return root.ctlQueue.length > 0 || ctlProc.running
  }
  readonly property string modeLabel: root.mode === "fullscreen" ? "Fullscreen"
    : root.mode === "window" ? "Windowed" : "PiP"
  readonly property int rowHeight: Math.max(Style.space(36), Style.font.body + Style.spacing.controlPaddingY * 2)

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function localPath(value) {
    var text = String(value || "")
    if (text.slice(0, 7) === "file://") text = text.slice(7)
    try { return decodeURIComponent(text) } catch (e) { return text }
  }

  function m3uPath(id) {
    for (var i = 0; i < root.services.length; i++) {
      if (root.services[i].id === id)
        return root.localPath(Qt.resolvedUrl("channels/" + root.services[i].file))
    }
    return ""
  }

  function dataFor(id) {
    var store = root.serviceData
    if (!store[id]) store[id] = { loaded: false, loading: false, error: "", channels: [], groups: [], count: 0 }
    return store[id]
  }

  function ensureLoaded(id) {
    var info = root.dataFor(id)
    if (info.loaded || info.loading || parseProc.running || root.parseQueue.length > 0) {
      if (parseProc.running && !root.parseQueueContains(id)) {
        root.parseQueue.push(id)
      }
      return
    }
    info.loading = true
    root.dataRevision++
    parseProc.pendingId = id
    parseProc.command = [root.parsePath, root.m3uPath(id)]
    parseProc.running = true
  }

  function parseQueueContains(id) {
    for (var i = 0; i < root.parseQueue.length; i++) {
      if (root.parseQueue[i] === id) return true
    }
    return false
  }

  function applyParsed(id, line) {
    var parsed = Model.parseChannels(line)
    var info = root.dataFor(id)
    info.loading = false
    if (parsed.length > 0) {
      info.channels = parsed
      info.groups = ["All"].concat(Model.extractGroups(parsed))
      info.count = parsed.length
      info.error = ""
      info.loaded = true
    } else {
      info.error = "No channels found"
    }
    root.dataRevision++
    if (id === root.activeService) {
      root.channels = info.channels
      root.groups = info.groups
      root.applyFilter()
    }
  }

  function applyFilter() {
    root.filteredChannels = Model.filterChannels(root.channels, root.filterText, root.selectedGroup)
    if (root.selectedIndex >= root.filteredChannels.length && root.filteredChannels.length > 0)
      root.selectedIndex = 0
    root.cursorActive = root.filteredChannels.length > 0
  }

  function selectService(id) {
    if (id === root.activeService) return
    root.activeService = id
    root.filterText = ""
    root.selectedGroup = "All"
    root.selectedIndex = 0
    var info = root.dataFor(id)
    root.channels = info.loaded ? info.channels : []
    root.groups = info.loaded ? info.groups : []
    root.applyFilter()
    root.ensureLoaded(id)
  }

  function selectGroup(group) {
    root.selectedGroup = group
    root.selectedIndex = 0
    root.cursorActive = true
    root.applyFilter()
  }

  function select(delta) {
    if (root.filteredChannels.length === 0) return
    if (!root.cursorActive) {
      root.cursorActive = true
      root.selectedIndex = delta < 0 ? root.filteredChannels.length - 1 : 0
    } else {
      root.selectedIndex = (root.selectedIndex + delta + root.filteredChannels.length) % root.filteredChannels.length
    }
    channelList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function playSelected() {
    if (root.filteredChannels.length === 0) return
    var ch = root.filteredChannels[Math.min(Math.max(root.selectedIndex, 0), root.filteredChannels.length - 1)]
    if (ch && ch.index !== undefined) {
      root.runCtl("play", root.activeService, String(ch.index))
      root.opened = false
    }
  }

  function setMode(target) {
    root.runCtl("mode", target)
  }

  function cycleMode() {
    root.runCtl("mode")
  }

  function stopPlayback() {
    root.runCtl("stop")
  }

  function zap(delta) {
    root.runCtl(delta < 0 ? "prev" : "next")
  }

  function refreshChannels() {
    if (root.ctlBusy) return
    root.refreshing = true
    root.awaitingReload = true
    root.statusMessage = "Refreshing channel lists…"
    root.statusError = false
    root.runCtl("refresh")
  }

  function reloadAfterRefresh() {
    root.refreshing = false
    var store = root.serviceData
    for (var key in store) delete store[key]
    root.dataRevision++
    root.channels = []
    root.groups = []
    root.applyFilter()
    for (var i = 0; i < root.services.length; i++) root.ensureLoaded(root.services[i].id)
  }

  function refreshServices() {
    if (svcProc.running) {
      root.svcPending = true
      return
    }
    svcProc.command = [root.ctlPath, "services"]
    svcProc.running = true
  }

  function applyServices(list) {
    if (!Array.isArray(list) || list.length === 0) return
    var active = root.activeService
    var found = false
    for (var i = 0; i < list.length; i++) {
      if (list[i].id === active) { found = true; break }
    }
    if (!found) active = list[0].id
    root.services = list
    root.activeService = active
    root.dataRevision++
    var info = root.dataFor(root.activeService)
    root.channels = info.loaded ? info.channels : []
    root.groups = info.loaded ? info.groups : []
    root.filterText = ""
    root.selectedGroup = "All"
    root.selectedIndex = 0
    root.applyFilter()
    for (var k = 0; k < root.services.length; k++) root.ensureLoaded(root.services[k].id)
  }

  function startAdd() {
    root.addMode = true
    root.addUrl = ""
    root.statusMessage = ""
    root.statusError = false
    panelFocus.forceActiveFocus()
  }

  function cancelAdd() {
    root.addMode = false
    root.addUrl = ""
    panelFocus.forceActiveFocus()
  }

  function confirmAdd() {
    var url = root.addUrl.trim()
    if (url === "") { root.cancelAdd(); return }
    root.addMode = false
    root.addUrl = ""
    root.pendingAdd = url
    root.statusMessage = "Adding playlist…"
    root.statusError = false
    root.runCtl("add", url)
  }

  function removeService(id) {
    if (root.ctlBusy || root.pendingRemove !== "" || root.pendingAdd !== "") return
    root.pendingRemove = id
    root.statusMessage = "Removing playlist…"
    root.statusError = false
    root.runCtl("remove", id)
  }

  function handleAddRemoveDone() {
    if (root.pendingAdd !== "") {
      var url = root.pendingAdd
      root.pendingAdd = ""
      if (ctlProc.capturedError !== "") {
        root.statusMessage = ctlProc.capturedError
        root.statusError = true
      } else {
        root.statusMessage = "Playlist added"
        root.statusError = false
        var res = ctlProc.lastResult
        if (res && res.id) {
          root.services.push({ id: String(res.id), label: String(res.label || res.id), file: String(res.file || ""), custom: true })
          root.dataRevision++
          root.selectService(String(res.id))
        }
        root.refreshServices()
      }
    }
    if (root.pendingRemove !== "") {
      var rid = root.pendingRemove
      root.pendingRemove = ""
      if (ctlProc.capturedError !== "") {
        root.statusMessage = ctlProc.capturedError
        root.statusError = true
      } else {
        root.statusMessage = "Removed playlist"
        root.statusError = false
        if (root.activeService === rid) root.activeService = "roku"
        root.refreshServices()
      }
    }
  }

  function togglePause() {
    root.runCtl("pause")
  }

  function runCtl() {
    var args = Array.prototype.slice.call(arguments)
    root.ctlQueue.push(args)
    root.dataRevision++
    if (!ctlProc.running) root.runNextCtl()
  }

  function runNextCtl() {
    if (root.ctlQueue.length === 0) return
    var args = root.ctlQueue.shift()
    root.dataRevision++
    ctlProc.capturedError = ""
    ctlProc.command = [root.ctlPath].concat(args)
    ctlProc.running = true
    Qt.callLater(root.refreshStatus)
  }

  function refreshStatus() {
    if (statusProc.running) {
      root.statusRefreshPending = true
      return
    }
    root.statusRefreshPending = false
    statusProc.command = [root.ctlPath, "status"]
    statusProc.running = true
  }

  function applyStatus(raw) {
    var data
    try {
      data = JSON.parse(String(raw || "").trim())
    } catch (e) {
      return
    }
    if (!data || typeof data !== "object") return
    root.running = data.running === true
    root.nowService = String(data.service || "")
    root.nowIndex = Number(data.index || 0)
    root.nowCount = Number(data.count || 0)
    var title = String(data.title || "")
    if (title === "" || title.indexOf(".m3u8") !== -1 || title.indexOf(".ts") !== -1) {
      var info = root.dataFor(root.nowService)
      var idx = root.nowIndex
      if (info && info.loaded && idx >= 0 && idx < info.channels.length)
        title = info.channels[idx].name
      else if (root.nowService === root.activeService && idx >= 0 && idx < root.channels.length)
        title = root.channels[idx].name
    }
    root.nowTitle = title
    root.mode = String(data.mode || "pip")
    root.paused = data.paused === true
  }

  function open(payloadJson) {
    root.opened = true
    root.filterText = ""
    root.selectedGroup = "All"
    for (var i = 0; i < root.services.length; i++) root.ensureLoaded(root.services[i].id)
    root.refreshServices()
    Qt.callLater(function() {
      if (root.opened) panelFocus.forceActiveFocus()
    })
  }

  function close() {
    root.opened = false
  }

  function togglePanel() {
    root.opened ? root.close() : root.open("{}")
  }

  Process {
    id: parseProc
    property string pendingId: ""
    command: []

    stdout: SplitParser {
      onRead: function(line) {
        if (parseProc.pendingId !== "") root.applyParsed(parseProc.pendingId, line)
        parseProc.pendingId = ""
      }
    }
    stderr: SplitParser {
      onRead: function(line) {
        var info = root.dataFor(parseProc.pendingId)
        info.loading = false
        if (line !== "") info.error = line
      }
    }
    onExited: function() {
      Qt.callLater(function() {
        var pid = parseProc.pendingId
        if (pid !== "") {
          var inf = root.dataFor(pid)
          inf.loading = false
          root.dataRevision++
        }
        parseProc.pendingId = ""
        if (root.parseQueue.length > 0) {
          var next = root.parseQueue.shift()
          var nextInfo = root.dataFor(next)
          nextInfo.loading = true
          root.dataRevision++
          parseProc.pendingId = next
          parseProc.command = [root.parsePath, root.m3uPath(next)]
          parseProc.running = true
        }
      })
    }
  }

  Process {
    id: ctlProc
    command: []
    property string capturedError: ""
    property var lastResult: ({})

    stdout: SplitParser {
      onRead: function(line) {
        var text = String(line || "").trim()
        if (text === "") return
        var parsed
        try { parsed = JSON.parse(text) } catch (e) { return }
        if (parsed.error) {
          ctlProc.capturedError = String(parsed.error)
        } else {
          ctlProc.lastResult = parsed
        }
      }
    }
    stderr: SplitParser {
      onRead: function(line) {
        if (String(line || "").trim() !== "") ctlProc.capturedError = String(line)
      }
    }
    onExited: function(exitCode) {
      Qt.callLater(function() {
        root.refreshing = false
        root.handleAddRemoveDone()
        if (root.awaitingReload) {
          root.awaitingReload = false
          root.reloadAfterRefresh()
        }
        if (ctlProc.capturedError !== "") {
          root.statusMessage = ctlProc.capturedError
          root.statusError = true
        } else {
          root.statusError = false
        }
        if (root.ctlQueue.length > 0) root.runNextCtl()
        else Qt.callLater(root.refreshStatus)
      })
    }
  }

  Process {
    id: svcProc
    command: []
    property var pendingList: []

    stdout: SplitParser {
      onRead: function(line) {
        var text = String(line || "").trim()
        if (text === "") return
        var parsed
        try { parsed = JSON.parse(text) } catch (e) { return }
        if (parsed && Array.isArray(parsed.services)) {
          svcProc.pendingList = parsed.services
        }
      }
    }
    onExited: function() {
      Qt.callLater(function() {
        var list = svcProc.pendingList
        svcProc.pendingList = []
        if (list && list.length > 0) root.applyServices(list)
        if (root.svcPending) {
          root.svcPending = false
          Qt.callLater(root.refreshServices)
        }
      })
    }
  }

  Process {
    id: statusProc
    command: []

    stdout: SplitParser {
      onRead: function(line) {
        root.applyStatus(line)
      }
    }
    onExited: function() {
      Qt.callLater(function() {
        if (root.statusRefreshPending) {
          root.statusRefreshPending = false
          Qt.callLater(root.refreshStatus)
        }
      })
    }
  }

  Timer {
    interval: root.running ? 1500 : 3000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshStatus()
  }

  Component.onCompleted: {
    root.services = root.builtinServices.slice()
    root.dataRevision++
    root.refreshServices()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf26c"
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.body
    active: root.running || root.statusError
    activeColor: root.statusError ? (root.bar ? root.bar.urgent : Color.urgent) : Color.accent
    dimmed: !root.running && !root.statusError
    tooltipText: root.running
      ? "Oma TV · " + root.nowTitle + " · " + root.modeLabel + " · Left click: popup · Right click: resize · Middle: stop"
      : "Oma TV · Left click: popup · Right click: resize · Middle: stop"

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.cycleMode()
      else if (buttonCode === Qt.MiddleButton) root.stopPlayback()
      else root.togglePanel()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panelFocus
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(660))

    Item {
      id: panelFocus
      anchors.fill: parent
      focus: true

      Keys.onEscapePressed: if (!root.addMode) root.close()
      Keys.onPressed: function(event) {
        if (root.addMode) {
          if (event.key === Qt.Key_Escape) {
            root.cancelAdd()
          } else if (event.key === Qt.Key_Backspace) {
            root.addUrl = root.addUrl.slice(0, -1)
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.confirmAdd()
          } else if (event.text && event.text.length === 1
                     && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.addUrl = root.addUrl + event.text
          }
          event.accepted = true
        } else if (event.key === Qt.Key_Up) {
          root.select(-1)
          event.accepted = true
        } else if (event.key === Qt.Key_Down) {
          root.select(1)
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.playSelected()
          event.accepted = true
        } else if (event.text && event.text.length === 1
                   && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
          root.filterText = root.filterText + event.text
          root.applyFilter()
          event.accepted = true
        }
      }

      Flickable {
        id: panelScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: panelColumn.implicitHeight
        clip: true
        interactive: contentHeight > height
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: panelColumn
          width: panelScroll.width
          spacing: Style.spacing.panelGap

          Item {
            width: parent.width
            implicitHeight: Math.max(headerText.implicitHeight, refreshButton.implicitHeight)

            Column {
              id: headerText
              anchors.left: parent.left
              anchors.right: refreshButton.left
              anchors.rightMargin: Style.spacing.controlGap
              spacing: Style.spacing.xs

              Text {
                width: parent.width
                text: "OMA TV"
                color: Color.popups.text
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                text: root.running
                  ? root.nowTitle + " · " + root.modeLabel + (root.paused ? " · paused" : "")
                  : "Free live TV · Roku channels & your own m3u lists"
                color: Qt.darker(Color.popups.text, 1.45)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            PanelActionButton {
              id: refreshButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: "\uf021"
              tooltipText: "Refresh channel lists"
              foreground: Color.popups.text
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              enabled: !root.ctlBusy
              onClicked: root.refreshChannels()
            }
          }

          Row {
            width: parent.width
            spacing: Style.spacing.controlGap

            ButtonGroup {
              id: modeGroup
              width: parent.width - stopButton.width - parent.spacing
              value: root.mode
              options: [
                { value: "pip", label: "PiP" },
                { value: "window", label: "Window" },
                { value: "fullscreen", label: "Full" }
              ]
              foreground: Color.popups.text
              background: Color.popups.background
              accent: Color.accent
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              enabled: root.running
              onChanged: function(value) {
                root.setMode(value)
              }
            }

            Button {
              id: stopButton
              width: Style.space(40)
              text: "\uf04d"
              iconSpinning: root.ctlBusy
              selected: root.running
              bordered: true
              focusable: true
              foreground: root.bar ? root.bar.urgent : Color.urgent
              accent: root.bar ? root.bar.urgent : Color.urgent
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              enabled: root.running
              onClicked: root.stopPlayback()
            }
          }

          ButtonGroup {
            id: serviceGroup
            width: parent.width
            value: root.activeService
            options: root.serviceOptions
            foreground: Color.popups.text
            background: Color.popups.background
            accent: Color.accent
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            enabled: !root.ctlBusy
            onChanged: function(value) {
              root.selectService(value)
            }
          }

          Button {
            id: addPlaylistButton
            width: parent.width
            height: Style.space(30)
            text: "\uf067  Add m3u playlist"
            foreground: Color.popups.text
            accent: Color.accent
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            enabled: !root.ctlBusy && !root.addMode
            visible: !root.addMode
            onClicked: root.startAdd()
          }

          Rectangle {
            width: parent.width
            height: Style.space(34)
            radius: Style.cornerRadius * 0.8
            color: Qt.rgba(1, 1, 1, 0.05)
            visible: root.addMode

            Row {
              anchors.fill: parent
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.spacing.xs

              Text {
                anchors.verticalCenter: parent.verticalCenter
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
                text: "\uf0c1"
                color: Color.accent
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - hintText.implicitWidth - parent.spacing - Style.space(16)
                text: root.addUrl !== "" ? root.addUrl : "Paste an m3u URL…"
                color: root.addUrl !== "" ? Color.popups.text : Qt.darker(Color.popups.text, 1.4)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }

              Text {
                id: hintText
                anchors.verticalCenter: parent.verticalCenter
                text: "↵ add · esc cancel"
                color: Qt.darker(Color.popups.text, 1.45)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            MouseArea {
              anchors.fill: parent
              onClicked: panelFocus.forceActiveFocus()
            }
          }

          Flow {
            width: parent.width
            spacing: Style.spacing.xs
            visible: root.customServices.length > 0

            Repeater {
              model: root.customServices

              Rectangle {
                required property var modelData
                height: Style.space(26)
                width: mgLabel.implicitWidth + mgRemove.implicitWidth + Style.space(20)
                radius: Style.space(13)
                color: Qt.rgba(1, 1, 1, 0.06)

                Row {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(8)
                  spacing: Style.spacing.xs

                  Text {
                    id: mgLabel
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.label
                    elide: Text.ElideRight
                    color: Qt.darker(Color.popups.text, 1.15)
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    id: mgRemove
                    anchors.verticalCenter: parent.verticalCenter
                    text: "\uf00d"
                    color: root.bar ? root.bar.urgent : Color.urgent
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption

                    MouseArea {
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.removeService(modelData.id)
                    }
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.selectService(modelData.id)
                }
              }
            }
          }

          MouseArea {
            id: searchArea
            width: parent.width
            height: Style.space(32)
            enabled: root.channels.length > 0
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor

            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius * 0.8
              color: searchArea.containsMouse
                ? Qt.rgba(1, 1, 1, 0.05)
                : Qt.rgba(1, 1, 1, 0.03)
            }

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              text: "\uf002"
              color: Qt.darker(Color.popups.text, 1.35)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(28)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: root.filterText || "Search channels…"
              color: root.filterText ? Color.popups.text : Qt.darker(Color.popups.text, 1.4)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }

            onClicked: {
              root.filterText = ""
              root.selectedGroup = "All"
              root.applyFilter()
              panelFocus.forceActiveFocus()
            }
          }

          Flow {
            width: parent.width
            spacing: Style.spacing.xs
            visible: root.groups.length > 1

            Repeater {
              model: root.groups

              Rectangle {
                required property string modelData
                required property int index

                width: chipText.implicitWidth + Style.space(18)
                height: Style.space(24)
                radius: Style.space(12)
                color: root.selectedGroup === modelData
                  ? Util.alpha(Color.accent, 0.28)
                  : Qt.rgba(1, 1, 1, 0.05)

                Text {
                  id: chipText
                  anchors.centerIn: parent
                  text: modelData
                  color: root.selectedGroup === modelData ? Color.accent : Qt.darker(Color.popups.text, 1.25)
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: root.selectedGroup === modelData
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.selectGroup(modelData)
                }
              }
            }
          }

          Text {
            width: parent.width
            text: root.loadingText
            color: root.statusError ? Color.urgent
              : Qt.darker(Color.popups.text, 1.45)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            visible: root.loadingText !== ""
          }

          Item {
            width: parent.width
            height: root.filteredChannels.length > 0
              ? Math.min(root.filteredChannels.length * root.rowHeight, Style.space(300))
              : 0
            clip: true

            ListView {
              id: channelList
              anchors.fill: parent
              model: root.filteredChannels.length
              spacing: 2
              boundsBehavior: Flickable.StopAtBounds

              delegate: Rectangle {
                required property int index
                readonly property var ch: root.filteredChannels[index]
                readonly property bool hasCursor: root.cursorActive && index === root.selectedIndex
                readonly property bool hovered: listHover.containsMouse
                readonly property bool playing: root.running
                  && root.nowService === root.activeService && ch && ch.index === root.nowIndex

                width: channelList.width
                height: root.rowHeight
                radius: Style.cornerRadius
                color: playing
                  ? Util.alpha(Color.accent, 0.18)
                  : hasCursor
                    ? Util.alpha(Color.popups.text, 0.11)
                    : hovered
                      ? Util.alpha(Color.popups.text, 0.05)
                      : "transparent"

                Row {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  spacing: Style.spacing.xs

                  Rectangle {
                    width: 6
                    height: 6
                    radius: 3
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.verticalCenterOffset: 1
                    color: Color.accent
                    visible: playing
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - playButton.width - parent.spacing
                    text: ch ? ch.name : ""
                    color: playing ? Color.accent : Color.popups.text
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: playing
                    elide: Text.ElideRight
                    horizontalAlignment: Text.AlignLeft
                  }

                  Text {
                    id: playButton
                    anchors.verticalCenter: parent.verticalCenter
                    text: playing ? "\uf04e" : "\uf04b"
                    color: playing ? Color.accent : Qt.darker(Color.popups.text, 1.4)
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }

                MouseArea {
                  id: listHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onContainsMouseChanged: if (containsMouse) {
                    root.cursorActive = true
                    root.selectedIndex = index
                  }
                  onClicked: {
                    root.cursorActive = true
                    root.selectedIndex = index
                    root.playSelected()
                  }
                }
              }
            }
          }

          BorderSurface {
            width: parent.width
            implicitHeight: nowPlayingContent.implicitHeight + Style.spacing.rowPaddingX * 2
            radius: Style.cornerRadius
            color: root.running
              ? Util.alpha(Color.accent, 0.10)
              : Util.alpha(Color.popups.text, 0.035)
            borderSpec: Border.flat(root.running
              ? Util.alpha(Color.accent, 0.38)
              : Util.alpha(Color.popups.text, 0.12), 1)

            Column {
              id: nowPlayingContent
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.spacing.rowPaddingX
              anchors.rightMargin: Style.spacing.rowPaddingX
              spacing: Style.spacing.xs

              Text {
                width: parent.width
                text: root.running
                  ? (root.nowTitle !== "" ? root.nowTitle : "Now playing")
                  : "Nothing playing"
                color: root.running ? Color.popups.text : Qt.darker(Color.popups.text, 1.35)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.subtitle
                font.bold: root.running
                elide: Text.ElideRight
              }

              Row {
                width: parent.width
                spacing: Style.spacing.controlGap

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - controlsRow.width - parent.spacing
                  text: root.running
                    ? (root.serviceLabel(root.nowService) + " · #" + (root.nowIndex + 1) + " of " + root.nowCount
                       + (root.paused ? " · paused" : ""))
                    : "Browse with ↑/↓, play with ↵, or press “/” to search"
                  color: Qt.darker(Color.popups.text, 1.35)
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }

                Row {
                  id: controlsRow
                  spacing: Style.spacing.xs

                  PanelActionButton {
                    iconText: "\uf049"
                    tooltipText: "Previous channel"
                    foreground: Color.popups.text
                    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                    enabled: root.running
                    onClicked: root.zap(-1)
                  }

                  PanelActionButton {
                    iconText: root.paused ? "\uf04b" : "\uf04c"
                    tooltipText: root.paused ? "Resume" : "Pause (F)"
                    foreground: Color.popups.text
                    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                    enabled: root.running
                    onClicked: root.togglePause()
                  }

                  PanelActionButton {
                    iconText: "\uf04e"
                    tooltipText: "Next channel"
                    foreground: Color.popups.text
                    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                    enabled: root.running
                    onClicked: root.zap(1)
                  }

                  PanelActionButton {
                    iconText: "\uf04d"
                    tooltipText: "Stop playback"
                    foreground: root.bar ? root.bar.urgent : Color.urgent
                    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                    enabled: root.running
                    onClicked: root.stopPlayback()
                  }
                }
              }

              Text {
                width: parent.width
                text: "In the player: ↑/↓ or →/← to zap · click to resize · Esc exits fullscreen"
                color: Qt.darker(Color.popups.text, 1.5)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }
          }
        }
      }
    }
  }

  readonly property var customServices: {
    root.dataRevision
    var result = []
    for (var i = 0; i < root.services.length; i++) {
      if (root.services[i].custom) result.push(root.services[i])
    }
    return result
  }

  readonly property var serviceOptions: {
    root.dataRevision
    var result = []
    for (var i = 0; i < root.services.length; i++) {
      var info = root.dataFor(root.services[i].id)
      var label = root.services[i].label
      if (info && info.loaded && info.count > 0) label += " · " + info.count
      result.push({ value: root.services[i].id, label: label })
    }
    return result
  }

  readonly property string loadingText: {
    root.dataRevision
    var info = root.dataFor(root.activeService)
    if (root.refreshing) return "Refreshing channel lists…"
    if (root.statusError) return root.statusMessage
    if (!info) return ""
    if (info.loading) return "Loading " + root.serviceLabel(root.activeService) + "…"
    if (info.error) return info.error
    if (info.loaded)
      return root.filteredChannels.length + " of " + info.count + " channels"
    return ""
  }

  function serviceLabel(id) {
    for (var i = 0; i < root.services.length; i++) {
      if (root.services[i].id === id) return root.services[i].label
    }
    return String(id || "TV")
  }
}