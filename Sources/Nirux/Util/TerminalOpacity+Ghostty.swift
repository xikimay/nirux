import GhosttyTerminal

extension TerminalOpacity {
    /// The per-terminal override at `opacity`: none at 100 %. Cells a
    /// program paints its own background in (a TUI's) take the opacity too.
    static func configuration(_ opacity: Double, userSetsContrast: Bool) -> TerminalConfiguration {
        guard opacity < 1 else { return TerminalConfiguration() }
        let translucent = TerminalConfiguration().backgroundOpacity(opacity).custom("background-opacity-cells", "true")
        return userSetsContrast ? translucent : translucent.minimumContrast(minimumContrast)
    }

    /// Whether the config a terminal opened with sets it.
    static func setsContrast(_ source: TerminalController.ConfigSource) -> Bool {
        if case .generated(let config) = source { return setsContrast(config) }
        return false
    }
}
