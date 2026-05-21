import AppKit
import ApplicationServices
import CoreGraphics
import CryptoKit

private let bundleIdentifier = "com.codex.WheelDragScroller"
private let appName = "Wheel Drag Scroller"
private let generatedScrollMarker: Int64 = 0x57445343

enum AppPaths {
    static let installedAppURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        .appendingPathComponent("\(appName).app", isDirectory: true)
}

final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard
    private let currentDefaultsVersion = 3
    static let defaultAcceleration = 0.018
    static let defaultCurve = 1.45
    static let defaultMaxPixelsPerFrame = 65.0

    private init() {
        migrateDefaultsIfNeeded()
    }

    private func migrateDefaultsIfNeeded() {
        let version = defaults.integer(forKey: "defaultsVersion")
        guard version < currentDefaultsVersion else { return }

        if version < 2 {
            defaults.set(false, forKey: "reverseVertical")
        }

        if version < 3 {
            defaults.set(false, forKey: "reverseVertical")
            defaults.set(false, forKey: "reverseHorizontal")
            defaults.set(false, forKey: "reverseMouse")
            defaults.set(false, forKey: "reverseTrackpad")
        }

        defaults.set(currentDefaultsVersion, forKey: "defaultsVersion")
    }

    var isEnabled: Bool {
        get { defaults.object(forKey: "isEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "isEnabled") }
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: "launchAtLogin") }
        set { defaults.set(newValue, forKey: "launchAtLogin") }
    }

    var acceleration: CGFloat {
        get { CGFloat(defaults.object(forKey: "acceleration") as? Double ?? Self.defaultAcceleration) }
        set { defaults.set(Double(newValue), forKey: "acceleration") }
    }

    var curve: CGFloat {
        get { CGFloat(defaults.object(forKey: "curve") as? Double ?? Self.defaultCurve) }
        set { defaults.set(Double(newValue), forKey: "curve") }
    }

    var maxPixelsPerFrame: CGFloat {
        get { CGFloat(defaults.object(forKey: "maxPixelsPerFrame") as? Double ?? Self.defaultMaxPixelsPerFrame) }
        set { defaults.set(Double(newValue), forKey: "maxPixelsPerFrame") }
    }

    var reverseVertical: Bool {
        get { defaults.object(forKey: "reverseVertical") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "reverseVertical") }
    }

    var reverseHorizontal: Bool {
        get { defaults.object(forKey: "reverseHorizontal") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "reverseHorizontal") }
    }

    var reverseMouse: Bool {
        get { defaults.object(forKey: "reverseMouse") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "reverseMouse") }
    }

    var reverseTrackpad: Bool {
        get { defaults.object(forKey: "reverseTrackpad") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "reverseTrackpad") }
    }

    func resetTuning() {
        acceleration = CGFloat(Self.defaultAcceleration)
        curve = CGFloat(Self.defaultCurve)
        maxPixelsPerFrame = CGFloat(Self.defaultMaxPixelsPerFrame)
    }
}

final class LaunchAtLoginManager {
    private let plistURL: URL = {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        return directory.appendingPathComponent("\(bundleIdentifier).plist")
    }()

    var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    func refreshIfEnabled() throws {
        guard isEnabled else { return }
        try setEnabled(true)
    }

    func setEnabled(_ enabled: Bool) throws {
        let directory = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if enabled {
            let appPath = AppPaths.installedAppURL.path
            let plist: [String: Any] = [
                "Label": bundleIdentifier,
                "ProgramArguments": ["/usr/bin/open", appPath],
                "RunAtLoad": true,
                "KeepAlive": false
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } else if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }
}

final class AppInstaller {
    func isRunningInstalledApp() -> Bool {
        Bundle.main.bundleURL.standardizedFileURL == AppPaths.installedAppURL.standardizedFileURL
    }

    func installCurrentAppIfNeeded() throws -> Bool {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return false }

        let sourceURL = Bundle.main.bundleURL.standardizedFileURL
        let destinationURL = AppPaths.installedAppURL.standardizedFileURL
        guard sourceURL != destinationURL else { return false }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return true
    }

