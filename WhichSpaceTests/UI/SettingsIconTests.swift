import AppKit
import Testing
@testable import WhichSpace

@MainActor
struct DesktopAccentTests {
    @Test("desktop accents match the menu-bar palette while leaving the wallpaper center transparent", arguments: [0, 1, 2])
    func preservesWallpaper(displayIndex: Int) throws {
        let color = StatusBarRenderer.displayBackgroundColors[displayIndex]
        let view = DesktopAccentView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), color: color)
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 200,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.clear.setFill()
        view.bounds.fill(using: .copy)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let center = try #require(bitmap.colorAt(x: 150, y: 100))
        let glow = try #require(bitmap.colorAt(x: 15, y: 100))
        let edge = try #require(bitmap.colorAt(x: 1, y: 100)?.usingColorSpace(.deviceRGB))
        let expected = try #require(color.usingColorSpace(.deviceRGB))
        #expect(center.alphaComponent < 0.01)
        #expect(glow.alphaComponent > 0.05 && glow.alphaComponent < 0.5)
        #expect(edge.alphaComponent > 0.8 && edge.alphaComponent < 1)
        #expect(abs(edge.redComponent - expected.redComponent) < 0.02)
        #expect(abs(edge.greenComponent - expected.greenComponent) < 0.02)
        #expect(abs(edge.blueComponent - expected.blueComponent) < 0.02)
    }

    @Test("desktop accents stay behind icons and never take focus or intercept clicks")
    func noninteractiveDesktopWindow() throws {
        let frame = try #require(NSScreen.screens.first).frame
        let window = DesktopAccentWindow(
            frame: frame,
            color: StatusBarRenderer.displayBackgroundColors[0]
        )
        defer { window.close() }
        #expect(window.ignoresMouseEvents)
        #expect(!window.canBecomeKey && !window.canBecomeMain)
        #expect(!window.isOpaque)
        #expect(window.frame == frame)
        #expect(window.level.rawValue > Int(CGWindowLevelForKey(.desktopWindow)))
        #expect(window.level.rawValue < Int(CGWindowLevelForKey(.desktopIconWindow)))
        #expect(window.collectionBehavior.contains(.canJoinAllSpaces))
    }
}

@MainActor
struct SettingsIconTests {
    private let store: DefaultsStore
    private let stub: CGSStub

    init() {
        let testSuite = TestSuiteFactory.createSuite()
        store = DefaultsStore(suite: testSuite.suite)
        stub = CGSStub()
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
    }

    /// AppState lives inside each test rather than on the suite: the suite
    /// value deallocates off the main actor, where AppState's deinit traps.
    private func makeAppState() -> AppState {
        AppState(displaySpaceProvider: stub, skipObservers: true, store: store)
    }

    private func pixels(_ image: NSImage) -> Data? {
        image.tiffRepresentation
    }

    @Test("honors per-Space preferences for a non-current Space")
    func honorsNonCurrentSpacePreferences() {
        let appState = makeAppState()
        let plain = appState.renderer.settingsIcon(forSpace: 3, display: "Main")
        SpacePreferences.setColors(
            SpaceColors(foreground: .red, background: .blue),
            forSpace: 3,
            display: "Main",
            store: store
        )
        let styled = appState.renderer.settingsIcon(forSpace: 3, display: "Main")
        #expect(pixels(styled) != pixels(plain))

        // Other Spaces stay unaffected
        let neighbor = appState.renderer.settingsIcon(forSpace: 2, display: "Main")
        let neighborAfter = appState.renderer.settingsIcon(forSpace: 2, display: "Main")
        #expect(pixels(neighbor) == pixels(neighborAfter))
    }

    @Test("resolves custom labels with the Space number")
    func resolvesLabels() {
        let appState = makeAppState()
        let plain = appState.renderer.settingsIcon(forSpace: 2, display: "Main")
        SpacePreferences.setLabel("Space {#}", forSpace: 2, display: "Main", store: store)
        let labeled = appState.renderer.settingsIcon(forSpace: 2, display: "Main")
        #expect(pixels(labeled) != pixels(plain))
        // Labels widen the icon beyond the single-number canvas
        #expect(labeled.size.width > plain.size.width)
    }

    @Test("space 0 renders the default-style template from shared storage")
    func rendersTemplate() {
        let appState = makeAppState()
        let plain = appState.renderer.settingsIcon(forSpace: 0, display: nil)
        SpacePreferences.setColors(
            SpaceColors(foreground: .yellow, background: .purple),
            forSpace: SpacePreferences.defaultStyleSpace,
            display: nil,
            store: store
        )
        let styled = appState.renderer.settingsIcon(forSpace: 0, display: nil)
        #expect(pixels(styled) != pixels(plain))
    }

