# Claude Usage Plasmoid

A KDE Plasma 6 system tray widget that shows your Claude Code usage (both the
5-hour session and 7-day weekly limits) with reset countdowns. Uses the claude cli `/usage`
endpoint with credential auto-refreshing and strictly applied rate limits to avoid 429s.

- **Tray icon**: a fill bar showing current 5-hour session utilization (0–100%). Color shifts blue → orange → red as you approach the cap. Shows `!` if something's wrong (hover for tooltip).
- **Popup**: progress bars for both *Session* (5-hour) and *Weekly* (7-day) limits, each with a live "Resets in X hr Y min" countdown, plus a "Last refreshed X ago" footer so you can see how stale the data is.
- **Adaptive polling** in the background: backoff sequence is `15s → 20s → 30s → 45s → 1m → 2m → 5m → 10m → 20m → 30m → 45m → 1h`. Resets to 15s on any whole-percent change in the data; otherwise advances one step each tick. Idles at 1h.
- **Manual refresh** is the only way to trigger an on-demand fetch:
  - Refresh button (↻) inside the popup.
  - **"Refresh now"** entry in the right-click menu on the tray icon.
- **Cooldown**: any manual refresh within 15s of the previous attempt is a silent no-op (the in-popup button visibly disables and shows a countdown tooltip). This is a hard guard against hammering the API.
- **429 handling**: if the API returns 429 with a `Retry-After` header, the next attempt is scheduled for exactly that delay. If the header is missing, the poller falls all the way back to the 1h idle interval rather than guessing.

## Requirements

- KDE Plasma 6
- `curl`, `jq`, `flock` (`sudo pacman -S curl jq util-linux`)
- Logged in to Claude Code (run `claude` once so `~/.claude/.credentials.json` exists)

## Install

```bash
kpackagetool6 --type=Plasma/Applet --install package
```

Then add the **Claude Usage** widget to your panel.

To upgrade or remove:

```bash
kpackagetool6 --type=Plasma/Applet --upgrade package
kpackagetool6 --type=Plasma/Applet --remove com.ryan.claudeusage
```

## License

MIT
