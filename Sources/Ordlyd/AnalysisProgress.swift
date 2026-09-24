import Foundation

enum AnalysisStage: Equatable {
    case preparing, awaitingIDUN, processingResponse

    var title: String {
        switch self {
        case .preparing: "Klargjør forespørselen"
        case .awaitingIDUN: "IDUN lager oppsummering"
        case .processingResponse: "Kontrollerer oppsummeringen"
        }
    }

    var detail: String {
        switch self {
        case .preparing: "Prompt og transkripsjon gjøres klar."
        case .awaitingIDUN: "Venter på svar fra valgt IDUN-modell. Dette kan ta et par minutter."
        case .processingResponse: "Svar og evidens knyttes til transkripsjonen."
        }
    }
}