    @Test("shared labels show through on displays without an override")
    func sharedLabelShowsThroughOnDisplays() {
        let appState = makeAppState()
        let plain = appState.renderer.settingsIcon(forSpace: 2, display: "Main")
        SpacePreferences.setLabel("Space {#}", forSpace: 2, display: nil, store: store)
        let labeled = appState.renderer.settingsIcon(forSpace: 2, display: "Main")
        #expect(labeled.size.width > plain.size.width)

        // An empty override is the "no label" sentinel and suppresses the
        // shared label on that display alone
        SpacePreferences.setLabel("", forSpace: 2, display: "Main", store: store)
        let suppressed = appState.renderer.settingsIcon(forSpace: 2, display: "Main")
        #expect(suppressed.size.width == plain.size.width)
    }

    @Test("the scale override multiplies the rendered size")
    func scaleOverride() {
        let appState = makeAppState()
        let base = appState.renderer.settingsIcon(forSpace: 1, display: "Main")
        let enlarged = appState.renderer.settingsIcon(forSpace: 1, display: "Main", sizeScale: 300)
        #expect(enlarged.size.width == base.size.width * 3)
        #expect(enlarged.size.height == base.size.height * 3)
    }

    // MARK: - Hover Preview Overrides

    @Test("nil overrides render identically to no overrides")
    func nilOverridesMatchBaseline() {
        let appState = makeAppState()
        let base = appState.renderer.settingsIcon(forSpace: 1, display: "Main")
        let explicit = appState.renderer.settingsIcon(forSpace: 1, display: "Main", overrides: nil)
        #expect(pixels(base) == pixels(explicit))
    }

    /// Pins the contract that a hover shows exactly what clicking commits:
    /// the overridden render must match a fresh render after the same value
    /// is stored.
    @Test("a style override renders what committing the style renders")
    func stylePreviewEqualsCommit() {
        let appState = makeAppState()
        let previewed = appState.renderer.settingsIcon(
            forSpace: 2, display: "Main", overrides: IconPreviewOverrides(style: .circle)
        )
        SpacePreferences.setIconStyle(.circle, forSpace: 2, display: "Main", store: store)
        let committed = appState.renderer.settingsIcon(forSpace: 2, display: "Main")
        #expect(pixels(previewed) == pixels(committed))
    }

    @Test("a style override forces the plain number over a stored label")
    func stylePreviewForcesPlainNumber() {
        let appState = makeAppState()
        SpacePreferences.setLabel("Work", forSpace: 2, display: "Main", store: store)
        let previewed = appState.renderer.settingsIcon(
            forSpace: 2, display: "Main", overrides: IconPreviewOverrides(style: .circle)
        )
        // Committing a number style clears the label and symbol sentinels
        SpacePreferences.setSymbol("", forSpace: 2, display: "Main", store: store)
        SpacePreferences.setLabel("", forSpace: 2, display: "Main", store: store)
        SpacePreferences.setIconStyle(.circle, forSpace: 2, display: "Main", store: store)
        let committed = appState.renderer.settingsIcon(forSpace: 2, display: "Main")
        #expect(pixels(previewed) == pixels(committed))
    }

    @Test("a style override keeps the stored badge, as committing does")
    func stylePreviewKeepsStoredBadge() {
        let appState = makeAppState()
        SpacePreferences.setBadge(
            SpaceBadge(character: "!", position: .topRight), forSpace: 2, display: "Main", store: store
        )
        let previewed = appState.renderer.settingsIcon(
            forSpace: 2, display: "Main", overrides: IconPreviewOverrides(style: .circle)
        )
        SpacePreferences.setSymbol("", forSpace: 2, display: "Main", store: store)
        SpacePreferences.setLabel("", forSpace: 2, display: "Main", store: store)
        SpacePreferences.setIconStyle(.circle, forSpace: 2, display: "Main", store: store)
        let committed = appState.renderer.settingsIcon(forSpace: 2, display: "Main")
        #expect(pixels(previewed) == pixels(committed))
    }

