import SwiftUI

/// M0 bring-up screen. Live status is added only after its milestone passes.
struct DebugView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("HeadsUp").font(.largeTitle)
            Text("Awareness aid · M0 bring-up").font(.headline)
            Text("Camera and band are not connected.")
            Text("The camera covers where you look. Use alongside your white cane.")
            Text("Default lead time: \(Config.leadTimeDefault, specifier: "%.1f") s")
            Text("Camera calibration: not measured")
        }
        .padding()
    }
}
