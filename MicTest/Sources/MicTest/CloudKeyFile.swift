//  CloudKeyFile.swift
//
//  The dotenv-style secrets file every cloud client reads, and the two small helpers that
//  used to live inside `FalClient`.
//
//  ── WHY THIS FILE EXISTS ─────────────────────────────────────────────────────────────
//
//  The cloud pass was fal Scribe v2; it is now Gemini. When fal was removed, three utilities
//  had to survive it because `GeminiClient` and `GeminiLiveRecognizer` had been reusing them
//  rather than growing second copies: the key-file path, the dotenv parser, and the keyterm
//  clamp. `main.swift` said so explicitly at the time:
//
//      * `FalClient.swift` is retained and STILL COMPILED IN. Nothing in *this* file
//        touches it and no audio goes to fal, but `GeminiClient` reuses its key loader,
//        its env-file path and its keyterm sanitizer rather than growing second copies of
//        all three. Deleting it would break the build, not merely tidy up.
//
//  Deleting fal therefore meant giving those three a home that is not named after a vendor
//  the app no longer talks to. That is all this file is. The behaviour is unchanged except
//  for the one deliberate hardening below.
//
//  ── THE ONE DELIBERATE CHANGE: `name:` IS NO LONGER OPTIONAL ─────────────────────────
//
//  `FalClient.loadKey(from:name:)` defaulted `name` to `FAL_KEY`, and both Gemini call sites
//  carried a paragraph of comment warning what happened if you forgot the label:
//
//      Omitting the label here would compile, read the fal key out of the very same file,
//      and POST it to Google in the `x-goog-api-key` header: a cross-vendor key leak from a
//      missing argument label.
//
//  A hazard that needs a warning comment at every call site is a hazard in the signature.
//  There is no longer a sensible default — no caller is "the default vendor" — so `name` is
//  required, and the leak is now a compile error instead of a comment. The warnings those
//  call sites carried have been replaced by a pointer here.
//
//  The thrown error names the variable that was actually missing, too. `FalClient`'s
//  `missingKey` always said "No FAL_KEY found" whichever key you asked for, which is why
//  `GeminiClient` had to catch it and re-throw its own to avoid telling a user to create a
//  key they already had. That translation is still fine to keep — the point is that the
//  message underneath is no longer wrong.

import Foundation

/// Reads `~/.config/thaidictate/env`. A namespace, never instantiated.
enum CloudKeyFile {

    /// Where the file lives, relative to the user's home directory.
    ///
    /// One copy, deliberately. `GeminiClient.defaultKeyFileURL()` delegates here rather than
    /// re-deriving the components, so "the same file for every provider" holds by
    /// construction and cannot drift if the location ever moves.
    private static let pathComponents = [".config", "thaidictate", "env"]

    /// Maximum bias terms kept by ``clampTerms(_:)``.
    ///
    /// Inherited from fal's documented request limits, and now serving a different purpose:
    /// with Gemini the terms are pasted into a prompt, so this is a bound on prompt growth,
    /// not an API constraint. An unclamped word list appended to an instruction is exactly
    /// the "wandering prompt" that makes output irreproducible, quite apart from the tokens
    /// it bills. Kept at the old values because they were never the binding constraint and
    /// changing them would silently change transcripts.
    static let maxTerms = 100
    /// Maximum characters per term. Same provenance as ``maxTerms``.
    static let maxTermLength = 50

    // MARK: - Errors

    enum KeyFileError: Error, LocalizedError {
        /// No usable assignment on disk. Carries the path we looked at AND the variable we
        /// looked for, so the message can name both — the failure is almost always "the
        /// file exists but has the other provider's line in it".
        case missingKey(path: String, name: String)

        var errorDescription: String? {
            switch self {
            case .missingKey(let path, let name):
                return """
                    No \(name) found. Create \(path) containing one line, \
                    `\(name)=<your key>`, then `chmod 600` it.
                    """
            }
        }
    }

    // MARK: - Location

    /// `~/.config/thaidictate/env`, resolved through `FileManager` so the tilde is a real
    /// home directory and not a literal path component.
    static func defaultURL() -> URL {
        var url = FileManager.default.homeDirectoryForCurrentUser
        for component in pathComponents {
            url.appendPathComponent(component)
        }
        return url
    }

    // MARK: - Parsing

    /// Parses `<name>=<value>` out of a dotenv-style file.
    ///
    /// Tolerates comments, blank lines, `export ` prefixes, surrounding quotes, and spaces
    /// around the `=`. Everything else is ignored. The parser is variable-name-agnostic on
    /// purpose: one file carries every provider's key, one line each.
    ///
    /// - Parameters:
    ///   - url: The dotenv-style file to read.
    ///   - name: Which assignment to return. **Required** — see the note at the top of this
    ///     file for why this has no default.
    /// - Throws: ``KeyFileError/missingKey(path:name:)`` for every failure — absent file,
    ///   unreadable file, no such assignment, empty value. Never traps, and never returns an
    ///   empty string.
    static func loadKey(from url: URL, name: String) throws -> String {
        // `Data(contentsOf:)` rather than `String(contentsOf:)`: the String overload without
        // an explicit encoding is deprecated on current SDKs.
        guard let data = try? Data(contentsOf: url) else {
            throw KeyFileError.missingKey(path: url.path, name: name)
        }
        let contents = String(decoding: data, as: UTF8.self)

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }

            guard let eq = line.firstIndex(of: "=") else { continue }
            // `assigned`, not `name`: the parameter owns that identifier now. Shadowing it
            // here would silently turn the guard into a tautology and hand back whichever
            // assignment came first in the file.
            let assigned = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard assigned == name else { continue }

            var value = line[line.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
            // Strip one matched pair of surrounding quotes, if present.
            if value.count >= 2,
               let first = value.first, let last = value.last,
               first == last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            guard !value.isEmpty else { break }
            return value
        }

        throw KeyFileError.missingKey(path: url.path, name: name)
    }

    // MARK: - Keyterms

    /// Clamp a caller's bias vocabulary to ``maxTerms`` × ``maxTermLength``.
    ///
    /// Trims each term, drops the empties, truncates anything over-long, de-duplicates, and
    /// keeps at most ``maxTerms``. Truncating is the deliberate choice over erroring: a
    /// slightly shortened bias list still produces a usable transcript, whereas a rejected
    /// request produces nothing.
    ///
    /// The de-duplication and trimming are why callers can safely join the result onto one
    /// comma-separated prompt line: no surviving term can carry a newline that would break
    /// the prompt's structure.
    static func clampTerms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        out.reserveCapacity(min(terms.count, maxTerms))

        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let clipped = trimmed.count > maxTermLength
                ? String(trimmed.prefix(maxTermLength))
                : trimmed
            guard seen.insert(clipped).inserted else { continue }
            out.append(clipped)
            if out.count == maxTerms { break }
        }
        return out
    }
}
