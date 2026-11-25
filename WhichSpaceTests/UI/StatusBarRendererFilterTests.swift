import AppKit
import Testing
@testable import WhichSpace

@MainActor
struct StatusBarRendererFilterTests {
    private let store: DefaultsStore
    private let testSuite: TestSuite
    private let stub: CGSStub

    init() {
        testSuite = TestSuiteFactory.createSuite()
        store = DefaultsStore(suite: testSuite.suite)
        stub = CGSStub()
    }

    @Test("label template resolves displayed number past a fullscreen space")
    func labelTemplate_usesDisplayedNumber() {
        stub.activeDisplayIdentifier = "Main"
        stub.displays = [
            CGSStub.makeDisplay(
                displayID: "Main",
                spaces: [
                    (id: 100, isFullscreen: false),
                    (id: 101, isFullscreen: true),
                    (id: 102, isFullscreen: false),
                ],
                activeSpaceID: 100
            ),
        ]
        store.showAllSpaces = true
        store.localSpaceNumbers = true
        // Labels are keyed by fullscreen-inclusive position (3), but the
        // displayed number for that space is its regular index (2)
        SpacePreferences.setLabel("S{#}", forSpace: 3, store: store)

        let appState = AppState(displaySpaceProvider: stub, skipObservers: true, store: store)
        let layout = appState.statusBarLayout()

        #expect(layout.slots.map(\.label) == ["1", "F", "S2"])
    }

    // MARK: - hideEmptySpaces

    @Test("hideEmptySpaces hides non-active empty spaces")
    func hideEmptySpaces_hidesNonActiveEmptySpaces() {
        stub.activeDisplayIdentifier = "Main"
        stub.displays = [
            CGSStub.makeDisplay(
                displayID: "Main",
                spaces: [
                    (id: 100, isFullscreen: false),
                    (id: 101, isFullscreen: false),
                    (id: 102, isFullscreen: false),
                ],
                activeSpaceID: 101
            ),
        ]
        // Only space 101 and 102 have windows
        stub.spacesWithWindowsSet = [101, 102]
        store.showAllSpaces = true
        store.hideEmptySpaces = true

        let appState = AppState(displaySpaceProvider: stub, skipObservers: true, store: store)
        let layout = appState.statusBarLayout()

        // Space 100 (index 1) is empty and not active => hidden
        // Space 101 (index 2) is active => shown
        // Space 102 (index 3) has windows => shown
        #expect(layout.slots.count == 2)
        #expect(layout.slots.map(\.label) == ["2", "3"])
    }

    @Test("Space changes refresh populated window data off the main thread")
    func spaceChange_refreshesPopulatedWindowDataInBackground() {
        stub.activeDisplayIdentifier = "Main"
        stub.displays = [
            CGSStub.makeDisplay(
                displayID: "Main",
                spaces: [
                    (id: 100, isFullscreen: false),
                    (id: 101, isFullscreen: false),
                ],
                activeSpaceID: 100
            ),
        ]
        stub.spacesWithWindowsSet = [100, 101]
        store.showAllSpaces = true
        store.hideEmptySpaces = true

        let appState = AppState(displaySpaceProvider: stub, skipObservers: true, store: store)
        _ = appState.statusBarLayout()
        #expect(stub.mainThreadSpacesWithWindowsCallCount == 1)

        stub.displays = [
            CGSStub.makeDisplay(
                displayID: "Main",
                spaces: [
                    (id: 100, isFullscreen: false),
                    (id: 101, isFullscreen: false),
                ],
                activeSpaceID: 101
            ),
        ]
        appState.forceSpaceUpdate()
        _ = appState.statusBarLayout()

        #expect(stub.mainThreadSpacesWithWindowsCallCount == 1)
    }

    @Test("window refreshes run one scan at a time")
    func windowRefreshes_runSingleFlight() async {
        stub.activeDisplayIdentifier = "Main"
        stub.displays = makeDisplays(activeSpaceID: 100)
        stub.spacesWithWindowsSet = [100, 101]
        store.showAllSpaces = true
        store.hideEmptySpaces = true

        let appState = AppState(displaySpaceProvider: stub, skipObservers: true, store: store)
        _ = appState.statusBarLayout()
        #expect(stub.spacesWithWindowsCallCount == 1)

        let blocker = DispatchSemaphore(value: 0)
        stub.spacesWithWindowsBlocker = blocker
        defer {
            blocker.signal()
            blocker.signal()
        }

        stub.displays = makeDisplays(activeSpaceID: 101)
        appState.forceSpaceUpdate()
        _ = appState.statusBarLayout()
        await waitForWindowScanCount(2)

        stub.displays = makeDisplays(activeSpaceID: 100)
        appState.forceSpaceUpdate()
        _ = appState.statusBarLayout()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(stub.spacesWithWindowsCallCount == 2)

        blocker.signal()
        await waitForWindowScanCount(3)
    }

    private func makeDisplays(activeSpaceID: Int) -> [NSDictionary] {
        [
            CGSStub.makeDisplay(
                displayID: "Main",
                spaces: [
                    (id: 100, isFullscreen: false),
                    (id: 101, isFullscreen: false),
                ],
                activeSpaceID: activeSpaceID
            ),
        ]
    }

    private func waitForWindowScanCount(_ expectedCount: Int) async {
        for _ in 0 ..< 100 where stub.spacesWithWindowsCallCount < expectedCount {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(stub.spacesWithWindowsCallCount == expectedCount)
    }

    // MARK: - Menu Bar App Icons

    @Test("the selected Space has a solid red background and white label", arguments: [false, true])
    func activeSpaceBackground_followsSelection(acrossDisplays: Bool) throws {
        stub.activeDisplayIdentifier = "Main"
        let otherDisplays = acrossDisplays ? [
            CGSStub.makeDisplay(
                displayID: "Other",
                spaces: [(id: 200, isFullscreen: false)],
                activeSpaceID: 200
            ),
        ] : []
        stub.displays = makeDisplays(activeSpaceID: 100) + otherDisplays
        stub.windowOwnerPIDsMap = [100: [11], 101: [22], 200: [33]]
        store.showAllSpaces = true
        store.showAllDisplays = acrossDisplays
        store.inactiveSpaceOpacity = 100
        store.spacePickerMaxAppIcons = 1
        store.spaceColors = [SpacePreferences.defaultStyleSpace: SpaceColors(foreground: .black, background: .blue)]
        let state = AppState(displaySpaceProvider: stub, skipObservers: true, store: store)
        state.renderer.appIconResolver = { _ in
            NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                NSColor.blue.setFill()
                rect.fill()
                return true
            }
        }

        func expectSelectedBackground() throws {
            let image = state.statusBarIcon
            #expect(!image.isTemplate)
            let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            let layout = state.statusBarLayout()
            #expect(abs(image.size.width - layout.totalWidth) < 0.01)
            for slot in layout.slots {
                let scale = Double(bitmap.pixelsWide) / image.size.width
                let start = Int(slot.startX * scale)
                let end = min(bitmap.pixelsWide, Int((slot.startX + slot.width) * scale))
                var redPixels = 0
                var whitePixels = 0
                var bluePixels = 0
                var maxAlpha = 0.0
                for x in start ..< end {
                    for y in 0 ..< bitmap.pixelsHigh {
                        let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                        maxAlpha = max(maxAlpha, Double(color.alphaComponent))
                        if color.redComponent > 0.6,
                           color.redComponent > color.greenComponent * 1.5,
                           color.redComponent > color.blueComponent * 1.5,
                           color.alphaComponent > 0.9
                        {
                            redPixels += 1
                        }
                        if color.redComponent > 0.9, color.greenComponent > 0.9,
                           color.blueComponent > 0.9, color.alphaComponent > 0.9
                        {
                            whitePixels += 1
                        }
                        if color.blueComponent > 0.6,
                           color.blueComponent > color.redComponent * 1.5,
                           color.blueComponent > color.greenComponent * 1.5,
                           color.alphaComponent > 0.9
                        {
                            bluePixels += 1
                        }
                    }
                }
                #expect(maxAlpha > 0.99)
                if slot.spaceID == state.currentSpaceID {
                    let inset = Int((acrossDisplays ? 2.0 : 0.5) * scale)
                    let selectionArea = (end - start - 2 * inset) * (bitmap.pixelsHigh - 2 * inset)
                    #expect(redPixels > selectionArea / 2, "The red fill must cover most of the selection box")
                    #expect(whitePixels > 5, "The selected label must remain legible on red")
                    #expect(bluePixels > 50, "Application icons must retain their original colors")
                } else {
                    #expect(redPixels == 0)
                }
            }
        }

        try expectSelectedBackground()
        stub.displays = makeDisplays(activeSpaceID: 101) + otherDisplays
        state.forceSpaceUpdate()
        try expectSelectedBackground()
    }

