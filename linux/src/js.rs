//! JS string literal encoding, mirroring `Sources/TVMVCore/JSString.swift`.

/// JSON-encode a string into a safe JS string literal for building
/// `evaluate_javascript` calls.
pub fn literal(value: &str) -> String {
    // JSON string syntax is a subset of JS string syntax, with one historical
    // exception: U+2028/U+2029 are legal unescaped in JSON but were line
    // terminators in JS before ES2019. Escaping them costs nothing and removes
    // the question.
    serde_json::to_string(value)
        .unwrap_or_else(|_| "\"\"".to_string())
        .replace('\u{2028}', "\\u2028")
        .replace('\u{2029}', "\\u2029")
}
