# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## About

Stats is a macOS menu bar system monitor written in Swift. It displays CPU, GPU, RAM, Disk, Network, Battery, Sensors, Bluetooth, and Clock data. Minimum supported macOS: 11.15 (Big Sur).

## Build Commands

```bash
# Full release build (requires notarization credentials)
make build

# Build and export archive only (no notarization)
make archive

# Clean build artifacts
make clean

# Rebuild bundled LevelDB static library (only needed if libleveldb.a needs updating)
make leveldb
```

For day-to-day development, open `Stats.xcodeproj` in Xcode and run the `Stats` scheme directly. The Makefile targets are for release distribution.

**Linting** (requires SwiftLint installed):
```bash
swiftlint
```

**Tests** – run via Xcode (Product → Test) or:
```bash
xcodebuild test -scheme Stats -destination 'platform=macOS'
```

Tests live in `Tests/` and use XCTest. Currently only RAM process-parsing logic is covered.

## Architecture

### Module System

Every sensor is a `Module` subclass (base class in `Kit/module/module.swift`). The module lifecycle:
1. `init` – creates readers, popup/settings/portal/notifications views, registers NotificationCenter observers
2. `mount()` – called at app start; starts readers and enables the menu bar item
3. `enable()`/`disable()` – toggle at runtime
4. `terminate()` – called before app quits

Each module in `Modules/` follows the same file layout:
- `main.swift` – Module subclass, data structs, reader wiring, widget updates
- `readers.swift` / `reader.swift` – Reader subclasses that collect system data
- `popup.swift` – Detail view shown when clicking the menu bar icon
- `settings.swift` – Settings panel
- `portal.swift` – Dashboard portal view
- `notifications.swift` – Notification thresholds/triggers
- `config.plist` – Declares name, icon, available widgets, default state

### Reader Pattern

`Reader<T>` (`Kit/module/reader.swift`) is a generic base class for periodic data collection. Subclasses override `read()`. Key properties:
- `popup: Bool` – reader only runs while the popup is visible
- `preview: Bool` – reader only runs while the settings window is open  
- `sleep: Bool` – reader pauses during system sleep
- `alignToSecondBoundary: Bool` – aligns first tick to the next whole second

Reader callbacks flow into the Module, which then pushes values to active widgets, the popup view, the portal view, and the notifications engine.

### Widgets

Reusable widget views live in `Kit/Widgets/`. The `widget_t` enum (`Kit/module/widget.swift`) maps string keys to widget instances. Each module's `config.plist` declares which widgets it supports. Widget types: `mini`, `line_chart`, `bar_chart`, `pie_chart`, `network_chart`, `speed`, `battery`, `battery_details`, `sensors` (stack), `memory`, `label`, `tachometer`, `state`, `text`.

### Persistence

- **`Store`** (`Kit/plugins/Store.swift`) – `UserDefaults` wrapper with in-process cache. Settings keys follow the pattern `"{ModuleName}_{settingKey}"` (e.g. `"CPU_updateInterval"`).
- **`DB`** (`Kit/plugins/DB.swift`) – LevelDB wrapper for historical time-series data. The compiled static library is at `Kit/lldb/libleveldb.a`.

### Inter-component Communication

Components communicate via `NotificationCenter`. Key notification names (defined in `Kit/module/notifications.swift`): `.toggleModule`, `.togglePopup`, `.toggleWidget`, `.clickInSettings`, `.pause`, `.openWindow`.

### SMC Helper (Fan Control)

`SMC/Helper/` is a privileged XPC helper for fan speed control, installed via `SMJobBless`. On Apple Silicon, automatic installation fails; use the manual path:
```bash
sudo ./install_helper.sh
```
Diagnostic log: `/tmp/stats_helper.log`

### App Entry Point

`Stats/AppDelegate.swift` instantiates all modules into a global `modules: [Module]` array and calls `mount()` on each at launch. Adding a new module means adding it here and importing its target.

### System Widgets Extension

`Widgets/` is a separate app extension target that provides macOS/iOS WidgetKit widgets. Modules push data to it via a shared `UserDefaults` suite (`{TeamId}.eu.exelban.Stats.widgets`).

## SwiftLint Configuration

`.swiftlint.yml` disables `force_cast`, `type_name`, `cyclomatic_complexity`, and several style rules. Line length limit is 200; file length limit is 1400/1800; type body limit is 700/1000.