    @Test("visible fullscreen artwork cannot cover its selection border", arguments: [false, true])
    func fullscreenArtwork_keepsVisibleBorder(acrossDisplays: Bool) throws {
        stub.activeDisplayIdentifier = "Main"
        stub.displays = [
            CGSStub.makeDisplay(
                displayID: "Main",
                spaces: [
                    (id: 100, isFullscreen: false),
                    (id: 101, isFullscreen: true),
                    (id: 102, isFullscreen: true),
                ],
                activeSpaceID: 101
            ),
        ]
        if acrossDisplays {
            stub.displays.append(CGSStub.makeDisplay(
                displayID: "Other",
                spaces: [(id: 201, isFullscreen: true)],
                activeSpaceID: 201
            ))
        }
        stub.fullscreenOwnerPIDsMap = [101: 11, 102: 22, 201: 33]
        store.showAllSpaces = true
        store.showAllDisplays = acrossDisplays
        store.fullscreenIconStyle = .appIcon
        store.sizeScale = 150
        store.paddingScale = 0
        store.inactiveSpaceOpacity = 100
        let state = AppState(displaySpaceProvider: stub, skipObservers: true, store: store)
        state.renderer.fullscreenAppIconResolver = { _ in
            NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
                NSColor.blue.setFill()
                rect.fill()
                return true
            }
        }
        for focusedDisplay in acrossDisplays ? ["Main", "Other"] : ["Main"] {
            stub.activeDisplayIdentifier = focusedDisplay
            state.forceSpaceUpdate()
            let image = state.statusBarIcon
            let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            let layout = state.statusBarLayout()
            #expect(abs(image.size.width - layout.totalWidth) < 0.01)
            let scale = Double(bitmap.pixelsWide) / image.size.width
            for slot in layout.slots where slot.spaceID != 100 {
                let x = Int((slot.startX + slot.width / 2) * scale)
                let y = Int((acrossDisplays ? 3.0 : 1.5) * scale)
                let border = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let center = try #require(bitmap.colorAt(x: x, y: Int(Layout.statusItemHeight / 2 * scale))?.usingColorSpace(.deviceRGB))
                #expect(center.blueComponent > center.redComponent * 1.5)
                if slot.spaceID == state.currentSpaceID {
                    #expect(border.redComponent > border.greenComponent * 1.5)
                    #expect(border.redComponent > border.blueComponent * 1.5)
                } else if slot.spaceID == 201 || slot.spaceID == 101 {
                    #expect(border.redComponent > border.greenComponent + 0.1)
                    #expect(border.redComponent > border.blueComponent + 0.1)
                    #expect(border.greenComponent > 0.4)
                } else {
                    #expect(border.blueComponent > border.redComponent * 1.5)
                }
                #expect(layout.slot(at: slot.startX + slot.width / 2)?.spaceID == slot.spaceID)
            }
        }
    }

    @Test("app click targets follow filtered icons, display ordering, and padding", arguments: [false, true])
    func appIconClickTargets(acrossDisplays: Bool) throws {
        stub.activeDisplayIdentifier = "Main"
        stub.displays = makeDisplays(activeSpaceID: 100)
        if acrossDisplays {
            stub.displays.append(CGSStub.makeDisplay(
                displayID: "Other", spaces: [(id: 200, isFullscreen: false)], activeSpaceID: 200
            ))
        }
        stub.windowOwnerPIDsMap = [100: [11, 22, 33, 44], 101: [55], 200: [66, 77]]
        store.showAllSpaces = true
        store.showAllDisplays = acrossDisplays
        store.swapFirstDisplayGroups = acrossDisplays
        store.spacePickerMaxAppIcons = 2
        let state = AppState(displaySpaceProvider: stub, skipObservers: true, store: store)
        state.renderer.appIconResolver = { pid in
            pid == 22 ? nil : NSImage(size: NSSize(width: 16, height: 16))
        }
        let layout = state.statusBarLayout()
        let owners: [Int: [pid_t]] = [100: [11, 33], 101: [55], 200: [66, 77]]
        #expect(layout.slots.map(\.spaceID) == (acrossDisplays ? [200, 100, 101] : [100, 101]))
        for slot in layout.slots {
            #expect(slot.appIcons.map(\.ownerPID) == owners[slot.spaceID])
            #expect(slot.appPID(at: slot.startX) == nil)
            for icon in slot.appIcons {
                #expect(slot.appPID(at: slot.startX + icon.startX + icon.width / 2) == icon.ownerPID)
                #expect(slot.appPID(at: slot.startX + icon.startX + icon.width + 0.5) == nil)
            }
        }
        store.spacePickerMaxAppIcons = 0
        #expect(state.statusBarLayout().slots.allSatisfy { $0.appIcons.isEmpty })
    }

    @Test("app icons extend each Space's clickable slot and respect the cap")
    func menuBarAppIcons_extendSlots() throws {
        stub.activeDisplayIdentifier = "Main"
        stub.displays = makeDisplays(activeSpaceID: 100)
        stub.windowOwnerPIDsMap = [100: [11, 22, 33, 44], 101: [55]]
        store.showAllSpaces = true
        store.hideEmptySpaces = false
        store.spacePickerStyle = .name
        store.spacePickerMaxAppIcons = 2
        let state = AppState(displaySpaceProvider: stub, skipObservers: true, store: store)
        state.renderer.appIconResolver = { pid in
            pid == 11 ? nil : NSImage(size: NSSize(width: 16, height: 16))
        }

        let layout = state.statusBarLayout()
        let image = state.statusBarIcon
        store.spacePickerMaxAppIcons = 0
        let indicators = state.statusBarLayout()

        try #require(layout.slots.count == 2)
        try #require(indicators.slots.count == 2)
        #expect(abs(layout.slots[0].width - indicators.slots[0].width - 38) < 0.01)
        #expect(abs(layout.slots[1].width - indicators.slots[1].width - 19) < 0.01)
        #expect(layout.slot(at: layout.slots[0].startX + layout.slots[0].width - 1)?.spaceID == 100)
        #expect(layout.slot(at: layout.slots[1].startX + layout.slots[1].width - 1)?.spaceID == 101)
        #expect(abs(image.size.width - layout.totalWidth) < 0.01)
        #expect(!image.isTemplate, "App artwork must keep its color")
        #expect(stub.windowOwnerPIDsCallCount == 1)
        #expect(stub.spacesWithWindowsCallCount == 0)
    }

    @Test("menu bar icons work across displays without widening picker indicators")
    func menuBarAppIcons_crossDisplayAndPicker() throws {
        stub.activeDisplayIdentifier = "Main"
        stub.displays = makeDisplays(activeSpaceID: 100) + [
            CGSStub.makeDisplay(
                displayID: "Other",
                spaces: [(id: 200, isFullscreen: false)],
                activeSpaceID: 200
            ),
        ]
        stub.windowOwnerPIDsMap = [100: [11], 200: [22]]
        store.showAllSpaces = false
        store.showAllDisplays = true
        store.hideEmptySpaces = false
        store.spacePickerMaxAppIcons = 1
        store.spacePickerStyle = .icons
        let state = AppState(displaySpaceProvider: stub, skipObservers: true, store: store)
        state.renderer.appIconResolver = { _ in NSImage(size: NSSize(width: 16, height: 16)) }

        let layout = state.statusBarLayout()
        let picker = state.spacePickerEntries()
        try #require(layout.slots.count == 2)
        try #require(picker.count == 2)
        #expect(layout.slots.map(\.spaceID) == [100, 200])
        #expect(abs(state.statusBarIcon.size.width - layout.totalWidth) < 0.01)
        #expect(picker[0].appIcons.count == 1)
        #expect(abs(picker[0].icon.size.width + 19 - layout.slots[0].width) < 0.01)

        store.spacePickerMaxAppIcons = 0
        let indicators = state.statusBarLayout()
        try #require(indicators.slots.count == 2)
        #expect(abs(layout.slots[1].width - indicators.slots[1].width - 19) < 0.01)

        store.showAllSpaces = true
        store.spacePickerMaxAppIcons = 1
        #expect(state.statusBarLayout().slots.map(\.spaceID) == [100, 101, 200])
    }

    @Test("fullscreen indicators stay unchanged and shrinking drops Desktop app icons")
    func menuBarAppIcons_fullscreenAndShrink() throws {
        stub.activeDisplayIdentifier = "Main"
        stub.displays = [
            CGSStub.makeDisplay(
                displayID: "Main",
                spaces: [(id: 100, isFullscreen: false), (id: 101, isFullscreen: true)],
                activeSpaceID: 100
            ),
        ]
        stub.windowOwnerPIDsMap = [100: [11], 101: [22]]
        store.showAllSpaces = true
        store.fullscreenIconStyle = .letter
        store.spacePickerMaxAppIcons = 1
        let state = AppState(displaySpaceProvider: stub, skipObservers: true, store: store)
        var resolved: [pid_t] = []
        state.renderer.appIconResolver = { pid in
            resolved.append(pid)
            return NSImage(size: NSSize(width: 16, height: 16))
        }

        let layout = state.statusBarLayout()
        try #require(layout.slots.count == 2)
        #expect(resolved == [11])
        store.spacePickerMaxAppIcons = 0
        let indicators = state.statusBarLayout()
        try #require(indicators.slots.count == 2)
        #expect(abs(indicators.slots[1].width - layout.slots[1].width) < 0.01)

        state.shrinkLevel = .compact
        let compactWithoutIcons = state.statusBarIcon.size.width
        store.spacePickerMaxAppIcons = 1
        #expect(abs(state.statusBarIcon.size.width - compactWithoutIcons) < 0.01)
    }

    @Test("Off skips app scans and single-indicator mode retains picker-only icons")
    func menuBarAppIcons_disabledModes() {
        stub.activeDisplayIdentifier = "Main"
        stub.displays = makeDisplays(activeSpaceID: 100)
        store.showAllSpaces = true
        store.spacePickerMaxAppIcons = 0
        let state = AppState(displaySpaceProvider: stub, skipObservers: true, store: store)

        _ = state.statusBarIcon
        _ = state.statusBarLayout()
        #expect(stub.windowOwnerPIDsCallCount == 0)

        store.showAllSpaces = false
        store.showAllDisplays = false
        store.spacePickerMaxAppIcons = 2
        _ = state.statusBarIcon
        #expect(state.statusBarLayout().slots.isEmpty)
        #expect(stub.windowOwnerPIDsCallCount == 0)
    }

    @Test("window membership changes refresh icons without a Space change or hide-empty filter")
    func menuBarAppIcons_refreshWindowMembership() async throws {
        stub.activeDisplayIdentifier = "Main"
        stub.displays = makeDisplays(activeSpaceID: 100)
        stub.windowOwnerPIDsMap = [100: [11]]
        store.showAllSpaces = true
        store.hideEmptySpaces = false
        store.spacePickerMaxAppIcons = 2
        let state = AppState(displaySpaceProvider: stub, skipObservers: true, store: store)
        state.renderer.appIconResolver = { _ in NSImage(size: NSSize(width: 16, height: 16)) }
        let before = state.statusBarLayout()
        try #require(before.slots.count == 2)
        #expect(before.slots[0].appIcons.map(\.ownerPID) == [11])
        let cachedImage = state.statusBarIcon
        var refreshed = false
        state.renderer.onIconNeedsUpdate = { refreshed = true }

        stub.windowOwnerPIDsMap = [101: [22, 33]]
        state.handleSpaceUpdate(.windowMembership)
        for _ in 0 ..< 100 where !refreshed {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(refreshed)
        let after = state.statusBarLayout()
        try #require(after.slots.count == 2)
        #expect(after.slots[0].appIcons.isEmpty)
        #expect(after.slots[1].appIcons.map(\.ownerPID) == [22, 33])
        #expect(abs(after.slots[0].width - before.slots[0].width + 19) < 0.01)
        #expect(abs(after.slots[1].width - before.slots[1].width - 38) < 0.01)
        #expect(state.statusBarIcon !== cachedImage)
        #expect(state.currentSpaceID == 100)
        #expect(stub.spacesWithWindowsCallCount == 0)
    }

    // MARK: - hideFullscreenApps

    @Test("hideFullscreenApps removes fullscreen spaces")
    func hideFullscreenApps_removesFullscreenSpaces() {
        stub.activeDisplayIdentifier = "Main"
        stub.displays = [
            CGSStub.makeDisplay(
                displayID: "Main",
                spaces: [
                    (id: 100, isFullscreen: false),
                    (id: 101, isFullscreen: true),
                    (id: 102, isFullscreen: false),
                ],
                activeSpaceID: 100
            ),
        ]
        store.showAllSpaces = true
        store.hideFullscreenApps = true

        let appState = AppState(displaySpaceProvider: stub, skipObservers: true, store: store)
        let layout = appState.statusBarLayout()

        // Fullscreen space should be hidden
        #expect(layout.slots.count == 2)
        #expect(layout.slots.map(\.label) == ["1", "2"])
    }

    // MARK: - Active Space Always Shown

    @Test("active space is always shown regardless of hideEmptySpaces")
    func activeSpaceAlwaysShown_evenWhenEmpty() {
        stub.activeDisplayIdentifier = "Main"
        stub.displays = [
            CGSStub.makeDisplay(
                displayID: "Main",
                spaces: [
                    (id: 100, isFullscreen: false),
                    (id: 101, isFullscreen: false),
                ],
                activeSpaceID: 100
            ),
        ]
        // No spaces have windows (both are "empty")
        stub.spacesWithWindowsSet = []
        store.showAllSpaces = true
        store.hideEmptySpaces = true

        let appState = AppState(displaySpaceProvider: stub, skipObservers: true, store: store)
        let layout = appState.statusBarLayout()

        // Active space 100 (index 1) should still be shown even though empty
        #expect(layout.slots.count == 1)
        #expect(layout.slots[0].label == "1")
    }

    @Test("active fullscreen space is still shown when hideFullscreenApps enabled")
    func activeFullscreenSpace_shownWhenHidden() {
        stub.activeDisplayIdentifier = "Main"
        stub.displays = [
            CGSStub.makeDisplay(
                displayID: "Main",
                spaces: [
                    (id: 100, isFullscreen: false),
                    (id: 101, isFullscreen: true),
                    (id: 102, isFullscreen: false),
                ],
                activeSpaceID: 101
            ),
        ]
        store.showAllSpaces = true
        store.hideFullscreenApps = true

        let appState = AppState(displaySpaceProvider: stub, skipObservers: true, store: store)
        let layout = appState.statusBarLayout()

        // Active fullscreen space should still appear
        let labels = layout.slots.map(\.label)
        #expect(labels.contains("F"), "Active fullscreen space should be shown")
    }

    // MARK: - Label Templates

    @Test("label with {#} template resolves to space number")
    func labelTemplateResolvesInLayout() {
        stub.activeDisplayIdentifier = "Main"
        stub.displays = [
            CGSStub.makeDisplay(
                displayID: "Main",
                spaces: [
                    (id: 100, isFullscreen: false),
                    (id: 101, isFullscreen: false),
                    (id: 102, isFullscreen: false),
                ],
                activeSpaceID: 100
            ),
        ]
        store.showAllSpaces = true
        store.spaceLabels = [2: "{#} - Work"]

        let appState = AppState(displaySpaceProvider: stub, skipObservers: true, store: store)
        let layout = appState.statusBarLayout()

        let labels = layout.slots.map(\.label)
        #expect(labels == ["1", "2 - Work", "3"])
    }

    @Test("label with only {#} template shows space number")
    func labelTemplateOnlySpace() {
        stub.activeDisplayIdentifier = "Main"
        stub.displays = [
            CGSStub.makeDisplay(
                displayID: "Main",
                spaces: [
                    (id: 100, isFullscreen: false),
                    (id: 101, isFullscreen: false),
                ],
                activeSpaceID: 100
            ),
        ]
        store.showAllSpaces = true
        store.spaceLabels = [1: "{#}"]

        let appState = AppState(displaySpaceProvider: stub, skipObservers: true, store: store)
        let layout = appState.statusBarLayout()

        #expect(layout.slots.first?.label == "1")
    }
}

