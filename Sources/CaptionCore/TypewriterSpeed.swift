import Foundation

/// Display cadence, not a conversion from model tokens to language characters.
public enum TypewriterSpeedMapping {
    public static let minimumCharactersPerSecond = 5.0
    public static let maximumCharactersPerSecond = 60.0
    public static let maximumTokensPerSecond = 1000.0
    private static let scale = 10.0
    private static let normalization = log(maximumTokensPerSecond / scale)

    public static func boundedTokens(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return min(maximumTokensPerSecond, value)
    }

    public static func charactersPerSecond(tokensPerSecond: Double?, fallback: Double = 15) -> Double {
        guard let tokens = boundedTokens(tokensPerSecond) else {
            return fallback.isFinite ? min(40, max(minimumCharactersPerSecond, fallback)) : 15
        }
        return minimumCharactersPerSecond + (maximumCharactersPerSecond - minimumCharactersPerSecond)
            * log(max(scale, tokens) / scale) / normalization
    }
}