    func relaunchInstalledApp() {
        NSWorkspace.shared.openApplication(
            at: AppPaths.installedAppURL,
            configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil
        )
    }
}

final class PermissionResetManager {
    private let defaults = UserDefaults.standard
    private let fingerprintKey = "permissionResetAppFingerprint"

    func resetIfCurrentAppChanged() {
        guard let fingerprint = currentAppFingerprint() else { return }
        guard defaults.string(forKey: fingerprintKey) != fingerprint else { return }

        reset(service: "Accessibility")
        reset(service: "ListenEvent")
        defaults.set(fingerprint, forKey: fingerprintKey)
    }

    private func currentAppFingerprint() -> String? {
        guard let executableURL = Bundle.main.executableURL,
              let executableData = try? Data(contentsOf: executableURL) else {
            return nil
        }

        let digest = SHA256.hash(data: executableData)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func reset(service: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, bundleIdentifier]
        try? process.run()
        process.waitUntilExit()
    }
}

final class WheelDragEngine {
    enum StartFailure {
        case accessibilityPermission
        case inputMonitoringPermission
        case eventTapPermission
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var scrollTimer: Timer?
    private var middleButtonPressed = false
    private var autoScrollActive = false
    private var anchorPoint = CGPoint.zero
    private var currentPoint = CGPoint.zero
    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    private let activationDistance: CGFloat = 8

