import SwiftUI
import UIKit
import Combine

extension View {
    func sessionsScreenListRow(insets: EdgeInsets = EdgeInsets()) -> some View {
        listRowInsets(insets)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    func sessionsTopChromeListRow() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 18, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .zIndex(1)
    }

    func sessionsChromeGlass<S: InsettableShape>(
        isInteractive: Bool = false,
        tint: Color? = nil,
        fallbackMaterial: Material = .ultraThinMaterial,
        in shape: S
    ) -> some View {
        adaptiveGlass(
            .regular,
            isInteractive: isInteractive,
            tint: tint,
            fallbackMaterial: fallbackMaterial,
            in: shape
        )
    }
}

extension View {
    func sidebarSubrowSelectionStyle(isSelected: Bool) -> some View {
        modifier(SidebarSubrowSelectionStyle(isSelected: isSelected))
    }
}
