// The arm64 goldens, from the same pre-split chain as the x86_64 ones. Apple silicon renders
// different sample bits from Intel for 19 of the 42 keys, so each arch holds the split to that
// chain's own samples on that arch. Only the sample hashes differ: Shuffle's presets and states and
// the saved files are the same on both.
// Every key with the camcorder mic at its default whine is rendered at 1250 Hz: look.camcorder,
// look.home-movie-1986, preset.camcorder, wear60.camcorder, damage.camcorder, and Shuffle's samples
// for the seeds that roll the mic on. The file.* keys carry their own 1600 Hz. The Shuffle states
// follow the mic's current parameter list, and Shuffle still spends the removed zoom sliders' draws.
// Seed 20's row here is not read (the test holds it to the Linear NR golden), so it stays.

extension AudioSplitGoldens {
    static let samplesArm64: [String: String] = [
        "damage.camcorder": "1485d4166af16bcc",
        "damage.eplinear": "ab3dd5745bc7bef5",
        "damage.hifi": "9f9de65daa65e298",
        "damage.linear": "ae431f5965147089",
        "damage.off": "e857995d3daa1d51",
        "damage.wornlinear": "3f104fdb8746ced",
        "default": "c1f0cd5c3de868fb",
        "file.camcorder": "b30a26389d0edfd7",
        "file.camcorder-tuned": "e552b3dfb5dde9c7",
        "file.eplinear": "74585fd1d488b029",
        "file.hifi": "c1f0cd5c3de868fb",
        "file.linear": "ba728c582a87b135",
        "file.off": "e857995d3daa1d51",
        "file.shoebox": "30ac71e5cd4c8899",
        "file.wornlinear": "22ec1b37ffa73b21",
        "look.attic-tape": "22ec1b37ffa73b21",
        "look.camcorder": "d609e08c38fc7277",
        "look.clean-sp": "c1f0cd5c3de868fb",
        "look.dub-of-a-dub": "198e76a6ee3941c2",
        "look.good-deck": "c1f0cd5c3de868fb",
        "look.home-movie-1986": "50020ce32ef3bec5",
        "look.hot-car": "c1f0cd5c3de868fb",
        "look.off-air": "c1f0cd5c3de868fb",
        "look.off-the-tv": "c1f0cd5c3de868fb",
        "look.rental": "74585fd1d488b029",
        "look.s-vhs": "c1f0cd5c3de868fb",
        "look.six-hour-tape": "74585fd1d488b029",
        "look.sticky-shed": "496a7cac334d06d0",
        "look.transfer-1986": "ba728c582a87b135",
        "look.wedding-video": "c1f0cd5c3de868fb",
        "preset.camcorder": "d609e08c38fc7277",
        "preset.eplinear": "74585fd1d488b029",
        "preset.hifi": "c1f0cd5c3de868fb",
        "preset.linear": "ba728c582a87b135",
        "preset.off": "e857995d3daa1d51",
        "preset.wornlinear": "22ec1b37ffa73b21",
        "wear60.camcorder": "17c2dac6e41c8745",
        "wear60.eplinear": "3adb1ab827c95c09",
        "wear60.hifi": "981afdcc06789cf1",
        "wear60.linear": "76bbb847cfb24a2d",
        "wear60.off": "e857995d3daa1d51",
        "wear60.wornlinear": "1c289f67911be815",
    ]

    static let shuffleArm64: [String: [String]] = [
        "1": ["eplinear", "ab5fd904fe0939c2", "2a44a8af1e311ff9"],
        "2": ["linear", "366b1250ff155992", "9dc70b105c7c12c9"],
        "3": ["wornlinear", "be28d7f0e688b494", "f214b635bdf39429"],
        "4": ["eplinear", "8dbedd85703e3980", "5354e956a3d0340d"],
        "5": ["camcorder", "f478f570808edad5", "fff259fc9616f776"],
        "6": ["hifi", "b530682fc237f63d", "2a3fecca71467400"],
        "7": ["linear", "a37e049b44d5d940", "2af4d8df8a61b41"],
        "8": ["wornlinear", "c36780e044a2c47f", "54533d489ce65cb5"],
        "9": ["camcorder", "51343bc407c73bf3", "983f6d6852ac7ef5"],
        "10": ["hifi", "b5482ccb0df6c6c2", "4a03cc46bfb3e354"],
        "11": ["camcorder", "a039bb4b604b2978", "412aeba33420f264"],
        "12": ["camcorder", "5fdbd76a5ac260c1", "eb7b4eea1031dec5"],
        "13": ["hifi", "5abd490592183cae", "56d62c541cca7b35"],
        "14": ["linear", "8d70bbb277f11ba0", "5f2b20237a4f25cd"],
        "15": ["linear", "9dcd18950f72d8ae", "1826b4e185aec59"],
        "16": ["linear", "e1626aa764751e08", "530a38485f6b20f9"],
        "17": ["eplinear", "f3c819c4a50d7d52", "13c7c812b4822335"],
        "18": ["linear", "7038ead045ccd344", "745f75b0ea506701"],
        "19": ["hifi", "40e1c0bd50483eb0", "57652d1f870b313b"],
        "20": ["hifi", "303ea28e1c13082f", "1e22d4573d093ebf"],
        "21": ["linear", "beba503eb0745c27", "97a4ca6d448425a7"],
        "22": ["hifi", "793fba2713dcbc9f", "930a128d51bf751"],
        "23": ["hifi", "852b78829f25a3a3", "862cb76ecce0196d"],
        "24": ["hifi", "2727111ea07126c", "1c0b7fabe5e06e27"],
        "25": ["wornlinear", "827ec3fa1d7dc3c5", "7198bc8043d06a1d"],
        "26": ["hifi", "66cf4f05e424d82e", "c16a176a420f49a6"],
        "27": ["hifi", "a5d5559f7e100541", "56147a3b073c806c"],
        "28": ["wornlinear", "c823d64959c5dc5b", "e91b0b426177ba0d"],
        "29": ["eplinear", "6b773d63071ae7ee", "244350486cbf315"],
        "30": ["wornlinear", "1edf8c34c472551", "b7100fc4db3abae5"],
    ]

    #if arch(arm64)
    static var samples: [String: String] { samplesArm64 }
    static var shuffle: [String: [String]] { shuffleArm64 }
    #else
    static var samples: [String: String] { samplesX86 }
    static var shuffle: [String: [String]] { shuffleX86 }
    #endif
}
