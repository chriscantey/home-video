// Goldens from the audio chain as it stood before the split into mic and track, rendered on an
// Intel Mac: sample hashes of that chain on `AudioSplitTests.input()`, Shuffle's audio for seeds 1
// to 30, and the sidecar and saved preset it wrote for each old audio preset, the tuned Camcorder
// and the Shoebox Look. The picture layers are cut from the files (a sidecar without them reads
// the picture defaults, a preset's list is empty), since only the audio is under test.
// The keys with the camcorder mic at its default whine are rendered at 1250 Hz on both arches
// (AudioSplitGoldensArm64.swift lists them). The files keep their own 1600 Hz.

enum AudioSplitGoldens {
    static let samplesX86: [String: String] = [
        "damage.camcorder": "1485d4166af16bcc",
        "damage.eplinear": "54392ec73022f295",
        "damage.hifi": "9f9de65daa65e298",
        "damage.linear": "1509b4fd5514e085",
        "damage.off": "e857995d3daa1d51",
        "damage.wornlinear": "e86cc63343ba8ce1",
        "default": "c1f0cd5c3de868fb",
        "file.camcorder": "b30a26389d0edfd7",
        "file.camcorder-tuned": "e552b3dfb5dde9c7",
        "file.eplinear": "89b77e5eaa57ca79",
        "file.hifi": "c1f0cd5c3de868fb",
        "file.linear": "6772b7a0415158d5",
        "file.off": "e857995d3daa1d51",
        "file.shoebox": "3d890da1c9309d91",
        "file.wornlinear": "c99ee8ec6da8c585",
        "look.attic-tape": "c99ee8ec6da8c585",
        "look.camcorder": "d609e08c38fc7277",
        "look.clean-sp": "c1f0cd5c3de868fb",
        "look.dub-of-a-dub": "e80d68eeb8592532",
        "look.good-deck": "c1f0cd5c3de868fb",
        "look.home-movie-1986": "3bc0728ba5ad41ed",
        "look.hot-car": "c1f0cd5c3de868fb",
        "look.off-air": "c1f0cd5c3de868fb",
        "look.off-the-tv": "c1f0cd5c3de868fb",
        "look.rental": "89b77e5eaa57ca79",
        "look.s-vhs": "c1f0cd5c3de868fb",
        "look.six-hour-tape": "89b77e5eaa57ca79",
        "look.sticky-shed": "496a7cac334d06d0",
        "look.transfer-1986": "6772b7a0415158d5",
        "look.wedding-video": "c1f0cd5c3de868fb",
        "preset.camcorder": "d609e08c38fc7277",
        "preset.eplinear": "89b77e5eaa57ca79",
        "preset.hifi": "c1f0cd5c3de868fb",
        "preset.linear": "6772b7a0415158d5",
        "preset.off": "e857995d3daa1d51",
        "preset.wornlinear": "c99ee8ec6da8c585",
        "wear60.camcorder": "17c2dac6e41c8745",
        "wear60.eplinear": "46b44ac1ec1ade29",
        "wear60.hifi": "981afdcc06789cf1",
        "wear60.linear": "cee50b7da88247dd",
        "wear60.off": "e857995d3daa1d51",
        "wear60.wornlinear": "668d5c245c42d05",
    ]

    static let shuffleX86: [String: [String]] = [
        "1": ["eplinear", "ab5fd904fe0939c2", "d812862bd40279b7"],
        "2": ["linear", "366b1250ff155992", "88b67959bfdf921d"],
        "3": ["wornlinear", "be28d7f0e688b494", "5b15a3935e3f2805"],
        "4": ["eplinear", "8dbedd85703e3980", "5354e956a3d0340d"],
        "5": ["camcorder", "f478f570808edad5", "fff259fc9616f776"],
        "6": ["hifi", "b530682fc237f63d", "2a3fecca71467400"],
        "7": ["linear", "a37e049b44d5d940", "2af4d8df8a61b41"],
        "8": ["wornlinear", "c36780e044a2c47f", "a62b00e35a7197a8"],
        "9": ["camcorder", "51343bc407c73bf3", "983f6d6852ac7ef5"],
        "10": ["hifi", "b5482ccb0df6c6c2", "4a03cc46bfb3e354"],
        "11": ["camcorder", "a039bb4b604b2978", "412aeba33420f264"],
        "12": ["camcorder", "5fdbd76a5ac260c1", "eb7b4eea1031dec5"],
        "13": ["hifi", "5abd490592183cae", "56d62c541cca7b35"],
        "14": ["linear", "8d70bbb277f11ba0", "fb31eab7119d8c79"],
        "15": ["linear", "9dcd18950f72d8ae", "80336905c1540ba1"],
        "16": ["linear", "e1626aa764751e08", "530a38485f6b20f9"],
        "17": ["eplinear", "f3c819c4a50d7d52", "3a6804ef33fcd259"],
        "18": ["linear", "7038ead045ccd344", "d75eb5eb6dddb70d"],
        "19": ["hifi", "40e1c0bd50483eb0", "57652d1f870b313b"],
        "20": ["hifi", "303ea28e1c13082f", "1e22d4573d093ebf"],
        "21": ["linear", "beba503eb0745c27", "30cd90ba1b1c9060"],
        "22": ["hifi", "793fba2713dcbc9f", "930a128d51bf751"],
        "23": ["hifi", "852b78829f25a3a3", "862cb76ecce0196d"],
        "24": ["hifi", "2727111ea07126c", "1c0b7fabe5e06e27"],
        "25": ["wornlinear", "827ec3fa1d7dc3c5", "eba4fac0016faced"],
        "26": ["hifi", "66cf4f05e424d82e", "c16a176a420f49a6"],
        "27": ["hifi", "a5d5559f7e100541", "3ac31412f6fc8faa"],
        "28": ["wornlinear", "c823d64959c5dc5b", "b50b9a9f7a1e5535"],
        "29": ["eplinear", "6b773d63071ae7ee", "718737005cfe41f1"],
        "30": ["wornlinear", "1edf8c34c472551", "ffb57ab7a1668f15"],
    ]