    static func hasAccessibilityPermission(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func hasInputMonitoringPermission(prompt: Bool) -> Bool {
        if CGPreflightListenEventAccess() {
            return true
        }

        return prompt ? CGRequestListenEventAccess() : false
    }

    var isRunning: Bool {
        eventTap != nil
    }

    func start() -> StartFailure? {
        guard eventTap == nil else { return nil }
        guard Self.hasAccessibilityPermission(prompt: true) else { return .accessibilityPermission }
        guard Self.hasInputMonitoringPermission(prompt: true) else { return .inputMonitoringPermission }

        let mask =
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let engine = Unmanaged<WheelDragEngine>.fromOpaque(userInfo).takeUnretainedValue()
            return engine.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return .eventTapPermission
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        return nil
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        stopAutoScroll()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .scrollWheel {
            return handleScrollWheel(event)
        }

        guard event.getIntegerValueField(.eventSourceUserData) != generatedScrollMarker else {
            return Unmanaged.passUnretained(event)
        }

        let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
        guard buttonNumber == 2 else {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .otherMouseDown:
            middleButtonPressed = true
            autoScrollActive = false
            anchorPoint = event.location
            currentPoint = event.location
            accumulatedX = 0
            accumulatedY = 0
            return nil
        case .otherMouseDragged:
            guard middleButtonPressed else { return Unmanaged.passUnretained(event) }
            currentPoint = event.location
            if !autoScrollActive, shouldActivateAutoScroll() {
                autoScrollActive = true
                startAutoScroll()
            }
            return nil
        case .otherMouseUp:
            let shouldSendClick = middleButtonPressed && !autoScrollActive
            let wasAutoScrolling = autoScrollActive
            let clickPoint = anchorPoint
            let flags = event.flags
            stopAutoScroll()
            if shouldSendClick {
                postMiddleClick(at: clickPoint, flags: flags)
            }
            return wasAutoScrolling || shouldSendClick ? nil : Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func postMiddleClick(at point: CGPoint, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(mouseEventSource: source, mouseType: .otherMouseDown, mouseCursorPosition: point, mouseButton: .center)
        let up = CGEvent(mouseEventSource: source, mouseType: .otherMouseUp, mouseCursorPosition: point, mouseButton: .center)

        [down, up].forEach { event in
            event?.flags = flags
            event?.setIntegerValueField(.eventSourceUserData, value: generatedScrollMarker)
            event?.post(tap: .cghidEventTap)
        }
    }

    private func shouldActivateAutoScroll() -> Bool {
        let dx = currentPoint.x - anchorPoint.x
        let dy = currentPoint.y - anchorPoint.y
        return hypot(dx, dy) >= activationDistance
    }

    private func handleScrollWheel(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard event.getIntegerValueField(.eventSourceUserData) != generatedScrollMarker else {
            return Unmanaged.passUnretained(event)
        }

        let isTrackpadLike = isTrackpadScroll(event)
        let settings = Settings.shared
        let shouldReverseDevice = isTrackpadLike ? settings.reverseTrackpad : settings.reverseMouse
        let shouldReverseAxis = settings.reverseVertical || settings.reverseHorizontal
        guard shouldReverseDevice && shouldReverseAxis else {
            return Unmanaged.passUnretained(event)
        }

        guard let reversedEvent = makeReversedScrollEvent(from: event, settings: settings) else {
            return Unmanaged.passUnretained(event)
        }

        reversedEvent.post(tap: .cghidEventTap)
        return nil
    }

    private func isTrackpadScroll(_ event: CGEvent) -> Bool {
        let scrollPhase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        let instantMouser = event.getIntegerValueField(.scrollWheelEventInstantMouser)

        if instantMouser != 0 {
            return false
        }

        return scrollPhase != 0 || momentumPhase != 0
    }

    private func makeReversedScrollEvent(from event: CGEvent, settings: Settings) -> CGEvent? {
        let pointY = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let pointX = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let usesPixels = isContinuous || pointY != 0 || pointX != 0
        let units: CGScrollEventUnit = usesPixels ? .pixel : .line

        let originalY = scrollAxisValue(
            event,
            usesPixels: usesPixels,
            pointField: .scrollWheelEventPointDeltaAxis1,
            fixedField: .scrollWheelEventFixedPtDeltaAxis1,
            deltaField: .scrollWheelEventDeltaAxis1
        )
        let originalX = scrollAxisValue(
            event,
            usesPixels: usesPixels,
            pointField: .scrollWheelEventPointDeltaAxis2,
            fixedField: .scrollWheelEventFixedPtDeltaAxis2,
            deltaField: .scrollWheelEventDeltaAxis2
        )

        let nextY = settings.reverseVertical ? -originalY : originalY
        let nextX = settings.reverseHorizontal ? -originalX : originalX
        let source = CGEventSource(stateID: .hidSystemState)
        let reversedEvent = CGEvent(
            scrollWheelEvent2Source: source,
            units: units,
            wheelCount: 2,
            wheel1: Int32(clampForScrollEvent(nextY)),
            wheel2: Int32(clampForScrollEvent(nextX)),
            wheel3: 0
        )

        reversedEvent?.flags = event.flags
        reversedEvent?.setIntegerValueField(.eventSourceUserData, value: generatedScrollMarker)
        copyScrollMetadata(from: event, to: reversedEvent)
        return reversedEvent
    }

    private func scrollAxisValue(
        _ event: CGEvent,
        usesPixels: Bool,
        pointField: CGEventField,
        fixedField: CGEventField,
        deltaField: CGEventField
    ) -> Int64 {
        if usesPixels {
            let pointValue = event.getIntegerValueField(pointField)
            if pointValue != 0 {
                return pointValue
            }

            let fixedValue = event.getDoubleValueField(fixedField)
            if fixedValue != 0 {
                return Int64(fixedValue.rounded())
            }
        }

        return event.getIntegerValueField(deltaField)
    }

    private func clampForScrollEvent(_ value: Int64) -> Int64 {
        min(max(value, Int64(Int32.min)), Int64(Int32.max))
    }

    private func copyScrollMetadata(from source: CGEvent, to destination: CGEvent?) {
        guard let destination else { return }
        let metadataFields: [CGEventField] = [
            .scrollWheelEventIsContinuous,
            .scrollWheelEventScrollPhase,
            .scrollWheelEventScrollCount,
            .scrollWheelEventMomentumPhase,
            .scrollWheelEventInstantMouser
        ]

        for field in metadataFields {
            destination.setIntegerValueField(field, value: source.getIntegerValueField(field))
        }
    }

    private func startAutoScroll() {
        scrollTimer?.invalidate()
        scrollTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tickAutoScroll()
        }
        if let scrollTimer {
            RunLoop.main.add(scrollTimer, forMode: .common)
        }
    }

    private func stopAutoScroll() {
        middleButtonPressed = false
        autoScrollActive = false
        scrollTimer?.invalidate()
        scrollTimer = nil
        accumulatedX = 0
        accumulatedY = 0
    }

    private func tickAutoScroll() {
        guard autoScrollActive else { return }

        let dx = currentPoint.x - anchorPoint.x
        let dy = currentPoint.y - anchorPoint.y
        let deadZone: CGFloat = 4
        let acceleration = Settings.shared.acceleration
        let maxPixelsPerFrame = Settings.shared.maxPixelsPerFrame

        accumulatedX += velocity(for: dx, deadZone: deadZone, acceleration: acceleration, maxPixelsPerFrame: maxPixelsPerFrame)
        accumulatedY += velocity(for: dy, deadZone: deadZone, acceleration: acceleration, maxPixelsPerFrame: maxPixelsPerFrame)

        let wholeX = Int32(accumulatedX.rounded(.towardZero))
        let wholeY = Int32(accumulatedY.rounded(.towardZero))
        guard wholeX != 0 || wholeY != 0 else { return }

        accumulatedX -= CGFloat(wholeX)
        accumulatedY -= CGFloat(wholeY)

        let source = CGEventSource(stateID: .hidSystemState)
        let scrollEvent = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: -wholeY,
            wheel2: -wholeX,
            wheel3: 0
        )
        scrollEvent?.setIntegerValueField(.eventSourceUserData, value: generatedScrollMarker)
        scrollEvent?.post(tap: .cghidEventTap)
    }

    private func velocity(
        for distance: CGFloat,
        deadZone: CGFloat,
        acceleration: CGFloat,
        maxPixelsPerFrame: CGFloat
    ) -> CGFloat {
        guard abs(distance) > deadZone else { return 0 }

        let sign: CGFloat = distance < 0 ? -1 : 1
        let effectiveDistance = abs(distance) - deadZone
        let curved = pow(effectiveDistance, Settings.shared.curve) * acceleration
        return min(curved, maxPixelsPerFrame) * sign
    }
}

final class TuningMenuView: NSView {
    private let settings = Settings.shared
    private let accelerationSlider = NSSlider(value: Settings.defaultAcceleration, minValue: 0.005, maxValue: 0.08, target: nil, action: nil)
    private let curveSlider = NSSlider(value: Settings.defaultCurve, minValue: 1.05, maxValue: 2.2, target: nil, action: nil)
    private let maxSpeedSlider = NSSlider(value: Settings.defaultMaxPixelsPerFrame, minValue: 20, maxValue: 160, target: nil, action: nil)
    private let accelerationValueLabel = NSTextField(labelWithString: "")
    private let curveValueLabel = NSTextField(labelWithString: "")
    private let maxSpeedValueLabel = NSTextField(labelWithString: "")
    private let verticalReverseCheckbox = NSButton(checkboxWithTitle: "수직 반전", target: nil, action: nil)
    private let horizontalReverseCheckbox = NSButton(checkboxWithTitle: "수평 반전", target: nil, action: nil)
    private let trackpadReverseCheckbox = NSButton(checkboxWithTitle: "트랙패드 반전", target: nil, action: nil)
    private let mouseReverseCheckbox = NSButton(checkboxWithTitle: "마우스 반전", target: nil, action: nil)

