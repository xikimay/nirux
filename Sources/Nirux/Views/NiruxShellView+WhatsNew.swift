import AppKit

// MARK: - What's New (docs/design/changelog.md)

extension NiruxShellView {
    /// The cached changelog at once, the published one when it arrives. It
    /// shows what the card would, so the card goes and the build counts as
    /// seen.
    func showWhatsNewWindow() {
        let controller = whatsNewWindow ?? WhatsNewWindowController { [weak self] in self?.changelogStore?.pullRequestURL($0) }
        whatsNewWindow = controller
        if whatsNewCard == nil { markWhatsNewSeen() } else { dismissWhatsNewCard() }
        changelogDidChange()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        changelogStore?.refresh()
    }

    /// Every surface that shows the changelog, after a fetch.
    func changelogDidChange() {
        whatsNewWindow?.update(
            changelog: changelogStore?.changelog, installedBuild: sideEffects.installedBuild(),
            failure: changelogStore == nil ? "this build doesn’t update from the nightlies." : changelogStore?.failure
        )
        showWhatsNewCardIfDue()
    }

    // MARK: - The card after an update

    /// The nightly whose changes were last shown, put away, or read in the
    /// window; nil before the first, or when the file holds no nightly.
    var lastSeenBuild: Int? {
        (try? String(contentsOf: sideEffects.whatsNewSeenFile, encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .flatMap { Changelog.date(ofBuild: $0) == nil ? nil : $0 }
    }

    /// At launch: a first launch only notes its build; a nightly newer than
    /// the last one seen fetches the changelog, and the card follows.
    func startWhatsNewAfterUpdate() {
        let installed = sideEffects.installedBuild()
        guard Changelog.date(ofBuild: installed) != nil, let store = changelogStore else { return }
        guard let seen = lastSeenBuild else { return markWhatsNewSeen() }
        guard seen < installed else { return }
        store.refresh()
    }

    /// Once the changelog published since launch is read: the card for the
    /// builds since the last one seen, or, when they hold nothing to show,
    /// the build marked as seen.
    func showWhatsNewCardIfDue() {
        let installed = sideEffects.installedBuild()
        guard whatsNewCard == nil, let seen = lastSeenBuild, seen < installed, let store = changelogStore, store.hasFetched,
              let shipped = store.changelog?.entries(after: seen, through: installed), !shipped.isEmpty
        else { return }
        guard shipped.contains(where: { $0.kind != .internal }) else { return markWhatsNewSeen() }
        let card = WhatsNewCardView(shipped: shipped, seen: seen)
        card.onDismiss = { [weak self] in self?.dismissWhatsNewCard() }
        card.onSeeAll = { [weak self] in
            self?.dismissWhatsNewCard()
            self?.showWhatsNewWindow()
        }
        whatsNewCard = card
        addSubview(card, positioned: .above, relativeTo: nil)
        layOutWhatsNewCard()
        animateWhatsNewCard(card, appearing: true)
    }

    func dismissWhatsNewCard() {
        guard let card = whatsNewCard else { return }
        markWhatsNewSeen()
        whatsNewCard = nil
        guard animateWhatsNewCard(card, appearing: false) else { return card.removeFromSuperview() }
        sideEffects.afterCommit(WhatsNewCardView.fadeDuration) { [weak card] in card?.removeFromSuperview() }
    }

    private func markWhatsNewSeen() {
        let installed = sideEffects.installedBuild()
        guard Changelog.date(ofBuild: installed) != nil else { return }
        try? String(installed).write(to: sideEffects.whatsNewSeenFile, atomically: true, encoding: .utf8)
    }

    /// Over the bottom right of the viewport, above the column dots; hidden
    /// while the viewport is too short to leave the work around it.
    func layOutWhatsNewCard(_ frames: ChromeFrames? = nil) {
        guard let card = whatsNewCard else { return }
        let viewport = frames?.viewport ?? viewportRestFrame
        let bottom = max(frames?.indicator.maxY ?? columnIndicator.frame.maxY, viewport.minY)
        card.setFrameOrigin(NSPoint(
            x: (viewport.maxX - card.frame.width - Theme.Space.lg).rounded(), y: (bottom + Theme.Space.sm).rounded()
        ))
        card.isHidden = card.frame.height * 2 > viewport.height
    }

    /// Sets where it ends at once, then fades and rises on its layer, unless
    /// motion is off; false when it didn't animate.
    @discardableResult
    private func animateWhatsNewCard(_ card: WhatsNewCardView, appearing: Bool) -> Bool {
        card.alphaValue = appearing ? 1 : 0
        guard animatesInterface, !sideEffects.reducesMotion(), let layer = card.layer else { return false }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = appearing ? 0 : 1
        fade.toValue = appearing ? 1 : 0
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = appearing ? -WhatsNewCardView.rise : 0
        rise.toValue = appearing ? 0 : -WhatsNewCardView.rise
        let group = CAAnimationGroup()
        group.animations = [fade, rise]
        group.duration = WhatsNewCardView.fadeDuration
        group.timingFunction = CAMediaTimingFunction(name: appearing ? .easeOut : .easeIn)
        layer.add(group, forKey: "whatsNew")
        return true
    }

    /// The store of a build that updates from GitHub's nightlies.
    func makeChangelogStore() -> ChangelogStore? {
        ChangelogStore(
            feed: Bundle.main.infoDictionary?["SUFeedURL"] as? String,
            cache: Persistence.stateDirectory.appendingPathComponent("changelog.json"),
            onChange: { [weak self] in self?.changelogDidChange() }
        )
    }
}