    static let sidecars: [String: String] = [
        "camcorder": #"""
            {
              "audio": "camcorder",
              "audioLayers": [
                {
                  "enabled": true,
                  "id": "audio-camcorder",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -44
                    },
                    {
                      "id": "whine",
                      "value": 1600
                    },
                    {
                      "id": "zoomRate",
                      "value": 1
                    },
                    {
                      "id": "zoomLength",
                      "value": 2
                    },
                    {
                      "id": "lift",
                      "value": 12
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-compressor",
                  "parameters": [
                    {
                      "id": "attack",
                      "value": 5
                    },
                    {
                      "id": "release",
                      "value": 100
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-fm-noise",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -48
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-click",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -55
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-expander",
                  "parameters": [
                    {
                      "id": "attack",
                      "value": 5
                    },
                    {
                      "id": "release",
                      "value": 100
                    },
                    {
                      "id": "tracking",
                      "value": 0.5
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-band",
                  "parameters": [
                    {
                      "id": "highpass",
                      "value": 20
                    },
                    {
                      "id": "lowpass",
                      "value": 20000
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-dropout",
                  "parameters": [
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "length",
                      "value": 150
                    },
                    {
                      "id": "click",
                      "value": -30
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-mono",
                  "parameters": []
                },
                {
                  "enabled": false,
                  "id": "audio-damage-glide",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-flutter",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-azimuth",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-clog",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 1
                    },
                    {
                      "id": "seed",
                      "value": 0
                    },
                    {
                      "id": "follow",
                      "value": true
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-worn",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 1.5
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-crackle",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 4
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-hifi",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 3
                    },
                    {
                      "id": "seed",
                      "value": 0
                    },
                    {
                      "id": "offset",
                      "value": 2
                    },
                    {
                      "id": "click",
                      "value": -30
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-mute",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 3
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                }
              ],
              "formatVersion": 2,
              "framing": {
                "mode": "cropCenter",
                "pan": 0,
                "panY": 0,
                "rotation": 0,
                "zoom": 1
              },
              "kind": "homevideo-sidecar",
              "look": null,
              "name": "camcorder",
              "version": 1
            }
            """#,
        "camcorder-tuned": #"""
            {
              "audio": "camcorder",
              "audioLayers": [
                {
                  "enabled": true,
                  "id": "audio-camcorder",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -38
                    },
                    {
                      "id": "whine",
                      "value": 1600
                    },
                    {
                      "id": "zoomRate",
                      "value": 6
                    },
                    {
                      "id": "zoomLength",
                      "value": 2
                    },
                    {
                      "id": "lift",
                      "value": 12
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-compressor",
                  "parameters": [
                    {
                      "id": "attack",
                      "value": 5
                    },
                    {
                      "id": "release",
                      "value": 100
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-fm-noise",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -43.2
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-click",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -51.1
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-expander",
                  "parameters": [
                    {
                      "id": "attack",
                      "value": 5
                    },
                    {
                      "id": "release",
                      "value": 100
                    },
                    {
                      "id": "tracking",
                      "value": 1.1
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-band",
                  "parameters": [
                    {
                      "id": "highpass",
                      "value": 59
                    },
                    {
                      "id": "lowpass",
                      "value": 15800
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-dropout",
                  "parameters": [
                    {
                      "id": "rate",
                      "value": 7.3999999999999995
                    },
                    {
                      "id": "length",
                      "value": 225
                    },
                    {
                      "id": "click",
                      "value": -30
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-mono",
                  "parameters": []
                },
                {
                  "enabled": false,
                  "id": "audio-damage-glide",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-flutter",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-azimuth",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-clog",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 1
                    },
                    {
                      "id": "seed",
                      "value": 0
                    },
                    {
                      "id": "follow",
                      "value": true
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-worn",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 1.5
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-crackle",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 4
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-hifi",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 3
                    },
                    {
                      "id": "seed",
                      "value": 0
                    },
                    {
                      "id": "offset",
                      "value": 2
                    },
                    {
                      "id": "click",
                      "value": -30
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-mute",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 3
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                }
              ],
              "audioWear": 30,
              "formatVersion": 2,
              "framing": {
                "mode": "cropCenter",
                "pan": 0,
                "panY": 0,
                "rotation": 0,
                "zoom": 1
              },
              "kind": "homevideo-sidecar",
              "look": null,
              "name": "camcorder-tuned",
              "version": 1
            }
            """#,
        "eplinear": #"""
            {
              "audio": "eplinear",
              "audioLayers": [
                {
                  "enabled": false,
                  "id": "audio-camcorder",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -44
                    },
                    {
                      "id": "whine",
                      "value": 1600
                    },
                    {
                      "id": "zoomRate",
                      "value": 1
                    },
                    {
                      "id": "zoomLength",
                      "value": 2
                    },
                    {
                      "id": "lift",
                      "value": 12
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-mono",
                  "parameters": []
                },
                {
                  "enabled": true,
                  "id": "audio-saturation",
                  "parameters": [
                    {
                      "id": "drive",
                      "value": 0.3
                    },
                    {
                      "id": "emphasis",
                      "value": 6
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-band",
                  "parameters": [
                    {
                      "id": "speed",
                      "value": "ep"
                    },
                    {
                      "id": "highpass",
                      "value": 100
                    },
                    {
                      "id": "lowpass",
                      "value": 6000
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-azimuth",
                  "parameters": [
                    {
                      "id": "gain",
                      "value": -3
                    },
                    {
                      "id": "frequency",
                      "value": 2000
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-bump",
                  "parameters": [
                    {
                      "id": "gain",
                      "value": 2
                    },
                    {
                      "id": "frequency",
                      "value": 80
                    },
                    {
                      "id": "q",
                      "value": 1
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-wow",
                  "parameters": [
                    {
                      "id": "depth",
                      "value": 0.3
                    },
                    {
                      "id": "wow",
                      "value": 0.5
                    },
                    {
                      "id": "flutter",
                      "value": 0.5
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-hiss",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -42
                    },
                    {
                      "id": "color",
                      "value": "pink"
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-whine",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -60
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-dolby",
                  "parameters": [
                    {
                      "id": "gain",
                      "value": 4
                    },
                    {
                      "id": "frequency",
                      "value": 5000
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-glide",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-flutter",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-azimuth",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-clog",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 1
                    },
                    {
                      "id": "seed",
                      "value": 0
                    },
                    {
                      "id": "follow",
                      "value": true
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-worn",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 1.5
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-crackle",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 4
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-hifi",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 3
                    },
                    {
                      "id": "seed",
                      "value": 0
                    },
                    {
                      "id": "offset",
                      "value": 2
                    },
                    {
                      "id": "click",
                      "value": -30
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-mute",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 3
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                }
              ],
              "formatVersion": 2,
              "framing": {
                "mode": "cropCenter",
                "pan": 0,
                "panY": 0,
                "rotation": 0,
                "zoom": 1
              },
              "kind": "homevideo-sidecar",
              "look": null,
              "name": "eplinear",
              "version": 1
            }
            """#,
        "hifi": #"""
            {
              "audio": "hifi",
              "audioLayers": [
                {
                  "enabled": false,
                  "id": "audio-camcorder",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -44
                    },
                    {
                      "id": "whine",
                      "value": 1600
                    },
                    {
                      "id": "zoomRate",
                      "value": 1
                    },
                    {
                      "id": "zoomLength",
                      "value": 2
                    },
                    {
                      "id": "lift",
                      "value": 12
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-compressor",
                  "parameters": [
                    {
                      "id": "attack",
                      "value": 5
                    },
                    {
                      "id": "release",
                      "value": 100
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-fm-noise",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -48
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-click",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -55
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-expander",
                  "parameters": [
                    {
                      "id": "attack",
                      "value": 5
                    },
                    {
                      "id": "release",
                      "value": 100
                    },
                    {
                      "id": "tracking",
                      "value": 0.5
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-band",
                  "parameters": [
                    {
                      "id": "highpass",
                      "value": 20
                    },
                    {
                      "id": "lowpass",
                      "value": 20000
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-dropout",
                  "parameters": [
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "length",
                      "value": 150
                    },
                    {
                      "id": "click",
                      "value": -30
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-mono",
                  "parameters": []
                },
                {
                  "enabled": false,
                  "id": "audio-damage-glide",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-flutter",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-azimuth",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-clog",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 1
                    },
                    {
                      "id": "seed",
                      "value": 0
                    },
                    {
                      "id": "follow",
                      "value": true
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-worn",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 1.5
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-crackle",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 4
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-hifi",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 3
                    },
                    {
                      "id": "seed",
                      "value": 0
                    },
                    {
                      "id": "offset",
                      "value": 2
                    },
                    {
                      "id": "click",
                      "value": -30
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-mute",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 3
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                }
              ],
              "formatVersion": 2,
              "framing": {
                "mode": "cropCenter",
                "pan": 0,
                "panY": 0,
                "rotation": 0,
                "zoom": 1
              },
              "kind": "homevideo-sidecar",
              "look": null,
              "name": "hifi",
              "version": 1
            }
            """#,
        "linear": #"""
            {
              "audio": "linear",
              "audioLayers": [
                {
                  "enabled": false,
                  "id": "audio-camcorder",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -44
                    },
                    {
                      "id": "whine",
                      "value": 1600
                    },
                    {
                      "id": "zoomRate",
                      "value": 1
                    },
                    {
                      "id": "zoomLength",
                      "value": 2
                    },
                    {
                      "id": "lift",
                      "value": 12
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-mono",
                  "parameters": []
                },
                {
                  "enabled": true,
                  "id": "audio-saturation",
                  "parameters": [
                    {
                      "id": "drive",
                      "value": 0.3
                    },
                    {
                      "id": "emphasis",
                      "value": 6
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-band",
                  "parameters": [
                    {
                      "id": "speed",
                      "value": "sp"
                    },
                    {
                      "id": "highpass",
                      "value": 100
                    },
                    {
                      "id": "lowpass",
                      "value": 10000
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-bump",
                  "parameters": [
                    {
                      "id": "gain",
                      "value": 2
                    },
                    {
                      "id": "frequency",
                      "value": 80
                    },
                    {
                      "id": "q",
                      "value": 1
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-wow",
                  "parameters": [
                    {
                      "id": "depth",
                      "value": 0.2
                    },
                    {
                      "id": "wow",
                      "value": 0.5
                    },
                    {
                      "id": "flutter",
                      "value": 0.25
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-hiss",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -42
                    },
                    {
                      "id": "color",
                      "value": "pink"
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-whine",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -60
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-dolby",
                  "parameters": [
                    {
                      "id": "gain",
                      "value": 4
                    },
                    {
                      "id": "frequency",
                      "value": 5000
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-glide",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-flutter",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-azimuth",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-clog",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 1
                    },
                    {
                      "id": "seed",
                      "value": 0
                    },
                    {
                      "id": "follow",
                      "value": true
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-worn",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 1.5
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-crackle",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 4
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-hifi",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 3
                    },
                    {
                      "id": "seed",
                      "value": 0
                    },
                    {
                      "id": "offset",
                      "value": 2
                    },
                    {
                      "id": "click",
                      "value": -30
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-mute",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 3
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                }
              ],
              "formatVersion": 2,
              "framing": {
                "mode": "cropCenter",
                "pan": 0,
                "panY": 0,
                "rotation": 0,
                "zoom": 1
              },
              "kind": "homevideo-sidecar",
              "look": null,
              "name": "linear",
              "version": 1
            }
            """#,
        "off": #"""
            {
              "audio": "off",
              "audioLayers": [
                {
                  "enabled": false,
                  "id": "audio-damage-glide",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-flutter",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-azimuth",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-clog",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 1
                    },
                    {
                      "id": "seed",
                      "value": 0
                    },
                    {
                      "id": "follow",
                      "value": true
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-worn",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 1.5
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-crackle",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 4
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-hifi",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 3
                    },
                    {
                      "id": "seed",
                      "value": 0
                    },
                    {
                      "id": "offset",
                      "value": 2
                    },
                    {
                      "id": "click",
                      "value": -30
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-mute",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 3
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                }
              ],
              "formatVersion": 2,
              "framing": {
                "mode": "cropCenter",
                "pan": 0,
                "panY": 0,
                "rotation": 0,
                "zoom": 1
              },
              "kind": "homevideo-sidecar",
              "look": null,
              "name": "off",
              "version": 1
            }
            """#,
        "shoebox": #"""
            {
              "audio": "linear",
              "audioLayers": [
                {
                  "enabled": true,
                  "id": "audio-camcorder",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -44
                    },
                    {
                      "id": "whine",
                      "value": 1600
                    },
                    {
                      "id": "zoomRate",
                      "value": 1
                    },
                    {
                      "id": "zoomLength",
                      "value": 2
                    },
                    {
                      "id": "lift",
                      "value": 12
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-mono",
                  "parameters": []
                },
                {
                  "enabled": true,
                  "id": "audio-saturation",
                  "parameters": [
                    {
                      "id": "drive",
                      "value": 0.3
                    },
                    {
                      "id": "emphasis",
                      "value": 6
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-band",
                  "parameters": [
                    {
                      "id": "speed",
                      "value": "sp"
                    },
                    {
                      "id": "highpass",
                      "value": 100
                    },
                    {
                      "id": "lowpass",
                      "value": 10000
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-bump",
                  "parameters": [
                    {
                      "id": "gain",
                      "value": 2
                    },
                    {
                      "id": "frequency",
                      "value": 80
                    },
                    {
                      "id": "q",
                      "value": 1
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-wow",
                  "parameters": [
                    {
                      "id": "depth",
                      "value": 0.2
                    },
                    {
                      "id": "wow",
                      "value": 0.5
                    },
                    {
                      "id": "flutter",
                      "value": 0.25
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-hiss",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -42
                    },
                    {
                      "id": "color",
                      "value": "pink"
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-whine",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -60
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-dolby",
                  "parameters": [
                    {
                      "id": "gain",
                      "value": 4
                    },
                    {
                      "id": "frequency",
                      "value": 5000
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-glide",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-flutter",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-azimuth",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-clog",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 1
                    },
                    {
                      "id": "seed",
                      "value": 0
                    },
                    {
                      "id": "follow",
                      "value": true
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-worn",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 1.5
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-crackle",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 4
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-hifi",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 3
                    },
                    {
                      "id": "seed",
                      "value": 0
                    },
                    {
                      "id": "offset",
                      "value": 2
                    },
                    {
                      "id": "click",
                      "value": -30
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-mute",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 3
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                }
              ],
              "formatVersion": 2,
              "framing": {
                "mode": "cropCenter",
                "pan": 0,
                "panY": 0,
                "rotation": 0,
                "zoom": 1
              },
              "kind": "homevideo-sidecar",
              "look": null,
              "name": "shoebox",
              "version": 1
            }
            """#,
        "wornlinear": #"""
            {
              "audio": "wornlinear",
              "audioLayers": [
                {
                  "enabled": false,
                  "id": "audio-camcorder",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -44
                    },
                    {
                      "id": "whine",
                      "value": 1600
                    },
                    {
                      "id": "zoomRate",
                      "value": 1
                    },
                    {
                      "id": "zoomLength",
                      "value": 2
                    },
                    {
                      "id": "lift",
                      "value": 12
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-mono",
                  "parameters": []
                },
                {
                  "enabled": true,
                  "id": "audio-saturation",
                  "parameters": [
                    {
                      "id": "drive",
                      "value": 0.3
                    },
                    {
                      "id": "emphasis",
                      "value": 6
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-band",
                  "parameters": [
                    {
                      "id": "speed",
                      "value": "sp"
                    },
                    {
                      "id": "highpass",
                      "value": 100
                    },
                    {
                      "id": "lowpass",
                      "value": 10000
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-bump",
                  "parameters": [
                    {
                      "id": "gain",
                      "value": 3
                    },
                    {
                      "id": "frequency",
                      "value": 80
                    },
                    {
                      "id": "q",
                      "value": 0.7
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-wow",
                  "parameters": [
                    {
                      "id": "depth",
                      "value": 0.4
                    },
                    {
                      "id": "wow",
                      "value": 0.5
                    },
                    {
                      "id": "flutter",
                      "value": 0.25
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-hiss",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -36
                    },
                    {
                      "id": "color",
                      "value": "pink"
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-whine",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -60
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-dolby",
                  "parameters": [
                    {
                      "id": "gain",
                      "value": 4
                    },
                    {
                      "id": "frequency",
                      "value": 5000
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-mute",
                  "parameters": [
                    {
                      "id": "rate",
                      "value": 3
                    },
                    {
                      "id": "shortest",
                      "value": 5
                    },
                    {
                      "id": "longest",
                      "value": 30
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-glide",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-flutter",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-azimuth",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-clog",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 1
                    },
                    {
                      "id": "seed",
                      "value": 0
                    },
                    {
                      "id": "follow",
                      "value": true
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-worn",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 1.5
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-crackle",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 4
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-hifi",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 3
                    },
                    {
                      "id": "seed",
                      "value": 0
                    },
                    {
                      "id": "offset",
                      "value": 2
                    },
                    {
                      "id": "click",
                      "value": -30
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-mute",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 3
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                }
              ],
              "formatVersion": 2,
              "framing": {
                "mode": "cropCenter",
                "pan": 0,
                "panY": 0,
                "rotation": 0,
                "zoom": 1
              },
              "kind": "homevideo-sidecar",
              "look": null,
              "name": "wornlinear",
              "version": 1
            }
            """#,
    ]

    static let presets: [String: String] = [
        "camcorder": #"""
            {
              "audio": "camcorder",
              "audioLayers": [
                {
                  "enabled": true,
                  "id": "audio-camcorder",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -44
                    },
                    {
                      "id": "whine",
                      "value": 1600
                    },
                    {
                      "id": "zoomRate",
                      "value": 1
                    },
                    {
                      "id": "zoomLength",
                      "value": 2
                    },
                    {
                      "id": "lift",
                      "value": 12
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-compressor",
                  "parameters": [
                    {
                      "id": "attack",
                      "value": 5
                    },
                    {
                      "id": "release",
                      "value": 100
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-fm-noise",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -48
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-click",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -55
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-expander",
                  "parameters": [
                    {
                      "id": "attack",
                      "value": 5
                    },
                    {
                      "id": "release",
                      "value": 100
                    },
                    {
                      "id": "tracking",
                      "value": 0.5
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-band",
                  "parameters": [
                    {
                      "id": "highpass",
                      "value": 20
                    },
                    {
                      "id": "lowpass",
                      "value": 20000
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-dropout",
                  "parameters": [
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "length",
                      "value": 150
                    },
                    {
                      "id": "click",
                      "value": -30
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-mono",
                  "parameters": []
                },
                {
                  "enabled": false,
                  "id": "audio-damage-glide",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-flutter",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-azimuth",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-clog",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 1
                    },
                    {
                      "id": "seed",
                      "value": 0
                    },
                    {
                      "id": "follow",
                      "value": true
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-worn",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 1.5
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-crackle",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 4
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-hifi",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 3
                    },
                    {
                      "id": "seed",
                      "value": 0
                    },
                    {
                      "id": "offset",
                      "value": 2
                    },
                    {
                      "id": "click",
                      "value": -30
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-mute",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 3
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                }
              ],
              "layers": [],
              "name": "camcorder",
              "version": 1
            }
            """#,
        "camcorder-tuned": #"""
            {
              "audio": "camcorder",
              "audioLayers": [
                {
                  "enabled": true,
                  "id": "audio-camcorder",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -38
                    },
                    {
                      "id": "whine",
                      "value": 1600
                    },
                    {
                      "id": "zoomRate",
                      "value": 6
                    },
                    {
                      "id": "zoomLength",
                      "value": 2
                    },
                    {
                      "id": "lift",
                      "value": 12
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-compressor",
                  "parameters": [
                    {
                      "id": "attack",
                      "value": 5
                    },
                    {
                      "id": "release",
                      "value": 100
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-fm-noise",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -43.2
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-click",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -51.1
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-expander",
                  "parameters": [
                    {
                      "id": "attack",
                      "value": 5
                    },
                    {
                      "id": "release",
                      "value": 100
                    },
                    {
                      "id": "tracking",
                      "value": 1.1
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-band",
                  "parameters": [
                    {
                      "id": "highpass",
                      "value": 59
                    },
                    {
                      "id": "lowpass",
                      "value": 15800
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-dropout",
                  "parameters": [
                    {
                      "id": "rate",
                      "value": 7.3999999999999995
                    },
                    {
                      "id": "length",
                      "value": 225
                    },
                    {
                      "id": "click",
                      "value": -30
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-mono",
                  "parameters": []
                },
                {
                  "enabled": false,
                  "id": "audio-damage-glide",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-flutter",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-azimuth",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-clog",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 1
                    },
                    {
                      "id": "seed",
                      "value": 0
                    },
                    {
                      "id": "follow",
                      "value": true
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-worn",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 1.5
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-crackle",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 4
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-hifi",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 3
                    },
                    {
                      "id": "seed",
                      "value": 0
                    },
                    {
                      "id": "offset",
                      "value": 2
                    },
                    {
                      "id": "click",
                      "value": -30
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-mute",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 3
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                }
              ],
              "audioWear": 30,
              "layers": [],
              "name": "camcorder-tuned",
              "version": 1
            }
            """#,
        "eplinear": #"""
            {
              "audio": "eplinear",
              "audioLayers": [
                {
                  "enabled": false,
                  "id": "audio-camcorder",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -44
                    },
                    {
                      "id": "whine",
                      "value": 1600
                    },
                    {
                      "id": "zoomRate",
                      "value": 1
                    },
                    {
                      "id": "zoomLength",
                      "value": 2
                    },
                    {
                      "id": "lift",
                      "value": 12
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-mono",
                  "parameters": []
                },
                {
                  "enabled": true,
                  "id": "audio-saturation",
                  "parameters": [
                    {
                      "id": "drive",
                      "value": 0.3
                    },
                    {
                      "id": "emphasis",
                      "value": 6
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-band",
                  "parameters": [
                    {
                      "id": "speed",
                      "value": "ep"
                    },
                    {
                      "id": "highpass",
                      "value": 100
                    },
                    {
                      "id": "lowpass",
                      "value": 6000
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-azimuth",
                  "parameters": [
                    {
                      "id": "gain",
                      "value": -3
                    },
                    {
                      "id": "frequency",
                      "value": 2000
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-bump",
                  "parameters": [
                    {
                      "id": "gain",
                      "value": 2
                    },
                    {
                      "id": "frequency",
                      "value": 80
                    },
                    {
                      "id": "q",
                      "value": 1
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-wow",
                  "parameters": [
                    {
                      "id": "depth",
                      "value": 0.3
                    },
                    {
                      "id": "wow",
                      "value": 0.5
                    },
                    {
                      "id": "flutter",
                      "value": 0.5
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-hiss",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -42
                    },
                    {
                      "id": "color",
                      "value": "pink"
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-whine",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -60
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-dolby",
                  "parameters": [
                    {
                      "id": "gain",
                      "value": 4
                    },
                    {
                      "id": "frequency",
                      "value": 5000
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-glide",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-flutter",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-azimuth",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-clog",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 1
                    },
                    {
                      "id": "seed",
                      "value": 0
                    },
                    {
                      "id": "follow",
                      "value": true
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-worn",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 1.5
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-crackle",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 4
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-hifi",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 3
                    },
                    {
                      "id": "seed",
                      "value": 0
                    },
                    {
                      "id": "offset",
                      "value": 2
                    },
                    {
                      "id": "click",
                      "value": -30
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-mute",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 3
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                }
              ],
              "layers": [],
              "name": "eplinear",
              "version": 1
            }
            """#,
        "hifi": #"""
            {
              "audio": "hifi",
              "audioLayers": [
                {
                  "enabled": false,
                  "id": "audio-camcorder",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -44
                    },
                    {
                      "id": "whine",
                      "value": 1600
                    },
                    {
                      "id": "zoomRate",
                      "value": 1
                    },
                    {
                      "id": "zoomLength",
                      "value": 2
                    },
                    {
                      "id": "lift",
                      "value": 12
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-compressor",
                  "parameters": [
                    {
                      "id": "attack",
                      "value": 5
                    },
                    {
                      "id": "release",
                      "value": 100
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-fm-noise",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -48
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-click",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -55
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-expander",
                  "parameters": [
                    {
                      "id": "attack",
                      "value": 5
                    },
                    {
                      "id": "release",
                      "value": 100
                    },
                    {
                      "id": "tracking",
                      "value": 0.5
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-band",
                  "parameters": [
                    {
                      "id": "highpass",
                      "value": 20
                    },
                    {
                      "id": "lowpass",
                      "value": 20000
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-dropout",
                  "parameters": [
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "length",
                      "value": 150
                    },
                    {
                      "id": "click",
                      "value": -30
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-mono",
                  "parameters": []
                },
                {
                  "enabled": false,
                  "id": "audio-damage-glide",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-flutter",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-azimuth",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-clog",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 1
                    },
                    {
                      "id": "seed",
                      "value": 0
                    },
                    {
                      "id": "follow",
                      "value": true
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-worn",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 1.5
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-crackle",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 4
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-hifi",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 3
                    },
                    {
                      "id": "seed",
                      "value": 0
                    },
                    {
                      "id": "offset",
                      "value": 2
                    },
                    {
                      "id": "click",
                      "value": -30
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-mute",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 3
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                }
              ],
              "layers": [],
              "name": "hifi",
              "version": 1
            }
            """#,
        "linear": #"""
            {
              "audio": "linear",
              "audioLayers": [
                {
                  "enabled": false,
                  "id": "audio-camcorder",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -44
                    },
                    {
                      "id": "whine",
                      "value": 1600
                    },
                    {
                      "id": "zoomRate",
                      "value": 1
                    },
                    {
                      "id": "zoomLength",
                      "value": 2
                    },
                    {
                      "id": "lift",
                      "value": 12
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-mono",
                  "parameters": []
                },
                {
                  "enabled": true,
                  "id": "audio-saturation",
                  "parameters": [
                    {
                      "id": "drive",
                      "value": 0.3
                    },
                    {
                      "id": "emphasis",
                      "value": 6
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-band",
                  "parameters": [
                    {
                      "id": "speed",
                      "value": "sp"
                    },
                    {
                      "id": "highpass",
                      "value": 100
                    },
                    {
                      "id": "lowpass",
                      "value": 10000
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-bump",
                  "parameters": [
                    {
                      "id": "gain",
                      "value": 2
                    },
                    {
                      "id": "frequency",
                      "value": 80
                    },
                    {
                      "id": "q",
                      "value": 1
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-wow",
                  "parameters": [
                    {
                      "id": "depth",
                      "value": 0.2
                    },
                    {
                      "id": "wow",
                      "value": 0.5
                    },
                    {
                      "id": "flutter",
                      "value": 0.25
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-hiss",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -42
                    },
                    {
                      "id": "color",
                      "value": "pink"
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-whine",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -60
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-dolby",
                  "parameters": [
                    {
                      "id": "gain",
                      "value": 4
                    },
                    {
                      "id": "frequency",
                      "value": 5000
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-glide",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-flutter",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-azimuth",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-clog",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 1
                    },
                    {
                      "id": "seed",
                      "value": 0
                    },
                    {
                      "id": "follow",
                      "value": true
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-worn",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 1.5
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-crackle",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 4
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-hifi",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 3
                    },
                    {
                      "id": "seed",
                      "value": 0
                    },
                    {
                      "id": "offset",
                      "value": 2
                    },
                    {
                      "id": "click",
                      "value": -30
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-mute",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 3
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                }
              ],
              "layers": [],
              "name": "linear",
              "version": 1
            }
            """#,
        "off": #"""
            {
              "audio": "off",
              "audioLayers": [
                {
                  "enabled": false,
                  "id": "audio-damage-glide",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-flutter",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-azimuth",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-clog",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 1
                    },
                    {
                      "id": "seed",
                      "value": 0
                    },
                    {
                      "id": "follow",
                      "value": true
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-worn",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 1.5
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-crackle",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 4
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-hifi",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 3
                    },
                    {
                      "id": "seed",
                      "value": 0
                    },
                    {
                      "id": "offset",
                      "value": 2
                    },
                    {
                      "id": "click",
                      "value": -30
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-mute",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 3
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                }
              ],
              "layers": [],
              "name": "off",
              "version": 1
            }
            """#,
        "shoebox": #"""
            {
              "audio": "linear",
              "audioLayers": [
                {
                  "enabled": true,
                  "id": "audio-camcorder",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -44
                    },
                    {
                      "id": "whine",
                      "value": 1600
                    },
                    {
                      "id": "zoomRate",
                      "value": 1
                    },
                    {
                      "id": "zoomLength",
                      "value": 2
                    },
                    {
                      "id": "lift",
                      "value": 12
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-mono",
                  "parameters": []
                },
                {
                  "enabled": true,
                  "id": "audio-saturation",
                  "parameters": [
                    {
                      "id": "drive",
                      "value": 0.3
                    },
                    {
                      "id": "emphasis",
                      "value": 6
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-band",
                  "parameters": [
                    {
                      "id": "speed",
                      "value": "sp"
                    },
                    {
                      "id": "highpass",
                      "value": 100
                    },
                    {
                      "id": "lowpass",
                      "value": 10000
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-bump",
                  "parameters": [
                    {
                      "id": "gain",
                      "value": 2
                    },
                    {
                      "id": "frequency",
                      "value": 80
                    },
                    {
                      "id": "q",
                      "value": 1
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-wow",
                  "parameters": [
                    {
                      "id": "depth",
                      "value": 0.2
                    },
                    {
                      "id": "wow",
                      "value": 0.5
                    },
                    {
                      "id": "flutter",
                      "value": 0.25
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-hiss",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -42
                    },
                    {
                      "id": "color",
                      "value": "pink"
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-whine",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -60
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-dolby",
                  "parameters": [
                    {
                      "id": "gain",
                      "value": 4
                    },
                    {
                      "id": "frequency",
                      "value": 5000
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-glide",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-flutter",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-azimuth",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-clog",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 1
                    },
                    {
                      "id": "seed",
                      "value": 0
                    },
                    {
                      "id": "follow",
                      "value": true
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-worn",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 1.5
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-crackle",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 4
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-hifi",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 3
                    },
                    {
                      "id": "seed",
                      "value": 0
                    },
                    {
                      "id": "offset",
                      "value": 2
                    },
                    {
                      "id": "click",
                      "value": -30
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-mute",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 3
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                }
              ],
              "layers": [],
              "name": "shoebox",
              "version": 1
            }
            """#,
        "wornlinear": #"""
            {
              "audio": "wornlinear",
              "audioLayers": [
                {
                  "enabled": false,
                  "id": "audio-camcorder",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -44
                    },
                    {
                      "id": "whine",
                      "value": 1600
                    },
                    {
                      "id": "zoomRate",
                      "value": 1
                    },
                    {
                      "id": "zoomLength",
                      "value": 2
                    },
                    {
                      "id": "lift",
                      "value": 12
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-mono",
                  "parameters": []
                },
                {
                  "enabled": true,
                  "id": "audio-saturation",
                  "parameters": [
                    {
                      "id": "drive",
                      "value": 0.3
                    },
                    {
                      "id": "emphasis",
                      "value": 6
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-band",
                  "parameters": [
                    {
                      "id": "speed",
                      "value": "sp"
                    },
                    {
                      "id": "highpass",
                      "value": 100
                    },
                    {
                      "id": "lowpass",
                      "value": 10000
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-bump",
                  "parameters": [
                    {
                      "id": "gain",
                      "value": 3
                    },
                    {
                      "id": "frequency",
                      "value": 80
                    },
                    {
                      "id": "q",
                      "value": 0.7
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-wow",
                  "parameters": [
                    {
                      "id": "depth",
                      "value": 0.4
                    },
                    {
                      "id": "wow",
                      "value": 0.5
                    },
                    {
                      "id": "flutter",
                      "value": 0.25
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-hiss",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -36
                    },
                    {
                      "id": "color",
                      "value": "pink"
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-whine",
                  "parameters": [
                    {
                      "id": "level",
                      "value": -60
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-dolby",
                  "parameters": [
                    {
                      "id": "gain",
                      "value": 4
                    },
                    {
                      "id": "frequency",
                      "value": 5000
                    }
                  ]
                },
                {
                  "enabled": true,
                  "id": "audio-mute",
                  "parameters": [
                    {
                      "id": "rate",
                      "value": 3
                    },
                    {
                      "id": "shortest",
                      "value": 5
                    },
                    {
                      "id": "longest",
                      "value": 30
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-glide",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-flutter",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-azimuth",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 2
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-clog",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 1
                    },
                    {
                      "id": "seed",
                      "value": 0
                    },
                    {
                      "id": "follow",
                      "value": true
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-worn",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 1.5
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-crackle",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 4
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-hifi",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 3
                    },
                    {
                      "id": "seed",
                      "value": 0
                    },
                    {
                      "id": "offset",
                      "value": 2
                    },
                    {
                      "id": "click",
                      "value": -30
                    }
                  ]
                },
                {
                  "enabled": false,
                  "id": "audio-damage-mute",
                  "parameters": [
                    {
                      "id": "strength",
                      "value": 0.5
                    },
                    {
                      "id": "rate",
                      "value": 3
                    },
                    {
                      "id": "seed",
                      "value": 0
                    }
                  ]
                }
              ],
              "layers": [],
              "name": "wornlinear",
              "version": 1
            }
            """#,
    ]
}