    override var intrinsicContentSize: NSSize {
        NSSize(width: 320, height: 386)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
        refreshControls()
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func setup() {
        frame = NSRect(x: 0, y: 0, width: 320, height: 386)

        let title = NSTextField(labelWithString: "스크롤 감도")
        title.font = .boldSystemFont(ofSize: 13)
        title.lineBreakMode = .byClipping
        title.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let titleContainer = NSView()
        titleContainer.translatesAutoresizingMaskIntoConstraints = false
        titleContainer.addSubview(title)
        NSLayoutConstraint.activate([
            titleContainer.widthAnchor.constraint(equalToConstant: 292),
            titleContainer.heightAnchor.constraint(equalToConstant: 24),
            title.leadingAnchor.constraint(equalTo: titleContainer.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: titleContainer.trailingAnchor),
            title.centerYAnchor.constraint(equalTo: titleContainer.centerYAnchor)
        ])

        stack.addArrangedSubview(titleContainer)
        stack.addArrangedSubview(row(title: "가속 계수", slider: accelerationSlider, valueLabel: accelerationValueLabel))
        stack.addArrangedSubview(row(title: "가속 곡선", slider: curveSlider, valueLabel: curveValueLabel))
        stack.addArrangedSubview(row(title: "최대 속도", slider: maxSpeedSlider, valueLabel: maxSpeedValueLabel))

        let resetButton = NSButton(title: "기본값으로 복원", target: self, action: #selector(resetDefaults))
        resetButton.bezelStyle = .rounded
        stack.addArrangedSubview(resetButton)

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(reverseSection())

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -14)
        ])

