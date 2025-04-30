//
//  FallbackView.swift
//  AVAR
//
//  Created by Roberto Riquelme on 22-04-25.
//

import SwiftUI

struct FallbackView: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace

    var body: some View {
        VStack(spacing: 12) {
            Text("Launching immersive space...")
                .font(.title)
                .onAppear {
                    Task {
                        await openImmersiveSpace(id: "MainImmersive")
                    }
                }

            ProgressView()
        }
        .padding()
    }
}