    @Test("a clear preview renders what toggling the symbol off renders")
    func symbolClearPreviewEqualsToggleOff() {
        let appState = makeAppState()
        // A template symbol must not bleed through the toggle-off, so the
        // commit writes the "none" sentinel rather than a clear
        SpacePreferences.setSymbol(
            "circle", forSpace: SpacePreferences.defaultStyleSpace, display: nil, store: store
        )
        SpacePreferences.setSymbol("star", forSpace: 2, display: "Main", store: store)
        let previewed = appState.renderer.settingsIcon(
            forSpace: 2, display: "Main", overrides: IconPreviewOverrides(clearSymbol: true)
        )
        SpacePreferences.setSymbol("", forSpace: 2, display: "Main", store: store)
        let committed = appState.renderer.settingsIcon(forSpace: 2, display: "Main")
        #expect(pixels(previewed) == pixels(committed))
    }

    @Test("a symbol wrap override renders what committing it renders")
    func symbolWrapPreviewEqualsCommit() {
        let appState = makeAppState()
        SpacePreferences.setLabel("Work", forSpace: 2, display: "Main", store: store)
        SpacePreferences.setSymbol("star", forSpace: 2, display: "Main", store: store)
        let previewed = appState.renderer.settingsIcon(
            forSpace: 2, display: "Main", overrides: IconPreviewOverrides(symbolWrap: .outside)
        )
        SpacePreferences.setSymbolWrap(.outside, forSpace: 2, display: "Main", store: store)
        let committed = appState.renderer.settingsIcon(forSpace: 2, display: "Main")
        #expect(pixels(previewed) == pixels(committed))
    }

    @Test("a symbol override renders what committing the symbol renders")
    func symbolPreviewEqualsCommit() {
        let appState = makeAppState()
        let previewed = appState.renderer.settingsIcon(
            forSpace: 2, display: "Main", overrides: IconPreviewOverrides(symbol: "star")
        )
        SpacePreferences.setSymbol("star", forSpace: 2, display: "Main", store: store)
        let committed = appState.renderer.settingsIcon(forSpace: 2, display: "Main")
        #expect(pixels(previewed) == pixels(committed))
    }

    @Test("an emoji override with a tone renders what committing renders")
    func emojiPreviewEqualsCommit() {
        let appState = makeAppState()
        let previewed = appState.renderer.settingsIcon(
            forSpace: 2,
            display: "Main",
            overrides: IconPreviewOverrides(skinTone: .dark, symbol: "\u{1F44B}")
        )
        SpacePreferences.setSymbol("\u{1F44B}", forSpace: 2, display: "Main", store: store)
        SpacePreferences.setSkinTone(.dark, forSpace: 2, display: "Main", store: store)
        let committed = appState.renderer.settingsIcon(forSpace: 2, display: "Main")
        #expect(pixels(previewed) == pixels(committed))
    }

    @Test("a foreground override merges with the stored background")
    func foregroundPreviewEqualsCommit() {
        let appState = makeAppState()
        SpacePreferences.setColors(
            SpaceColors(foreground: .white, background: .blue),
            forSpace: 2,
            display: "Main",
            store: store
        )
        let previewed = appState.renderer.settingsIcon(
            forSpace: 2, display: "Main", overrides: IconPreviewOverrides(foreground: .red)
        )
        SpacePreferences.setColors(
            SpaceColors(foreground: .red, background: .blue),
            forSpace: 2,
            display: "Main",
            store: store
        )
        let committed = appState.renderer.settingsIcon(forSpace: 2, display: "Main")
        #expect(pixels(previewed) == pixels(committed))
    }

    @Test("a full-colors override renders what committing the swap renders")
    func invertPreviewEqualsCommit() {
        let appState = makeAppState()
        let colors = SpaceColors(foreground: .red, background: .blue)
        SpacePreferences.setColors(colors, forSpace: 2, display: "Main", store: store)
        let previewed = appState.renderer.settingsIcon(
            forSpace: 2,
            display: "Main",
            overrides: IconPreviewOverrides(colors: colors.inverted(for: nil))
        )
        SpacePreferences.setColors(colors.inverted(for: nil), forSpace: 2, display: "Main", store: store)
        let committed = appState.renderer.settingsIcon(forSpace: 2, display: "Main")
        #expect(pixels(previewed) == pixels(committed))
    }