// MARK: - Shrink Levels

@MainActor
struct StatusBarShrinkLevelTests {
    private let store: DefaultsStore
    private let testSuite: TestSuite
    private let stub: CGSStub

    init() {
        testSuite = TestSuiteFactory.createSuite()
        store = DefaultsStore(suite: testSuite.suite)
        stub = CGSStub()
    }

    private func makeAppState(
        spaces: [(id: Int, isFullscreen: Bool)], activeSpaceID: Int
    ) -> AppState {
        stub.activeDisplayIdentifier = "Main"
        stub.displays = [
            CGSStub.makeDisplay(displayID: "Main", spaces: spaces, activeSpaceID: activeSpaceID),
        ]
        return AppState(displaySpaceProvider: stub, skipObservers: true, store: store)
    }

    private static let plainSpaces: [(id: Int, isFullscreen: Bool)] = [
        (id: 100, isFullscreen: false),
        (id: 101, isFullscreen: false),
        (id: 102, isFullscreen: false),
    ]

    @Test("shrinking drops custom labels for the plain Space number")
    func compact_dropsCustomLabels() {
        store.showAllSpaces = true
        store.spaceLabels = [2: "Work"]
        let appState = makeAppState(spaces: Self.plainSpaces, activeSpaceID: 100)

        #expect(appState.statusBarLayout().slots.map(\.label) == ["1", "Work", "3"])

        for level in [IconShrinkLevel.tight, .small] {
            appState.shrinkLevel = level
            let layout = appState.statusBarLayout()
            #expect(layout.slots.map(\.label) == ["1", "Work", "3"])
            let hitWidth = layout.slots.reduce(0) { $0 + $1.width }
            let iconWidth = Double(appState.statusBarIcon.size.width)
            #expect(hitWidth == iconWidth, "Hit width \(hitWidth), image width \(iconWidth)")
        }

        appState.shrinkLevel = .compact
        #expect(appState.statusBarLayout().slots.map(\.label) == ["1", "2", "3"])
    }

