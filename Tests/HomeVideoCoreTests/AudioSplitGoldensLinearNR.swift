// The Linear NR track has no pre-split golden, so these are its own renders of
// `AudioSplitTests.input()` on arm64 and on x86_64, held so the track does not drift. The sample
// bits differ by arch like the other goldens (AudioSplitGoldensArm64.swift). Shuffle's seed 20
// rolls on Fresh SP and keeps its sound, which is Linear NR.

extension AudioSplitGoldens {
    static let linearNRArm64: [String: String] = [
        "preset.linearnr": "e200bcade1706d25",
        "wear60.linearnr": "15a9d5b126d8c609",
        "damage.linearnr": "eb5c0f07203fa421",
        "shuffle20.state": "f5567218ed57875f",
        "shuffle20.samples": "16d7b458ce962f51",
    ]

    static let linearNRX86: [String: String] = [
        "preset.linearnr": "4745f9df55dba881",
        "wear60.linearnr": "d61159e580826c25",
        "damage.linearnr": "e9bd53c2580ab145",
        "shuffle20.state": "f5567218ed57875f",
        "shuffle20.samples": "1349156bcfab16c9",
    ]

    #if arch(arm64)
    static var linearNR: [String: String] { linearNRArm64 }
    #else
    static var linearNR: [String: String] { linearNRX86 }
    #endif
}