    @Test("clearSymbolBackground strips a stored symbol chip color")
    func clearSymbolBackgroundOverride() {
        let appState = makeAppState()
        SpacePreferences.setLabel("Work", forSpace: 2, display: "Main", store: store)
        SpacePreferences.setSymbol("star", forSpace: 2, display: "Main", store: store)
        // The chip only draws in the outside-label layout
        SpacePreferences.setSymbolWrap(.outside, forSpace: 2, display: "Main", store: store)
        SpacePreferences.setColors(
            SpaceColors(foreground: .white, background: .blue, symbol: .red, symbolBackground: .green),
            forSpace: 2,
            display: "Main",
            store: store
        )
        let base = appState.renderer.settingsIcon(forSpace: 2, display: "Main")
        let stripped = appState.renderer.settingsIcon(
            forSpace: 2,
            display: "Main",
            overrides: IconPreviewOverrides(clearSymbolBackground: true)
        )
        #expect(pixels(stripped) != pixels(base))
    }

    @Test("a badge position override renders what committing it renders")
    func badgePositionPreviewEqualsCommit() {
        let appState = makeAppState()
        SpacePreferences.setBadge(
            SpaceBadge(character: "A", position: .topLeft), forSpace: 2, display: "Main", store: store
        )
        let previewed = appState.renderer.settingsIcon(
            forSpace: 2, display: "Main", overrides: IconPreviewOverrides(badgePosition: .bottomRight)
        )
        SpacePreferences.setBadge(
            SpaceBadge(character: "A", position: .bottomRight), forSpace: 2, display: "Main", store: store
        )
        let committed = appState.renderer.settingsIcon(forSpace: 2, display: "Main")
        #expect(pixels(previewed) == pixels(committed))
    }

    @Test("a symbol position override renders what committing it renders")
    func symbolPositionPreviewEqualsCommit() {
        let appState = makeAppState()
        SpacePreferences.setLabel("Work", forSpace: 2, display: "Main", store: store)
        SpacePreferences.setSymbol("star", forSpace: 2, display: "Main", store: store)
        let previewed = appState.renderer.settingsIcon(
            forSpace: 2, display: "Main", overrides: IconPreviewOverrides(symbolPosition: .right)
        )
        SpacePreferences.setSymbolPosition(.right, forSpace: 2, display: "Main", store: store)
        let committed = appState.renderer.settingsIcon(forSpace: 2, display: "Main")
        #expect(pixels(previewed) == pixels(committed))
    }

    @Test("overrides never touch the status bar icon")
    func overridesLeaveStatusBarAlone() {
        let appState = makeAppState()
        let barBefore = appState.renderer.statusBarIcon(level: .full)
        _ = appState.renderer.settingsIcon(
            forSpace: 1,
            display: "Main",
            overrides: IconPreviewOverrides(background: .orange)
        )
        let barAfter = appState.renderer.statusBarIcon(level: .full)
        #expect(pixels(barBefore) == pixels(barAfter))
    }
}

@MainActor
struct NativeMenuBarTintTests {
    private let store: DefaultsStore
    private let stub = CGSStub()

    init() {
        store = DefaultsStore(suite: TestSuiteFactory.createSuite().suite)
        store.inactiveSpaceOpacity = 100
        stub.activeDisplayIdentifier = "Main"
        stub.displays = [
            CGSStub.makeDisplay(
                displayID: "Main",
                spaces: [(id: 100, isFullscreen: false), (id: 101, isFullscreen: false)],
                activeSpaceID: 100
            ),
        ]
    }

    private func makeAppState() -> AppState {
        AppState(displaySpaceProvider: stub, skipObservers: true, store: store)
    }

    private func bitmap(_ image: NSImage) throws -> NSBitmapImageRep {
        let data = try #require(image.tiffRepresentation)
        return try #require(NSBitmapImageRep(data: data))
    }

    @Test("native tint is the default and explicit colors take precedence")
    func defaultTintHonorsCustomColors() {
        let appState = makeAppState()
        let tinted = appState.renderer.statusBarIcon(level: .full)
        #expect(tinted.isTemplate)
        #expect(tinted === appState.renderer.statusBarIcon(level: .full))

        store.spaceColors = [1: SpaceColors(foreground: .yellow, background: .blue)]
        let custom = appState.renderer.statusBarIcon(level: .full)
        let preview = appState.renderer.settingsIcon(forSpace: 1, display: "Main")
        #expect(!custom.isTemplate)
        #expect(custom.size == tinted.size)
        #expect(custom.tiffRepresentation == preview.tiffRepresentation)

        store.spaceColors = [:]
        #expect(appState.renderer.statusBarIcon(level: .full).isTemplate)
    }

