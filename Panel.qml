import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The clock and the calendar in one bar widget.
//
// A plugin of its own rather than part of Olook, because a plugin registers
// one bar widget and Olook's is the mail envelope -- and a repository of its
// own, because `omarchy plugin add` installs one plugin per repository.
// It reads through the same engine as the Calendar tab, so the bar and the
// window cannot disagree about what is on.
//
// It replaces Omarchy's clock rather than sitting beside it: the label is the
// date and time, and the popup is the month that clock was already showing,
// with the days you have something on marked and that day's appointments
// underneath.
Panel {
  id: root
  moduleName: "ttt.olook-calendar"
  ipcTarget: "ttt.olook-calendar"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color faint: Qt.darker(foreground, 2.2)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string clockFormat: String(setting("format", "dddd HH:mm"))
  readonly property bool showNext: setting("showNextInBar", false) === true
  readonly property int daysAhead: {
    var value = parseInt(String(setting("daysAhead", 7)), 10)
    return isFinite(value) ? Math.max(1, Math.min(7, value)) : 7
  }
  readonly property int refreshSeconds: {
    var value = parseInt(String(setting("refreshIntervalSec", 300)), 10)
    return isFinite(value) ? Math.max(60, Math.min(3600, value)) : 300
  }

  // Olook installs beside this, so its engine is one directory over. Asking
  // PATH would depend on what the shell inherited, which is not something a
  // bar widget should rely on.
  readonly property string cliPath:
    Qt.resolvedUrl("../ttt.olook/bin/olook").toString().replace(/^file:\/\//, "")

  property date now: new Date()
  property var events: []
  property bool loading: false
  property string trouble: ""

  // The month on show in the popup, and the day picked out of it.
  property int viewYear: now.getFullYear()
  property int viewMonth: now.getMonth()
  property string selectedDay: ""

  readonly property var weekdayNames: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
  readonly property var monthNames: ["January", "February", "March", "April",
    "May", "June", "July", "August", "September", "October", "November", "December"]

  // Notification bodies are read as markup by the notification server.
  function markupSafe(text) {
    return String(text || "").replace(/&/g, "&amp;").replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
  }

  function pad(value) { return value < 10 ? "0" + value : String(value) }

  function dayKey(date) {
    return date.getFullYear() + "-" + root.pad(date.getMonth() + 1)
           + "-" + root.pad(date.getDate())
  }

  function clockOf(event) {
    var from = new Date(event.start * 1000)
    return root.pad(from.getHours()) + ":" + root.pad(from.getMinutes())
  }

  readonly property string todayKey: root.dayKey(root.now)

  // ------------------------------------------------------------- the label

  readonly property string labelText: {
    var text = Qt.formatDateTime(root.now, root.clockFormat)
    if (!root.showNext || !root.nextEvent) return text
    // Off by default: next to a clock a bare time reads as a second clock,
    // and the glyph that says otherwise is still one more thing in the bar
    // than most people want. What is next is a keystroke away in the panel.
    return text + "   " + String.fromCodePoint(0xF00F0) + " "
           + (root.nextEvent.allDay ? "all day" : root.clockOf(root.nextEvent))
  }

  // ------------------------------------------------------------- the month

  function monthStart() { return new Date(root.viewYear, root.viewMonth, 1) }

  // The Monday on or before the first, which is where the grid starts.
  function gridStart() {
    var first = root.monthStart()
    var weekday = (first.getDay() + 6) % 7
    return new Date(first.getFullYear(), first.getMonth(), 1 - weekday)
  }

  readonly property var monthCells: {
    var out = []
    var from = root.gridStart()
    for (var i = 0; i < 42; i++) {
      var day = new Date(from.getFullYear(), from.getMonth(), from.getDate() + i)
      out.push({
        "key": root.dayKey(day),
        "number": day.getDate(),
        "outside": day.getMonth() !== root.viewMonth
      })
    }
    return out
  }

  readonly property var byDay: {
    var map = ({})
    for (var i = 0; i < root.events.length; i++) {
      var key = String(root.events[i].day || "")
      if (!key) continue
      if (!map[key]) map[key] = []
      map[key].push(root.events[i])
    }
    return map
  }

  function eventsOn(key) { return root.byDay[key] || [] }

  function step(direction) {
    var moved = new Date(root.viewYear, root.viewMonth + direction, 1)
    root.viewYear = moved.getFullYear()
    root.viewMonth = moved.getMonth()
    root.selectedDay = ""
    root.reload()
  }

  function goToday() {
    root.viewYear = root.now.getFullYear()
    root.viewMonth = root.now.getMonth()
    root.selectedDay = ""
    root.reload()
  }

  // ------------------------------------------------------------ the agenda

  // What is still to come, which is what the bar reports and what the panel
  // opens on. An appointment that has finished is not what is next.
  readonly property var upcoming: {
    var cutoff = Math.floor(root.now.getTime() / 1000)
    var limit = new Date(root.now.getFullYear(), root.now.getMonth(),
                         root.now.getDate() + root.daysAhead)
    var until = Math.floor(limit.getTime() / 1000)
    var out = []
    for (var i = 0; i < root.events.length; i++) {
      var event = root.events[i]
      if (Number(event.end) <= cutoff) continue
      if (Number(event.start) >= until) continue
      out.push(event)
    }
    return out
  }

  readonly property var nextEvent: root.upcoming.length > 0 ? root.upcoming[0] : null


  // Rows for the list: a heading per day, then that day's appointments. With
  // a day picked it is that day alone; otherwise it is what is coming.
  readonly property var agendaRows: {
    var source = root.selectedDay !== "" ? root.eventsOn(root.selectedDay)
                                         : root.upcoming
    var rows = []
    var seen = ""
    for (var i = 0; i < source.length; i++) {
      var event = source[i]
      var key = String(event.day || "")
      if (key !== seen) {
        seen = key
        rows.push({ "heading": root.headingFor(key), "event": null })
      }
      rows.push({ "heading": "", "event": event })
    }
    return rows
  }

  function headingFor(key) {
    if (key === root.todayKey) return "Today"
    var parts = key.split("-")
    if (parts.length !== 3) return key
    var when = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
    var tomorrow = new Date(root.now.getFullYear(), root.now.getMonth(),
                            root.now.getDate() + 1)
    if (key === root.dayKey(tomorrow)) return "Tomorrow"
    return root.weekdayNames[(when.getDay() + 6) % 7] + " " + when.getDate()
           + " " + root.monthNames[when.getMonth()]
  }

  // --------------------------------------------------------------- reminders

  // Minutes before an appointment to say something; 0 is never.
  readonly property int remindMinutes: {
    var value = parseInt(String(setting("remindMinutes", 15)), 10)
    return isFinite(value) ? Math.max(0, Math.min(120, value)) : 15
  }

  // One notification per appointment, and only from one screen's copy of the
  // widget: the bar mounts one per monitor, and three monitors should not
  // mean three reminders.
  property var reminded: ({})

  readonly property bool isPrimary: {
    if (!bar || typeof bar.moduleWidgets !== "function") return true
    var peers = bar.moduleWidgets(moduleName)
    return !peers || peers.length === 0 || peers[0] === root
  }

  // Reminders are bounded. The events come from calendars other people
  // publish, and each notification is a notify-send that lives until it is
  // answered: a feed with hundreds of appointments in the next hour would
  // otherwise start hundreds of processes and bury the desktop in popups.
  // So a handful at most are alive at once, a burst of appointments becomes
  // one summary, and every reminder lets go after ten minutes.
  readonly property int maxLiveReminders: 3
  readonly property int maxSeparateReminders: 3
  readonly property int reminderLifetimeMs: 10 * 60 * 1000
  property int liveReminders: 0

  function checkReminders() {
    if (root.remindMinutes <= 0 || !root.isPrimary) return
    var now = Math.floor(Date.now() / 1000)
    var horizon = now + root.remindMinutes * 60
    var due = []
    for (var i = 0; i < root.events.length; i++) {
      var event = root.events[i]
      if (event.allDay) continue
      var start = Number(event.start)
      // Already started, or too far off to mention yet.
      if (start <= now || start > horizon) continue
      var key = String(event.uid || event.summary || "") + "@" + start
      if (root.reminded[key]) continue
      root.reminded[key] = start
      due.push(event)
    }
    root.forgetOldReminders(now)
    if (due.length === 0) return

    var room = root.maxLiveReminders - root.liveReminders
    if (room <= 0) return
    if (due.length <= Math.min(room, root.maxSeparateReminders)) {
      for (var j = 0; j < due.length; j++)
        root.announce(due[j], Math.max(1, Math.round((Number(due[j].start) - now) / 60)))
    } else {
      root.announceMany(due, now)
    }
  }

  // Keys for appointments that started over an hour ago will not come round
  // again; without this the map grows for as long as the shell runs.
  function forgetOldReminders(now) {
    var kept = {}
    for (var key in root.reminded)
      if (Number(root.reminded[key]) > now - 3600) kept[key] = root.reminded[key]
    root.reminded = kept
  }

  // One notification for a burst: the first appointment named, the rest
  // counted.
  function announceMany(events, now) {
    events.sort(function (a, b) { return Number(a.start) - Number(b.start) })
    var first = events[0]
    var minutes = Math.max(1, Math.round((Number(first.start) - now) / 60))
    var others = events.length - 1
    root.notify(events.length + " appointments starting soon",
                String(first.summary || "Appointment") + " — " + root.clockOf(first)
                + (minutes === 1 ? ", in a minute" : ", in " + minutes + " minutes")
                + "\nand " + others + (others === 1 ? " more" : " more"))
  }

  function announce(event, minutes) {
    var when = minutes === 1 ? "in a minute" : "in " + minutes + " minutes"
    var where = String(event.location || "")
    root.notify(String(event.summary || "Appointment"),
                root.clockOf(event) + " — " + when + (where !== "" ? "\n" + where : ""))
  }

  function notify(summary, body) {
    if (root.liveReminders >= root.maxLiveReminders) return
    var process = reminder.createObject(root, {
      // "--" first, and the body escaped: the title and place come from
      // whoever sent the invitation or published the calendar.
      command: ["notify-send", "--app-name=Calendar", "--icon=office-calendar",
                "--action=default=Open", "--", String(summary),
                root.markupSafe(body)]
    })
    if (!process) return
    root.liveReminders += 1
    process.running = true
  }

  Component {
    id: reminder

    Process {
      id: reminderProc
      running: false
      // notify-send stays alive until the notification is answered and
      // prints the action that answered it, which is the only way to learn
      // it was clicked.
      stdout: SplitParser {
        onRead: function (line) {
          if (String(line).trim() !== "") root.openCalendar()
        }
      }
      onExited: {
        root.liveReminders = Math.max(0, root.liveReminders - 1)
        Qt.callLater(function () { reminderProc.destroy() })
      }

      // An unanswered reminder lets go after a while: the popup stays with
      // the notification server, only the wait for a click ends.
      property Timer lifetime: Timer {
        interval: root.reminderLifetimeMs
        running: reminderProc.running
        onTriggered: reminderProc.running = false
      }
    }
  }

  Timer {
    running: root.remindMinutes > 0
    repeat: true
    interval: 30000
    triggeredOnStart: true
    onTriggered: root.checkReminders()
  }

  // ------------------------------------------------------------------ data

  function reload() {
    if (root.loading || root.cliPath.indexOf("bin/olook") === -1) return
    // The month on screen, and always today through the days ahead too:
    // what is coming up, the bar's label and the reminders all read from the
    // same events, and browsing to March must not empty them.
    var from = root.gridStart()
    var to = new Date(from.getFullYear(), from.getMonth(), from.getDate() + 42)
    var today = new Date(root.now.getFullYear(), root.now.getMonth(), root.now.getDate())
    var ahead = new Date(today.getFullYear(), today.getMonth(),
                         today.getDate() + root.daysAhead + 1)
    if (today < from) from = today
    if (ahead > to) to = ahead
    root.loading = true
    var command = [root.cliPath, "--json", "calendar",
                   "--start", root.dayKey(from), "--end", root.dayKey(to)]
    // Bounded: a calendar someone else publishes decides how much comes
    // back, and this widget lives in the shell for the whole session. Olook
    // before 1.2.2 does not know these options; readerComponent retries
    // without them.
    if (root.boundedReads)
      command = command.concat(["--max-events", String(root.maxEvents), "--brief"])
    // Every read -- the bounded one and the compatibility retry alike -- goes
    // through the wrapper, which caps what can reach this process.
    var process = readerComponent.createObject(root, {
      command: ["bash", "-c", root.cappedRead, "olook-calendar-read",
                String(root.maxAnswerBytes), String(root.maxErrorBytes),
                String(root.engineTimeoutSec)].concat(command)
    })
    if (!process) {
      root.loading = false
      root.trouble = "Could not start the calendar engine."
      return
    }
    process.running = true
  }

  // How much one read may bring back, and how long it may take. Olook caps
  // the answer itself (--max-events, --brief); the size check here is the
  // backstop, and the deadline ends a read that never finishes, which would
  // otherwise leave "loading" set and every later read returning early.
  readonly property int maxEvents: 1500
  readonly property int maxAnswerBytes: 8 * 1024 * 1024
  readonly property int maxErrorBytes: 64 * 1024
  readonly property int engineTimeoutSec: 25
  readonly property int readDeadlineMs: 30000

  // The engine runs behind this, so the caps hold in the pipe, before any of
  // its output reaches the shell: StdioCollector keeps everything it is
  // given until the process ends, so checking the size afterwards would be
  // too late. stdout passes through head -c, one byte past the limit so an
  // oversized answer can be told from one that fits; stderr is capped the same
  // way; and timeout ends the engine itself, so nothing is left running when
  // the read is abandoned. Past the limit, head exits and the engine gets
  // SIGPIPE on its next write. pipefail carries timeout's exit status out,
  // so a read that ran out of time is not mistaken for an empty one.
  readonly property string cappedRead:
    'set -o pipefail; max="$1"; errmax="$2"; limit="$3"; shift 3; '
    + '{ timeout -k 2 "$limit" "$@" 2>&1 1>&3 3>&- | head -c "$errmax" >&2; } '
    + '3>&1 | head -c "$((max + 1))"'

  // Bytes, not characters: the answer is UTF-8 and the cap is on bytes.
  function utf8Length(text) {
    var bytes = 0
    for (var i = 0; i < text.length; i++) {
      var code = text.charCodeAt(i)
      if (code < 0x80) bytes += 1
      else if (code < 0x800) bytes += 2
      else if (code >= 0xD800 && code <= 0xDBFF) { bytes += 4; i++ }
      else bytes += 3
    }
    return bytes
  }
  property bool boundedReads: true

  // A process per read, made when the read starts, which is how Olook's own
  // engine calls have always worked. A single Process declared here did
  // start -- the command and `running` both took -- and then neither exited
  // nor finished its stream, leaving `loading` true and every later read
  // returning early at the guard.
  Component {
    id: readerComponent

    Process {
      id: proc
      running: false
      stdout: StdioCollector { id: procOut; waitForEnd: true }
      stderr: StdioCollector { id: procErr; waitForEnd: true }

      property bool timedOut: false

      property Timer deadline: Timer {
        interval: root.readDeadlineMs
        running: proc.running
        onTriggered: {
          proc.timedOut = true
          proc.running = false
        }
      }

      onExited: function (exitCode) {
        root.loading = false
        // 124: timeout ended the engine; 137: it had to be killed as well.
        if (proc.timedOut || exitCode === 124 || exitCode === 137) {
          root.trouble = "The calendar took too long to answer; trying again later."
          Qt.callLater(function () { proc.destroy() })
          return
        }
        var text = String(procOut.text || "")
        // Cut off in the pipe one byte past the limit: an answer that long
        // did not fit, and is not parsed.
        if (text.length > root.maxAnswerBytes / 4 && root.utf8Length(text) > root.maxAnswerBytes) {
          root.trouble = "The calendar answered with more than this widget reads."
          Qt.callLater(function () { proc.destroy() })
          return
        }
        // An Olook from before --max-events: ask again the old way.
        if (root.boundedReads && String(procErr.text || "").indexOf("unrecognized arguments") !== -1) {
          root.boundedReads = false
          Qt.callLater(function () { proc.destroy(); root.reload() })
          return
        }
        var payload = null
        try {
          payload = JSON.parse(text)
        } catch (error) {
          // Nothing at all back is the engine missing: this widget reads the
          // calendar through Olook and cannot on its own.
          // One line of the engine's complaint, not all of it.
          root.trouble = String(procErr.text || "").trim().split("\n")[0].slice(0, 200)
            || "The calendar is read through Olook, which is not installed: "
               + "omarchy plugin add https://github.com/TiniTinyTerminator/Olook.git"
          Qt.callLater(function () { proc.destroy() })
          return
        }
        if (!payload || payload.ok === false) {
          root.trouble = String((payload && payload.error) || "").split("\n")[0].slice(0, 200)
          root.events = (payload && payload.events) || []
        } else {
          root.trouble = ""
          root.events = payload.events || []
        }
        Qt.callLater(function () { proc.destroy() })
      }
    }
  }

  // Keeps the label honest across a minute and the highlight across midnight.
  SystemClock {
    id: systemClock
    precision: SystemClock.Minutes
    onDateChanged: root.now = date
  }

  Timer {
    running: true
    repeat: true
    triggeredOnStart: true
    interval: root.refreshSeconds * 1000
    onTriggered: root.reload()
  }

  onOpenedChanged: if (root.opened) {
    root.now = new Date()
    root.reload()
  }

  // An appointment opens in a window of its own, the way the mail widget
  // opens a message -- not the whole client. Everything the window shows is
  // already here, so it travels with the request rather than being looked up
  // again at the other end. With no appointment, the calendar itself opens.
  function openCalendar(event) {
    root.close()
    var target = { "view": "calendar" }
    if (event) {
      target = {
        "popout": true,
        "event": {
          "uid": String(event.uid || ""),
          "day": String(event.day || ""),
          "summary": String(event.summary || ""),
          "location": String(event.location || ""),
          "description": String(event.description || ""),
          "organiser": String(event.organiser || ""),
          "calendarName": String(event.calendarName || ""),
          "colour": String(event.colour || ""),
          "start": Number(event.start || 0),
          "end": Number(event.end || 0),
          "allDay": event.allDay === true,
          "recurring": event.recurring === true
        }
      }
    }
    // Through the shell's own command rather than bar.shell.summon. A
    // plugin's shell handle is scoped to that plugin: the call is there and
    // takes the arguments, and summoning somebody else's overlay with it
    // quietly does nothing. This is a different plugin asking for Olook's
    // window, so it has to ask from outside.
    Quickshell.execDetached(["omarchy-shell", "shell", "summon",
                             "ttt.olook", JSON.stringify(target)])
  }

  // ------------------------------------------------------------------- bar

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.labelText
    labelVisible: true
    hasVisualContent: text !== ""
    horizontalMargin: 8.75
    verticalPadding: 8.75

    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton) root.reload()
      else if (buttonCode === Qt.MiddleButton) root.openCalendar()
      else root.toggle()
    }
  }

  // ----------------------------------------------------------------- panel
  //
  // Laid out like Omarchy's own clock popup, which this replaces: the date
  // as a hero, the year's progress as the rule under it, a month grid with
  // ISO week numbers down a gutter, and a rail of chevrons to step it. What
  // this adds is below the grid -- the appointments -- in the same quiet
  // small-caps voice, and a dot under each day that has something on.

  readonly property int cellWidth: Style.space(50)
  readonly property int cellHeight: Style.space(34)
  readonly property int cellSpacing: Style.space(2)
  readonly property int weekColumnWidth: Style.space(30)
  readonly property int gutterWidth: Style.space(12)
  readonly property int gridWidth: root.weekColumnWidth + root.gutterWidth
    + 7 * root.cellWidth + 8 * root.cellSpacing

  readonly property bool viewingThisMonth: root.viewYear === root.now.getFullYear()
    && root.viewMonth === root.now.getMonth()

  // Pinned to today rather than to the month on screen: browsing does not
  // change how much of the year has gone.
  readonly property real yearDone: {
    var year = root.now.getFullYear()
    var begin = new Date(year, 0, 1)
    var days = (new Date(year + 1, 0, 1) - begin) / 86400000
    var today = new Date(year, root.now.getMonth(), root.now.getDate())
    return Math.round((today - begin) / 86400000) / days
  }

  function isoWeek(date) {
    // The Thursday of the date's week decides which year the week is in.
    var thursday = new Date(date.getFullYear(), date.getMonth(),
                            date.getDate() + 3 - (date.getDay() + 6) % 7)
    var firstThursday = new Date(thursday.getFullYear(), 0, 4)
    return 1 + Math.round(((thursday - firstThursday) / 86400000
                           - 3 + (firstThursday.getDay() + 6) % 7) / 7)
  }

  readonly property var weeks: {
    var out = []
    for (var row = 0; row < 6; row++) {
      var days = root.monthCells.slice(row * 7, row * 7 + 7)
      var parts = days[0].key.split("-")
      out.push({
        "week": root.isoWeek(new Date(Number(parts[0]), Number(parts[1]) - 1,
                                      Number(parts[2]))),
        "days": days
      })
    }
    return out
  }

  function stepYear(direction) { root.step(12 * direction) }

  // Measured out here rather than read off the hero itself, which does not
  // exist until the popup is first built -- and a width of nothing then is
  // a popup that never shows.
  TextMetrics {
    id: heroMetrics
    font.family: root.fontFamily
    font.pixelSize: 48
    font.bold: true
    text: Qt.formatDate(root.now, "MMMM d")
  }
  TextMetrics {
    id: heroGlyphMetrics
    font.family: root.fontFamily
    font.pixelSize: 44
    text: "󰃭"
  }
  readonly property real heroWidth: heroMetrics.advanceWidth
    + heroGlyphMetrics.advanceWidth + Style.space(20)

  function smallCaps(text) { return String(text).toUpperCase() }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    // Wide enough for the hero date as well as the grid, with room either
    // side for the chevrons that sit on the grid's edges.
    contentWidth: panel.fittedContentWidth(
      Math.max(root.gridWidth, root.heroWidth) + Style.space(40))
    contentHeight: panel.fittedContentHeight(pageColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onActivateRequested: root.goToday()
      onMoveRequested: function (dx, dy) {
        if (dx !== 0) root.step(dx)
        if (dy !== 0) root.stepYear(dy)
      }
      onTextKey: function (text) {
        if (text === "[") root.step(-1)
        else if (text === "]") root.step(1)
        else if (text === "{") root.stepYear(-1)
        else if (text === "}") root.stepYear(1)
        else if (text === "t" || text === "T") root.goToday()
        else if (text === "r" || text === "R") root.reload()
        else if (text === "o" || text === "O") root.openCalendar()
      }

      Column {
        id: pageColumn
        width: parent.width
        spacing: Style.space(8)

        // ---- Hero: today. Once the month has been stepped away from it is
        //      also the way back.
        Item {
          width: parent.width
          height: heroRow.height

          Row {
            id: heroRow
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(20)

            Text {
              textFormat: Text.PlainText
              anchors.baseline: heroDate.baseline
              text: "󰃭"
              color: heroMouse.containsMouse
                ? Style.hoverStateColor(root.foreground, Color.accent) : root.foreground
              font.family: root.fontFamily
              font.pixelSize: 44
            }

            Text {
              id: heroDate
              textFormat: Text.PlainText
              text: Qt.formatDate(root.now, "MMMM d")
              color: heroMouse.containsMouse
                ? Style.hoverStateColor(root.foreground, Color.accent) : root.foreground
              font.family: root.fontFamily
              font.pixelSize: 48
              font.bold: true
            }
          }

          MouseArea {
            id: heroMouse
            x: heroRow.x
            y: heroRow.y
            width: heroRow.width
            height: heroRow.height
            enabled: !root.viewingThisMonth || root.selectedDay !== ""
            hoverEnabled: enabled
            cursorShape: Qt.PointingHandCursor
            onClicked: root.goToday()

            PanelToolTip {
              visible: heroMouse.containsMouse
              text: "Back to today"
              fontFamily: root.fontFamily
            }
          }
        }

        // ---- The year so far, as the rule under the hero.
        Item {
          width: parent.width
          height: yearBlock.y + yearBlock.height

          Item {
            id: yearBlock
            y: Style.space(4)
            anchors.horizontalCenter: parent.horizontalCenter
            width: root.gridWidth
            height: Math.max(yearLabel.implicitHeight, Style.space(10))

            Text {
              id: yearLabel
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: root.now.getFullYear()
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.letterSpacing: 1
            }

            Text {
              id: yearPercent
              textFormat: Text.PlainText
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: Math.floor(root.yearDone * 100) + "%"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Rectangle {
              anchors.left: yearLabel.right
              anchors.right: yearPercent.left
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              height: Style.space(6)
              radius: Style.cornerRadius > 0 ? height / 2 : 0
              color: Util.alpha(root.foreground, 0.12)

              Rectangle {
                width: Math.round(parent.width * root.yearDone)
                height: parent.height
                radius: parent.radius
                color: Style.selectedStateColor(root.foreground, Color.accent)
              }
            }
          }
        }

        // ---- The month: week numbers, a gutter, then seven days. Always
        //      six rows, so the popup does not change height with the month.
        Item {
          width: parent.width
          height: gridColumn.y + gridColumn.height

          WheelHandler {
            onWheel: function (event) {
              if (event.angleDelta.y === 0) return
              root.step(event.angleDelta.y > 0 ? -1 : 1)
            }
          }

          Column {
            id: gridColumn
            y: Style.space(14)
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(3)

            Row {
              id: headerRow
              spacing: root.cellSpacing

              Text {
                textFormat: Text.PlainText
                width: root.weekColumnWidth
                height: Style.space(16)
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: "W"
                color: root.faint
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
                font.bold: true
              }

              Item { width: root.gutterWidth; height: Style.space(16) }

              Repeater {
                model: root.weekdayNames

                Text {
                  required property string modelData
                  textFormat: Text.PlainText
                  width: root.cellWidth
                  height: Style.space(16)
                  horizontalAlignment: Text.AlignHCenter
                  verticalAlignment: Text.AlignVCenter
                  text: root.smallCaps(modelData)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                  font.bold: true
                }
              }
            }

            Repeater {
              model: root.weeks

              Row {
                required property var modelData
                spacing: root.cellSpacing

                Text {
                  textFormat: Text.PlainText
                  width: root.weekColumnWidth
                  height: root.cellHeight
                  horizontalAlignment: Text.AlignHCenter
                  verticalAlignment: Text.AlignVCenter
                  text: modelData.week
                  color: root.faint
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Item { width: root.gutterWidth; height: root.cellHeight }

                Repeater {
                  model: modelData.days

                  Rectangle {
                    id: cell
                    required property var modelData
                    required property int index
                    readonly property bool isToday: modelData.key === root.todayKey
                    readonly property bool isPicked: modelData.key === root.selectedDay
                    readonly property bool weekend: index >= 5
                    readonly property int count: root.eventsOn(modelData.key).length

                    width: root.cellWidth
                    height: root.cellHeight
                    radius: Style.cornerRadius
                    // Today is outlined, not filled, as the clock has it; a
                    // picked day gets the soft fill a hover would.
                    color: cell.isPicked ? Style.hoverFillFor(root.foreground, Color.accent)
                      : (cellMouse.containsMouse ? Util.alpha(root.foreground, 0.06)
                                                 : "transparent")
                    border.width: cell.isToday ? Style.spacing.hairline : 0
                    border.color: Style.normalBorderFor(root.foreground, Color.accent)

                    Text {
                      textFormat: Text.PlainText
                      anchors.centerIn: parent
                      anchors.verticalCenterOffset: cell.count > 0 ? -Style.space(3) : 0
                      text: cell.modelData.number
                      color: cell.modelData.outside ? root.faint
                        : (cell.weekend ? Qt.darker(root.foreground, 1.45) : root.foreground)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: cell.isToday
                    }

                    // Something is on that day; the list below says what.
                    Rectangle {
                      visible: cell.count > 0
                      anchors.horizontalCenter: parent.horizontalCenter
                      anchors.bottom: parent.bottom
                      anchors.bottomMargin: Style.space(5)
                      width: Style.space(4)
                      height: width
                      radius: width / 2
                      color: cell.modelData.outside ? root.faint : Color.accent
                    }

                    MouseArea {
                      id: cellMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.selectedDay =
                        (root.selectedDay === cell.modelData.key) ? "" : cell.modelData.key
                    }
                  }
                }
              }
            }
          }

          // Hairline down the week-number gutter, beside the day rows only.
          Rectangle {
            x: gridColumn.x + root.weekColumnWidth + root.cellSpacing
               + Math.round((root.gutterWidth - width) / 2)
            y: gridColumn.y + headerRow.height + gridColumn.spacing
            width: Style.spacing.hairline
            height: gridColumn.height - headerRow.height - gridColumn.spacing
            color: root.foreground
            opacity: 0.1
          }
        }

        // ---- Month stepping, spanning the grid it drives.
        Item {
          width: parent.width
          height: monthNav.height

          Item {
            id: monthNav
            anchors.horizontalCenter: parent.horizontalCenter
            width: root.gridWidth
            height: monthLabel.implicitHeight + Style.space(10)

            Text {
              id: monthLabel
              textFormat: Text.PlainText
              anchors.centerIn: parent
              width: Style.space(130)
              horizontalAlignment: Text.AlignHCenter
              text: root.smallCaps(root.monthNames[root.viewMonth] + " " + root.viewYear)
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.letterSpacing: 1
            }

            PanelActionButton {
              anchors.left: parent.left
              anchors.leftMargin: -Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰅁"
              tooltipText: "Previous month"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.step(-1)
            }

            PanelActionButton {
              anchors.right: parent.right
              anchors.rightMargin: -Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰅂"
              tooltipText: "Next month"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.step(1)
            }
          }
        }

        // ---- What is on: the day picked in the grid, or what is coming.
        Item {
          width: parent.width
          height: agendaBlock.height

          Column {
            id: agendaBlock
            anchors.horizontalCenter: parent.horizontalCenter
            width: root.gridWidth
            spacing: Style.space(6)

            Rectangle {
              width: parent.width
              height: Style.spacing.hairline
              color: root.foreground
              opacity: 0.1
            }

            Item {
              width: parent.width
              height: agendaTitle.implicitHeight

              Text {
                id: agendaTitle
                textFormat: Text.PlainText
                anchors.left: parent.left
                text: root.smallCaps(root.selectedDay !== ""
                                     ? root.headingFor(root.selectedDay) : "Coming up")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
                font.bold: true
              }

              Text {
                id: openAll
                textFormat: Text.PlainText
                anchors.right: parent.right
                text: root.smallCaps("Open calendar")
                color: openAllMouse.containsMouse
                  ? Style.hoverStateColor(root.foreground, Color.accent) : root.faint
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1

                MouseArea {
                  id: openAllMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openCalendar()
                }
              }
            }

            Text {
              width: parent.width
              visible: root.trouble !== ""
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              text: root.trouble
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              width: parent.width
              visible: root.trouble === "" && root.agendaRows.length === 0
              textFormat: Text.PlainText
              text: root.loading ? "Reading the calendar…"
                : (root.selectedDay !== "" ? "Nothing on that day" : "Nothing coming up")
              color: root.faint
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Flickable {
              id: agendaFlick
              width: parent.width
              height: Math.min(agendaColumn.implicitHeight, Style.space(190))
              contentWidth: width
              contentHeight: agendaColumn.implicitHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              interactive: contentHeight > height

              MomentumScroll { view: agendaFlick }

              Column {
                id: agendaColumn
                width: agendaFlick.width
                spacing: Style.space(2)

                Repeater {
                  // With one day picked its heading is already the title.
                  model: root.selectedDay !== ""
                    ? root.agendaRows.filter(function (row) { return !!row.event })
                    : root.agendaRows

                  Item {
                    id: agendaRow
                    required property var modelData
                    readonly property var event: modelData.event
                    width: agendaColumn.width
                    height: event ? Style.space(26) : Style.space(24)

                    Text {
                      visible: !agendaRow.event
                      anchors.left: parent.left
                      anchors.bottom: parent.bottom
                      anchors.bottomMargin: Style.space(3)
                      textFormat: Text.PlainText
                      text: root.smallCaps(agendaRow.modelData.heading)
                      color: root.faint
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.letterSpacing: 1
                    }

                    Rectangle {
                      visible: !!agendaRow.event
                      anchors.fill: parent
                      radius: Style.cornerRadius
                      color: rowMouse.containsMouse
                        ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"

                      Row {
                        anchors.left: parent.left
                        anchors.leftMargin: Style.space(6)
                        anchors.right: parent.right
                        anchors.rightMargin: Style.space(6)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(10)

                        Rectangle {
                          anchors.verticalCenter: parent.verticalCenter
                          width: Style.space(3)
                          height: Style.space(15)
                          radius: Style.space(2)
                          color: agendaRow.event && agendaRow.event.colour
                            ? agendaRow.event.colour : Color.accent
                        }

                        Text {
                          anchors.verticalCenter: parent.verticalCenter
                          width: Style.space(48)
                          textFormat: Text.PlainText
                          text: agendaRow.event
                            ? (agendaRow.event.allDay ? "all day" : root.clockOf(agendaRow.event))
                            : ""
                          color: root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                        }

                        Text {
                          anchors.verticalCenter: parent.verticalCenter
                          width: parent.width - Style.space(81)
                          textFormat: Text.PlainText
                          elide: Text.ElideRight
                          text: agendaRow.event
                            ? (agendaRow.event.summary || "(no title)") : ""
                          color: root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                        }
                      }

                      MouseArea {
                        id: rowMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.openCalendar(agendaRow.event)
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.reload(); return "ok" }
    // Exercises exactly what a click on an agenda row does, so a click that
    // does nothing can be told apart from a summon that does nothing.
    function openFirst(): string {
      if (!root.nextEvent) return "nothing to open"
      root.openCalendar(root.nextEvent)
      return "asked for " + String(root.nextEvent.summary || "")
    }
    function next(): string {
      return root.nextEvent ? String(root.nextEvent.summary || "") : ""
    }
    // What the widget is working from, which is otherwise invisible from
    // outside the shell. This is what found the read that never finished.
    function status(): string {
      return JSON.stringify({
        "events": root.events.length,
        "loading": root.loading,
        "trouble": root.trouble,
        "remindMinutes": root.remindMinutes,
        "reminded": Object.keys(root.reminded).length,
        "isPrimary": root.isPrimary
      })
    }
  }
}
