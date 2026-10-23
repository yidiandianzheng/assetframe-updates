import CoreGraphics

@main
struct PreviewDecodePolicySelfTest {
    static func main() {
        let preview = PreviewDecodePolicy.targetPixelSize(
            sourceWidth: 8_000, sourceHeight: 6_000,
            viewportSize: CGSize(width: 1_200, height: 800), backingScale: 2,
            fullResolution: false
        )
        precondition(preview == 2_400, "窗口预览应按 Retina 视口下采样")

        let capped = PreviewDecodePolicy.targetPixelSize(
            sourceWidth: 12_000, sourceHeight: 8_000,
            viewportSize: CGSize(width: 4_000, height: 3_000), backingScale: 2,
            fullResolution: false
        )
        precondition(capped == PreviewDecodePolicy.maximumPreviewPixelSize, "预览尺寸必须受上限保护")

        let full = PreviewDecodePolicy.targetPixelSize(
            sourceWidth: 8_000, sourceHeight: 6_000,
            viewportSize: CGSize(width: 1_200, height: 800), backingScale: 2,
            fullResolution: true
        )
        precondition(full == 8_000, "1:1 模式必须请求原图最大边")

        let small = PreviewDecodePolicy.targetPixelSize(
            sourceWidth: 64, sourceHeight: 64,
            viewportSize: CGSize(width: 1_200, height: 800), backingScale: 2,
            fullResolution: false
        )
        precondition(small == 64, "小图不能被无意义放大")
        print("Preview decode policy self-test passed")
    }
}
