import AppKit

@main
struct PreviewKeyNavigationSelfTest {
    @MainActor
    static func main() {
        precondition(PreviewEscapeView.navigationStep(keyCode: 123, modifiers: [], textEditing: false) == -1)
        precondition(PreviewEscapeView.navigationStep(keyCode: 124, modifiers: [], textEditing: false) == 1)
        precondition(PreviewEscapeView.navigationStep(keyCode: 124, modifiers: [.numericPad, .function], textEditing: false) == 1)
        for modifier: NSEvent.ModifierFlags in [.command, .option, .control, .shift] {
            for code: UInt16 in [123, 124] {
                precondition(PreviewEscapeView.navigationStep(keyCode: code, modifiers: modifier, textEditing: false) == nil)
            }
        }
        for code: UInt16 in [123, 124] {
            precondition(PreviewEscapeView.navigationStep(keyCode: code, modifiers: [], textEditing: true) == nil)
        }
        for code: UInt16 in [53, 125, 126, 0, 36] {
            precondition(PreviewEscapeView.navigationStep(keyCode: code, modifiers: [], textEditing: false) == nil)
        }
        print("PreviewKeyNavigationSelfTest passed: arrows, native flags, editing, modifiers and unrelated keys")
    }
}
