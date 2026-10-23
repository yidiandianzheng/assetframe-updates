import SwiftUI

struct GalleryWorkspaceShell<Toolbar: View, Content: View>: View {
    @ViewBuilder let toolbar: () -> Toolbar
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            toolbar()
            Divider()
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppSurfaceTokens.canvas)
    }
}
