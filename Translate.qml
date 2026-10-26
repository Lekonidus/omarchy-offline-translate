import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Translator overlay + clipboard watcher. keepLoaded keeps this mounted for
// the whole session so the watcher runs from login; the model itself lives
// in bin/offline-translate's on-demand server, not here.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string pluginId: "io.github.lekonidus.offline-translate"
  readonly property string helper: decodeURIComponent(Qt.resolvedUrl("bin/offline-translate").toString().replace(/^file:\/\//, ""))
  readonly property string stateFile: Quickshell.env("XDG_RUNTIME_DIR") + "/omarchy-offline-translate/state.json"

  property bool opened: false
  property bool installed: true
  property string source: "auto"   // forced lid label, or "auto"
  property var result: null        // last helper response
  property bool busy: false
  property bool dirty: false       // input changed while a request was in flight
  property var server: null        // state.json while the model server runs
  property var languages: [{ value: "auto", label: "Detect language" }]

  property color background: Commons.Color.menu.background
  property color foreground: Commons.Color.menu.text
  property color border: Commons.Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Commons.Color.menu.scrim
  property string fontFamily: Style.font.menuFamily
  readonly property int cornerRadius: Style.cornerRadius
  property int contentMargin: Style.spacing.panelPadding
  property int contentSpacing: Style.spacing.md

  readonly property string statusText: {
    if (!root.installed) return ""
    if (root.busy) return root.server && root.server.loaded === true ? "Translating…" : "Loading the translation model…"
    if (!root.result) return input.text.trim() ? "" : "Paste text in any language — it translates to English as you paste."
    if (!root.result.ok) return root.result.error || "Translation failed"
    var name = root.result.name || root.result.src
    if (root.result.note) return name + " · " + root.result.note
    if (root.result.confidence === null || root.result.confidence === undefined) return name + " → English"
    return name + " (detected " + Math.round(root.result.confidence * 100) + "%) → English"
  }

  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") || {} } catch (e) {}
    root.opened = true
    statusProc.running = true
    root.setSource(typeof payload.src === "string" && payload.src ? payload.src : "auto")
    // A popup's "Open" stashes its text in a 0600 file; text never rides in
    // the summon IPC arguments.
    if (payload.stashed === true) takeOpenProc.running = true
    Qt.callLater(function() { input.forceActiveFocus() })
  }

  function loadStashed(raw) {
    var stash = {}
    try { stash = JSON.parse(raw) || {} } catch (e) {}
    if (typeof stash.text !== "string" || !stash.text) return
    root.setSource(typeof stash.src === "string" && stash.src ? stash.src : "auto")
    input.text = stash.text
    root.translateNow()
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  function setSource(value) {
    root.source = value
    sourcePicker.value = value  // imperative: the picker's own select also assigns value
  }

  function translateNow() {
    debounce.stop()
    if (!input.text.trim()) {
      root.result = null
      return
    }
    if (translateProc.running) {
      root.dirty = true
      return
    }
    root.dirty = false
    root.busy = true
    translateProc.payload = JSON.stringify({ text: input.text, src: root.source })
    translateProc.running = true
  }

  function onTranslated(raw) {
    root.busy = false
    var parsed = null
    try { parsed = JSON.parse(raw) } catch (e) {}
    root.result = parsed || { ok: false, error: "The translation helper failed; see " + Quickshell.env("XDG_RUNTIME_DIR") + "/omarchy-offline-translate/server.log" }
    if (root.dirty) Qt.callLater(root.translateNow)
  }

  function copyEnglish() {
    if (!root.result || !root.result.ok || !root.result.text) return
    // Over stdin: process arguments are readable by other local users.
    copyProc.payload = JSON.stringify({ text: root.result.text })
    copyProc.running = true
    root.dismiss()
  }

  Process {
    id: copyProc
    property string payload: ""
    command: [root.helper, "copy"]
    stdinEnabled: true
    onStarted: write(payload + "\n")
  }

  Process {
    id: takeOpenProc
    command: [root.helper, "take-open"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadStashed(text)
    }
  }

  Process {
    id: translateProc
    property string payload: ""
    command: [root.helper, "run"]
    stdinEnabled: true
    onStarted: write(payload + "\n")
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onTranslated(text)
    }
  }

  Process {
    id: statusProc
    command: [root.helper, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.installed = JSON.parse(text).installed === true } catch (e) {}
      }
    }
  }

  Process {
    id: langsProc
    command: [root.helper, "langs"]
    running: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.languages = [{ value: "auto", label: "Detect language" }].concat(JSON.parse(text)) } catch (e) {}
      }
    }
  }

  FileView {
    id: stateView
    path: root.stateFile
    printErrors: false
    onLoaded: {
      try { root.server = JSON.parse(text()) } catch (e) { root.server = null }
    }
    onLoadFailed: root.server = null
  }

  // state.json comes and goes with the server; a cheap re-read beats
  // watching a file that may not exist yet.
  Timer {
    interval: 1000
    repeat: true
    running: root.opened
    triggeredOnStart: true
    onTriggered: stateView.reload()
  }

  Timer {
    id: debounce
    interval: 400
    onTriggered: root.translateNow()
  }

  // ---- clipboard watcher (same lifecycle as omarchy.clipboard's) ----

  Process {
    id: reapProc
    command: ["pkill", "-f", "wl-paste .*--watch .*/bin/offline-translate on-copy"]
    onExited: watchProc.running = true
  }

  Process {
    id: watchProc
    command: ["setpriv", "--pdeathsig", "TERM", "wl-paste", "--type", "text", "--watch", root.helper, "on-copy"]
    onExited: watchRestart.restart()
  }

  Timer {
    id: watchRestart
    interval: 2000
    onTriggered: if (!watchProc.running) watchProc.running = true
  }

  Component.onCompleted: reapProc.running = true

  // ---- UI ----

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-offline-translate"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: Math.min(Style.space(720), panel.width - Style.gapsOut * 2)
      height: Math.min(Style.space(540), panel.height - Style.gapsOut * 2)
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape && !sourcePicker.popupOpen) {
          root.dismiss()
          event.accepted = true
        } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) {
          root.copyEnglish()
          event.accepted = true
        }
      }

      Column {
        id: content
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        Item {
          width: parent.width
          height: sourcePicker.implicitHeight

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Translate to English"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
          }

          SearchableDropdown {
            id: sourcePicker
            anchors.right: parent.right
            width: Style.space(220)
            showLabel: false
            options: root.languages
            value: "auto"
            placeholderText: "Search languages…"
            onChanged: function(v) {
              root.source = v
              root.translateNow()
            }
          }
        }

        // Setup needed: one button, nothing else on screen.
        Column {
          visible: !root.installed
          width: parent.width
          spacing: root.contentSpacing

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            text: "One-time setup: creates a Python environment and downloads the NLLB-200 1.3B translation model (about 1.4 GB). Everything runs on this computer afterwards."
          }

          Button {
            text: "Run setup in a terminal"
            bordered: true
            onClicked: {
              Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", "'" + root.helper.replace(/'/g, "'\\''") + "' setup"])
              root.dismiss()
            }
          }
        }

        Item {
          visible: root.installed
          width: parent.width
          height: content.height - sourcePicker.implicitHeight - statusLine.height - actions.height - root.contentSpacing * 4

          Column {
            anchors.fill: parent
            spacing: root.contentSpacing

            BorderSurface {
              width: parent.width
              height: (parent.height - root.contentSpacing) / 2
              radius: root.cornerRadius
              color: Style.controlFill(input.activeFocus, false, root.foreground, Commons.Color.accent)
              borderSpec: Border.controlSpec(input.activeFocus ? "focus" : "normal", root.foreground, Commons.Color.accent)

              QQC.ScrollView {
                anchors.fill: parent
                anchors.margins: Style.spacing.controlPaddingX

                QQC.TextArea {
                  id: input
                  wrapMode: TextEdit.Wrap
                  placeholderText: "Paste text (Ctrl+V)…"
                  placeholderTextColor: Qt.darker(root.foreground, 1.6)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  background: null
                  selectByMouse: true
                  onTextChanged: if (root.opened) debounce.restart()
                }
              }
            }

            QQC.ScrollView {
              id: outputView
              width: parent.width
              height: (parent.height - root.contentSpacing) / 2

              TextEdit {
                // parent here is the scroll content, which grows with the text; wrap to the view.
                width: outputView.availableWidth
                readOnly: true
                selectByMouse: true
                wrapMode: TextEdit.Wrap
                textFormat: TextEdit.PlainText
                text: root.result && root.result.ok ? root.result.text : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
              }
            }
          }
        }

        Text {
          id: statusLine
          width: parent.width
          elide: Text.ElideRight
          textFormat: Text.PlainText
          text: root.statusText
          color: root.foreground
          opacity: 0.7
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Row {
          id: actions
          visible: root.installed
          anchors.right: parent.right
          spacing: Style.spacing.sm

          Button {
            text: "Close (Esc)"
            onClicked: root.dismiss()
          }

          Button {
            text: "Copy English (Ctrl+Enter)"
            bordered: true
            enabled: root.result !== null && root.result.ok === true && !root.busy
            onClicked: root.copyEnglish()
          }
        }
      }
    }
  }
}
