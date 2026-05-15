# Wheel Drag Scroller

A macOS menu bar app that enables Windows-style middle-button auto-scroll. Hold the mouse wheel button, drag in any direction, and keep scrolling until you release.

## Build

```bash
cd ~/WheelDragScroller
chmod +x Scripts/make-app.sh
Scripts/make-app.sh
```

The app bundle is created at `build/Wheel Drag Scroller.app`.

## Features

- Windows-style middle-button drag scrolling
- Adjustable auto-scroll acceleration, curve, and max speed
- Optional vertical and horizontal scroll reversal
- Separate reversal toggles for mouse and trackpad
- Menu bar toggle and launch-at-login support

## Usage

1. Launch the app.
2. Use the menu bar icon to enable or disable scrolling and configure launch at login.
3. Adjust auto-scroll sensitivity with the sliders in the menu.
4. Use the checkboxes to control vertical or horizontal reversal and whether those reversal rules apply to mouse or trackpad input.
5. When macOS prompts for permissions, allow both `Accessibility` and `Input Monitoring` in `System Settings > Privacy & Security`.

After granting permissions, quitting and reopening the app usually helps macOS apply them cleanly.

Trackpad and mouse input are distinguished using macOS scroll event characteristics. Standard wheel mice and trackpads are generally detected correctly, but devices such as Magic Mouse may behave more like trackpads.