    /// Highlighting the selection must not recolor another Space's artwork.
    private func expectConfiguredInactiveSlot(_ image: NSImage, appState: AppState) throws {
        let actual = try bitmap(image)
        let slot = try #require(appState.statusBarLayout().slots.first { $0.spaceID != appState.currentSpaceID })
        let display = try #require(appState.allDisplaysSpaceInfo.first { $0.entries.contains { $0.id == slot.spaceID } })
        let index = try #require(display.entries.firstIndex { $0.id == slot.spaceID })
        let indicator = appState.renderer.settingsIcon(forSpace: index + 1, display: display.displayID)
        let expected = try bitmap(indicator)
        let actualScale = Double(actual.pixelsWide) / image.size.width
        let expectedScale = Double(expected.pixelsWide) / indicator.size.width
        let inset = Int(3 * Double(expected.pixelsHigh) / indicator.size.height)
        for y in inset ..< expected.pixelsHigh - inset {
            for x in inset ..< expected.pixelsWide - inset {
                let sampleX = Int(((slot.startX + Double(x) / expectedScale) * actualScale).rounded())
                let sampleY = Int((Double(y) / expectedScale * actualScale).rounded())
                #expect(actual.colorAt(x: sampleX, y: sampleY) == expected.colorAt(x: x, y: y))
            }
        }
    }

    @Test("filled styles support native tint", arguments: IconStyle.allCases.filter(\.isFilled))
    func filledStyles(style: IconStyle) {
        store.spaceIconStyles = [1: style]
        let appState = makeAppState()
        #expect(appState.renderer.statusBarIcon(level: .full).isTemplate)
    }

    @Test("unfilled styles keep their artwork", arguments: IconStyle.allCases.filter { !$0.isFilled })
    func unfilledStyles(style: IconStyle) {
        store.spaceIconStyles = [1: style]
        let appState = makeAppState()
        let original = appState.renderer.settingsIcon(forSpace: 1, display: "Main").tiffRepresentation
        let image = appState.renderer.statusBarIcon(level: .full)
        #expect(!image.isTemplate)
        #expect(image.tiffRepresentation == original)
    }

    @Test("template pixels are black with a transparent label")
    func transparentLabel() throws {
        let appState = makeAppState()
        let rep = try bitmap(appState.renderer.statusBarIcon(level: .full))
        var opaquePixels = 0
        var centralHoles = 0
        for y in 0 ..< rep.pixelsHigh {
            for x in 0 ..< rep.pixelsWide {
                let color = try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if color.alphaComponent > 0.9 {
                    opaquePixels += 1
                    #expect(color.redComponent < 0.01)
                    #expect(color.greenComponent < 0.01)
                    #expect(color.blueComponent < 0.01)
                }
                if x > rep.pixelsWide * 4 / 10, x < rep.pixelsWide * 6 / 10,
                   y > rep.pixelsHigh * 4 / 10, y < rep.pixelsHigh * 6 / 10,
                   color.alphaComponent < 0.1
                {
                    centralHoles += 1
                }
            }
        }
        #expect(opaquePixels > 0)
        #expect(centralHoles > 0)
    }

    @Test(
        "selection highlighting preserves inactive artwork",
        arguments: ["symbol", "emoji", "label", "badge", "outline", "color"]
    )
    func mixedArtwork(kind: String) throws {
        store.showAllSpaces = true
        switch kind {
        case "symbol":
            store.spaceSymbols = [2: "star.fill"]
        case "emoji":
            store.spaceSymbols = [2: "🌿"]
        case "label":
            store.spaceLabels = [2: "🌿"]
        case "badge":
            store.spaceBadges = [2: SpaceBadge(character: "🌿", position: .topRight)]
        case "color":
            store.spaceColors = [2: SpaceColors(foreground: .yellow, background: .blue)]
        default:
            store.spaceIconStyles = [2: .circleOutline]
        }
        let appState = makeAppState()
        let image = appState.renderer.statusBarIcon(level: .full)
        #expect(!image.isTemplate)
        try expectConfiguredInactiveSlot(image, appState: appState)
    }

