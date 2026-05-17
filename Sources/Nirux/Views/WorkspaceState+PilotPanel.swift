import AppKit

// MARK: - Pilot Info Panel

extension WorkspaceState {
    static let pilotPanelWidth: CGFloat = 200

    func createPilotPanel() {
        guard pilotPanel == nil else { return }
        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(red: 0.11, green: 0.11, blue: 0.14, alpha: 1).cgColor
        containerView.addSubview(panel)
        pilotPanel = panel

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        containerView.addSubview(divider)
        pilotDivider = divider

        let accentBar = NSView()
        accentBar.wantsLayer = true
        accentBar.layer?.backgroundColor = Self.pilotAccentColor.cgColor
        panel.addSubview(accentBar)
        pilotAccentBar = accentBar
    }

    func updatePilotPanel(info: WorkspaceInfo) {
        guard let panel = pilotPanel else { return }

        animatePilotBackgroundAndAccent(panel: panel, isActive: info.isActive)

        // Skip full rebuild if nothing meaningful changed
        let fingerprint = pilotFingerprint(info)
        guard fingerprint != lastPilotFingerprint else { return }
        lastPilotFingerprint = fingerprint

        // Crossfade content changes
        if let panelLayer = panel.layer, !pilotPanelViews.isEmpty {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.2
            panelLayer.add(transition, forKey: "contentFade")
        }

        rebuildPilotContent(panel: panel, info: info)
    }