    @Test("single-icon mode still shrinks a custom label")
    func compact_singleIconModeDropsCustomLabel() {
        store.spaceLabels = [2: "A very long workspace label"]
        let appState = makeAppState(spaces: Self.plainSpaces, activeSpaceID: 101)
        let fullWidth = appState.statusBarIcon.size.width

        appState.shrinkLevel = .compact

        #expect(appState.statusBarIcon.size.width < fullWidth)
    }

    @Test("every level of the ladder narrows the icon again")
    func levels_narrowTheIconMonotonically() {
        store.showAllDisplays = true
        store.showAllSpaces = true
        store.spaceLabels = [2: "Work"]
        stub.activeDisplayIdentifier = "Main"
        stub.displays = [
            CGSStub.makeDisplay(displayID: "Main", spaces: Self.plainSpaces, activeSpaceID: 100),
            CGSStub.makeDisplay(
                displayID: "Second",
                spaces: [(id: 200, isFullscreen: false), (id: 201, isFullscreen: false)],
                activeSpaceID: 200
            ),
        ]
        let appState = AppState(displaySpaceProvider: stub, skipObservers: true, store: store)

        let widths = IconShrinkLevel.allCases.map { level -> Double in
            appState.shrinkLevel = level
            return appState.statusBarIcon.size.width
        }

        #expect(widths == widths.sorted(by: >), "each level should be strictly narrower: \(widths)")
        #expect(Set(widths).count == widths.count, "no level should be a no-op: \(widths)")
    }

