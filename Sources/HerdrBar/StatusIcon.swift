import AppKit

/// The count in the corner of the menu bar icon, and the colour that says why.
///
/// Modelled on jankeesvw/omarchy-herdr's bar badge: how many agents herdr is
/// running, tinted by the loudest state among them — and absent entirely when
/// every agent is merely ready, so a quiet menu bar stays quiet.
struct IconBadge: Equatable {
    let count: Int
    let state: AgentState

    var text: String { count > 99 ? "99+" : String(count) }

    var color: NSColor {
        switch state {
        case .needsYou: return NSColor(srgbRed: 0.957, green: 0.251, blue: 0.369, alpha: 1)
        case .done: return NSColor(srgbRed: 0.204, green: 0.831, blue: 0.533, alpha: 1)
        // Amber while something is still running, as the reference plugin uses.
        case .working: return NSColor(srgbRed: 1.000, green: 0.702, blue: 0.180, alpha: 1)
        case .ready: return NSColor(srgbRed: 0.435, green: 0.475, blue: 0.576, alpha: 1)
        }
    }
}

/// The menu bar glyph: herdr's ram, from the project's own `ram.svg`.
///
/// The asset ships as a vector PDF (see `scripts/make-icon.sh`) cropped to the
/// ram's head — at 18pt the full mark's body is an unreadable block, while the
/// curled horn and `>-` prompt face stay recognisable.
enum StatusIcon {

    static let size = NSSize(width: 18, height: 18)

    /// Width of the status item with no badge: the menu bar's own thickness,
    /// which is what `NSStatusItem.squareLength` would give.
    static var baseLength: CGFloat { NSStatusBar.system.thickness }

    /// Loaded once: NSImage keeps the PDF representation and re-renders it at
    /// whatever scale the display needs, so one instance covers every size.
    private static let artwork: NSImage? = {
        guard let url = Bundle.main.url(forResource: "ram", withExtension: "pdf"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = size
        return image
    }()

    /// The colour the blink falls back to if it ever runs without a badge to
    /// take its colour from.
    static let fallbackAlertTint = NSColor(srgbRed: 0.957, green: 0.251,
                                           blue: 0.369, alpha: 1)

    /// The ram, either as a template or filled with `tint`.
    ///
    /// `tint == nil` yields an AppKit template image, which is what makes the
    /// icon behave like every other one in the menu bar: white on a dark bar,
    /// black on a light one, inverted while its menu is open, and correct under
    /// Increase Contrast. That is also why the count badge is drawn as a
    /// separate overlay — a template image is painted in a single tint, so a
    /// coloured badge baked into it would come out monochrome.
    /// `canvasWidth` widens the image to the right, leaving the ram at the left
    /// edge — that reserved transparent strip is where the badge sits, and it
    /// keeps the ram from drifting sideways as the badge appears or grows.
    static func ram(tint: NSColor? = nil, canvasWidth: CGFloat? = nil) -> NSImage {
        let canvas = NSSize(width: canvasWidth ?? size.width, height: size.height)
        let image = NSImage(size: canvas, flipped: false) { _ in
            let rect = NSRect(origin: .zero, size: size)
            if let artwork {
                artwork.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                if let tint {
                    tint.setFill()
                    rect.fill(using: .sourceAtop)
                }
            } else {
                // The bundle lost its resource: draw something rather than an
                // invisible status item the user cannot click.
                fallbackGlyph(in: rect, color: tint ?? .black)
            }
            return true
        }
        // A template is tinted by AppKit; a filled ram must be left alone.
        image.isTemplate = tint == nil
        return image
    }

    // MARK: Badge geometry

    static let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .bold)

    /// Sized to be read at a glance rather than merely noticed — the reference
    /// plugin's badge is a full circle beside the icon, not a corner pip.
    static let badgeHeight: CGFloat = 15

    /// Space between the ram and the badge.
    static let badgeGap: CGFloat = 3

    /// A pill just wide enough for its digits, never narrower than a circle.
    static func badgeWidth(_ badge: IconBadge) -> CGFloat {
        let text = PanelText.attributed(badge.text, font: badgeFont, color: .white)
        return max(badgeHeight, text.size().width + 9)
    }

    private static func fallbackGlyph(in rect: NSRect, color: NSColor) {
        color.setStroke()
        let frame = rect.insetBy(dx: 2, dy: 3.5)
        let border = NSBezierPath(roundedRect: frame, xRadius: 2.6, yRadius: 2.6)
        border.lineWidth = 1.4
        border.stroke()
    }
}

