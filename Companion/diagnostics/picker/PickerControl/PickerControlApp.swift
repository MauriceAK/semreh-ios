import SwiftUI
import UniformTypeIdentifiers

@main
struct PickerControlApp: App {
    var body: some Scene {
        WindowGroup { PickerHost() }
    }
}

private struct PickerHost: View {
    @State private var pickerPresented = false
    @State private var hasPresented = false

    var body: some View {
        VStack(spacing: 24) {
            Text(pickerPresented ? "Picker presented" : hasPresented ? "Picker dismissed" : "Host ready")
                .accessibilityIdentifier("pickerState")
            Button("Open Files") {
                hasPresented = true
                pickerPresented = true
            }
            .accessibilityIdentifier("openPicker")
        }
        .fileImporter(isPresented: $pickerPresented, allowedContentTypes: [.item], allowsMultipleSelection: true) { _ in }
    }
}