    @Test("giving up the inactive Spaces leaves one icon per display")
    func activePerDisplay_keepsEveryDisplay() {
        store.showAllDisplays = true
        store.showAllSpaces = true
        stub.activeDisplayIdentifier = "Main"
        stub.displays = [
            CGSStub.makeDisplay(displayID: "Main", spaces: Self.plainSpaces, activeSpaceID: 101),
            CGSStub.makeDisplay(
                displayID: "Second",
                spaces: [(id: 200, isFullscreen: false), (id: 201, isFullscreen: false)],
                activeSpaceID: 201
            ),
        ]
        let appState = AppState(displaySpaceProvider: stub, skipObservers: true, store: store)

        appState.shrinkLevel = .activePerDisplay

        // One slot per display, each naming the Space that display is on
        let slots = appState.statusBarLayout().slots
        #expect(slots.count == 2)
        #expect(slots.map(\.spaceID) == [101, 201])
    }

    @Test("a compact numeral respects tighter user padding", arguments: [0.0, 10.0, 25.0])
    func compact_respectsTighterPadding(padding: Double) {
        store.paddingScale = padding
        store.showAllSpaces = true
        let appState = makeAppState(spaces: Self.plainSpaces, activeSpaceID: 100)
        let fullWidth = appState.statusBarIcon.size.width

        appState.shrinkLevel = .tight
        #expect(appState.statusBarIcon.size.width == fullWidth)
        appState.shrinkLevel = .compact
        #expect(appState.statusBarIcon.size.width <= fullWidth)
    }

    @Test("shrinking drops padding but keeps every Space")
    func compact_keepsEverySpace() {
        store.showAllSpaces = true
        let appState = makeAppState(spaces: Self.plainSpaces, activeSpaceID: 100)
        let full = appState.statusBarIcon.size.width

        appState.shrinkLevel = .compact

        #expect(appState.statusBarLayout().slots.count == 3)
        #expect(appState.statusBarIcon.size.width < full)
    }

    @Test("shrinking drops inactive fullscreen Spaces")
    func compact_dropsInactiveFullscreenSpaces() {
        store.showAllSpaces = true
        let appState = makeAppState(
            spaces: [
                (id: 100, isFullscreen: false),
                (id: 101, isFullscreen: true),
                (id: 102, isFullscreen: false),
            ],
            activeSpaceID: 100
        )

        #expect(appState.statusBarLayout().slots.map(\.label) == ["1", "F", "2"])

        for level in [IconShrinkLevel.tight, .small] {
            appState.shrinkLevel = level
            let layout = appState.statusBarLayout()
            #expect(layout.slots.map(\.label) == ["1", "F", "2"])
            let hitWidth = layout.slots.reduce(0) { $0 + $1.width }
            let iconWidth = Double(appState.statusBarIcon.size.width)
            #expect(hitWidth == iconWidth, "Hit width \(hitWidth), image width \(iconWidth)")
        }

        appState.shrinkLevel = .compact
        #expect(appState.statusBarLayout().slots.map(\.label) == ["1", "2"])
    }

    @Test("an active fullscreen Space survives shrinking")
    func compact_keepsActiveFullscreenSpace() {
        store.showAllSpaces = true
        let appState = makeAppState(
            spaces: [
                (id: 100, isFullscreen: false),
                (id: 101, isFullscreen: true),
            ],
            activeSpaceID: 101
        )

        appState.shrinkLevel = .compact

        #expect(appState.statusBarLayout().slots.map(\.label).contains("F"))
    }

    @Test("collapsing to the current Space reports no slots so the picker takes over")
    func currentOnly_reportsNoSlots() {
        store.showAllSpaces = true
        let appState = makeAppState(spaces: Self.plainSpaces, activeSpaceID: 101)

        #expect(!appState.statusBarLayout().slots.isEmpty)

        appState.shrinkLevel = .currentOnly

        // An empty layout is what routes a left click to showSpacePickerMenu,
        // which is the only way to reach the other Spaces while collapsed
        #expect(appState.statusBarLayout().slots.isEmpty)
        #expect(appState.spacePickerEntries().count == 3)
    }

    @Test("collapsing gives up the other displays last")
    func currentOnly_collapsesAcrossDisplays() {
        store.showAllDisplays = true
        store.showAllSpaces = true
        stub.activeDisplayIdentifier = "Main"
        stub.displays = [
            CGSStub.makeDisplay(
                displayID: "Main",
                spaces: [(id: 100, isFullscreen: false), (id: 101, isFullscreen: false)],
                activeSpaceID: 100
            ),
            CGSStub.makeDisplay(
                displayID: "Second",
                spaces: [(id: 200, isFullscreen: false), (id: 201, isFullscreen: false)],
                activeSpaceID: 200
            ),
        ]
        let appState = AppState(displaySpaceProvider: stub, skipObservers: true, store: store)
        let full = appState.statusBarIcon.size.width

        appState.shrinkLevel = .currentOnly

        #expect(appState.statusBarLayout().slots.isEmpty)
        #expect(appState.statusBarIcon.size.width < full)
    }

    @Test("the icon cache serves each level separately")
    func levels_cacheIndependently() {
        store.showAllSpaces = true
        let appState = makeAppState(spaces: Self.plainSpaces, activeSpaceID: 100)

        let full = appState.statusBarIcon
        appState.shrinkLevel = .compact
        _ = appState.statusBarIcon
        appState.shrinkLevel = .full

        #expect(appState.statusBarIcon.size.width == full.size.width)
    }
}

// MARK: - Space Picker Menu

@MainActor
struct SpacePickerTests {
    @Test("only other applications can own a fullscreen Space during teardown")
    func fullscreenOwnerCandidates() {
        func window(_ id: Int, pid: pid_t) -> [String: Any] {
            [kCGWindowLayer as String: 0, kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid]
        }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let panel = window(18, pid: currentPID)
        let transition = window(35, pid: 82)
        let other = window(29, pid: 67)
        let runningApps: Set<pid_t> = [currentPID, 67]
        let candidates = FullscreenSpaceOwners.candidates(in: [transition, panel, other], runningAppPIDs: runningApps)
        #expect(candidates.map(\.pid) == [67])
        #expect(candidates.map(\.windows) == [[29]])
        #expect(FullscreenSpaceOwners.candidates(in: [transition, panel], runningAppPIDs: runningApps).isEmpty)
    }

    private let store: DefaultsStore
    private let testSuite: TestSuite
    private let stub: CGSStub

    init() {
        testSuite = TestSuiteFactory.createSuite()
        store = DefaultsStore(suite: testSuite.suite)
        stub = CGSStub()
    }

