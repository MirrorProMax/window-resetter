import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "macwindow")
                .resizable()
                .frame(width: 56, height: 56)
                .foregroundStyle(.tint)

            Text("窗口复位器")
                .font(.title.bold())

            Text("版本 1.0")
                .foregroundStyle(.secondary)

            Text("左键单击菜单栏图标，将当前置顶窗口按规则复位到它所在的屏幕。")
                .font(.callout)
                .multilineTextAlignment(.center)
                .frame(width: 260)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(24)
        .frame(width: 300, height: 240)
    }
}
