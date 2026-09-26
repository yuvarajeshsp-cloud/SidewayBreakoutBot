import Foundation

/// One row of the on-screen table / one line of signal_log.csv.
struct SignalRecord: Identifiable {
    let id = UUID()
    let time: String
    let action: String
    let groupId: String
    let leg: String
    let symbol: String
    let dir: String
    let entry: String
    let sl: String
    let tp: String
    let status: String
}