        configure(slider: accelerationSlider, action: #selector(accelerationChanged))
        configure(slider: curveSlider, action: #selector(curveChanged))
        configure(slider: maxSpeedSlider, action: #selector(maxSpeedChanged))
    }

    private func row(title: String, slider: NSSlider, valueLabel: NSTextField) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.alignment = .right
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        slider.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(label)
        container.addSubview(valueLabel)
        container.addSubview(slider)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 292),
            container.heightAnchor.constraint(equalToConstant: 40),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            label.topAnchor.constraint(equalTo: container.topAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            valueLabel.widthAnchor.constraint(equalToConstant: 56),
            slider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            slider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            slider.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 2)
        ])

        return container
    }

    private func configure(slider: NSSlider, action: Selector) {
        slider.target = self
        slider.action = action
        slider.isContinuous = true
    }

    private func configure(checkbox: NSButton, action: Selector) {
        checkbox.target = self
        checkbox.action = action
        checkbox.font = .systemFont(ofSize: 12)
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 292).isActive = true
        return box
    }

    private func reverseSection() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let directionTitle = NSTextField(labelWithString: "스크롤 방향")
        let deviceTitle = NSTextField(labelWithString: "스크롤 기기")
        [directionTitle, deviceTitle].forEach {
            $0.font = .boldSystemFont(ofSize: 12)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        let directionStack = NSStackView(views: [verticalReverseCheckbox, horizontalReverseCheckbox])
        directionStack.orientation = .vertical
        directionStack.alignment = .leading
        directionStack.spacing = 4
        directionStack.translatesAutoresizingMaskIntoConstraints = false

        let deviceStack = NSStackView(views: [trackpadReverseCheckbox, mouseReverseCheckbox])
        deviceStack.orientation = .vertical
        deviceStack.alignment = .leading
        deviceStack.spacing = 4
        deviceStack.translatesAutoresizingMaskIntoConstraints = false

        [verticalReverseCheckbox, horizontalReverseCheckbox, trackpadReverseCheckbox, mouseReverseCheckbox].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        container.addSubview(directionTitle)
        container.addSubview(deviceTitle)
        container.addSubview(directionStack)
        container.addSubview(deviceStack)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 292),
            container.heightAnchor.constraint(equalToConstant: 92),
            directionTitle.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            directionTitle.topAnchor.constraint(equalTo: container.topAnchor),
            deviceTitle.leadingAnchor.constraint(equalTo: container.centerXAnchor, constant: 10),
            deviceTitle.topAnchor.constraint(equalTo: container.topAnchor),
            directionStack.leadingAnchor.constraint(equalTo: directionTitle.leadingAnchor),
            directionStack.topAnchor.constraint(equalTo: directionTitle.bottomAnchor, constant: 8),
            deviceStack.leadingAnchor.constraint(equalTo: deviceTitle.leadingAnchor),
            deviceStack.topAnchor.constraint(equalTo: deviceTitle.bottomAnchor, constant: 8)
        ])

        configure(checkbox: verticalReverseCheckbox, action: #selector(verticalReverseChanged))
        configure(checkbox: horizontalReverseCheckbox, action: #selector(horizontalReverseChanged))
        configure(checkbox: trackpadReverseCheckbox, action: #selector(trackpadReverseChanged))
        configure(checkbox: mouseReverseCheckbox, action: #selector(mouseReverseChanged))

        return container
    }

    private func refreshControls() {
        accelerationSlider.doubleValue = Double(settings.acceleration)
        curveSlider.doubleValue = Double(settings.curve)
        maxSpeedSlider.doubleValue = Double(settings.maxPixelsPerFrame)
        verticalReverseCheckbox.state = settings.reverseVertical ? .on : .off
        horizontalReverseCheckbox.state = settings.reverseHorizontal ? .on : .off
        trackpadReverseCheckbox.state = settings.reverseTrackpad ? .on : .off
        mouseReverseCheckbox.state = settings.reverseMouse ? .on : .off
        updateValueLabels()
    }

    private func updateValueLabels() {
        accelerationValueLabel.stringValue = String(format: "%.3f", settings.acceleration)
        curveValueLabel.stringValue = String(format: "%.2f", settings.curve)
        maxSpeedValueLabel.stringValue = String(format: "%.0f", settings.maxPixelsPerFrame)
    }

    @objc private func accelerationChanged() {
        settings.acceleration = CGFloat(accelerationSlider.doubleValue)
        updateValueLabels()
    }

    @objc private func curveChanged() {
        settings.curve = CGFloat(curveSlider.doubleValue)
        updateValueLabels()
    }

    @objc private func maxSpeedChanged() {
        settings.maxPixelsPerFrame = CGFloat(maxSpeedSlider.doubleValue)
        updateValueLabels()
    }

    @objc private func resetDefaults() {
        settings.resetTuning()
        refreshControls()
    }

    @objc private func verticalReverseChanged() {
        settings.reverseVertical = verticalReverseCheckbox.state == .on
    }

    @objc private func horizontalReverseChanged() {
        settings.reverseHorizontal = horizontalReverseCheckbox.state == .on
    }

    @objc private func trackpadReverseChanged() {
        settings.reverseTrackpad = trackpadReverseCheckbox.state == .on
    }

    @objc private func mouseReverseChanged() {
        settings.reverseMouse = mouseReverseCheckbox.state == .on
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings.shared
    private let launchAtLoginManager = LaunchAtLoginManager()
    private let appInstaller = AppInstaller()
    private let permissionResetManager = PermissionResetManager()
    private let engine = WheelDragEngine()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let accessibilityStatusItem = NSMenuItem()
    private let inputMonitoringStatusItem = NSMenuItem()
    private let enabledItem = NSMenuItem()
    private let launchAtLoginItem = NSMenuItem()
    private let tuningView = TuningMenuView()
    private var permissionSettingsPane = "Privacy_Accessibility"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if ensureInstalledApp() {
            return
        }
        permissionResetManager.resetIfCurrentAppChanged()
        configureStatusItem()
        settings.launchAtLogin = launchAtLoginManager.isEnabled
        try? launchAtLoginManager.refreshIfEnabled()
        applyEnabledState()
    }

    private func ensureInstalledApp() -> Bool {
        guard !appInstaller.isRunningInstalledApp() else { return false }

        do {
            let installed = try appInstaller.installCurrentAppIfNeeded()
            if installed {
                appInstaller.relaunchInstalledApp()
                NSApp.terminate(nil)
                return true
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "\(appName)을 Applications에 설치하지 못했습니다"
            alert.informativeText = "권한과 자동실행이 안정적으로 동작하려면 /Applications/\(appName).app 경로로 실행되는 편이 좋습니다."
            alert.runModal()
        }

        return false
    }

    private func configureStatusItem() {
        statusItem.button?.image = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right", accessibilityDescription: appName)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.toolTip = appName

        enabledItem.title = "기능 켜기"
        enabledItem.target = self
        enabledItem.action = #selector(toggleEnabled)
        menu.addItem(enabledItem)

        launchAtLoginItem.title = "부팅 시 자동실행"
        launchAtLoginItem.target = self
        launchAtLoginItem.action = #selector(toggleLaunchAtLogin)
        menu.addItem(launchAtLoginItem)

        menu.addItem(.separator())
        accessibilityStatusItem.isEnabled = false
        inputMonitoringStatusItem.isEnabled = false
        menu.addItem(accessibilityStatusItem)
        menu.addItem(inputMonitoringStatusItem)

        let accessibilityItem = NSMenuItem(title: "손쉬운 사용 열기", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)

        let inputMonitoringItem = NSMenuItem(title: "입력 모니터링 열기", action: #selector(openInputMonitoringSettings), keyEquivalent: "")
        inputMonitoringItem.target = self
        menu.addItem(inputMonitoringItem)

        menu.addItem(.separator())
        let tuningItem = NSMenuItem()
        tuningItem.view = tuningView
        menu.addItem(tuningItem)

        menu.addItem(.separator())
        let permissionItem = NSMenuItem(title: "권한 설정 열기", action: #selector(openPrivacySettings), keyEquivalent: "")
        permissionItem.target = self
        menu.addItem(permissionItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "종료", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        refreshMenu()
    }

    private func applyEnabledState() {
        if settings.isEnabled {
            if let failure = engine.start() {
                settings.isEnabled = false
                showPermissionNotification(for: failure)
            }
        } else {
            engine.stop()
        }
        refreshMenu()
    }

    private func refreshMenu() {
        let hasAccessibility = WheelDragEngine.hasAccessibilityPermission(prompt: false)
        let hasInputMonitoring = WheelDragEngine.hasInputMonitoringPermission(prompt: false)

        enabledItem.state = settings.isEnabled ? .on : .off
        launchAtLoginItem.state = launchAtLoginManager.isEnabled ? .on : .off
        accessibilityStatusItem.title = "손쉬운 사용: " + (hasAccessibility ? "허용됨" : "필요")
        inputMonitoringStatusItem.title = "입력 모니터링: " + (hasInputMonitoring ? "허용됨" : "필요")
        statusItem.button?.contentTintColor = settings.isEnabled ? nil : .secondaryLabelColor
    }

    private func showPermissionNotification(for failure: WheelDragEngine.StartFailure) {
        let alert = NSAlert()
        switch failure {
        case .accessibilityPermission:
            permissionSettingsPane = "Privacy_Accessibility"
            alert.messageText = "\(appName)에 손쉬운 사용 권한이 필요합니다"
            alert.informativeText = "목록에 체크되어 있는데도 반복된다면 권한 기록이 꼬인 상태일 수 있습니다. 체크를 껐다 켜거나, 터미널에서 tccutil reset Accessibility com.codex.WheelDragScroller 실행 후 다시 허용해 주세요."
            alert.addButton(withTitle: "손쉬운 사용 열기")
        case .inputMonitoringPermission:
            permissionSettingsPane = "Privacy_ListenEvent"
            alert.messageText = "\(appName)에 입력 모니터링 권한이 필요합니다"
            alert.informativeText = "손쉬운 사용 권한과 별개로, 마우스 버튼 입력을 전역에서 감지하려면 입력 모니터링 권한이 필요합니다. 시스템 설정에서 \(appName)을 입력 모니터링에도 허용해 주세요."
            alert.addButton(withTitle: "입력 모니터링 열기")
        case .eventTapPermission:
            permissionSettingsPane = "Privacy_ListenEvent"
            alert.messageText = "\(appName)이 마우스 이벤트를 감지하지 못했습니다"
            alert.informativeText = "손쉬운 사용과 입력 모니터링이 둘 다 허용돼 있어야 합니다. 특히 입력 모니터링이 빠져 있으면 기능 켜기가 다시 꺼집니다. 두 권한을 모두 확인해 주세요."
            alert.addButton(withTitle: "입력 모니터링 열기")
        }
        alert.addButton(withTitle: "나중에")
        if alert.runModal() == .alertFirstButtonReturn {
            openPrivacySettings()
        }
    }

    @objc private func toggleEnabled() {
        settings.isEnabled.toggle()
        applyEnabledState()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            let nextValue = !launchAtLoginManager.isEnabled
            try launchAtLoginManager.setEnabled(nextValue)
            settings.launchAtLogin = nextValue
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "자동실행 설정을 변경하지 못했습니다"
            alert.runModal()
        }
        refreshMenu()
    }

    @objc private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(permissionSettingsPane)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openAccessibilitySettings() {
        permissionSettingsPane = "Privacy_Accessibility"
        openPrivacySettings()
    }

    @objc private func openInputMonitoringSettings() {
        permissionSettingsPane = "Privacy_ListenEvent"
        openPrivacySettings()
    }

    @objc private func quit() {
        engine.stop()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
