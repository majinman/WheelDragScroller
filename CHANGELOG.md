# Changelog

## Unreleased

### Fixed

- Added automatic TCC permission reset for app reinstalls. When the installed executable changes, the app now clears stale `Accessibility` and `ListenEvent` entries for its bundle identifier so macOS can attach fresh permissions to the current app.
- Preserved normal middle-click behavior while keeping drag-to-scroll support.
- Fixed an input-state bug where middle-button `down` could be delivered to the active app, while the matching `up` event was swallowed after auto-scroll activation. That mismatch could leave apps thinking the middle button was still pressed and make regular clicks feel unresponsive.
- Middle-button input is now held until intent is clear. A short click is replayed as a normal middle click, while movement beyond the drag threshold starts auto-scroll.
