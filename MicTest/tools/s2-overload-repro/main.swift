import Foundation
let s = Task {
    let c = GeminiClient()
    print("concrete:", try await callSite(client: c))
    print("existential:", try await viaExistential(c))
}
_ = try await s.value