    @Test("inherited custom colors retain their artwork", arguments: [false, true])
    func inheritedColors(perDisplay: Bool) {
        let colors = SpaceColors(foreground: .yellow, background: .blue)
        if perDisplay {
            store.displaySpaceColors = ["Main": [1: colors]]
        } else {
            store.spaceColors = [SpacePreferences.defaultStyleSpace: colors]
        }
        let appState = makeAppState()
        let image = appState.renderer.statusBarIcon(level: .full)
        #expect(!image.isTemplate)
        #expect(image.tiffRepresentation == appState.renderer.settingsIcon(forSpace: 1, display: "Main")
            .tiffRepresentation)
    }

    @Test("fullscreen app artwork and letter fallback retain the colored selection background")
    func fullscreenArtwork() throws {
        store.showAllSpaces = true
        stub.displays = [
            CGSStub.makeDisplay(
                displayID: "Main",
                spaces: [(id: 100, isFullscreen: false), (id: 101, isFullscreen: true)],
                activeSpaceID: 100
            ),
        ]
        stub.fullscreenOwnerPIDsMap = [101: 42]
        let appState = makeAppState()
        appState.renderer.fullscreenAppIconResolver = { _ in
            NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
                NSColor.green.setFill()
                rect.fill()
                return true
            }
        }
        appState.renderer.invalidateIconCache()
        let image = appState.renderer.statusBarIcon(level: .full)
        #expect(!image.isTemplate)
        try expectConfiguredInactiveSlot(image, appState: appState)

        appState.renderer.fullscreenAppIconResolver = { _ in nil }
        appState.renderer.invalidateIconCache()
        #expect(!appState.renderer.statusBarIcon(level: .full).isTemplate)

        store.fullscreenIconStyle = .letter
        #expect(!appState.renderer.statusBarIcon(level: .full).isTemplate)
        store.fullscreenIconStyle = .appIcon
        #expect(!appState.renderer.statusBarIcon(level: .full).isTemplate)
        stub.fullscreenOwnerPIDsMap = [101: 53]
        appState.renderer.spaceSnapshotDidChange()
        #expect(!appState.renderer.statusBarIcon(level: .full).isTemplate)
    }

    @Test("closing a fullscreen window keeps its artwork until its Space disappears")
    func fullscreenArtworkDuringRemoval() async throws {
        store.showAllSpaces = true
        let desktop = (id: 18, isFullscreen: false)
        let fullscreen = (id: 27, isFullscreen: true)
        func setSpaces(_ spaces: [(id: Int, isFullscreen: Bool)], current: Int) {
            stub.displays = [CGSStub.makeDisplay(displayID: "Main", spaces: spaces, activeSpaceID: current)]
        }
        setSpaces([desktop, fullscreen], current: fullscreen.id)
        stub.fullscreenOwnerPIDsMap = [fullscreen.id: 73]
        let appState = makeAppState()
        appState.renderer.fullscreenAppIconResolver = { _ in
            NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                NSColor.green.setFill()
                rect.fill()
                return true
            }
        }
        appState.renderer.invalidateIconCache()
        let before = appState.renderer.statusBarIcon(level: .full)
        #expect(!before.isTemplate)

        stub.fullscreenOwnerPIDsMap = [:]
        appState.renderer.spaceSnapshotDidChange()
        #expect(appState.renderer.statusBarIcon(level: .full).tiffRepresentation == before.tiffRepresentation)
        try await Task.sleep(for: .milliseconds(1200))
        appState.renderer.invalidateIconCache()
        #expect(appState.renderer.statusBarIcon(level: .full).tiffRepresentation == before.tiffRepresentation)

        setSpaces([desktop, fullscreen], current: desktop.id)
        appState.forceSpaceUpdate()
        #expect(!appState.renderer.statusBarIcon(level: .full).isTemplate)
        setSpaces([desktop], current: desktop.id)
        appState.forceSpaceUpdate()
        #expect(!appState.renderer.statusBarIcon(level: .full).isTemplate)
        setSpaces([desktop, fullscreen], current: desktop.id)
        appState.forceSpaceUpdate()
        #expect(!appState.renderer.statusBarIcon(level: .full).isTemplate)
    }

    @Test("text labels and badges support tint without changing layout")
    func textLabelAndBadge() {
        store.spaceLabels = [1: "Work {#}"]
        store.spaceBadges = [1: SpaceBadge(character: "x", position: .topRight)]
        let appState = makeAppState()
        let original = appState.renderer.settingsIcon(forSpace: 1, display: "Main")
        let image = appState.renderer.statusBarIcon(level: .full)
        #expect(image.isTemplate)
        #expect(image.size == original.size)
    }

    @Test("highlighted Space strips retain configured inactive opacity")
    func inactiveOpacity() throws {
        store.showAllSpaces = true
        store.inactiveSpaceOpacity = 25
        let appState = makeAppState()
        let image = appState.renderer.statusBarIcon(level: .full)
        #expect(!image.isTemplate)
        let rep = try bitmap(image)
        var activeAlpha = 0.0
        var inactiveAlpha = 0.0
        for y in 0 ..< rep.pixelsHigh {
            for x in 0 ..< rep.pixelsWide {
                let alpha = try Double(#require(rep.colorAt(x: x, y: y)).alphaComponent)
                if x < rep.pixelsWide / 2 {
                    activeAlpha = max(activeAlpha, alpha)
                } else {
                    inactiveAlpha = max(inactiveAlpha, alpha)
                }
            }
        }
        #expect(activeAlpha > 0.99)
        #expect(abs(inactiveAlpha - 0.25) < 0.01)
    }

    @Test("display separators retain their color and opacity alongside the selection background")
    func displaySeparators() throws {
        store.showAllDisplays = true
        store.separatorColor = .red
        let appState = makeAppState()
        #expect(!appState.renderer.statusBarIcon(level: .full).isTemplate)

        stub.displays.append(CGSStub.makeDisplay(
            displayID: "Secondary",
            spaces: [(id: 200, isFullscreen: false)],
            activeSpaceID: 200
        ))
        appState.forceSpaceUpdate()
        let mixed = appState.renderer.statusBarIcon(level: .full)
        #expect(!mixed.isTemplate)

        store.separatorStyle = .blank
        #expect(!appState.renderer.statusBarIcon(level: .full).isTemplate)

        store.separatorStyle = .line
        store.separatorColor = nil
        let tinted = appState.renderer.statusBarIcon(level: .full)
        #expect(!tinted.isTemplate)
        let rep = try bitmap(tinted)
        let slots = appState.renderer.statusBarLayout(level: .full).slots
        let separatorStart = slots[1].startX - Layout.displaySeparatorWidth
        let scale = Double(rep.pixelsWide) / tinted.size.width
        let start = Int(separatorStart * scale)
        let end = Int((separatorStart + Layout.displaySeparatorWidth) * scale)
        // Integrate the stroke across its antialiased pixels.
        var alpha = 0.0
        for x in start ..< end {
            try alpha += Double(#require(rep.colorAt(x: x, y: rep.pixelsHigh / 2)).alphaComponent)
        }
        #expect(abs(alpha / scale - 0.6) < 0.05)
    }

    @Test("selection backgrounds preserve slot widths", arguments: IconStyle.allCases.filter(\.isFilled), [0.0, 100.0])
    func matchingLayoutWidths(style: IconStyle, padding: Double) {
        store.showAllSpaces = true
        store.spaceLabels = [1: "Long label", 2: "Another label"]
        store.spaceLabelStyles = [1: style, 2: style]
        store.paddingScale = padding
        let appState = makeAppState()
        let icon = appState.renderer.statusBarIcon(level: .full)
        let width = appState.renderer.statusBarLayout(level: .full).slots.reduce(0) { $0 + $1.width }
        #expect(abs(icon.size.width - width) < 0.01)

        store.spaceColors = [1: SpaceColors(foreground: .blue, background: .clear)]
        let custom = appState.renderer.statusBarIcon(level: .full)
        let customWidth = appState.renderer.statusBarLayout(level: .full).slots.reduce(0) { $0 + $1.width }
        #expect(!custom.isTemplate)
        #expect(abs(custom.size.width - customWidth) < 0.01)
    }

    @Test("display groups keep their colors and click targets when the first two swap", arguments: [false, true])
    func displayGroupBackgrounds(swapped: Bool) throws {
        store.showAllDisplays = true
        store.swapFirstDisplayGroups = swapped
        stub.displays.append(CGSStub.makeDisplay(
            displayID: "Secondary",
            spaces: [(id: 200, isFullscreen: false)],
            activeSpaceID: 200
        ))
        stub.displays.append(CGSStub.makeDisplay(
            displayID: "Third",
            spaces: [(id: 300, isFullscreen: false)],
            activeSpaceID: 300
        ))
        let appState = makeAppState()
        for selectedDisplay in ["Main", "Third"] {
            stub.activeDisplayIdentifier = selectedDisplay
            appState.forceSpaceUpdate()
            let image = appState.statusBarIcon
            let rep = try bitmap(image)
            let layout = appState.statusBarLayout()
            try #require(layout.slots.count == 3)
            #expect(layout.slots.map(\.spaceID) == (swapped ? [200, 100, 300] : [100, 200, 300]))
            #expect(abs(image.size.width - layout.totalWidth) < 0.01)
            let scale = Double(rep.pixelsWide) / image.size.width
            func color(in slot: StatusBarIconSlot, y: Double) throws -> NSColor {
                let x = Int(((slot.startX + 4) * scale).rounded())
                return try #require(rep.colorAt(x: x, y: Int((y * scale).rounded()))?.usingColorSpace(.deviceRGB))
            }
            let blue = try color(in: layout.slots[swapped ? 1 : 0], y: 1)
            let green = try color(in: layout.slots[swapped ? 0 : 1], y: 1)
            let yellow = try color(in: layout.slots[2], y: 1)
            #expect(blue.blueComponent > blue.redComponent && blue.blueComponent > blue.greenComponent)
            #expect(green.greenComponent > green.redComponent && green.greenComponent > green.blueComponent)
            #expect(yellow.redComponent > yellow.blueComponent + 0.2)
            #expect(yellow.greenComponent > yellow.blueComponent + 0.2)
            for outer in [blue, green, yellow] {
                #expect(outer.alphaComponent > 0.99)
            }
            let selected = try #require(layout.slots.first { $0.spaceID == appState.currentSpaceID })
            let red = try color(in: selected, y: Layout.statusItemHeight / 2)
            #expect(red.redComponent > red.greenComponent * 1.5 && red.redComponent > red.blueComponent * 1.5)
            #expect(red.alphaComponent > 0.99)
            for slot in layout.slots {
                #expect(layout.slot(at: slot.startX + slot.width / 2)?.spaceID == slot.spaceID)
            }
        }
    }

    @Test("visible Spaces on unfocused displays are light red and follow display and Space changes")
    func unfocusedVisibleSpaceBackgrounds() throws {
        store.showAllDisplays = true
        store.showAllSpaces = true
        store.swapFirstDisplayGroups = true
        let appState = makeAppState()
        for (focusedDisplay, thirdActiveSpace) in [("Main", 300), ("Secondary", 300), ("Third", 300), ("Main", 301)] {
            stub.activeDisplayIdentifier = focusedDisplay
            stub.displays = [
                CGSStub.makeDisplay(
                    displayID: "Main",
                    spaces: [(id: 100, isFullscreen: false), (id: 101, isFullscreen: false)],
                    activeSpaceID: 100
                ),
                CGSStub.makeDisplay(
                    displayID: "Secondary",
                    spaces: [(id: 200, isFullscreen: false), (id: 201, isFullscreen: false)],
                    activeSpaceID: 200
                ),
                CGSStub.makeDisplay(
                    displayID: "Third",
                    spaces: [(id: 300, isFullscreen: false), (id: 301, isFullscreen: true)],
                    activeSpaceID: thirdActiveSpace
                ),
            ]
            appState.forceSpaceUpdate()
            let image = appState.statusBarIcon
            let rep = try bitmap(image)
            let layout = appState.statusBarLayout()
            try #require(layout.slots.count == 6)
            #expect(abs(image.size.width - layout.totalWidth) < 0.01)
            let scale = Double(rep.pixelsWide) / image.size.width
            let visibleSpaceIDs: Set<Int> = [100, 200, thirdActiveSpace]
            for slot in layout.slots {
                let x = Int(((slot.startX + 4) * scale).rounded())
                let y = Int((Layout.statusItemHeight / 2 * scale).rounded())
                let color = try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let isLightRed = color.redComponent > color.greenComponent + 0.1
                    && color.redComponent > color.blueComponent + 0.1
                    && color.greenComponent > 0.4 && color.blueComponent > 0.4
                #expect(color.alphaComponent > 0.99)
                if slot.spaceID == appState.currentSpaceID {
                    #expect(color.redComponent > color.greenComponent * 1.5)
                    #expect(color.redComponent > color.blueComponent * 1.5)
                    #expect(!isLightRed)
                } else {
                    #expect(isLightRed == visibleSpaceIDs.contains(slot.spaceID))
                }
                #expect(layout.slot(at: slot.startX + slot.width / 2)?.spaceID == slot.spaceID)
            }
        }
    }

    @Test("selection backgrounds remain when artwork is hidden or shrunk away")
    func visibleArtworkOnly() {
        store.showAllSpaces = true
        store.spaceSymbols = [2: "star.fill"]
        let appState = makeAppState()
        #expect(!appState.renderer.statusBarIcon(level: .full).isTemplate)
        #expect(!appState.renderer.statusBarIcon(level: .compact).isTemplate)
        #expect(appState.renderer.statusBarIcon(level: .currentOnly).isTemplate)

        store.hideEmptySpaces = true
        stub.spacesWithWindowsSet = [100]
        #expect(!appState.renderer.statusBarIcon(level: .full).isTemplate)
    }
}
