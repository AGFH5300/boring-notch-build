from pathlib import Path

path = Path("boringNotch/boringNotchApp.swift")
text = path.read_text()

# v11 fixed click-through in normal Spaces. v12 extends the same geometry-aware
# routing to a fullscreen Space after the top-edge reveal, so the transparent
# 640x210 panel cannot steal clicks from the temporarily visible macOS menu bar.

# Replace the generated fullscreen suppression method by boundaries rather than
# matching its debug-print spelling, which is adjusted by fix-v9-generated-swift.py.
set_start = text.find("    @MainActor\n    private func setFullscreenSuppressed(")
set_end = text.find("    @MainActor\n    private func hideFullscreenNotch(", set_start)
if set_start == -1 or set_end == -1:
    raise SystemExit("v12 setFullscreenSuppressed boundaries not found")

new_set = r'''    @MainActor
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

'''
text = text[:set_start] + new_set + text[set_end:]

# Replace v11's normal-only router with a unified normal + fullscreen router.
router_start = text.find("    @MainActor\n    private func updateNormalMousePassthrough(")
router_end = text.find("    @MainActor\n    private func handleFullscreenPointerTick()", router_start)
if router_start == -1 or router_end == -1:
    raise SystemExit("v12 v11 mouse-router boundaries not found")

new_router = r'''    @MainActor
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

'''
text = text[:router_start] + new_router + text[router_end:]

# Rename the v11 call sites to the unified router.
text = text.replace("updateNormalMousePassthrough(mouse:", "updateMousePassthrough(mouse:")

# Recompute routing immediately after a top-edge reveal instead of waiting up to
# one 30 Hz timer tick.
reveal_anchor = '''        setFullscreenSuppressed(false, on: screenUUID, animated: true)\n\n        if !wasRevealed {\n'''
reveal_replacement = '''        setFullscreenSuppressed(false, on: screenUUID, animated: true)\n        updateMousePassthrough(mouse: mouse)\n\n        if !wasRevealed {\n'''
if reveal_anchor not in text:
    raise SystemExit("v12 reveal anchor not found")
text = text.replace(reveal_anchor, reveal_replacement, 1)

path.write_text(text)

updated = path.read_text()
assert "private func updateMousePassthrough(mouse: NSPoint)" in updated
assert "updateNormalMousePassthrough" not in updated
assert "screenIsFullscreen && viewModel.fullscreenSuppressed" in updated
assert "updateMousePassthrough(mouse: mouse)" in updated
set_slice = updated[updated.find("private func setFullscreenSuppressed"):updated.find("private func hideFullscreenNotch")]
assert "notchWindow.ignoresMouseEvents = false" not in set_slice
print("Applied v12 fullscreen revealed click-through patch")
