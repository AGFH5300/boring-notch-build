//
//  boringNotchApp.swift
//  boringNotchApp
//
//  Created by Harsh Vardhan  Goswami  on 02/08/24.
//

import AVFoundation
import Combine
import Defaults
import KeyboardShortcuts
import Sparkle
import SwiftUI

@main
struct DynamicNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Default(.menubarIcon) var showMenuBarIcon
    @Environment(\.openWindow) var openWindow

    let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

        // Initialize the settings window controller with the updater controller
        SettingsWindowController.shared.setUpdaterController(updaterController)
    }

    var body: some Scene {
        MenuBarExtra("boring.notch", systemImage: "sparkle", isInserted: $showMenuBarIcon) {
            Button("Settings") {
                DispatchQueue.main.async {
                    SettingsWindowController.shared.showWindow()
                }
            }
            .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
            CheckForUpdatesView(updater: updaterController.updater)
            Divider()
            Button("Restart Boring Notch") {
                ApplicationRelauncher.restart()
            }
            Button("Quit", role: .destructive) {
                NSApplication.shared.terminate(self)
            }
            .keyboardShortcut(KeyEquivalent("Q"), modifiers: .command)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var windows: [String: NSWindow] = [:] // UUID -> NSWindow
    var viewModels: [String: BoringViewModel] = [:] // UUID -> BoringViewModel
    var window: NSWindow?
    let vm: BoringViewModel = .init()
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    var quickShareService = QuickShareService.shared
    var whatsNewWindow: NSWindow?
    var timer: Timer?
    var closeNotchTask: Task<Void, Never>?
    private var previousScreens: [NSScreen]?
    private var onboardingWindowController: NSWindowController?
    private var screenLockedObserver: Any?
    private var screenUnlockedObserver: Any?
    private var isScreenLocked: Bool = false
    private var windowScreenDidChangeObserver: Any?
    private var fullscreenVisibilityCancellable: AnyCancellable?
    private var fullscreenStatusSnapshot: [String: Bool] = [:]
    private var fullscreenBehaviorEnabled: Bool = false
    private var fullscreenRevealScreens: Set<String> = []
    private var fullscreenPointerTimer: Timer?
    private var fullscreenHideWorkItems: [String: DispatchWorkItem] = [:]
    private var fullscreenRevealHideWorkItems: [String: DispatchWorkItem] = [:]
    private var dragDetectors: [String: DragDetector] = [:] // UUID -> DragDetector

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        if let observer = screenLockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenLockedObserver = nil
        }
        if let observer = screenUnlockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenUnlockedObserver = nil
        }
        MusicManager.shared.destroy()
        fullscreenPointerTimer?.invalidate()
        fullscreenPointerTimer = nil
        fullscreenHideWorkItems.values.forEach { $0.cancel() }
        fullscreenRevealHideWorkItems.values.forEach { $0.cancel() }
        fullscreenHideWorkItems.removeAll()
        fullscreenRevealHideWorkItems.removeAll()
        cleanupDragDetectors()
        cleanupWindows()
        XPCHelperClient.shared.stopMonitoringAccessibilityAuthorization()
    }

    @MainActor
    func onScreenLocked(_ notification: Notification) {
        isScreenLocked = true
        if !Defaults[.showOnLockScreen] {
            cleanupWindows()
        } else {
            enableSkyLightOnAllWindows()
        }
    }

    @MainActor
    func onScreenUnlocked(_ notification: Notification) {
        isScreenLocked = false
        if !Defaults[.showOnLockScreen] {
            adjustWindowPosition(changeAlpha: true)
        } else {
            disableSkyLightOnAllWindows()
        }
    }
    
    @MainActor
    private func enableSkyLightOnAllWindows() {
        if Defaults[.showOnAllDisplays] {
            windows.values.forEach { window in
                if let skyWindow = window as? BoringNotchSkyLightWindow {
                    skyWindow.enableSkyLight()
                }
            }
        } else {
            if let skyWindow = window as? BoringNotchSkyLightWindow {
                skyWindow.enableSkyLight()
            }
        }
    }
    
    @MainActor
    private func disableSkyLightOnAllWindows() {
        // Delay disabling SkyLight to avoid flicker during unlock transition
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            await MainActor.run {
                if Defaults[.showOnAllDisplays] {
                    self.windows.values.forEach { window in
                        if let skyWindow = window as? BoringNotchSkyLightWindow {
                            skyWindow.disableSkyLight()
                        }
                    }
                } else {
                    if let skyWindow = self.window as? BoringNotchSkyLightWindow {
                        skyWindow.disableSkyLight()
                    }
                }
            }
        }
    }

    private func cleanupWindows(shouldInvert: Bool = false) {
        let shouldCleanupMulti = shouldInvert ? !Defaults[.showOnAllDisplays] : Defaults[.showOnAllDisplays]
        
        if shouldCleanupMulti {
            windows.values.forEach { window in
                window.close()
                NotchSpaceManager.shared.notchSpace.windows.remove(window)
            }
            windows.removeAll()
            viewModels.removeAll()
        } else if let window = window {
            window.close()
            NotchSpaceManager.shared.notchSpace.windows.remove(window)
            if let obs = windowScreenDidChangeObserver {
                NotificationCenter.default.removeObserver(obs)
                windowScreenDidChangeObserver = nil
            }
            self.window = nil
        }
    }

    private func cleanupDragDetectors() {
        dragDetectors.values.forEach { detector in
            detector.stopMonitoring()
        }
        dragDetectors.removeAll()
    }

    @MainActor
    private func fullscreenTarget(for screenUUID: String) -> (NSWindow, BoringViewModel)? {
        if Defaults[.showOnAllDisplays] {
            guard let notchWindow = windows[screenUUID],
                  let viewModel = viewModels[screenUUID]
            else { return nil }
            return (notchWindow, viewModel)
        }

        let uuid = vm.screenUUID ?? coordinator.selectedScreenUUID
        guard uuid == screenUUID, let notchWindow = window else { return nil }
        return (notchWindow, vm)
    }

    private func distance(_ point: NSPoint, to frame: NSRect) -> CGFloat {
        let dx = max(frame.minX - point.x, max(0, point.x - frame.maxX))
        let dy = max(frame.minY - point.y, max(0, point.y - frame.maxY))
        return hypot(dx, dy)
    }

    private func screenNearestPointer(_ point: NSPoint) -> NSScreen? {
        // Do NOT use frame.contains(point) here. At the literal top edge the
        // cursor may equal frame.maxY, which is outside CGRect's half-open max
        // boundary. That was the reveal bug in v5/v6/v8.
        guard let screen = NSScreen.screens.min(by: {
            distance(point, to: $0.frame) < distance(point, to: $1.frame)
        }) else { return nil }

        return distance(point, to: screen.frame) <= 4 ? screen : nil
    }

    @MainActor
    private func setFullscreenSuppressed(_ suppressed: Bool, on screenUUID: String, animated: Bool) {
        guard let (notchWindow, viewModel) = fullscreenTarget(for: screenUUID) else { return }

        // If the visual state is already correct, do not repeatedly force the
        // window's mouse routing. A revealed fullscreen notch may intentionally
        // be click-through outside its visible collapsed geometry.
        if viewModel.fullscreenSuppressed == suppressed {
            if suppressed && !notchWindow.ignoresMouseEvents {
                notchWindow.ignoresMouseEvents = true
            }
            return
        }

        if suppressed {
            // A hidden fullscreen notch must never block the app underneath.
            notchWindow.ignoresMouseEvents = true
        } else if !notchWindow.isVisible {
            notchWindow.orderFrontRegardless()
        }

        if animated {
            withAnimation(.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)) {
                viewModel.fullscreenSuppressed = suppressed
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                viewModel.fullscreenSuppressed = suppressed
            }
        }

        // Revealing changes the visual state only. Mouse routing is based on
        // the actual visible/interactable notch geometry.
        if !suppressed {
            updateMousePassthrough(mouse: NSEvent.mouseLocation)
        }

        print("[BN-v9] \(suppressed ? "SUPPRESS" : "REVEAL") screen=\(screenUUID) animated=\(animated)")
    }

    @MainActor
    private func hideFullscreenNotch(on screenUUID: String) {
        guard fullscreenBehaviorEnabled,
              (fullscreenStatusSnapshot[screenUUID] ?? false),
              !fullscreenRevealScreens.contains(screenUUID),
              let (_, viewModel) = fullscreenTarget(for: screenUUID)
        else { return }

        fullscreenHideWorkItems[screenUUID]?.cancel()
        fullscreenHideWorkItems.removeValue(forKey: screenUUID)

        if viewModel.notchState == .open {
            // First use Boring Notch's normal open -> closed animation.
            viewModel.close(force: true)

            let item = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.fullscreenHideWorkItems.removeValue(forKey: screenUUID)
                    guard self.fullscreenBehaviorEnabled,
                          (self.fullscreenStatusSnapshot[screenUUID] ?? false),
                          !self.fullscreenRevealScreens.contains(screenUUID)
                    else { return }
                    self.setFullscreenSuppressed(true, on: screenUUID, animated: true)
                }
            }
            fullscreenHideWorkItems[screenUUID] = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.38, execute: item)
        } else {
            setFullscreenSuppressed(true, on: screenUUID, animated: true)
        }
    }

    @MainActor
    private func revealFullscreenNotch(on screenUUID: String, mouse: NSPoint) {
        guard fullscreenBehaviorEnabled,
              (fullscreenStatusSnapshot[screenUUID] ?? false)
        else { return }

        let wasRevealed = fullscreenRevealScreens.contains(screenUUID)
        fullscreenRevealScreens.insert(screenUUID)
        fullscreenHideWorkItems[screenUUID]?.cancel()
        fullscreenHideWorkItems.removeValue(forKey: screenUUID)
        fullscreenRevealHideWorkItems[screenUUID]?.cancel()
        fullscreenRevealHideWorkItems.removeValue(forKey: screenUUID)

        setFullscreenSuppressed(false, on: screenUUID, animated: true)
        updateMousePassthrough(mouse: mouse)

        if !wasRevealed {
            print("[BN-v9] TOP EDGE screen=\(screenUUID) mouse=(\(Int(mouse.x)),\(Int(mouse.y)))")
        }
    }

    @MainActor
    private func scheduleFullscreenRevealHide(on screenUUID: String) {
        guard fullscreenRevealHideWorkItems[screenUUID] == nil else { return }

        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.fullscreenRevealHideWorkItems.removeValue(forKey: screenUUID)
                guard let (_, viewModel) = self.fullscreenTarget(for: screenUUID) else { return }

                let mouse = NSEvent.mouseLocation
                let screen = NSScreen.screen(withUUID: screenUUID)
                let distanceFromTop = screen.map { abs($0.frame.maxY - mouse.y) } ?? .greatestFiniteMagnitude
                let withinHorizontalBounds = screen.map {
                    mouse.x >= $0.frame.minX - 1 && mouse.x <= $0.frame.maxX + 1
                } ?? false

                if (withinHorizontalBounds && distanceFromTop <= 110)
                    || viewModel.fullscreenInteractionActive
                    || viewModel.notchState == .open
                    || viewModel.isMouseHovering(position: mouse)
                {
                    return
                }

                self.fullscreenRevealScreens.remove(screenUUID)
                self.hideFullscreenNotch(on: screenUUID)
            }
        }

        fullscreenRevealHideWorkItems[screenUUID] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42, execute: item)
    }

    @MainActor
    private func updateMousePassthrough(mouse: NSPoint) {
        func update(window notchWindow: NSWindow, viewModel: BoringViewModel, screenUUID: String) {
            let screenIsFullscreen = fullscreenBehaviorEnabled
                && (fullscreenStatusSnapshot[screenUUID] ?? false)

            // While visually suppressed in fullscreen, the whole panel is
            // click-through. After reveal, continue below so only real visible
            // notch content captures the pointer and the menu bar remains usable.
            if screenIsFullscreen && viewModel.fullscreenSuppressed {
                if !notchWindow.ignoresMouseEvents {
                    notchWindow.ignoresMouseEvents = true
                }
                return
            }

            // The NSPanel always retains the full expanded footprint. Make that
            // entire footprint interactive only when the UI really expands or
            // another interactive live activity is using it. In the collapsed
            // state, only the actual visible notch accepts pointer events.
            let expandedInteractionActive = viewModel.notchState == .open
                || coordinator.expandingView.show
                || coordinator.sneakPeek.show
                || viewModel.isBatteryPopoverActive
                || viewModel.isCameraExpanded
                || SharingStateManager.shared.preventNotchClose

            let shouldAcceptMouse = expandedInteractionActive
                || viewModel.isMouseHovering(position: mouse)

            let shouldIgnore = !shouldAcceptMouse
            if notchWindow.ignoresMouseEvents != shouldIgnore {
                notchWindow.ignoresMouseEvents = shouldIgnore
            }
        }

        if Defaults[.showOnAllDisplays] {
            for (uuid, notchWindow) in windows {
                guard let viewModel = viewModels[uuid] else { continue }
                update(window: notchWindow, viewModel: viewModel, screenUUID: uuid)
            }
        } else if let notchWindow = window {
            let uuid = vm.screenUUID ?? coordinator.selectedScreenUUID
            update(window: notchWindow, viewModel: vm, screenUUID: uuid)
        }
    }

    @MainActor
    private func handleFullscreenPointerTick() {
        let mouse = NSEvent.mouseLocation

        // Reuse the existing lightweight in-process pointer watcher. This is
        // not shell polling and adds no second timer.
        updateMousePassthrough(mouse: mouse)

        guard fullscreenBehaviorEnabled else { return }
        guard let pointerScreen = screenNearestPointer(mouse),
              let uuid = pointerScreen.displayUUID,
              (fullscreenStatusSnapshot[uuid] ?? false)
        else {
            return
        }

        let distanceFromTop = abs(pointerScreen.frame.maxY - mouse.y)
        let withinHorizontalBounds = mouse.x >= pointerScreen.frame.minX - 1
            && mouse.x <= pointerScreen.frame.maxX + 1

        if withinHorizontalBounds && distanceFromTop <= 12 {
            revealFullscreenNotch(on: uuid, mouse: mouse)
            return
        }

        guard fullscreenRevealScreens.contains(uuid) else { return }
        let viewModel = fullscreenTarget(for: uuid)?.1
        let keepVisible = (withinHorizontalBounds && distanceFromTop <= 110)
            || (viewModel?.fullscreenInteractionActive ?? false)
            || (viewModel?.notchState == .open)
            || (viewModel?.isMouseHovering(position: mouse) ?? false)

        if keepVisible {
            fullscreenRevealHideWorkItems[uuid]?.cancel()
            fullscreenRevealHideWorkItems.removeValue(forKey: uuid)
        } else {
            scheduleFullscreenRevealHide(on: uuid)
        }
    }

    @MainActor
    private func setupFullscreenPointerWatcher() {
        fullscreenPointerTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.handleFullscreenPointerTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fullscreenPointerTimer = timer
    }

    @MainActor
    private func applyFullscreenState(previous: [String: Bool]? = nil) {
        for screen in NSScreen.screens {
            guard let uuid = screen.displayUUID else { continue }
            let isFullscreen = fullscreenBehaviorEnabled
                && (fullscreenStatusSnapshot[uuid] ?? false)
            let wasFullscreen = previous?[uuid] ?? false

            if isFullscreen {
                if !wasFullscreen {
                    print("[BN-v9] FULLSCREEN ENTER screen=\(uuid)")
                }
                if fullscreenRevealScreens.contains(uuid) {
                    setFullscreenSuppressed(false, on: uuid, animated: true)
                } else {
                    hideFullscreenNotch(on: uuid)
                }
            } else {
                if wasFullscreen {
                    print("[BN-v9] FULLSCREEN EXIT screen=\(uuid)")
                }
                fullscreenRevealScreens.remove(uuid)
                fullscreenHideWorkItems[uuid]?.cancel()
                fullscreenRevealHideWorkItems[uuid]?.cancel()
                fullscreenHideWorkItems.removeValue(forKey: uuid)
                fullscreenRevealHideWorkItems.removeValue(forKey: uuid)

                // Restore without an animation on Space exit. This prevents the
                // misleading "animates in on the desktop" behavior from v7/v8.
                setFullscreenSuppressed(false, on: uuid, animated: false)
                updateMousePassthrough(mouse: NSEvent.mouseLocation)
            }
        }
    }

    private func setupDragDetectors() {
        cleanupDragDetectors()

        guard Defaults[.expandedDragDetection] else { return }

        if Defaults[.showOnAllDisplays] {
            for screen in NSScreen.screens {
                setupDragDetectorForScreen(screen)
            }
        } else {
            let preferredScreen: NSScreen? = window?.screen
                ?? NSScreen.screen(withUUID: coordinator.selectedScreenUUID)
                ?? NSScreen.main

            if let screen = preferredScreen {
                setupDragDetectorForScreen(screen)
            }
        }
    }

    private func setupDragDetectorForScreen(_ screen: NSScreen) {
        guard let uuid = screen.displayUUID else { return }
        
        let screenFrame = screen.frame
        let notchHeight = openNotchSize.height
        let notchWidth = openNotchSize.width
        
        // Create notch region at the top-center of the screen where an open notch would occupy
        let notchRegion = CGRect(
            x: screenFrame.midX - notchWidth / 2,
            y: screenFrame.maxY - notchHeight,
            width: notchWidth,
            height: notchHeight
        )
        
        let detector = DragDetector(notchRegion: notchRegion)
        
        detector.onDragEntersNotchRegion = { [weak self] in
            Task { @MainActor in
                self?.handleDragEntersNotchRegion(onScreen: screen)
            }
        }
        
        dragDetectors[uuid] = detector
        detector.startMonitoring()
    }

    private func handleDragEntersNotchRegion(onScreen screen: NSScreen) {
        guard let uuid = screen.displayUUID else { return }
        
        if Defaults[.showOnAllDisplays], let viewModel = viewModels[uuid] {
            viewModel.open()
            coordinator.currentView = .shelf
        } else if !Defaults[.showOnAllDisplays], let windowScreen = window?.screen, screen == windowScreen {
            vm.open()
            coordinator.currentView = .shelf
        }
    }

    private func createBoringNotchWindow(for screen: NSScreen, with viewModel: BoringViewModel) -> NSWindow {
        let rect = NSRect(x: 0, y: 0, width: windowSize.width, height: windowSize.height)
        let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow]
        
        let window = BoringNotchSkyLightWindow(contentRect: rect, styleMask: styleMask, backing: .buffered, defer: false)
        
        // Enable SkyLight only when screen is locked
        if isScreenLocked {
            window.enableSkyLight()
        } else {
            window.disableSkyLight()
        }

        window.contentView = NSHostingView(
            rootView: ContentView()
                .environmentObject(viewModel)
        )

        window.orderFrontRegardless()
        NotchSpaceManager.shared.notchSpace.windows.insert(window)

        // Observe when the window's screen changes so we can update drag detectors
        windowScreenDidChangeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.setupDragDetectors()
                }
        }
        return window
    }

    @MainActor
    private func positionWindow(_ window: NSWindow, on screen: NSScreen, changeAlpha: Bool = false) {
        if changeAlpha {
            window.alphaValue = 0
        }

        let screenFrame = screen.frame
        window.setFrameOrigin(
            NSPoint(
                x: screenFrame.origin.x + (screenFrame.width / 2) - window.frame.width / 2,
                y: screenFrame.origin.y + screenFrame.height - window.frame.height
            ))
        window.alphaValue = 1
    }

    func applicationDidFinishLaunching(_ notification: Notification) {

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            forName: Notification.Name.selectedScreenChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.adjustWindowPosition(changeAlpha: true)
                self?.setupDragDetectors()
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.notchHeightChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.adjustWindowPosition()
                self?.setupDragDetectors()
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.automaticallySwitchDisplayChanged, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self = self, let window = self.window else { return }
            Task { @MainActor in
                window.alphaValue = self.coordinator.selectedScreenUUID == self.coordinator.preferredScreenUUID ? 1 : 0
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.showOnAllDisplaysChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.cleanupWindows(shouldInvert: true)
                self.adjustWindowPosition(changeAlpha: true)
                self.setupDragDetectors()
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.expandedDragDetectionChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.setupDragDetectors()
            }
        }

        // Use closure-based observers for DistributedNotificationCenter and keep tokens for removal
        screenLockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: "com.apple.screenIsLocked"),
            object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    self?.onScreenLocked(notification)
                }
        }

        screenUnlockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: "com.apple.screenIsUnlocked"),
            object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    self?.onScreenUnlocked(notification)
                }
        }

        KeyboardShortcuts.onKeyDown(for: .toggleSneakPeek) { [weak self] in
            guard let self = self else { return }
            if Defaults[.sneakPeekStyles] == .inline {
                let newStatus = !self.coordinator.expandingView.show
                self.coordinator.toggleExpandingView(status: newStatus, type: .music)
            } else {
                self.coordinator.toggleSneakPeek(
                    status: !self.coordinator.sneakPeek.show,
                    type: .music,
                    duration: 3.0
                )
            }
        }

        KeyboardShortcuts.onKeyDown(for: .toggleNotchOpen) { [weak self] in
            Task { [weak self] in
                guard let self = self else { return }

                let mouseLocation = NSEvent.mouseLocation

                var viewModel = self.vm

                if Defaults[.showOnAllDisplays] {
                    for screen in NSScreen.screens {
                        if screen.frame.contains(mouseLocation) {
                            if let uuid = screen.displayUUID, let screenViewModel = self.viewModels[uuid] {
                                viewModel = screenViewModel
                                break
                            }
                        }
                    }
                }

                self.closeNotchTask?.cancel()
                self.closeNotchTask = nil

                switch viewModel.notchState {
                case .closed:
                    await MainActor.run {
                        viewModel.open()
                    }

                    let task = Task { [weak viewModel] in
                        do {
                            try await Task.sleep(for: .seconds(3))
                            await MainActor.run {
                                viewModel?.close()
                            }
                        } catch { }
                    }
                    self.closeNotchTask = task
                case .open:
                    await MainActor.run {
                        viewModel.close()
                    }
                }
            }
        }

        if !Defaults[.showOnAllDisplays] {
            let viewModel = self.vm
            let window = createBoringNotchWindow(
                for: NSScreen.main ?? NSScreen.screens.first!, with: viewModel)
            self.window = window
            adjustWindowPosition(changeAlpha: true)
        } else {
            adjustWindowPosition(changeAlpha: true)
        }

        let fullscreenEnabledPublisher = Defaults
            .publisher(.hideNotchOption)
            .map(\.newValue)
            .map { $0 != .never }
            .removeDuplicates()

        fullscreenVisibilityCancellable = Publishers.CombineLatest(
            FullscreenMediaDetector.shared.$fullscreenStatus.removeDuplicates(),
            fullscreenEnabledPublisher
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] fullscreenStatus, enabled in
            guard let self else { return }
            Task { @MainActor in
                let previous = self.fullscreenStatusSnapshot
                self.fullscreenStatusSnapshot = fullscreenStatus
                self.fullscreenBehaviorEnabled = enabled
                if !enabled {
                    self.fullscreenRevealScreens.removeAll()
                }
                self.applyFullscreenState(previous: previous)
            }
        }

        fullscreenStatusSnapshot = FullscreenMediaDetector.shared.fullscreenStatus
        fullscreenBehaviorEnabled = Defaults[.hideNotchOption] != .never
        setupFullscreenPointerWatcher()
        applyFullscreenState()

        setupDragDetectors()

        if coordinator.firstLaunch {
            DispatchQueue.main.async {
                self.showOnboardingWindow()
            }
            playWelcomeSound()
        } else if MusicManager.shared.isNowPlayingDeprecated
            && Defaults[.mediaController] == .nowPlaying
        {
            DispatchQueue.main.async {
                self.showOnboardingWindow(step: .musicPermission)
            }
        }

        previousScreens = NSScreen.screens
    }

    func playWelcomeSound() {
        let audioPlayer = AudioPlayer()
        audioPlayer.play(fileName: "boring", fileExtension: "m4a")
    }

    func deviceHasNotch() -> Bool {
        if #available(macOS 12.0, *) {
            for screen in NSScreen.screens {
                if screen.safeAreaInsets.top > 0 {
                    return true
                }
            }
        }
        return false
    }

    @objc func screenConfigurationDidChange() {
        let currentScreens = NSScreen.screens

        let screensChanged =
            currentScreens.count != previousScreens?.count
            || Set(currentScreens.compactMap { $0.displayUUID })
                != Set(previousScreens?.compactMap { $0.displayUUID } ?? [])
            || Set(currentScreens.map { $0.frame }) != Set(previousScreens?.map { $0.frame } ?? [])

        previousScreens = currentScreens

        if screensChanged {
            DispatchQueue.main.async { [weak self] in
                self?.cleanupWindows()
                self?.adjustWindowPosition()
                self?.setupDragDetectors()
            }
        }
    }

    @objc func adjustWindowPosition(changeAlpha: Bool = false) {
        if Defaults[.showOnAllDisplays] {
            let currentScreenUUIDs = Set(NSScreen.screens.compactMap { $0.displayUUID })

            // Remove windows for screens that no longer exist
            for uuid in windows.keys where !currentScreenUUIDs.contains(uuid) {
                if let window = windows[uuid] {
                    window.close()
                    NotchSpaceManager.shared.notchSpace.windows.remove(window)
                    windows.removeValue(forKey: uuid)
                    viewModels.removeValue(forKey: uuid)
                }
            }

            // Create or update windows for all screens
            for screen in NSScreen.screens {
                guard let uuid = screen.displayUUID else { continue }
                
                if windows[uuid] == nil {
                    let viewModel = BoringViewModel(screenUUID: uuid)
                    let window = createBoringNotchWindow(for: screen, with: viewModel)

                    windows[uuid] = window
                    viewModels[uuid] = viewModel
                }

                if let window = windows[uuid], let viewModel = viewModels[uuid] {
                    positionWindow(window, on: screen, changeAlpha: changeAlpha)

                    if viewModel.notchState == .closed {
                        viewModel.close()
                    }
                }
            }
        } else {
            let selectedScreen: NSScreen

            if let preferredScreen = NSScreen.screen(withUUID: coordinator.preferredScreenUUID ?? "") {
                coordinator.selectedScreenUUID = coordinator.preferredScreenUUID ?? ""
                selectedScreen = preferredScreen
            } else if Defaults[.automaticallySwitchDisplay], let mainScreen = NSScreen.main,
                      let mainUUID = mainScreen.displayUUID {
                coordinator.selectedScreenUUID = mainUUID
                selectedScreen = mainScreen
            } else {
                if let window = window {
                    window.alphaValue = 0
                }
                return
            }

            vm.screenUUID = selectedScreen.displayUUID
            vm.notchSize = getClosedNotchSize(screenUUID: selectedScreen.displayUUID)

            if window == nil {
                window = createBoringNotchWindow(for: selectedScreen, with: vm)
            }

            if let window = window {
                positionWindow(window, on: selectedScreen, changeAlpha: changeAlpha)

                if vm.notchState == .closed {
                    vm.close()
                }
            }
        }
    }

    @objc func togglePopover(_ sender: Any?) {
        if window?.isVisible == true {
            window?.orderOut(nil)
        } else {
            window?.orderFrontRegardless()
        }
    }

    @objc func showMenu() {
        statusItem?.menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc func quitAction() {
        NSApplication.shared.terminate(self)
    }

    private func showOnboardingWindow(step: OnboardingStep = .welcome) {
        if onboardingWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                styleMask: [.titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "Onboarding"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.contentView = NSHostingView(
                rootView: OnboardingView(
                    step: step,
                    onFinish: {
                        window.orderOut(nil)
//                        NSApp.setActivationPolicy(.accessory)
                        window.close()
                        NSApp.deactivate()
                    },
                    onOpenSettings: {
                        window.close()
                        SettingsWindowController.shared.showWindow()
                    }
                ))
            window.isRestorable = false
            window.identifier = NSUserInterfaceItemIdentifier("OnboardingWindow")

            onboardingWindowController = NSWindowController(window: window)
        }

//        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindowController?.window?.makeKeyAndOrderFront(nil)
        onboardingWindowController?.window?.orderFrontRegardless()
    }
}

extension Notification.Name {
    static let selectedScreenChanged = Notification.Name("SelectedScreenChanged")
    static let notchHeightChanged = Notification.Name("NotchHeightChanged")
    static let showOnAllDisplaysChanged = Notification.Name("showOnAllDisplaysChanged")
    static let automaticallySwitchDisplayChanged = Notification.Name("automaticallySwitchDisplayChanged")
    static let expandedDragDetectionChanged = Notification.Name("expandedDragDetectionChanged")
}

extension CGRect: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(origin.x)
        hasher.combine(origin.y)
        hasher.combine(size.width)
        hasher.combine(size.height)
    }

    public static func == (lhs: CGRect, rhs: CGRect) -> Bool {
        return lhs.origin == rhs.origin && lhs.size == rhs.size
    }
}
