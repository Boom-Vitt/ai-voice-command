import Foundation

/// Delivers text into whatever app currently has keyboard focus.
///
/// Ported from PhayaVoice's Contract.swift. Only this one protocol came across:
/// that file also declared a `DictationHUD` *protocol*, which would collide with
/// this module's `DictationHUD` *class*, so wholesale porting was not an option.
protocol TextInjecting: AnyObject {
    /// Returns nil on success, or a human-readable reason it could not inject.
    @MainActor func inject(_ text: String) -> String?
    /// True if the frontmost app is holding Secure Event Input (password field,
    /// Terminal secure entry, or a Cursor/Electron leak) -- injection is unsafe.
    @MainActor func secureInputActive() -> Bool
}
