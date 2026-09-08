from pathlib import Path

path = Path("boringNotch/boringNotchApp.swift")
text = path.read_text()

# v11 made the transparent part of the fixed-size panel click-through in normal
# Spaces, but deliberately returned early while a screen was fullscreen. During
# the v9 top-edge reveal, setFullscreenSuppressed(false) also forced the entire
# 640x210 panel interactive. That means the invisible expanded-notch footprint
# can sit over the temporarily revealed macOS menu bar and steal its clicks.
#
# v12 uses the same pointer-aware hit routing in BOTH normal Spaces and a
# revealed fullscreen Space. A suppressed fullscreen notch remains completely
# click-through; a revealed-but-collapsed notch only accepts the mouse over the
# actual visible collapsed notch. Once the notch genuinely expands (or another
# interactive live activity is active), the whole panel remains interactive.

old_set = '''    @MainActor
    private func setFullscreenSuppressed(_ suppressed: Bool, on screenUUID: String, animated: Bool) {
        guard let (notchWindow, viewModel) = fullscreenTarget(for: screenUUID) else { return }
        guard viewModel.fullscreenSuppressed != suppressed || notchWindow.ignoresMouseEvents != suppressed else { return }

        if suppressed {
            // Make the invisible overlay click-through immediately while the
            // visual spring continues to finish.
            notchWindow.ignoresMouseEvents = true
        } else {
            notchWindow.ignoresMouseEvents = false
            if !notchWindow.isVisible {
                notchWindow.orderFrontRegardless()
            }
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

        print("[BN-v9] \\(suppressed ? \"SUPPRESS\" : \"REVEAL\") screen=\\(screenUUID) animated=\\(animated)")
    }
'''

new_set = '''    @MainActor
    private func setFullscreenSuppressed(_ suppressed: Bool, on screenUUID: String, animated: Bool) {
        guard let (notchWindow, viewModel) = fullscreenTarget(for: screenUUID) else { return }

        // If the visual state is already correct, do not repeatedly force the
        // window's mouse routing. In particular, a revealed fullscreen notch
        // may intentionally be click-through outside its visible collapsed
        // geometry.
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

        // A reveal changes only the visual suppression state. Mouse routing is
        // determined from the actual visible/interactable notch geometry.
        if !suppressed {
            updateMousePassthrough(mouse: NSEvent.mouseLocation)
        }

        print("[BN-v9] \\(suppressed ? \"SUPPRESS\" : \"REVEAL\") screen=\\(screenUUID) animated=\\(animated)")
    }
'''

if old_set not in text:
    raise SystemExit("v12 setFullscreenSuppressed anchor not found")
text = text.replace(old_set, new_set, 1)

old_router = '''    @MainActor
    private func updateNormalMousePassthrough(mouse: NSPoint) {
        func update(window notchWindow: NSWindow, viewModel: BoringViewModel, screenUUID: String) {
            // Fullscreen visibility owns mouse-event routing while its screen is
            // suppressed/revealed. Do not fight that state here.
            let fullscreenOwnsMouseRouting = fullscreenBehaviorEnabled
                && (fullscreenStatusSnapshot[screenUUID] ?? false)
            if fullscreenOwnsMouseRouting { return }

            // The AppKit panel is always the full open-notch size (640x210),
            // even while SwiftUI draws only the small collapsed notch. A clear
            // NSPanel still receives mouse events, so its invisible area can
            // otherwise block Finder/Desktop and the app underneath.
            //
            // Keep the whole panel interactive only while something genuinely
            // uses the expanded footprint. In the normal closed state, enable
            // mouse handling only when the pointer is over the actual collapsed
            // notch; everywhere else becomes click-through.
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
'''

new_router = '''    @MainActor
    private func updateMousePassthrough(mouse: NSPoint) {
        func update(window notchWindow: NSWindow, viewModel: BoringViewModel, screenUUID: String) {
            let screenIsFullscreen = fullscreenBehaviorEnabled
                && (fullscreenStatusSnapshot[screenUUID] ?? false)

            // A visually suppressed fullscreen notch must be completely
            // click-through. Once revealed, fall through to the same geometry-
            // aware routing used in normal Spaces so the menu bar under the
            // transparent panel remains clickable.
            if screenIsFullscreen && viewModel.fullscreenSuppressed {
                if !notchWindow.ignoresMouseEvents {
                    notchWindow.ignoresMouseEvents = true
                }
                return
            }

            // The AppKit panel is always the full open-notch size (640x210),
            // even while SwiftUI draws only the small collapsed notch. Keep the
            // whole panel interactive only when something genuinely occupies
            // that footprint. Otherwise only the visible collapsed notch should
            // capture mouse events; the transparent remainder clicks through.
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
'''

if old_router not in text:
    raise SystemExit("v12 v11 router anchor not found")
text = text.replace(old_router, new_router, 1)

# Update all v11 call sites to the unified normal/fullscreen router.
text = text.replace("updateNormalMousePassthrough(mouse:", "updateMousePassthrough(mouse:")

# After a top-edge reveal, recompute routing immediately using the current
# pointer position rather than waiting for the next 30 Hz watcher tick.
old_reveal = '''        setFullscreenSuppressed(false, on: screenUUID, animated: true)

        if !wasRevealed {
'''
new_reveal = '''        setFullscreenSuppressed(false, on: screenUUID, animated: true)
        updateMousePassthrough(mouse: mouse)

        if !wasRevealed {
'''
if old_reveal not in text:
    raise SystemExit("v12 reveal anchor not found")
text = text.replace(old_reveal, new_reveal, 1)

path.write_text(text)

updated = path.read_text()
assert "private func updateMousePassthrough(mouse: NSPoint)" in updated
assert "updateNormalMousePassthrough" not in updated
assert "screenIsFullscreen && viewModel.fullscreenSuppressed" in updated
assert "updateMousePassthrough(mouse: mouse)" in updated
assert "notchWindow.ignoresMouseEvents = false" not in updated[updated.find("private func setFullscreenSuppressed"):updated.find("private func hideFullscreenNotch")]
print("Applied v12 fullscreen revealed click-through patch")
