import SwiftUI

/// Cornell Lab'in ücretsiz Merlin Bird ID uygulaması: ikinci görüş için.
/// Merlin'in modeli başka uygulamalara gömülemez (kullanım koşulları; açık API/SDK yok); bu yüzden
/// uygulamaya devredilir. Yüklüyse App Store sayfasındaki "Aç" ile, değilse indirme sayfasıyla açılır.
struct MerlinLink: View {
    static let url = URL(string: "https://apps.apple.com/app/id773457673")!

    var body: some View {
        Link(destination: Self.url) {
            Label("Merlin Bird ID ile ikinci görüş (Cornell Lab, ücretsiz)", systemImage: "arrow.up.forward.app")
        }
    }
}
