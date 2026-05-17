import XCTest
import AppKit
@testable import Nirux

/// Covers the PTY byte-encoding rules in KeyMapper. The lookup tables
/// (`specialKeyTable`, `cmdKeyTable`, `controlCharTable`, `csiLetterTable`,
/// `csiNumericTable`) are internal — exercising them through the public
/// `bytesForEvent` locks the observable contract the way the terminal sees it.
final class KeyMapperTests: XCTestCase {

    // MARK: - Helpers
    /// Synthesize a key-down NSEvent with the given keyCode, characters, and
    /// modifier flags. `chars`/`charsIgnoringMods` default to an empty string
    /// because many callers drive the special-key lookup by keyCode alone.
    private func keyDown(
        keyCode: UInt16,
        chars: String = "",
        charsIgnoringMods: String = "",
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: chars,
            charactersIgnoringModifiers: charsIgnoringMods,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            fatalError("NSEvent.keyEvent returned nil for keyCode \(keyCode)")
        }
        return event
    }

    private func bytes(_ data: Data) -> [UInt8] { Array(data) }

    // MARK: - Special keys (no modifiers)

    func testEnterSendsCarriageReturn() {
        let out = KeyMapper.bytesForEvent(keyDown(keyCode: 0x24))
        XCTAssertEqual(bytes(out), [0x0D])
    }

    func testNumpadEnterSendsCarriageReturn() {
        let out = KeyMapper.bytesForEvent(keyDown(keyCode: 0x4C))
        XCTAssertEqual(bytes(out), [0x0D])
    }

    func testTabSendsHorizontalTab() {
        let out = KeyMapper.bytesForEvent(keyDown(keyCode: 0x30))
        XCTAssertEqual(bytes(out), [0x09])
    }

    func testBackspaceSendsDEL() {
        let out = KeyMapper.bytesForEvent(keyDown(keyCode: 0x33))
        XCTAssertEqual(bytes(out), [0x7F])
    }

    func testEscapeSendsESC() {
        let out = KeyMapper.bytesForEvent(keyDown(keyCode: 0x35))
        XCTAssertEqual(bytes(out), [0x1B])
    }

    func testForwardDeleteSendsCSI3Tilde() {
        let out = KeyMapper.bytesForEvent(keyDown(keyCode: 0x75))
        XCTAssertEqual(bytes(out), Array("\u{1B}[3~".utf8))
    }

    // MARK: - Arrows (no modifiers)

    func testLeftArrow() {
        let out = KeyMapper.bytesForEvent(keyDown(keyCode: 0x7B))
        XCTAssertEqual(bytes(out), Array("\u{1B}[D".utf8))
    }

    func testRightArrow() {
        let out = KeyMapper.bytesForEvent(keyDown(keyCode: 0x7C))
        XCTAssertEqual(bytes(out), Array("\u{1B}[C".utf8))
    }

    func testDownArrow() {
        let out = KeyMapper.bytesForEvent(keyDown(keyCode: 0x7D))
        XCTAssertEqual(bytes(out), Array("\u{1B}[B".utf8))
    }

    func testUpArrow() {
        let out = KeyMapper.bytesForEvent(keyDown(keyCode: 0x7E))
        XCTAssertEqual(bytes(out), Array("\u{1B}[A".utf8))
    }

    // MARK: - Navigation keys

    func testHomeKey() {
        XCTAssertEqual(bytes(KeyMapper.bytesForEvent(keyDown(keyCode: 0x73))),
                       Array("\u{1B}[H".utf8))
    }

    func testEndKey() {
        XCTAssertEqual(bytes(KeyMapper.bytesForEvent(keyDown(keyCode: 0x77))),
                       Array("\u{1B}[F".utf8))
    }

    func testPageUp() {
        XCTAssertEqual(bytes(KeyMapper.bytesForEvent(keyDown(keyCode: 0x74))),
                       Array("\u{1B}[5~".utf8))
    }

    func testPageDown() {
        XCTAssertEqual(bytes(KeyMapper.bytesForEvent(keyDown(keyCode: 0x79))),
                       Array("\u{1B}[6~".utf8))
    }

    // MARK: - Function keys

    func testF1() {
        XCTAssertEqual(bytes(KeyMapper.bytesForEvent(keyDown(keyCode: 0x7A))),
                       Array("\u{1B}OP".utf8))
    }

    // MARK: - Modified arrows (CSI 1;mod format)

    func testShiftUpArrow() {
        // mod = 1 + shift(1) = 2 → CSI 1;2A
        let out = KeyMapper.bytesForEvent(keyDown(keyCode: 0x7E, modifiers: .shift))
        XCTAssertEqual(bytes(out), Array("\u{1B}[1;2A".utf8))
    }

    func testOptionLeftArrow() {
        // Option-only Left/Right use readline word-motion. The xterm CSI
        // form is not bound by default in most shells and gets echoed.
        let out = KeyMapper.bytesForEvent(keyDown(keyCode: 0x7B, modifiers: .option))
        XCTAssertEqual(bytes(out), Array("\u{1B}b".utf8))
    }

    func testOptionRightArrow() {
        let out = KeyMapper.bytesForEvent(keyDown(keyCode: 0x7C, modifiers: .option))
        XCTAssertEqual(bytes(out), Array("\u{1B}f".utf8))
    }

    func testCtrlRightArrow() {
        // mod = 1 + ctrl(4) = 5 → CSI 1;5C
        let out = KeyMapper.bytesForEvent(keyDown(keyCode: 0x7C, modifiers: .control))
        XCTAssertEqual(bytes(out), Array("\u{1B}[1;5C".utf8))
    }

    func testShiftCtrlDownArrow() {
        // mod = 1 + shift(1) + ctrl(4) = 6 → CSI 1;6B
        let out = KeyMapper.bytesForEvent(
            keyDown(keyCode: 0x7D, modifiers: [.shift, .control])
        )
        XCTAssertEqual(bytes(out), Array("\u{1B}[1;6B".utf8))
    }

    // MARK: - Shift+Tab backtab

    func testShiftTabSendsBacktab() {
        let out = KeyMapper.bytesForEvent(keyDown(keyCode: 0x30, modifiers: .shift))
        XCTAssertEqual(bytes(out), Array("\u{1B}[Z".utf8))
    }

    // MARK: - Shift+Enter via CSI u (Kitty keyboard protocol)

    func testShiftEnterSendsCSIu() {
        // mod = 1 + shift(1) = 2 → CSI 13;2u
        let out = KeyMapper.bytesForEvent(keyDown(keyCode: 0x24, modifiers: .shift))
        XCTAssertEqual(bytes(out), Array("\u{1B}[13;2u".utf8))
    }

    // MARK: - Control characters

    func testCtrlASendsSOH() {
        let out = KeyMapper.bytesForEvent(
            keyDown(keyCode: 0x00, chars: "\u{01}", charsIgnoringMods: "a", modifiers: .control)
        )
        XCTAssertEqual(bytes(out), [0x01])
    }

    func testCtrlZSendsSUB() {
        let out = KeyMapper.bytesForEvent(
            keyDown(keyCode: 0x06, chars: "\u{1A}", charsIgnoringMods: "z", modifiers: .control)
        )
        XCTAssertEqual(bytes(out), [0x1A])
    }

    func testCtrlUppercaseASendsSOH() {
        let out = KeyMapper.bytesForEvent(
            keyDown(keyCode: 0x00, chars: "\u{01}", charsIgnoringMods: "A", modifiers: .control)
        )
        XCTAssertEqual(bytes(out), [0x01])
    }

    func testCtrlBracketSendsESC() {
        let out = KeyMapper.bytesForEvent(
            keyDown(keyCode: 0x21, chars: "\u{1B}", charsIgnoringMods: "[", modifiers: .control)
        )
        XCTAssertEqual(bytes(out), [0x1B])
    }

    func testCtrlSpaceSendsNUL() {
        let out = KeyMapper.bytesForEvent(
            keyDown(keyCode: 0x31, chars: "\u{00}", charsIgnoringMods: " ", modifiers: .control)
        )
        XCTAssertEqual(bytes(out), [0x00])
    }

    // MARK: - Cmd+key

    func testCmdBackspaceSendsCtrlU() {
        // Cmd+Backspace → 0x15 (kill line)
        let out = KeyMapper.bytesForEvent(keyDown(keyCode: 0x33, modifiers: .command))
        XCTAssertEqual(bytes(out), [0x15])
    }

    func testCmdAReturnsEmptyData() {
        // Cmd+A isn't a terminal combo; returns empty so menu can handle it
        let out = KeyMapper.bytesForEvent(
            keyDown(keyCode: 0x00, chars: "a", charsIgnoringMods: "a", modifiers: .command)
        )
        XCTAssertEqual(out, Data())
    }

    // MARK: - Regular characters

    func testPlainLetterSendsItself() {
        let out = KeyMapper.bytesForEvent(
            keyDown(keyCode: 0x00, chars: "a", charsIgnoringMods: "a")
        )
        XCTAssertEqual(bytes(out), Array("a".utf8))
    }

    func testOptionPlusLetterSkipsESCPrefix() {
        // Documented Claude Code compatibility: Option+letter must NOT be ESC-prefixed,
        // or Claude interprets ESC as "cancel input".
        let out = KeyMapper.bytesForEvent(
            keyDown(keyCode: 0x00, chars: "å", charsIgnoringMods: "a", modifiers: .option)
        )
        XCTAssertEqual(bytes(out), Array("a".utf8))
        XCTAssertFalse(out.first == 0x1B, "Option+letter must not be ESC-prefixed")
    }

    func testFunctionKeyPrivateUseCharsFiltered() {
        // macOS puts function-key characters in the Unicode Private Use Area
        // (0xF700-0xF8FF). Those should be filtered out when no special-key
        // mapping is matched, so we don't send garbage to the PTY.
        let out = KeyMapper.bytesForEvent(
            keyDown(keyCode: 0xFF, chars: "\u{F710}", charsIgnoringMods: "\u{F710}")
        )
        XCTAssertEqual(out, Data())
    }
}