    private func makeAppState(
        spaces: [(id: Int, isFullscreen: Bool)], activeSpaceID: Int
    ) -> AppState {
        stub.activeDisplayIdentifier = "Main"
        stub.displays = [
            CGSStub.makeDisplay(displayID: "Main", spaces: spaces, activeSpaceID: activeSpaceID),
        ]
        return AppState(displaySpaceProvider: stub, skipObservers: true, store: store)
    }

    @Test("picker lists every space with the active one marked")
    func entriesListAllSpaces() {
        let appState = makeAppState(
            spaces: [
                (id: 100, isFullscreen: false),
                (id: 101, isFullscreen: false),
                (id: 102, isFullscreen: false),
            ],
            activeSpaceID: 101
        )

        let entries = appState.spacePickerEntries()

        #expect(entries.map(\.isActive) == [false, true, false])
        #expect(entries.map(\.targetSpace) == [1, 2, 3])
        #expect(entries.map(\.spaceID) == [100, 101, 102])
        #expect(entries.map(\.title) == (1 ... 3).map {
            String(format: Localization.labelDesktopNumber, $0)
        })
        #expect(entries.map(\.keyEquivalent) == ["1", "2", "3"])
    }

    @Test("picker names respect display overrides, label templates, and explicit empty labels")
    func entriesPreferCustomLabels() {
        store.spaceLabels = [0: "Desk {#}", 1: "Shared"]
        store.displaySpaceLabels = ["Main": [1: "Draft", 2: "Fullscreen", 4: ""]]
        let appState = makeAppState(
            spaces: [
                (id: 100, isFullscreen: false),
                (id: 101, isFullscreen: true),
                (id: 102, isFullscreen: false),
                (id: 103, isFullscreen: false),
            ],
            activeSpaceID: 100
        )

        let entries = appState.spacePickerEntries()

        #expect(entries.map(\.title) == ["Draft", "", "Desk 2", String(format: Localization.labelDesktopNumber, 3)])
        #expect(entries.map(\.keyEquivalent) == ["1", "", "2", "3"])
    }

    @Test("picker extends bare shortcuts past nine desktops without counting fullscreen spaces")
    func extendedShortcuts() {
        var spaces = (1 ... 16).map { (id: $0, isFullscreen: false) }
        spaces.insert((id: 100, isFullscreen: true), at: 9)
        let appState = makeAppState(spaces: spaces, activeSpaceID: 10)
        let entries = appState.spacePickerEntries()
        let menu = MenuBuilder.buildSpacePickerMenu(entries: entries, style: .name, target: NSObject())
        let desktopItems = menu.items.filter { ($0.representedObject as? SpacePickerEntry)?.targetSpace != nil }

        #expect(desktopItems.count == 16)
        #expect(desktopItems[8].keyEquivalent == "9")
        #expect(desktopItems[9].keyEquivalent == "0")
        #expect(desktopItems[10].keyEquivalent == "a")
        #expect(desktopItems[15].keyEquivalent == "f")
        #expect(Set(desktopItems.map(\.keyEquivalent)).count == 16)
        #expect(desktopItems.allSatisfy { $0.keyEquivalentModifierMask.rawValue == 0 })
        #expect(menu.items[9].keyEquivalent.isEmpty)
        #expect((desktopItems[9].representedObject as? SpacePickerEntry)?.spaceID == 10)
    }

    @Test("picker ignores hide filters so hidden spaces stay reachable")
    func entriesIgnoreHideFilters() {
        store.hideEmptySpaces = true
        store.hideFullscreenApps = true
        stub.spacesWithWindowsSet = [100]
        let appState = makeAppState(
            spaces: [
                (id: 100, isFullscreen: false),
                (id: 101, isFullscreen: true),
                (id: 102, isFullscreen: false),
            ],
            activeSpaceID: 100
        )

        let entries = appState.spacePickerEntries()

        #expect(entries.count == 3)
        #expect(entries.map(\.spaceID) == [100, 101, 102])
    }

    @Test("fullscreen spaces have no target space and take the owning app's name")
    func fullscreenEntryHasNoTargetSpace() {
        let pid = ProcessInfo.processInfo.processIdentifier
        stub.fullscreenOwnerPIDsMap = [101: pid]
        let appState = makeAppState(
            spaces: [
                (id: 100, isFullscreen: false),
                (id: 101, isFullscreen: true),
            ],
            activeSpaceID: 100
        )

        let entries = appState.spacePickerEntries()

        #expect(entries.count == 2)
        #expect(entries[1].targetSpace == nil)
        #expect(entries[1].title == (NSRunningApplication.current.localizedName ?? ""))
        #expect(entries[1].keyEquivalent.isEmpty)
    }

    @Test("Split View resolves both tiles from left to right without a window scan")
    func splitViewIconUsesBothTiles() throws {
        store.fullscreenIconStyle = .appIcon
        stub.activeDisplayIdentifier = "Main"
        let tiles: [[String: Any]] = [
            ["pid": ProcessInfo.processInfo.processIdentifier, "TileRect": ["X": -600]],
            ["pid": 43, "TileRect": ["X": 900]],
            ["pid": 52, "TileRect": ["X": 0]],
        ]
        let display: NSDictionary = [
            "Display Identifier": "Main",
            "Current Space": ["ManagedSpaceID": 62],
            "Spaces": [["ManagedSpaceID": 62, "TileLayoutManager": ["TileSpaces": tiles]]],
        ]
        stub.displays = [display]
        let state = AppState(displaySpaceProvider: stub, skipObservers: true, store: store)
        var owners: [pid_t] = []
        state.renderer.fullscreenAppIconResolver = { pid in
            owners.append(pid)
            return NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
                (pid == 52 ? NSColor.red : NSColor.blue).setFill()
                rect.fill()
                return true
            }
        }
        let entries = state.spacePickerEntries()
        #expect(entries.map(\.spaceID) == [62])
        let first = try #require(entries.first?.icon)
        state.renderer.invalidateIconCache()
        #expect(state.spacePickerEntries().first?.icon === first)
        store.sizeScale = 80
        let smaller = try #require(state.spacePickerEntries().first?.icon)
        #expect(smaller.size.width < first.size.width)
        store.sizeScale = 100
        #expect(state.spacePickerEntries().first?.icon === first)
        #expect(owners == [52, 43])
        #expect(stub.fullscreenOwnerPIDsCallCount == 0)
        store.showAllSpaces = true
        let slot = try #require(state.statusBarLayout().slots.first)
        #expect(slot.appIcons.map(\.ownerPID) == [52, 43])
        for icon in slot.appIcons {
            #expect(slot.appPID(at: slot.startX + icon.startX + icon.width / 2) == icon.ownerPID)
        }
    }

    @Test("Split View shows one title and icon per app", arguments: [true, false], [true, false])
    func splitViewAppIdentity(sameProcess: Bool, sharedBundle: Bool) async {
        let owners: [pid_t] = [.max, sameProcess ? .max : .max - 1]
        let count = sameProcess || sharedBundle ? 1 : 2
        store.fullscreenIconStyle = .appIcon
        stub.activeDisplayIdentifier = "Main"
        let tiles: [[String: Any]] = owners.enumerated().map { ["pid": $0.element, "TileRect": ["X": $0.offset]] }
        let display: NSDictionary = [
            "Display Identifier": "Main",
            "Current Space": ["ManagedSpaceID": 35],
            "Spaces": [["ManagedSpaceID": 35, "TileLayoutManager": ["TileSpaces": tiles]]],
        ]
        stub.displays = [display]
        let state = AppState(displaySpaceProvider: stub, skipObservers: true, store: store)
        let bundle: (pid_t) -> String? = { _ in sharedBundle ? "example.editor" : nil }
        let titles = await state.fullscreenShortcutTitles(
            for: state.fullscreenShortcutTargets,
            bundleIdentifier: bundle
        ) { _ in "Editor" }
        #expect(titles[35] == (count == 1 ? "Editor" : "Editor + Editor"))

        state.renderer.fullscreenAppIconResolver = { _ in NSImage(size: NSSize(width: 16, height: 16)) }
        #expect(state.renderer.fullscreenAppIcons(forSpaceID: 35, bundleIdentifier: bundle).count == count)
    }

    @Test("a lone Desktop keeps the bare Mission Control name")
    func loneDesktopStaysUnnumbered() {
        let appState = makeAppState(
            spaces: [
                (id: 100, isFullscreen: false),
                (id: 101, isFullscreen: true),
            ],
            activeSpaceID: 100
        )

        let entries = appState.spacePickerEntries()

        #expect(entries[0].title == Localization.labelDesktop)
    }

    @Test("fullscreen spaces with no known owner stay untitled")
    func fullscreenEntryWithoutOwnerHasNoTitle() {
        let appState = makeAppState(
            spaces: [
                (id: 100, isFullscreen: false),
                (id: 101, isFullscreen: true),
            ],
            activeSpaceID: 100
        )

        let entries = appState.spacePickerEntries()

        #expect(entries[1].title.isEmpty)
    }

    @Test("built menu carries icons, titles, checkmark, and entries for the action")
    func builtMenuMatchesEntries() {
        let appState = makeAppState(
            spaces: [
                (id: 100, isFullscreen: false),
                (id: 101, isFullscreen: false),
            ],
            activeSpaceID: 101
        )
        let entries = appState.spacePickerEntries()
        let target = NSObject()

        let menu = MenuBuilder.buildSpacePickerMenu(entries: entries, style: .both, target: target)

        #expect(menu.items.count == 3)
        let spaceItems = Array(menu.items.prefix(2))
        // No occupancy configured, so the combined style stays on the plain
        // titles the picker always had
        #expect(spaceItems.allSatisfy { $0.attributedTitle == nil })
        #expect(spaceItems.map(\.state) == [.off, .on])
        #expect(spaceItems.map(\.title) == (1 ... 2).map {
            String(format: Localization.labelDesktopNumber, $0)
        })
        #expect(spaceItems.map(\.keyEquivalent) == ["1", "2"])
        #expect(spaceItems.allSatisfy { $0.keyEquivalentModifierMask.rawValue == 0 })
        #expect(spaceItems.allSatisfy { $0.image != nil })
        #expect(spaceItems.allSatisfy { $0.target === target })
        #expect(spaceItems.allSatisfy {
            $0.action == #selector(ActionHandler.switchToPickedSpace(_:))
        })
        #expect(spaceItems.compactMap { ($0.representedObject as? SpacePickerEntry)?.spaceID } == [100, 101])
        // The hidden item claims Cmd+, during menu tracking so the shortcut
        // opens the real settings window rather than the blank Settings scene
        let settingsItem = menu.items[2]
        #expect(settingsItem.isHidden)
        #expect(settingsItem.keyEquivalent == ",")
        #expect(settingsItem.keyEquivalentModifierMask == [.command])
        #expect(settingsItem.action == #selector(ActionHandler.openSettingsWindow))
    }

    @Test("capped splits an ordered list at the app-icon limit")
    func cappedSplitsAtLimit() {
        let (under, underOverflow) = StatusBarRenderer.capped([1, 2], limit: 5)
        #expect(under == [1, 2])
        #expect(underOverflow == 0)

        let (exact, exactOverflow) = StatusBarRenderer.capped([1, 2, 3], limit: 3)
        #expect(exact == [1, 2, 3])
        #expect(exactOverflow == 0)

        let (over, overOverflow) = StatusBarRenderer.capped([1, 2, 3, 4, 5], limit: 2)
        #expect(over == [1, 2])
        #expect(overOverflow == 3)

        let (empty, emptyOverflow) = StatusBarRenderer.capped([Int](), limit: 2)
        #expect(empty.isEmpty)
        #expect(emptyOverflow == 0)
    }

    @Test("entries carry app icons frontmost first, fullscreen rows stay empty")
    func entriesCarryAppIcons() {
        stub.windowOwnerPIDsMap = [100: [11, 22]]
        let appState = makeAppState(
            spaces: [
                (id: 100, isFullscreen: false),
                (id: 101, isFullscreen: true),
            ],
            activeSpaceID: 100
        )
        var resolvedPIDs: [pid_t] = []
        appState.renderer.appIconResolver = { pid in
            resolvedPIDs.append(pid)
            return NSImage()
        }

        let entries = appState.spacePickerEntries()

        #expect(resolvedPIDs == [11, 22])
        #expect(entries[0].appIcons.count == 2)
        #expect(entries[0].overflowCount == 0)
        #expect(entries[1].appIcons.isEmpty)
        #expect(entries[1].overflowCount == 0)
    }

    @Test("apps beyond the cap fold into the overflow count")
    func overflowCountsBeyondCap() {
        store.spacePickerMaxAppIcons = 2
        stub.windowOwnerPIDsMap = [100: [1, 2, 3, 4, 5]]
        let appState = makeAppState(spaces: [(id: 100, isFullscreen: false)], activeSpaceID: 100)
        appState.renderer.appIconResolver = { _ in NSImage() }

        let entries = appState.spacePickerEntries()

        #expect(entries[0].appIcons.count == 2)
        #expect(entries[0].overflowCount == 3)
    }

    @Test("apps without a resolvable icon do not burn cap slots")
    func unresolvedIconsSkipCapSlots() {
        store.spacePickerMaxAppIcons = 2
        stub.windowOwnerPIDsMap = [100: [1, 2, 3]]
        let appState = makeAppState(spaces: [(id: 100, isFullscreen: false)], activeSpaceID: 100)
        appState.renderer.appIconResolver = { pid in pid == 1 ? nil : NSImage() }

        let entries = appState.spacePickerEntries()

        #expect(entries[0].appIcons.count == 2)
        #expect(entries[0].overflowCount == 0)
    }

    @Test("a cap of zero and name mode both skip the window scan")
    func capZeroAndNameModeSkipScan() {
        stub.windowOwnerPIDsMap = [100: [1]]
        let appState = makeAppState(spaces: [(id: 100, isFullscreen: false)], activeSpaceID: 100)

        store.spacePickerMaxAppIcons = 0
        _ = appState.spacePickerEntries()
        #expect(stub.windowOwnerPIDsCallCount == 0)

        store.spacePickerMaxAppIcons = 5
        store.spacePickerStyle = .name
        _ = appState.spacePickerEntries()
        #expect(stub.windowOwnerPIDsCallCount == 0)

        store.spacePickerStyle = .icons
        _ = appState.spacePickerEntries()
        #expect(stub.windowOwnerPIDsCallCount == 1)
    }

    @Test("a sticky window does not attribute its app to every Space")
    func stickyWindowFiltering() {
        // Window 50 sits on every Space, window 51 only on Space 2
        let owners = CGSDisplaySpaceProvider.resolveWindowOwners(
            appWindows: [(pid: 5, windowIDs: [50, 51])],
            spaceIDs: [1, 2, 3]
        ) { windows in
            windows == [51] ? [2] : [1, 2, 3]
        }

        #expect(owners == [2: [5]])
    }

    @Test("an app with one window per Space keeps them all")
    func everywhereAppSurvivesStickyFilter() {
        let spacesByWindow = [61: [1], 62: [2], 63: [3]]
        let owners = CGSDisplaySpaceProvider.resolveWindowOwners(
            appWindows: [(pid: 7, windowIDs: [61, 62, 63])],
            spaceIDs: [1, 2, 3]
        ) { windows in
            windows.count == 1 ? spacesByWindow[windows[0]] ?? [] : [1, 2, 3]
        }

        #expect(owners == [1: [7], 2: [7], 3: [7]])
    }

    @Test("a single requested Space skips the sticky filter")
    func singleSpaceSkipsStickyFilter() {
        var queries = 0
        let owners = CGSDisplaySpaceProvider.resolveWindowOwners(
            appWindows: [(pid: 5, windowIDs: [50])],
            spaceIDs: [1]
        ) { _ in
            queries += 1
            return [1, 2, 3]
        }

        #expect(owners == [1: [5]])
        #expect(queries == 1)
    }

    @Test("ordered-in, minimized, and hidden windows occupy their Space")
    func spaceOccupantKeepsLiveWindows() {
        // Ordered in: a normal window on any Space
        #expect(CGSDisplaySpaceProvider.isSpaceOccupant(attributes: 0x2, tags: 0x300_0001_0048_2001))
        // Minimized to the Dock: attribute cleared, tag bit 60 set
        #expect(CGSDisplaySpaceProvider.isSpaceOccupant(attributes: 0, tags: 0x1300_0001_0048_0001))
        // Minimized tag on older macOS releases: bit 58
        #expect(CGSDisplaySpaceProvider.isSpaceOccupant(attributes: 0, tags: 0x400_0000_0000_0000))
        // Hidden app: attribute cleared, tag bit 39 set
        #expect(CGSDisplaySpaceProvider.isSpaceOccupant(attributes: 0, tags: 0x300_0081_0048_0001))
    }

    @Test("a closed window kept alive by its app does not occupy a Space")
    func spaceOccupantDropsClosedWindows() {
        // A never-released closed window clears the ordered-in attribute
        // and carries none of the minimized or hidden tags
        #expect(!CGSDisplaySpaceProvider.isSpaceOccupant(attributes: 0, tags: 0x300_0001_0048_0001))
        #expect(!CGSDisplaySpaceProvider.isSpaceOccupant(attributes: 0, tags: 0x1_0008_0001))
    }

    @Test("owners keep the front-to-back app order per Space")
    func ownersKeepAppOrder() {
        let owners = CGSDisplaySpaceProvider.resolveWindowOwners(
            appWindows: [(pid: 9, windowIDs: [90]), (pid: 8, windowIDs: [80])],
            spaceIDs: [1, 2]
        ) { _ in [1] }

        #expect(owners == [1: [9, 8]])
    }

    private func makeEntry(
        targetSpace: Int? = 1,
        appIcons: [NSImage] = [],
        overflowCount: Int = 0
    ) -> SpacePickerEntry {
        SpacePickerEntry(
            icon: NSImage(),
            title: "Desktop 1",
            keyEquivalent: "1",
            isActive: false,
            targetSpace: targetSpace,
            spaceID: 100,
            appIcons: appIcons,
            overflowCount: overflowCount
        )
    }

    private func attachmentCount(_ string: NSAttributedString?) -> Int {
        guard let string else {
            return 0
        }
        var count = 0
        string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: string.length)) { value, _, _ in
            if value != nil {
                count += 1
            }
        }
        return count
    }

    @Test("attributed titles follow the picker style")
    func attributedTitlesFollowStyle() {
        let entry = makeEntry(appIcons: [NSImage(), NSImage()])

        #expect(MenuBuilder.attributedTitle(for: entry, style: .name) == nil)

        let fullscreen = makeEntry(targetSpace: nil, appIcons: [NSImage()])
        #expect(MenuBuilder.attributedTitle(for: fullscreen, style: .icons) == nil)
        #expect(MenuBuilder.attributedTitle(for: fullscreen, style: .both) == nil)

        let both = MenuBuilder.attributedTitle(for: entry, style: .both)
        #expect(both?.string.hasPrefix("Desktop 1") == true)
        #expect(attachmentCount(both) == 2)

        let iconsOnly = MenuBuilder.attributedTitle(for: entry, style: .icons)
        #expect(iconsOnly?.string.contains("Desktop") == false)
        #expect(attachmentCount(iconsOnly) == 2)
    }

    @Test("empty Spaces show a dim placeholder in icons mode and stay plain in the combined mode")
    func emptySpacesShowPlaceholderInIconsMode() {
        let empty = makeEntry()

        let iconsOnly = MenuBuilder.attributedTitle(for: empty, style: .icons)
        #expect(iconsOnly?.string == Localization.labelPickerEmpty)
        let color = iconsOnly?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == .secondaryLabelColor)

        #expect(MenuBuilder.attributedTitle(for: empty, style: .both) == nil)

        // The placeholder does not name the Space, so the row keeps the
        // Desktop name as a tooltip
        let menu = MenuBuilder.buildSpacePickerMenu(entries: [empty], style: .icons, target: NSObject())
        #expect(menu.items[0].attributedTitle?.string == Localization.labelPickerEmpty)
        #expect(menu.items[0].toolTip == "Desktop 1")
    }

    @Test("the none style blanks every row and keeps the name as a tooltip")
    func noneStyleBlanksAllRows() {
        let withIcons = makeEntry(appIcons: [NSImage()])

        let title = MenuBuilder.attributedTitle(for: withIcons, style: SpacePickerStyle.none)
        #expect(title?.string.isEmpty == true)

        let menu = MenuBuilder.buildSpacePickerMenu(
            entries: [withIcons],
            style: SpacePickerStyle.none,
            target: NSObject()
        )
        #expect(menu.items[0].title.isEmpty)
        #expect(menu.items[0].attributedTitle == nil)
        #expect(menu.items[0].toolTip == "Desktop 1")
    }

    @Test("overflow appends a +N suffix")
    func overflowAppendsSuffix() {
        let entry = makeEntry(appIcons: [NSImage()], overflowCount: 3)

        let title = MenuBuilder.attributedTitle(for: entry, style: .both)

        #expect(title?.string.hasSuffix(" +3") == true)
    }
}