/// The count badge, drawn over the status item's top-right corner.
///
/// A subview rather than part of the icon image, so the ram can stay a template
/// image and keep following the menu bar while the badge keeps its own colour.
final class BadgeView: NSView {

    var badge: IconBadge? {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let badge else { return }
        badge.color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2,
                     yRadius: bounds.height / 2).fill()
        PanelText.draw(badge.text, font: StatusIcon.badgeFont, color: .white,
                       in: bounds, alignment: .center)
    }
}

/// Owns the status item's appearance: the icon, the count badge, and the
/// attention flash.
///
/// The flash exists because herdr already raises its own notification when an
/// agent needs input — this only makes that easy to notice from anywhere on
/// screen. It alternates the menu bar's own tint with the badge's colour, so
/// the blink says the same thing the badge does.
final class IconController {

    enum State {
        /// Nothing waiting.
        case idle
        /// An agent is waiting and the user has not looked at herdr yet.
        case flashing
        /// Still waiting, but herdr has been brought forward — stop moving and
        /// leave the badge, so the state is visible but not nagging.
        case acknowledged
    }

    /// Three swaps a second: quick enough to catch the eye in peripheral
    /// vision, slow enough not to read as a rendering glitch.
    private static let blinkInterval: TimeInterval = 1.0 / 3.0

    private weak var statusItem: NSStatusItem?
    private weak var button: NSStatusBarButton?
    private let badgeView = BadgeView()
    private var timer: Timer?
    private var inverted = false
    private(set) var state: State = .idle
    private(set) var badge: IconBadge?
    /// Width of the icon image, including the strip reserved for the badge.
    private var canvasWidth: CGFloat = StatusIcon.size.width

    init(statusItem: NSStatusItem?) {
        self.statusItem = statusItem
        self.button = statusItem?.button
        button?.addSubview(badgeView)
        apply()
    }

    func set(_ newState: State, badge newBadge: IconBadge?) {
        guard newState != state || newBadge != badge else { return }
        state = newState
        badge = newBadge
        apply()
    }

    private func apply() {
        timer?.invalidate()
        timer = nil
        layoutBadge()

        switch state {
        case .idle, .acknowledged:
            // The badge is the standing signal; the blink is the interruption.
            button?.image = StatusIcon.ram(canvasWidth: canvasWidth)
        case .flashing:
            // Start on the alert colour so the very first frame is a visible
            // change rather than the resting look the user already sees.
            inverted = true
            button?.image = flashFrame()
            let timer = Timer(timeInterval: Self.blinkInterval, repeats: true) { [weak self] _ in
                guard let self, self.state == .flashing else { return }
                self.inverted.toggle()
                self.button?.image = self.flashFrame()
            }
            // Common mode: keep blinking while a menu is tracking the run loop.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    /// One frame of the blink: the badge's colour, or the menu bar's own tint.
    private func flashFrame() -> NSImage {
        guard inverted else { return StatusIcon.ram(canvasWidth: canvasWidth) }
        return StatusIcon.ram(tint: badge?.color ?? StatusIcon.fallbackAlertTint,
                              canvasWidth: canvasWidth)
    }

    /// Grow the status item to hold the ram and the badge side by side, then
    /// place the badge in the strip the icon image reserved for it.
    private func layoutBadge() {
        badgeView.badge = badge
        guard let statusItem else { return }

        guard let badge else {
            badgeView.isHidden = true
            canvasWidth = StatusIcon.size.width
            statusItem.length = StatusIcon.baseLength
            return
        }

        badgeView.isHidden = false
        let width = StatusIcon.badgeWidth(badge)
        canvasWidth = StatusIcon.size.width + StatusIcon.badgeGap + width

        // The button centres the image, so the item is the canvas plus the same
        // side padding a bare 18pt icon gets inside a square item.
        let sidePadding = (StatusIcon.baseLength - StatusIcon.size.width) / 2
        statusItem.length = canvasWidth + sidePadding * 2

        let barHeight = NSStatusBar.system.thickness
        badgeView.frame = NSRect(
            x: sidePadding + StatusIcon.size.width + StatusIcon.badgeGap,
            y: ((barHeight - StatusIcon.badgeHeight) / 2).rounded(),
            width: width, height: StatusIcon.badgeHeight)
    }

    deinit { timer?.invalidate() }
}