    private func animatePilotBackgroundAndAccent(panel: NSView, isActive: Bool) {
        let targetBg = isActive
            ? NSColor(red: 0.12, green: 0.12, blue: 0.15, alpha: 1).cgColor
            : NSColor(red: 0.11, green: 0.11, blue: 0.14, alpha: 1).cgColor
        if let layer = panel.layer, layer.backgroundColor != targetBg {
            let bgAnim = CABasicAnimation(keyPath: "backgroundColor")
            bgAnim.duration = 0.25
            bgAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(bgAnim, forKey: "bgFade")
        }
        panel.layer?.backgroundColor = targetBg

        if let accentBar = pilotAccentBar {
            let targetAlpha: CGFloat = isActive ? 1.0 : 0.0
            if accentBar.alphaValue != targetAlpha {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    accentBar.animator().alphaValue = targetAlpha
                }
            }
        }
    }

    private func rebuildPilotContent(panel: NSView, info: WorkspaceInfo) {
        pilotPanelViews.forEach { $0.removeFromSuperview() }
        pilotPanelViews.removeAll()
        pilotClickableAreas.removeAll()
        pilotColumnClickAreas.removeAll()

        let panelWidth = Self.pilotPanelWidth
        let padding: CGFloat = 20
        let panelHeight = panel.bounds.height

        // Calculate total content height first for vertical centering
        var contentHeight: CGFloat = 18 // title
        if let branch = info.gitBranch, branch != info.title { contentHeight += 18 }
        contentHeight += 16 // gap before columns
        contentHeight += CGFloat(info.columns.count) * 24
        if info.prInfo != nil { contentHeight += 30 }
        if info.diffStats != nil { contentHeight += 20 }

        // Vertically center, clamp to top
        var cursorY = min(panelHeight - padding, (panelHeight + contentHeight) / 2)

        // — Workspace title (14pt bold, hero element)
        let titleLabel = NSTextField(labelWithString: info.title)
        titleLabel.font = .monospacedSystemFont(ofSize: 14, weight: .bold)
        titleLabel.textColor = info.isActive
            ? NSColor.white.withAlphaComponent(0.9)
            : NSColor.white.withAlphaComponent(0.4)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.frame = NSRect(x: padding, y: cursorY - 18, width: panelWidth - padding * 2, height: 18)
        panel.addSubview(titleLabel)
        pilotPanelViews.append(titleLabel)
        cursorY -= 22

        // — Git branch (only if different from title)
        if let branch = info.gitBranch, branch != info.title {
            let branchLabel = NSTextField(labelWithString: branch)
            branchLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            branchLabel.textColor = NSColor.white.withAlphaComponent(0.3)
            branchLabel.lineBreakMode = .byTruncatingTail
            branchLabel.frame = NSRect(x: padding, y: cursorY - 14, width: panelWidth - padding * 2, height: 14)
            panel.addSubview(branchLabel)
            pilotPanelViews.append(branchLabel)
            cursorY -= 18
        }

        // — Space instead of separator line
        cursorY -= 16

        // — Column entries
        for columnInfo in info.columns {
            cursorY = layoutPilotColumnEntry(
                columnInfo: columnInfo,
                panel: panel,
                panelWidth: panelWidth,
                padding: padding,
                cursorY: cursorY
            )
        }

        // — Diff stats with colored +/- (before PR, more prominent)
        if let stats = info.diffStats {
            cursorY -= 8
            let statsLabel = Self.makeDiffStatsLabel(stats, width: panelWidth - padding * 2)
            statsLabel.frame = NSRect(x: padding, y: cursorY - 14, width: panelWidth - padding * 2, height: 14)
            panel.addSubview(statsLabel)
            pilotPanelViews.append(statsLabel)
            pilotClickableAreas.append(
                PilotClickableArea(frame: statsLabel.frame, url: "action:diff", label: statsLabel)
            )
            cursorY -= 20
        }

        // — PR info (line 1: PR state, line 2: CI status, line 3: review status)
        if let pullRequest = info.prInfo {
            layoutPilotPRInfo(
                pullRequest: pullRequest,
                panel: panel,
                panelWidth: panelWidth,
                padding: padding,
                cursorY: &cursorY
            )
        }
    }

    private func layoutPilotColumnEntry(
        columnInfo: ColumnInfo,
        panel: NSView,
        panelWidth: CGFloat,
        padding: CGFloat,
        cursorY: CGFloat
    ) -> CGFloat {
        var cursorY = cursorY
        let rowHeight: CGFloat = 14
        let dotSize: CGFloat = 8

        if let dot = PilotSidebarRenderer.makeAgentDot(
            status: columnInfo.agentStatus, x: padding,
            yOffset: cursorY, rowHeight: rowHeight, size: dotSize
        ) {
            panel.addSubview(dot)
            pilotPanelViews.append(dot)
        }

        let textX: CGFloat = padding + dotSize + 6
        let label = NSTextField(labelWithAttributedString: PilotSidebarRenderer.attributedColumn(columnInfo, fontSize: 11))
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: textX, y: cursorY - rowHeight, width: panelWidth - textX - padding, height: rowHeight)
        panel.addSubview(label)
        pilotPanelViews.append(label)

        // Full-width hit area for column click
        let hitRect = NSRect(x: 0, y: cursorY - 24, width: panelWidth, height: 24)
        pilotColumnClickAreas.append((frame: hitRect, colIndex: columnInfo.index))

        cursorY -= 24
        return cursorY
    }

    private static func makeDiffStatsLabel(_ stats: String, width: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.allowsEditingTextAttributes = true
        label.isSelectable = false
        label.attributedStringValue = PilotSidebarRenderer.diffStatsAttributedString(
            PilotSidebarRenderer.formatDiffStats(stats), fontSize: 11
        )
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func layoutPilotPRInfo(
        pullRequest: PRInfo,
        panel: NSView,
        panelWidth: CGFloat,
        padding: CGFloat,
        cursorY: inout CGFloat
    ) {
        let indent: CGFloat = 12

        // Line 1: PR number + state
        let (stateText, stateColor) = PilotSidebarRenderer.prStateDisplay(pullRequest)
        let prLabel = NSTextField(labelWithString: "#\(pullRequest.number) \(stateText)")
        prLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        prLabel.textColor = stateColor
        prLabel.lineBreakMode = .byTruncatingTail
        prLabel.frame = NSRect(x: padding, y: cursorY - 14, width: panelWidth - padding * 2, height: 14)
        panel.addSubview(prLabel)
        pilotPanelViews.append(prLabel)
        pilotClickableAreas.append(PilotClickableArea(frame: prLabel.frame, url: pullRequest.url, label: prLabel))
        cursorY -= 16

        // Line 2: CI status
        if let ciStatus = pullRequest.ciStatus {
            let (ciDot, ciColor, ciText) = PilotSidebarRenderer.ciStatusDisplay(ciStatus, style: .long)
            let ciLabel = NSTextField(labelWithString: "\(ciDot) \(ciText)")
            ciLabel.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
            ciLabel.textColor = ciColor
            ciLabel.lineBreakMode = .byTruncatingTail
            ciLabel.frame = NSRect(x: padding + indent, y: cursorY - 12, width: panelWidth - padding * 2 - indent, height: 12)
            panel.addSubview(ciLabel)
            pilotPanelViews.append(ciLabel)
            let ciUrl = (ciStatus == "FAILURE" ? pullRequest.failedCheckUrl : nil) ?? pullRequest.url
            pilotClickableAreas.append(PilotClickableArea(frame: ciLabel.frame, url: ciUrl, label: ciLabel))
            cursorY -= 14
        }

        // Line 3: Review status / mergeable
        if let display = PilotSidebarRenderer.reviewDecisionDisplay(
            reviewDecision: pullRequest.reviewDecision, mergeable: pullRequest.mergeable
        ) {
            let reviewLabel = NSTextField(labelWithString: "\(display.dot) \(display.text)")
            reviewLabel.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
            reviewLabel.textColor = display.color
            reviewLabel.lineBreakMode = .byTruncatingTail
            reviewLabel.frame = NSRect(x: padding + indent, y: cursorY - 12, width: panelWidth - padding * 2 - indent, height: 12)
            panel.addSubview(reviewLabel)
            pilotPanelViews.append(reviewLabel)
            pilotClickableAreas.append(PilotClickableArea(frame: reviewLabel.frame, url: pullRequest.url, label: reviewLabel))
            cursorY -= 14
        }

        cursorY -= 2
    }

    func hidePilotPanel() {
        pilotPanel?.removeFromSuperview()
        pilotPanel = nil
        pilotDivider?.removeFromSuperview()
        pilotDivider = nil
        pilotAccentBar = nil
        pilotPanelViews.removeAll()
        pilotClickableAreas.removeAll()
        pilotColumnClickAreas.removeAll()
        lastPilotFingerprint = ""
    }

    func pilotFingerprint(_ info: WorkspaceInfo) -> String {
        let cols = info.columns.map {
            "\($0.processName ?? "")|\($0.isFocused)|\($0.agentStatus)"
        }.joined(separator: ",")
        let prString = info.prInfo.map {
            "#\($0.number)|\($0.ciStatus ?? "")|\($0.reviewDecision ?? "")|\($0.isDraft)"
        } ?? ""
        return "\(info.title)|\(info.isActive)|\(info.gitBranch ?? "")"
            + "|\(info.diffStats ?? "")|\(cols)|\(prString)"
            + "|\(Int(pilotPanel?.bounds.height ?? 0))"
    }

    /// Check if a click hit a clickable area in the pilot panel; opens URL if so.
    func handlePilotPanelClick(windowPoint: NSPoint) -> Bool {
        guard let panel = pilotPanel, !panel.isHidden else { return false }
        let panelPoint = panel.convert(windowPoint, from: nil)
        guard panel.bounds.contains(panelPoint) else { return false }
        for area in pilotClickableAreas where area.frame.contains(panelPoint) {
            if area.url == "action:diff" {
                onDiffStatsClicked?()
            } else if let url = URL(string: area.url) {
                NSWorkspace.shared.open(url)
            }
            return true
        }
        return false
    }

    /// Check if a click hit a column entry in the pilot panel; returns column index if so.
    func handlePilotColumnClick(windowPoint: NSPoint) -> Int? {
        guard let panel = pilotPanel, !panel.isHidden else { return nil }
        let panelPoint = panel.convert(windowPoint, from: nil)
        guard panel.bounds.contains(panelPoint) else { return nil }
        for area in pilotColumnClickAreas where area.frame.contains(panelPoint) {
            return area.colIndex
        }
        return nil
    }

    /// Returns true when the mouse is over a clickable pilot-panel element.
    /// Adds/removes an underline on the hovered label.
    func handlePilotPanelHover(windowPoint: NSPoint) -> Bool {
        guard let panel = pilotPanel, !panel.isHidden else {
            clearHoveredLabel()
            return false
        }
        let panelPoint = panel.convert(windowPoint, from: nil)
        for area in pilotClickableAreas where area.frame.contains(panelPoint) {
            if hoveredLabel !== area.label {
                clearHoveredLabel()
                applyUnderline(to: area.label)
                hoveredLabel = area.label
            }
            return true
        }
        // Column entries are clickable too
        for area in pilotColumnClickAreas where area.frame.contains(panelPoint) {
            clearHoveredLabel()
            return true
        }
        clearHoveredLabel()
        return false
    }

    private func applyUnderline(to label: NSTextField) {
        let attr = NSMutableAttributedString(attributedString: label.attributedStringValue)
        attr.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                          range: NSRange(location: 0, length: attr.length))
        label.attributedStringValue = attr
    }

    private func clearHoveredLabel() {
        guard let label = hoveredLabel else { return }
        let attr = NSMutableAttributedString(attributedString: label.attributedStringValue)
        attr.removeAttribute(.underlineStyle, range: NSRange(location: 0, length: attr.length))
        label.attributedStringValue = attr
        hoveredLabel = nil
    }

}
