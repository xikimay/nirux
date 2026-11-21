import NiruxCore
import Testing

struct AppearanceTests {
    @Test(arguments: InterfaceTransparency.allCases)
    func accessibilityOverridesTheSelectedLevel(_ level: InterfaceTransparency) {
        #expect(level.effective(reducesTransparency: true, increasesContrast: false) == .opaque)
        #expect(level.effective(reducesTransparency: false, increasesContrast: true) == .opaque)
        #expect(level.effective(reducesTransparency: false, increasesContrast: false) == level)
    }

    @Test func onlyOpaqueDrawsWithoutGlass() {
        #expect(InterfaceTransparency.allCases.filter { !$0.usesGlass } == [.opaque])
    }

    @Test(arguments: [(0.3, 0.6), (0.62, 0.6), (0.82, 0.8), (1.4, 1.0)])
    func terminalOpacityIsClampedToAnExactStep(value: Double, expected: Double) {
        #expect(TerminalOpacity.clamped(value) == expected)
    }

    @Test func userConfigurationCanSetMinimumContrast() {
        #expect(TerminalOpacity.setsContrast("font-size = 14\nminimum-contrast = 1.1\n"))
    }
}
