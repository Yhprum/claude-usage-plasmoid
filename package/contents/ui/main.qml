import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as P5Support
import org.kde.plasma.core as PlasmaCore
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    // ===================================================================
    // State
    // ===================================================================
    property var usageData: null
    // A canonical string representation of just the *utilization* values
    // we care about. Used for change-detection. We deliberately do NOT
    // include resets_at fields here, because the 5-hour window appears
    // to be rolling (server returns a slightly-different resets_at on
    // every call), which would make every poll look like a "change"
    // and pin the backoff at 10s forever.
    property string lastUsageSnapshot: ""
    property string errorState: ""

    // Rate-limit guard. fetchNow() is a no-op if called within
    // minFetchIntervalMs of the previous fetch attempt — prevents the
    // API from 429-ing when the user mashes the refresh control.
    // Matches the active-poll floor (15s) so a manual refresh can never
    // trigger faster than the timer would on its own.
    property real lastFetchMs: 0
    readonly property int minFetchIntervalMs: 15000

    // When the most recent fetch *succeeded* (not just "started"). Used
    // for the "Last refreshed X ago" label so a string of failures
    // doesn't make us claim we just refreshed.
    property real lastSuccessMs: 0

    // Drives the enabled state of the manual refresh button. Only ticks
    // while the popup is open (nowMs only updates then), which is fine
    // since the button only exists while the popup is open.
    readonly property bool canManuallyRefresh:
        (nowMs - lastFetchMs) >= minFetchIntervalMs

    // Backoff sequence (seconds). Index 0 = "just saw a change, poll soon".
    // Last index = "nothing's happening, poll once an hour".
    readonly property var backoffSeconds: [
        15, 20, 30, 45,
        60, 120, 300, 600, 1200, 1800, 2700, 3600
    ]
    property int backoffIdx: backoffSeconds.length - 1   // start at 1 hour

    // Live "now" value used by countdown labels. Only ticked while popup
    // is open so we don't wake the CPU when nobody's looking.
    property real nowMs: Date.now()

    // Convenience accessors. utilization is a 0-100 number per your schema.
    readonly property real sessionPct: usageData && usageData.five_hour
        ? usageData.five_hour.utilization : 0
    readonly property real weeklyPct: usageData && usageData.seven_day
        ? usageData.seven_day.utilization : 0
    readonly property string sessionResetIso: usageData && usageData.five_hour
        ? usageData.five_hour.resets_at : ""
    readonly property string weeklyResetIso: usageData && usageData.seven_day
        ? usageData.seven_day.resets_at : ""

    // ===================================================================
    // Plasmoid metadata + tooltip
    // ===================================================================
    Plasmoid.icon: "utilities-system-monitor"
    toolTipMainText: "Claude Usage"
    toolTipSubText: errorState !== ""
        ? errorMessage(errorState)
        : "Session: " + sessionPct.toFixed(0) + "%   Weekly: " + weeklyPct.toFixed(0) + "%"

    // Right-click context menu: "Refresh now" entry. fetchNow() handles
    // its own cooldown, so a click during cooldown is a silent no-op.
    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: i18n("Refresh now")
            icon.name: "view-refresh"
            onTriggered: root.fetchNow()
        }
    ]

    // ===================================================================
    // Compact representation: the tray icon (a fill bar)
    // ===================================================================
    compactRepresentation: MouseArea {
        id: compactRoot
        Layout.minimumWidth: Kirigami.Units.iconSizes.small
        Layout.minimumHeight: Kirigami.Units.iconSizes.small
        implicitWidth: Kirigami.Units.iconSizes.medium
        implicitHeight: Kirigami.Units.iconSizes.medium

        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        hoverEnabled: true

        onClicked: (mouse) => {
            if (mouse.button === Qt.LeftButton) {
                root.expanded = !root.expanded
            } else if (mouse.button === Qt.MiddleButton) {
                root.fetchNow()
            }
        }

        Canvas {
            id: barCanvas
            anchors.fill: parent
            anchors.margins: Math.max(1, Math.min(width, height) * 0.08)

            // Repaint whenever any of these change.
            property real fillPct: root.errorState !== "" ? 0 : root.sessionPct
            property bool isError: root.errorState !== ""
            onFillPctChanged: requestPaint()
            onIsErrorChanged: requestPaint()
            Component.onCompleted: requestPaint()

            onPaint: {
                var ctx = getContext("2d")
                ctx.reset()

                var w = width
                var h = height
                var stroke = Math.max(1, Math.min(w, h) * 0.10)
                var radius = Math.min(w, h) * 0.18

                // Pick frame + fill color.
                var frame = Kirigami.Theme.textColor
                var fillColor
                if (isError) {
                    fillColor = Kirigami.Theme.negativeTextColor
                } else if (fillPct >= 90) {
                    fillColor = Kirigami.Theme.negativeTextColor
                } else if (fillPct >= 75) {
                    fillColor = Kirigami.Theme.neutralTextColor
                } else {
                    fillColor = Kirigami.Theme.highlightColor
                }

                // Outer frame.
                ctx.strokeStyle = frame
                ctx.lineWidth = stroke
                roundRectPath(ctx,
                    stroke / 2, stroke / 2,
                    w - stroke, h - stroke,
                    radius)
                ctx.stroke()

                if (isError) {
                    // Draw a "!" instead of a fill.
                    ctx.fillStyle = fillColor
                    ctx.font = "bold " + Math.floor(h * 0.65) + "px sans-serif"
                    ctx.textAlign = "center"
                    ctx.textBaseline = "middle"
                    ctx.fillText("!", w / 2, h / 2 + 1)
                    return
                }

                // Inner fill, growing from the bottom.
                var pad = stroke + 1
                var innerW = w - pad * 2
                var innerH = h - pad * 2
                var fillH = innerH * Math.max(0, Math.min(100, fillPct)) / 100
                if (fillH > 0.5) {
                    ctx.fillStyle = fillColor
                    roundRectPath(ctx,
                        pad,
                        h - pad - fillH,
                        innerW,
                        fillH,
                        Math.max(0, radius - pad / 2))
                    ctx.fill()
                }
            }

            function roundRectPath(ctx, x, y, w, h, r) {
                if (w < 2 * r) r = w / 2
                if (h < 2 * r) r = h / 2
                ctx.beginPath()
                ctx.moveTo(x + r, y)
                ctx.arcTo(x + w, y,     x + w, y + h, r)
                ctx.arcTo(x + w, y + h, x,     y + h, r)
                ctx.arcTo(x,     y + h, x,     y,     r)
                ctx.arcTo(x,     y,     x + w, y,     r)
                ctx.closePath()
            }
        }
    }

    // ===================================================================
    // Full representation: the popup
    // ===================================================================
    fullRepresentation: ColumnLayout {
        Layout.preferredWidth: Kirigami.Units.gridUnit * 18
        Layout.preferredHeight: Kirigami.Units.gridUnit * 11
        Layout.minimumWidth: Kirigami.Units.gridUnit * 16
        spacing: Kirigami.Units.smallSpacing

        Kirigami.Heading {
            level: 3
            text: "Claude Usage"
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            Layout.topMargin: Kirigami.Units.smallSpacing
        }

        // Error banner
        QQC2.Label {
            visible: root.errorState !== ""
            text: root.errorMessage(root.errorState)
            color: Kirigami.Theme.negativeTextColor
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
        }

        // Session row
        ColumnLayout {
            visible: root.errorState === ""
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            spacing: 2

            RowLayout {
                Layout.fillWidth: true
                QQC2.Label { text: "Session"; font.bold: true }
                Item { Layout.fillWidth: true }
                QQC2.Label {
                    text: root.sessionPct.toFixed(0) + "%"
                    font.bold: true
                }
            }
            QQC2.ProgressBar {
                Layout.fillWidth: true
                from: 0; to: 100
                value: root.sessionPct
            }
            QQC2.Label {
                text: root.formatReset(root.sessionResetIso, root.nowMs)
                opacity: 0.7
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
        }

        // Weekly row
        ColumnLayout {
            visible: root.errorState === ""
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            spacing: 2

            RowLayout {
                Layout.fillWidth: true
                QQC2.Label { text: "Weekly"; font.bold: true }
                Item { Layout.fillWidth: true }
                QQC2.Label {
                    text: root.weeklyPct.toFixed(0) + "%"
                    font.bold: true
                }
            }
            QQC2.ProgressBar {
                Layout.fillWidth: true
                from: 0; to: 100
                value: root.weeklyPct
            }
            QQC2.Label {
                text: root.formatReset(root.weeklyResetIso, root.nowMs)
                opacity: 0.7
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
        }

        Item { Layout.fillHeight: true }

        // Footer: next-refresh hint + manual refresh button
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            Layout.bottomMargin: Kirigami.Units.smallSpacing

            QQC2.Label {
                text: root.formatLastRefreshed(root.lastSuccessMs, root.nowMs)
                opacity: 0.5
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
            Item { Layout.fillWidth: true }
            QQC2.ToolButton {
                icon.name: "view-refresh"
                enabled: root.canManuallyRefresh
                onClicked: root.fetchNow()
                QQC2.ToolTip.visible: hovered
                QQC2.ToolTip.text: enabled
                    ? "Refresh now"
                    : "Cooldown — " + Math.max(1, Math.ceil((root.minFetchIntervalMs - (root.nowMs - root.lastFetchMs)) / 1000)) + "s"
            }
        }
    }

    // ===================================================================
    // Logic
    // ===================================================================

    // Live ticker for the "Resets in ..." labels — runs only while the
    // popup is open so we're not burning a wakeup every second 24/7.
    Timer {
        interval: 1000
        running: root.expanded
        repeat: true
        onTriggered: root.nowMs = Date.now()
    }

    // The actual refresh schedule. interval is rewritten by
    // scheduleNextRefresh() based on the backoff state machine.
    Timer {
        id: refreshTimer
        interval: root.backoffSeconds[root.backoffIdx] * 1000
        running: false
        repeat: false
        onTriggered: root.fetchNow()
    }

    // Bash subprocess runner (Plasma's classic "executable" data engine,
    // exposed in Plasma 6 via the plasma5support compat module).
    P5Support.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []

        onNewData: (sourceName, data) => {
            disconnectSource(sourceName)
            root.handleResponse(data["stdout"] || "")
        }

        function exec(cmd) {
            connectSource(cmd)
        }
    }

    function fetchNow() {
        var now = Date.now()
        if (now - lastFetchMs < minFetchIntervalMs) {
            // Cooldown active — skip silently. The auto-refresh timer is
            // left alone, so the next scheduled fetch still happens on time.
            return
        }
        lastFetchMs = now
        refreshTimer.stop()
        // Resolve the script path relative to this QML file.
        var scriptUrl = Qt.resolvedUrl("../code/fetch-usage.sh").toString()
        var scriptPath = scriptUrl.replace(/^file:\/\//, "")
        executable.exec("bash '" + scriptPath + "'")
    }

    function handleResponse(stdout) {
        var data
        try {
            data = JSON.parse(stdout.trim())
        } catch (e) {
            root.errorState = "parse_error"
            scheduleNextRefresh(false)
            return
        }

        if (data.error) {
            root.errorState = data.error
            if (data.error === "http_429") {
                // Honor server-provided Retry-After. If absent, fall all
                // the way back to the 1-hour ceiling — we don't know when
                // we'll be unblocked, so pessimism beats more 429s.
                var retrySec = (typeof data.retry_after === "number" && data.retry_after > 0)
                    ? data.retry_after
                    : 3600
                scheduleRefreshIn(retrySec)
            } else {
                scheduleNextRefresh(false)
            }
            return
        }

        root.errorState = ""
        var newSnapshot = root.usageSnapshot(data)
        var changed = newSnapshot !== root.lastUsageSnapshot
        var hadPrior = root.lastUsageSnapshot !== ""
        root.lastUsageSnapshot = newSnapshot
        root.usageData = data
        root.lastSuccessMs = Date.now()
        // First successful fetch counts as "no change" so we don't
        // immediately enter the active-polling cycle on startup.
        scheduleNextRefresh(hadPrior && changed)
    }

    function scheduleNextRefresh(changed) {
        // Only a *change* in the data resets the backoff to the floor
        // (15s active polling). A manual refresh that returns identical
        // data falls into the "else" branch and advances backoff one
        // step, exactly like a no-change auto-tick — it does not reset
        // to the floor. Likewise an error response is treated as no-change
        // so we keep backing off instead of pounding the API.
        if (changed) {
            root.backoffIdx = 0
        } else {
            root.backoffIdx = Math.min(root.backoffIdx + 1, root.backoffSeconds.length - 1)
        }
        refreshTimer.interval = root.backoffSeconds[root.backoffIdx] * 1000
        refreshTimer.start()
    }

    // Schedule the next refresh at an exact delay (used for honoring a
    // server-provided Retry-After). Snaps backoffIdx to the closest step
    // ≥ this delay so the *next* natural backoff doesn't suddenly drop
    // back to the floor.
    function scheduleRefreshIn(seconds) {
        var idx = root.backoffSeconds.length - 1
        for (var i = 0; i < root.backoffSeconds.length; i++) {
            if (root.backoffSeconds[i] >= seconds) { idx = i; break }
        }
        root.backoffIdx = idx
        refreshTimer.interval = seconds * 1000
        refreshTimer.start()
    }

    // Keep the countdown labels accurate the moment the popup opens —
    // but do NOT trigger a fetch. Refresh is manual only (button or
    // right-click) plus the auto backoff timer.
    onExpandedChanged: {
        if (expanded) {
            nowMs = Date.now()
        }
    }

    // ===================================================================
    // Formatting helpers
    // ===================================================================

    // Build a deterministic, key-ordered string of just the utilization
    // values from the API response. This is what we compare against the
    // previous response to decide whether to reset the backoff. We
    // ignore resets_at on purpose (rolling window timestamps drift on
    // every call) and we walk a fixed key order so server-side key
    // reordering can't ever look like a change. Utilization is rounded
    // to whole percent so sub-1% jitter from background usage elsewhere
    // can't pin the poller at the floor.
    function usageSnapshot(data) {
        if (!data) return ""
        var keys = ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus"]
        var parts = []
        for (var i = 0; i < keys.length; i++) {
            var k = keys[i]
            var v = data[k]
            if (v && typeof v === "object" && v.utilization !== undefined && v.utilization !== null) {
                parts.push(k + "=" + Math.round(v.utilization))
            } else {
                parts.push(k + "=null")
            }
        }
        return parts.join("|")
    }

    function formatReset(isoStr, now) {
        if (!isoStr) return ""
        var resetMs = Date.parse(isoStr)
        if (isNaN(resetMs)) return ""
        var diffMs = resetMs - now
        if (diffMs <= 0) return "Resetting now…"

        var totalMin = Math.floor(diffMs / 60000)
        var days = Math.floor(totalMin / 1440)
        var hours = Math.floor((totalMin % 1440) / 60)
        var minutes = totalMin % 60

        if (days >= 1) {
            return "Resets in " + days + " day " + hours + " hr"
        } else if (hours >= 1) {
            return "Resets in " + hours + " hr " + minutes + " min"
        } else {
            return "Resets in " + minutes + " min"
        }
    }

    function formatLastRefreshed(successMs, now) {
        if (!successMs) return "Never refreshed"
        var diffSec = Math.max(0, Math.floor((now - successMs) / 1000))
        var label
        if (diffSec < 5) {
            label = "just now"
        } else if (diffSec < 60) {
            label = diffSec + "s ago"
        } else if (diffSec < 3600) {
            label = Math.floor(diffSec / 60) + "m ago"
        } else {
            var hours = Math.floor(diffSec / 3600)
            var mins = Math.floor((diffSec % 3600) / 60)
            label = mins > 0 ? (hours + "h " + mins + "m ago") : (hours + "h ago")
        }
        return "Last refreshed " + label
    }

    function errorMessage(state) {
        switch (state) {
            case "no_credentials": return "No Claude Code credentials found. Run `claude` to log in."
            case "no_token":       return "Could not read access token from credentials file."
            case "auth_expired":   return "Auth token rejected and refresh failed. Run `claude` to re-login."
            case "network_error":  return "Network error contacting Anthropic."
            case "parse_error":    return "Could not parse response."
            case "missing_jq":     return "`jq` not installed (sudo pacman -S jq)."
            case "missing_curl":   return "`curl` not installed (sudo pacman -S curl)."
            case "missing_flock":  return "`flock` not installed (sudo pacman -S util-linux)."
            default:
                if (state.indexOf("http_") === 0) return "HTTP " + state.substr(5) + " from API."
                return "Error: " + state
        }
    }

    Component.onCompleted: fetchNow()
}
