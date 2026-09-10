import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "ChannelsModel.js" as Model

Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property url parseScriptUrl: Qt.resolvedUrl("scripts/parse-m3u.sh")
  readonly property url ctlScriptUrl: Qt.resolvedUrl("scripts/oma-tv-ctl")
  readonly property string parseScriptPath: root.localPath(parseScriptUrl)
  readonly property string ctlScriptPath: root.localPath(ctlScriptUrl)

  property bool opened: false
  property string playlistPath: ""
  property string filterText: ""
  property string selectedGroup: "All"
  property int selectedIndex: 0
  property bool cursorActive: false
  property var channels: []
  property var filteredChannels: []
  property var groups: []
  property bool loading: false
  property string error: ""
  property bool expectedStop: false
  property bool playlistInputVisible: false
  property string playlistInput: ""
  property bool editingPlaylist: false

  property bool playerRunning: false
  property string playerNowTitle: ""
  property string playerMode: ""

  readonly property string fontFamily: Style.font.family
  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color border: Color.menu.border
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  readonly property color scrim: Color.menu.scrim
  readonly property color selectedBackground: Color.menu.selectedBackground
  readonly property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius

  readonly property int panelWidth: Math.min(Style.space(480), panel.width - Style.gapsOut * 2)
  readonly property int panelHeight: Math.min(Style.space(600), panel.height - Style.gapsOut * 2)
  readonly property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  readonly property int rowHeight: Math.max(Style.space(36), Style.font.body + Style.spacing.controlPaddingY * 2)

  function localPath(value) {
    var text = String(value || "")
    if (text.slice(0, 7) === "file://") text = text.slice(7)
    try { return decodeURIComponent(text) } catch (e) { return text }
  }

  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") || {} } catch (e) {}
    if (payload.playlist !== undefined) root.playlistPath = String(payload.playlist)
    root.opened = true
    root.filterText = ""
    root.selectedGroup = "All"
    root.selectedIndex = 0
    root.cursorActive = false
    root.playlistInputVisible = false
    root.editingPlaylist = false
    if (root.channels.length === 0 && root.playlistPath !== "") {
      loadPlaylist()
    }
    Qt.callLater(function() {
      if (root.opened) keyCatcher.forceActiveFocus()
    })
  }

  function close() {
    root.opened = false
    root.loading = false
    root.error = ""
    if (parseProc.running) {
      root.expectedStop = true
      parseProc.running = false
    }
  }

  function dismiss() {
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "user.oma-tv")
    else close()
  }

  function loadPlaylist() {
    if (root.playlistPath === "") {
      root.playlistInputVisible = true
      return
    }
    if (parseProc.running) {
      root.expectedStop = true
      parseProc.running = false
    }
    root.loading = true
    root.error = ""
    root.channels = []
    root.filteredChannels = []
    root.groups = []
    root.filterText = ""
    root.selectedGroup = "All"
    root.selectedIndex = 0
    parseProc.command = [root.parseScriptPath, root.playlistPath]
    parseProc.running = true
  }

  function applyFilter() {
    root.filteredChannels = Model.filterChannels(root.channels, root.filterText, root.selectedGroup)
    if (root.selectedIndex >= root.filteredChannels.length)
      root.selectedIndex = Math.max(0, root.filteredChannels.length - 1)
    root.cursorActive = root.filteredChannels.length > 0
  }

  function selectGroup(group) {
    root.selectedGroup = group
    root.selectedIndex = 0
    root.cursorActive = true
    applyFilter()
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
    if (root.selectedIndex < 0 || root.selectedIndex >= root.filteredChannels.length) return
    var ch = root.filteredChannels[root.selectedIndex]
    ctlProc.command = [root.ctlScriptPath, "play-url", ch.url, ch.name]
    ctlProc.running = true
  }

  function togglePlaylistInput() {
    root.editingPlaylist = true
    root.playlistInputVisible = true
    root.playlistInput = root.playlistPath
    Qt.callLater(function() {
      playlistTextInput.forceActiveFocus()
    })
  }

  function setPlaylistFromInput() {
    var path = root.playlistInput.trim()
    if (path !== "") {
      root.playlistPath = path
      root.playlistInputVisible = false
      root.editingPlaylist = false
      loadPlaylist()
    }
  }

  function refreshPlayerStatus() {
    if (playerStatusProc.running || ctlProc.running) return
    playerStatusProc.command = [root.ctlScriptPath, "status"]
    playerStatusProc.running = true
  }

  function applyPlayerStatus(line) {
    var parsed
    try {
      parsed = JSON.parse(String(line || "").trim())
    } catch (e) { parsed = null }
    if (!parsed || typeof parsed !== "object") return
    root.playerRunning = parsed.running === true
    root.playerMode = String(parsed.mode || "")
    root.playerNowTitle = parsed.running ? String(parsed.title || "") : ""
  }

  Process {
    id: parseProc
    stdout: SplitParser {
      onRead: function(line) {
        if (root.expectedStop) return
        root.loading = false
        var parsed = Model.parseChannels(line)
        if (parsed.length > 0) {
          root.channels = parsed
          root.groups = Model.extractGroups(root.channels)
          root.groups.unshift("All")
          root.applyFilter()
        } else {
          root.error = "No channels found in playlist"
        }
      }
    }
    stderr: SplitParser {
      onRead: function(line) {
        if (!root.expectedStop && line !== "") root.error = line
      }
    }
    onExited: function(exitCode) {
      root.loading = false
      if (root.expectedStop) {
        root.expectedStop = false
        return
      }
      if (exitCode !== 0 && root.error === "") {
        root.error = "Failed to parse playlist"
      }
    }
  }

  Process {
    id: ctlProc
    stdout: SplitParser { onRead: function(line) {} }
    stderr: SplitParser { onRead: function(line) {} }
    onExited: function(exitCode) {
      Qt.callLater(root.refreshPlayerStatus)
    }
  }

  Process {
    id: playerStatusProc
    stdout: SplitParser { onRead: function(line) { root.applyPlayerStatus(line) } }
    stderr: SplitParser { onRead: function(line) {} }
  }

  Timer {
    interval: 3000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshPlayerStatus()
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omarchy-oma-tv"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    Rectangle {
      anchors.fill: parent
      color: root.scrim
      MouseArea {
        anchors.fill: parent
        onClicked: root.dismiss()
      }
    }

    BorderSurface {
      width: root.panelWidth
      height: root.panelHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            if (root.playlistInputVisible && root.editingPlaylist) {
              root.playlistInputVisible = false
              root.editingPlaylist = false
            } else if (root.filterText !== "") {
              root.filterText = ""
              root.applyFilter()
            } else {
              root.dismiss()
            }
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.select(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.select(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.playlistInputVisible && root.editingPlaylist) {
              root.setPlaylistFromInput()
            } else if (root.filteredChannels.length > 0) {
              root.playSelected()
            }
            event.accepted = true
          } else if (event.key === Qt.Key_Slash) {
            root.filterText = ""
            root.applyFilter()
            event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            if (!root.editingPlaylist) {
              root.filterText = root.filterText + event.text
              root.applyFilter()
            }
            event.accepted = true
          }
        }
      }

      ColumnLayout {
        anchors.fill: parent
        anchors.topMargin: Style.space(16)
        anchors.bottomMargin: Style.space(16)
        anchors.leftMargin: Style.space(16)
        anchors.rightMargin: Style.space(16)
        spacing: Style.space(12)

        // Header
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Text {
            text: "Oma TV"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            Layout.fillWidth: true
          }

          // Settings button
          Rectangle {
            width: Style.space(28)
            height: Style.space(28)
            radius: root.cornerRadius
            color: settingsArea.containsMouse
              ? Style.hoverFillFor(root.foreground, root.accent)
              : "transparent"

            Text {
              anchors.centerIn: parent
              text: "󰒓"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
            }

            MouseArea {
              id: settingsArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.togglePlaylistInput()
            }
          }
        }

        // Playlist path display
        Rectangle {
          Layout.fillWidth: true
          height: Style.space(28)
          radius: root.cornerRadius
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
          visible: !root.playlistInputVisible

          Text {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(8)
            anchors.rightMargin: Style.space(8)
            text: root.playlistPath || "No playlist loaded — click 󰒓 to set"
            color: root.playlistPath ? root.foreground : Qt.darker(root.foreground, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignLeft
          }
        }

        // Playlist input
        Rectangle {
          Layout.fillWidth: true
          height: Style.space(32)
          radius: root.cornerRadius
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
          visible: root.playlistInputVisible

          TextInput {
            id: playlistTextInput
            anchors.fill: parent
            anchors.leftMargin: Style.space(8)
            anchors.rightMargin: Style.space(8)
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            clip: true
            text: root.playlistInput
            onTextChanged: root.playlistInput = text
            Keys.onReturnPressed: root.setPlaylistFromInput()
            Keys.onEscapePressed: {
              root.playlistInputVisible = false
              root.editingPlaylist = false
            }
          }
        }

        // Search bar
        Rectangle {
          Layout.fillWidth: true
          height: Style.space(32)
          radius: root.cornerRadius
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
          visible: root.channels.length > 0

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(8)
            text: "󰈭"
            color: Qt.darker(root.foreground, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(24)
            anchors.right: parent.right
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || "Search channels..."
            color: root.filterText ? root.foreground : Qt.darker(root.foreground, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }
        }

        // Category chips
        Flow {
          Layout.fillWidth: true
          spacing: Style.space(6)
          visible: root.groups.length > 1

          Repeater {
            model: root.groups

            Rectangle {
              required property string modelData
              required property int index

              width: chipText.implicitWidth + Style.space(16)
              height: Style.space(26)
              radius: Style.space(13)
              color: root.selectedGroup === modelData
                ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)
                : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)

              Text {
                id: chipText
                anchors.centerIn: parent
                text: modelData
                color: root.selectedGroup === modelData ? root.foreground : Qt.darker(root.foreground, 1.3)
                font.family: root.fontFamily
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

        PanelSeparator { Layout.fillWidth: true; foreground: root.foreground; visible: root.channels.length > 0 }

        // Status text
        Text {
          Layout.fillWidth: true
          text: root.loading ? "Loading channels..."
            : root.error !== "" ? root.error
            : root.filteredChannels.length + " channel" + (root.filteredChannels.length !== 1 ? "s" : "")
          color: root.error !== "" ? "#ff6b6b" : Qt.darker(root.foreground, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          visible: !root.playlistInputVisible
        }

        // Now playing
        Rectangle {
          Layout.fillWidth: true
          height: Style.space(30)
          radius: root.cornerRadius
          color: root.playerRunning
            ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.15)
            : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
          visible: root.playerRunning

          Text {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(8)
            anchors.rightMargin: Style.space(8)
            text: "Now playing: " + (root.playerNowTitle || "…")
              + (root.playerMode ? "  ·  " + root.playerMode : "")
            color: root.playerRunning ? Color.accent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            elide: Text.ElideRight
          }
        }

        // Channel list area
        Item {
          id: listArea
          Layout.fillWidth: true
          Layout.fillHeight: true
          clip: true

          ListView {
            id: channelList
            anchors.fill: parent
            clip: true
            model: root.filteredChannels.length
            spacing: 2
            boundsBehavior: Flickable.StopAtBounds

          delegate: Rectangle {
            required property int index
            readonly property var ch: root.filteredChannels[index]
            readonly property bool hasCursor: root.cursorActive && index === root.selectedIndex

            width: channelList.width
            height: root.rowHeight
            radius: root.cornerRadius
            color: hasCursor ? root.selectedBackground : "transparent"

            Row {
              anchors.fill: parent
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(8)

              // Channel name
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: ch ? ch.name : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
                width: parent.width - (ch && ch.group && ch.group !== "Ungrouped" ? groupTag.width + Style.space(8) : 0)
                horizontalAlignment: Text.AlignLeft
              }

              // Group tag
              Rectangle {
                id: groupTag
                anchors.verticalCenter: parent.verticalCenter
                width: groupTagText.implicitWidth + Style.space(10)
                height: Style.space(20)
                radius: Style.space(10)
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
                visible: ch && ch.group && ch.group !== "Ungrouped"

                Text {
                  id: groupTagText
                  anchors.centerIn: parent
                  text: ch ? ch.group : ""
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption * 0.85
                }
              }
            }

            MouseArea {
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

          // Empty state
          Column {
            width: parent.width
            visible: root.channels.length === 0 && !root.loading && !root.playlistInputVisible
            spacing: Style.space(8)
            anchors.centerIn: parent

            Text {
              text: "󰖩"
              color: Qt.darker(root.foreground, 1.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              anchors.horizontalCenter: parent.horizontalCenter
            }

            Text {
              text: "No playlist loaded"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              anchors.horizontalCenter: parent.horizontalCenter
            }

            Text {
              text: "Click the gear icon (󰒓) to set your M3U playlist path"
              color: Qt.darker(root.foreground, 1.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              width: parent.width
              wrapMode: Text.WordWrap
              horizontalAlignment: Text.AlignHCenter
            }
          }

          // Loading spinner
          Text {
            anchors.centerIn: parent
            width: parent.width
            text: "Loading channels..."
            color: Qt.darker(root.foreground, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            horizontalAlignment: Text.AlignHCenter
            visible: root.loading
          }
        }
      }
    }
  }
}