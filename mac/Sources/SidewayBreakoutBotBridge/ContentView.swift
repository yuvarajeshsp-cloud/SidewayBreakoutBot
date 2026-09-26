import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: BridgeModel
    @State private var showSecret = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Shared Secret:")
                Group {
                    if showSecret {
                        TextField("secret", text: $model.secret)
                    } else {
                        SecureField("secret", text: $model.secret)
                    }
                }
                .frame(width: 200)
                Toggle("show", isOn: $showSecret).toggleStyle(.checkbox)
                Button("Apply Secret") { model.applySecret() }

                Spacer().frame(width: 24)
                Text("Port:")
                TextField("port", text: $model.port).frame(width: 60)
                Button("Restart Server") { model.restartServer() }
            }

            HStack {
                Text("Pending folder:")
                TextField("pending dir", text: $model.pendingDir)
                Button("Open Folder") { model.openPendingFolder() }
            }

            HStack {
                Circle()
                    .fill(model.statusOK ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(model.status)
                    .font(.callout)
                Spacer()
                Button("Send Test Signal") { model.sendTestSignal() }
            }

            Table(model.records) {
                TableColumn("Time", value: \.time)
                TableColumn("Action", value: \.action)
                TableColumn("Group ID", value: \.groupId)
                TableColumn("Leg", value: \.leg)
                TableColumn("Symbol", value: \.symbol)
                TableColumn("Dir", value: \.dir)
                TableColumn("Entry", value: \.entry)
                TableColumn("SL", value: \.sl)
                TableColumn("TP", value: \.tp)
                TableColumn("Status", value: \.status)
            }
            .frame(minHeight: 320)

            HStack {
                Text("\(model.records.count) signals")
                    .foregroundColor(.secondary)
                Spacer()
                Button("Open Log File (CSV)") { model.openLogFile() }
                Button("Clear Table") { model.clearTable() }
            }
        }
        .padding(16)
        .frame(minWidth: 940, minHeight: 560)
    }
}
