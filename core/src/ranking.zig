const std = @import("std");

pub const REVISION = "ws-ranking-calibration-v2";
pub const SCALE: u64 = 1_000_000_000;

/// Conservative identity confidence. Vote support gates a high raw coverage
/// score so short/repetitive clips cannot dominate from a few coincidences.
pub fn fingerprintConfidence(score_ppm: u32, votes: u32) u64 {
    if (votes < 3 or score_ppm < 30_000) return 0;
    const vote_factor: u64 = @min(@as(u64, 1_000_000), @as(u64, votes) * 100_000);
    return @as(u64, score_ppm) * vote_factor / 1_000;
}

/// Piecewise CLAP cosine calibration derived from the held-out opaque-name
/// acceptance set. Below 0.05 is treated as unsupported similarity; 0.45 and
/// above saturates. Keeping this integer-valued makes ties portable.
pub fn semanticConfidence(cosine: f32) u64 {
    if (!std.math.isFinite(cosine) or cosine <= 0.05) return 0;
    if (cosine >= 0.45) return SCALE;
    const scaled = (@as(f64, cosine) - 0.05) / 0.40;
    return @intFromFloat(scaled * SCALE);
}

test "confidence calibration is monotonic and vote gated" {
    try std.testing.expectEqual(@as(u64, 0), fingerprintConfidence(900_000, 2));
    try std.testing.expect(fingerprintConfidence(200_000, 10) > fingerprintConfidence(100_000, 10));
    try std.testing.expectEqual(@as(u64, 0), semanticConfidence(0.01));
    try std.testing.expect(semanticConfidence(0.3) > semanticConfidence(0.2));
    try std.testing.expectEqual(SCALE, semanticConfidence(0.8));
}
