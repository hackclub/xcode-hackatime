import AppKit

/// shared builder for the onboarding-style windows.
enum OnboardingUI {
    struct Content {
        var icon: String
        var iconColor: NSColor = .controlAccentColor
        var title: String
        var subtitle: String
        var steps: [String] = []
        var buttonTitle: String?
        var buttonURL: URL?
        var footer: String
    }

    static let width: CGFloat = 460

    static func makeWindow(_ content: Content) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        apply(content, to: window)
        return window
    }

    /// replace a window's content in place (used to flip to success states)
    static func apply(_ content: Content, to window: NSWindow) {
        let stack = buildStack(content)
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            container.widthAnchor.constraint(equalToConstant: width),
        ])
        window.contentView = container
        window.setContentSize(stack.fittingSize)
    }

    private static func buildStack(_ c: Content) -> NSStackView {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 40, left: 36, bottom: 28, right: 36)
        content.translatesAutoresizingMaskIntoConstraints = false

        if let icon = NSImage(systemSymbolName: c.icon, accessibilityDescription: "Hackatime") {
            let config = NSImage.SymbolConfiguration(pointSize: 52, weight: .medium)
                .applying(.init(hierarchicalColor: c.iconColor))
            let imageView = NSImageView(image: icon.withSymbolConfiguration(config) ?? icon)
            content.addArrangedSubview(imageView)
        }

        let title = NSTextField(labelWithString: c.title)
        title.font = .systemFont(ofSize: 20, weight: .bold)
        title.alignment = .center
        content.addArrangedSubview(title)

        let subtitle = NSTextField(wrappingLabelWithString: c.subtitle)
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.preferredMaxLayoutWidth = width - 88
        content.addArrangedSubview(subtitle)
        content.setCustomSpacing(22, after: subtitle)

        if !c.steps.isEmpty {
            let card = stepsCard(c.steps)
            content.addArrangedSubview(card)
            card.widthAnchor.constraint(equalToConstant: width - 72).isActive = true
            content.setCustomSpacing(22, after: card)
        }

        if let buttonTitle = c.buttonTitle {
            ButtonTarget.shared.url = c.buttonURL
            let button = NSButton(
                title: buttonTitle, target: ButtonTarget.shared, action: #selector(ButtonTarget.open))
            button.bezelStyle = .push
            button.controlSize = .large
            button.keyEquivalent = "\r"
            content.addArrangedSubview(button)
        }

        if !c.footer.isEmpty {
            let footer = NSTextField(labelWithString: c.footer)
            footer.font = .systemFont(ofSize: 11)
            footer.textColor = .tertiaryLabelColor
            content.addArrangedSubview(footer)
        }
        return content
    }

    private static func stepsCard(_ texts: [String]) -> NSView {
        let steps = NSStackView()
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 10
        steps.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        steps.translatesAutoresizingMaskIntoConstraints = false
        for (index, text) in texts.enumerated() {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 10
            row.alignment = .centerY
            // fixed circle container; sizing the text field itself leaves
            // the digit top-aligned
            let badge = NSView()
            badge.wantsLayer = true
            badge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            badge.layer?.cornerRadius = 10
            badge.translatesAutoresizingMaskIntoConstraints = false
            let digit = NSTextField(labelWithString: "\(index + 1)")
            digit.font = .monospacedDigitSystemFont(ofSize: 12, weight: .bold)
            digit.textColor = .white
            digit.translatesAutoresizingMaskIntoConstraints = false
            badge.addSubview(digit)
            NSLayoutConstraint.activate([
                badge.widthAnchor.constraint(equalToConstant: 20),
                badge.heightAnchor.constraint(equalToConstant: 20),
                digit.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
                digit.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            ])
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 13)
            row.addArrangedSubview(badge)
            row.addArrangedSubview(label)
            steps.addArrangedSubview(row)
        }
        let card = NSVisualEffectView()
        card.material = .contentBackground
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(steps)
        NSLayoutConstraint.activate([
            steps.topAnchor.constraint(equalTo: card.topAnchor),
            steps.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            steps.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            steps.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        return card
    }

    /// present, poll, flip to a green win-state when complete, dwell 2.5s,
    /// exit. `onDismiss(byUser:)` must not return; it receives true only
    /// when the user closed the window before completion
    static func runWindow(
        _ content: Content,
        pollEvery: TimeInterval,
        isComplete: @escaping () -> Bool,
        successTitle: String,
        successSubtitle: String,
        onDismiss: @escaping (_ byUser: Bool) -> Never,
        tick: (() -> Void)? = nil
    ) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = makeWindow(content)
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)

        var celebrating = false
        Timer.scheduledTimer(withTimeInterval: pollEvery, repeats: true) { _ in
            if !window.isVisible {
                onDismiss(!celebrating)
            }
            if celebrating { return }
            tick?()
            if isComplete() {
                celebrating = true
                apply(
                    .init(
                        icon: "checkmark.seal.fill", iconColor: .systemGreen,
                        title: successTitle, subtitle: successSubtitle, footer: ""),
                    to: window)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { onDismiss(false) }
            }
        }
        app.run()
        exit(0)
    }

    final class ButtonTarget: NSObject {
        static let shared = ButtonTarget()
        var url: URL?
        @objc func open() {
            if let url { NSWorkspace.shared.open(url) }
        }
    }
}
