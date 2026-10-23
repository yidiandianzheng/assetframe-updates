import CoreGraphics

@main
struct PreviewZoomMathSelfTest {
    static func main() {
        let portrait = PreviewZoomMath.fitMagnification(
            imageSize: CGSize(width: 1086, height: 1448),
            viewportSize: CGSize(width: 650, height: 850)
        )
        precondition(portrait > 0.578 && portrait < 0.580, "竖图应完整缩小并近贴边显示")

        let landscape = PreviewZoomMath.fitMagnification(
            imageSize: CGSize(width: 3840, height: 2160),
            viewportSize: CGSize(width: 1200, height: 700)
        )
        precondition(landscape > 0.30 && landscape < 0.31, "横图应按宽度适配窗口")

        let smallImage = PreviewZoomMath.fitMagnification(
            imageSize: CGSize(width: 400, height: 400),
            viewportSize: CGSize(width: 1200, height: 900)
        )
        precondition(smallImage > 2.219 && smallImage < 2.221, "小图应在不裁切的前提下放大铺满窗口")

        let matchingLandscape = PreviewZoomMath.fitMagnification(
            imageSize: CGSize(width: 1536, height: 960),
            viewportSize: CGSize(width: 1920, height: 1200)
        )
        precondition(matchingLandscape > 1.237 && matchingLandscape < 1.238, "同比例横图应自动放大至近乎铺满窗口")

        let largeCameraPhoto = PreviewZoomMath.fitMagnification(
            imageSize: CGSize(width: 7008, height: 4672),
            viewportSize: CGSize(width: 1650, height: 1000)
        )
        precondition(
            largeCameraPhoto > 0.211 && largeCameraPhoto < 0.212,
            "7008×4672 原图首次打开应约为 21%，不能错误落到 5%"
        )

        let dragged = PreviewPanMath.draggedOrigin(
            startOrigin: CGPoint(x: 400, y: 300),
            viewportTranslation: CGSize(width: 80, height: -40),
            magnification: 2
        )
        precondition(dragged == CGPoint(x: 360, y: 320), "放大后拖动应按缩放倍率换算图片位移")

        let dragRight = PreviewPanMath.draggedOrigin(
            startOrigin: CGPoint(x: 400, y: 300),
            viewportTranslation: CGSize(width: 80, height: 0),
            magnification: 2
        )
        precondition(dragRight.x < 400, "鼠标向右拖时图片必须跟手向右，不能反向滚动画布")

        let dragUp = PreviewPanMath.draggedOrigin(
            startOrigin: CGPoint(x: 400, y: 300),
            viewportTranslation: CGSize(width: 0, height: 40),
            magnification: 2
        )
        precondition(dragUp.y < 300, "窗口坐标中鼠标向上拖时图片必须跟手向上")

        let dragDown = PreviewPanMath.draggedOrigin(
            startOrigin: CGPoint(x: 400, y: 300),
            viewportTranslation: CGSize(width: 0, height: -40),
            magnification: 2
        )
        precondition(dragDown.y > 300, "窗口坐标中鼠标向下拖时图片必须跟手向下")

        print("PreviewZoomMathSelfTest passed")
    }
}
