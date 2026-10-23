import SwiftUI

// Dueño: agente "design-system". Placeholder con firma congelada.
struct CelebrationView: View {
    let reward: SessionReward
    let post: PostResponse?
    let onClose: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Text("Pausa cumplida").font(.largeTitle.weight(.heavy))
            Text("Día \(reward.dayInBlock) de 7").font(.title2)
            PrimaryButton(title: "LISTO") { onClose() }
        }
        .padding()
        .appScreen()
    }
}
