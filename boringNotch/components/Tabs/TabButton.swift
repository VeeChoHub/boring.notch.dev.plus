//
//  TabButton.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-24.
//

import SwiftUI

struct TabButton: View {
    let label: String
    let icon: String
    let selected: Bool
    let onClick: () -> Void
    
    var body: some View {
        Button(action: onClick) {
            // icon: asset del catalogo (es. "claude") o SF Symbol
            Group {
                if NSImage(named: icon) != nil {
                    Image(icon).renderingMode(.template).resizable().scaledToFit().frame(width: 15, height: 15)
                } else {
                    Image(systemName: icon)
                }
            }
            .padding(.horizontal, 15)
            .contentShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

#Preview {
    TabButton(label: "Home", icon: "tray.fill", selected: true) {
        print("Tapped")
    }
}
