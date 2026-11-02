import SwiftUI
import Installer

struct FileListView: View {
    let files: [TransferProgress.FileProgress]

    var body: some View {
        if files.isEmpty {
            ContentUnavailableView(
                "队列中没有文件",
                systemImage: "tray",
                description: Text("将游戏文件拖放到上方以开始")
            )
        } else {
            List(files) { file in
                FileRowView(file: file)
            }
            .listStyle(.plain)
        }
    }
}
