# Looks

Named presets above every other control. They run from clean to hard, at different tape speeds and
levels of wear, and a Look can carry the trappings of an old capture without static or tracking
trouble.

How a Look works (`Sources/HomeVideoCore/Looks.swift`): a Look is a picker selection (`PresetSelection`)
plus a few layer values on top (overrides). Choosing one resets every layer to the chain the Look
builds on fresh layers, through each layer's own `setParameter`, then sets the audio preset and its
values. It reads back when every layer switch and value (and the audio chain's) matches that
chain, else the picker shows Custom. That is stricter than "the pickers it names": any moved
slider outside Damage reads Custom. The Damage layers, picture and sound, are left out of the
match (below).

**The worn Looks carry their wear.** Five Looks switch on some
Damage layers (`docs/SIGNAL-CHAIN.md`, "Damage"): Rental, Dub of a Dub, Attic Tape, Hot Car and
Sticky Shed. Every other Look switches every Damage layer off. Choosing a Look sets them, so
going from a worn Look to a clean one leaves no wear behind. A Look still reads as itself with a
Damage slider moved or a layer switched, since the sliders are there to tweak the wear. A saved user preset is the whole chain, so
it carries them. The section "Wear" below lists each worn Look's layers and values.

**Two Looks carry the camcorder motor.** Camcorder takes the
Camcorder audio preset (Hi-Fi with the camcorder mic on) and Shoebox keeps Linear with the mic
layer `audio-camcorder` switched on by an override. Every other Look has the mic off. The mic is
the drum and transport whine, the preamp hiss, and the
AGC swelling all of it in the pauses. In the Audio section
both read Mic Camcorder, on the Hi-Fi track for Camcorder and the Linear track for
Shoebox, and every other Look reads Mic Clean on its track. The Looks store their audio as a
preset name plus the mic switch.

| Look | Audio | Motor |
|---|---|---|
| Camcorder | Camcorder | on |
| Shoebox | Linear | on (override) |
| every other Look | its own preset | off |

**The menu has sections.** Each Look names its `category`, and
`Looks.grouped` gives the menu Tape, Film, Telecine and Display in that order, each plainest first
(`Looks.menuOrder`), with the user's saved presets under Custom after them. Every Telecine Look
turns the Film on, since a telecine is film put onto video. `Looks.all` keeps a fixed order with
new Looks added at the end, so Shuffle's seeded rolls and the Tape stage presets stay the same.

| Section | Looks, in the menu's order |
|---|---|
| Tape | Fresh SP, Good Deck, S-VHS, Off the TV, Off-Air, Six Hour Tape, Camcorder, Wedding Video, Shoebox, Tape Transfer, Rental, Dub of a Dub, Attic Tape, Hot Car, Sticky Shed |
| Film | Super 8, Summer Reel, Cinema 35, 16mm News, Living Room, 16mm Faded, Estate Sale |
| Telecine | Pro Scan, Mall Transfer, 8mm to Tape |
| Display | Filmed TV, Tripod TV, Up Close, Phone Dub |

**A Look lights the stages it uses:** after choosing one, the stages in use are its section's (Film, Film and
Telecine, the Display and the camera) plus the Tape unless it switches the Tape off, plus Audio
when it has a sound. A Look outside Display leaves the Display as it was and switches the camera
off. `LookStagesTests` holds every Look to that.

Everywhere: `homevideo-render --look <id>` (before `--preset` and `--set`), `homevideo-render --list-looks`,
and the app's launch argument `-homevideoLook <id>` (before `-homevideoPreset` and `-homevideoSet`).

Where a number comes from: CAL is matched to measurements of four real home VHS tapes, SPEC is
`docs/SIGNAL-CHAIN.md`'s defaults, BRIEF is a design choice, INFERRED is by eye.

## Every Look on the calibration basis

`homevideo-render <clip>.mov --frames 90 --set framing.mode=cropCenter --look <id>` on a test clip,
measured at frames 30, 45 and 60, raw and after a YouTube-like encode (yt). The four tapes'
sat p95 spans 20.0 to 38.0 (CAL).

| Look | sat p95 | sat p95 (yt) | Y p50 (yt) |
|---|---:|---:|---:|
| clean-sp | 29.47 | 28.89 | 118.26 |
| camcorder | 37.16 | 37.33 | 126.92 |
| home-movie-1986 | 26.42 | 26.23 | 111.26 |
| transfer-1986 | 26.42 | 26.24 | 107.58 |
| rental | 29.77 | 28.95 | 117.61 |
| dub-of-a-dub | 30 | 28.51 | 110.18 |
| attic-tape | 30.76 | 29.99 | 141.41 |
| off-air | 30.82 | 28.93 | 118.87 |

## The cleaner Looks

Three Looks sit right after Fresh SP, at the clean end of the menu. They leave Fresh SP and the default
picture as they are. RESEARCH marks a published figure for the VHS and S-VHS formats. The three share one deck, the values below as overrides on
the Clean deck:

| value | Clean deck | cleaner Looks | source |
|---|---:|---:|---|
| time base jitter (`time-base.amplitude`) | 0.5 px | 0 | BRIEF: a line TBC, which the late HQ and S-VHS decks of that class carried (RESEARCH: broadcast decks have a TBC, consumer decks generally do not) |
| top flagging (`time-base.flag`) | 2 px | 0 | BRIEF, the same TBC |
| dropouts (`dropouts.rate`) | 3 a minute | 0 | BRIEF, fresh tape |
| luma S/N (`tape-noise.luma`) | 45 dB | 48 | BRIEF, noise reduction (the clean deck's 45 is SPEC) |
| chroma S/N (`tape-noise.chroma`) | 45 dB | 48 | BRIEF, noise reduction |
| head switch height (`head-switch.height`) | 6 lines | 1 | BRIEF, the slider's floor |
| head switch shift (`head-switch.shift`) | 24 px | 0 | BRIEF, a TBC holds the switch line |

Pickers for all three: Source Digital, Tape SP, Deck Clean, Capture Weave, Audio Hi-Fi, border
off, tracking off. They set their own luma cut, so the Tape picker under Tune reads Custom, and
their deck overrides make the Deck picker read Custom too. That is expected: the Look menu reads
back by the whole chain.

### S-VHS (`s-vhs`)

Super VHS on a deck with a line TBC: twice the luma detail, steady lines, almost no grain. Link
S-Video. Overrides: L3 luma cut 5.0 MHz (RESEARCH: S-VHS reaches 400 to 420 TVL, at about 80 TVL
per MHz that is 5.0 MHz, and its FM carrier sits at 5.4 to 7.0 MHz with 1.6 MHz deviation against
VHS's 3.4 to 4.4), the shared deck values above. L4 chroma stays as VHS, 320 kHz (RESEARCH:
chroma is heterodyned down to 629 kHz for VHS and S-VHS alike). The L3 slider runs 1.0...5.5 MHz to
reach this: the Butterworth is designed per line at 13.5 MHz sampling, so
5.5 MHz is 0.41 of the sample rate, under Nyquist.

### Good Deck (`good-deck`)

A late four-head deck with a line TBC and noise reduction, fresh SP tape: steady, quiet, still VHS
soft. Link S-Video. Overrides: L3 luma cut 3.0 MHz (RESEARCH: baseband video "up to 3 MHz", 250
TVL in SP, which this cut gives a touch more of than Fresh SP's 2.4, the ntsc-rs tuned value),
the shared deck values above.

### Off the TV (`off-the-tv`)

A good deck taping broadcast: the tuner's composite through a comb filter, nothing else wrong. Good
Deck with the tuner's composite into the deck through `comb2` (overrides: L2 on, separator comb2)
and the deck's S-Video out to the capture card (the card's composite input stays off), FM moire
off (its default). L2 on with the card on S-Video matches neither Link choice, so the Link picker
under Tune reads Custom, as the Tape picker does. Sources: BRIEF
(comb2 at both ends measured softer than Fresh SP), and the separator is SIGNAL-CHAIN L2, the
band-split 2-line comb.

On a 0.2 to 6.0 MHz sweep Off the TV
reads 0.665 at 3.0 MHz against Fresh SP's 0.288 (0.935 against 0.802 at 2.0 MHz), the same as
Good Deck, since the comb costs nothing on a line that is the same down the frame. On a test clip at
2 s the horizontal luma gradient (mean absolute neighbor difference, higher is sharper) reads 3.47
against Fresh SP's 3.59 and Good Deck's 3.70: it sits below Fresh SP because a 2-line comb takes
any luma that changes from line to line above about 2 MHz as chroma, which is the real comb's loss
of diagonal detail, and one pixel differences are mostly that band. It reads nicer than Fresh SP
as steadier and quieter (line TBC, S/N 48, no head switch band, no dropouts), not as sharper on
that gradient.

### Measured

Luma response on a sweep (depth at f over depth at 0.5 MHz). The 720 wide fixture's
sweep ends at 4.0 MHz in the last column, which the frame's edge blanking covers for every Look
(Fresh SP reads 0 there too), so the numbers come from the same fixture recipe swept 0.2 to 6.0
MHz. The bare fixture reads 0.945 at 4.0 MHz.

| Look | 2.0 MHz | 3.0 MHz | 4.0 MHz | 5.0 MHz | 5.5 MHz |
|---|---:|---:|---:|---:|---:|
| s-vhs | 0.880 | 0.916 | 0.888 | 0.612 | 0.260 |
| good-deck | 0.935 | 0.665 | 0.163 | 0.016 | 0.012 |
| clean-sp | 0.802 | 0.288 | 0.033 | 0.008 | 0.004 |

S-VHS falls through 0.707 between 4.6 (0.720) and 4.8 MHz (0.688), and at the 5.0 MHz design cut
once divided by the bare fixture's own response there (0.612 over 0.882, 0.69).

Flat-field luma S/N, a mid-gray 720 by 480 ProRes clip, 90 frames, frames
30, 45 and 60: good-deck 52.38, 52.58, 54.29, s-vhs 52.08, 52.18, 53.79, clean-sp
51.24, 51.80, 52.67. The meter reads above the S/N set on the layer (48 and 45) because the
noise is band limited and quantized to 8 bits, so the step between the Looks is small on it.

## Fresh SP (`clean-sp`)

A fresh SP tape on a good deck, S-Video out. Its id is `clean-sp`, which scripts and
`--look clean-sp` use. It is the default chain exactly (a fresh `VHSLayers` reads back as Fresh
SP), with the tracking noise burst off by default.

Pickers: Source Digital, Tape SP, Link S-Video, Deck Clean, Capture Weave, Audio Linear NR, Capture
border off, Tracking noise off. Overrides: none. Sources: SPEC, CAL.

**The default sound is Linear NR.** It is the linear track on a good deck with its
B type noise reduction matched on record and playback: Linear's band, mono, head bump and wow, the
hiss up to 10 dB lower in the treble (`docs/SIGNAL-CHAIN.md`, Audio). Linear stays a preset of its own, and
every Look that names it keeps it.

`AudioChain.defaultPreset` is Linear NR, so a new chain, the launch, `homevideo-render` with no
`--preset audio=` and the Audio switch turned on with nothing held all play it. The Display Looks that film a fresh SP tape (Filmed TV, Tripod TV, Up Close) carry the
same sound, so Fresh SP with the Filmed TV Display preset over it still reads as Filmed TV. A sidecar from before the audio key still reads as Hi-Fi, the default it was written on.

## Camcorder (`camcorder`)

Shot on a camcorder and played back clean: the trappings without the damage and without the
border.

Pickers: Source Camcorder (camera on, soft focus 1.6 MHz, tungsten cast Cb -3, Cr +5, hue -15,
levels gain 1.15 into a 255 clip), Tape SP, Link S-Video, Deck Clean, Capture Weave, Audio
Camcorder (Hi-Fi with the camcorder mic on: the motor humming in the pauses), border off,
tracking off. Overrides: none. Sources: CAL (cast, gain, softness).

## Shoebox (`home-movie-1986`)

Its id, `home-movie-1986`, is what scripts and saved settings use.

Chases a 1986 home tape: faded
color, a dark tungsten cast, composite, and no static or border, with the camera's motor in the
pauses.

Pickers: Source Camcorder, Tape SP, Link Composite (comb1 at both ends), Deck Clean, Capture
Weave, Audio Linear, border off, tracking off. The camcorder mic layer is on by override,
so the drum's whine and the AGC's swell ride the linear track. Tape Transfer shares the picture
overrides but not the mic.

Overrides: chroma gain 0.6 (BRIEF, near the faded tapes' p95 ratio 0.70 in CAL, pushed further
for the 1986 fade), camera exposure -0.3 stops, toe 0.12 (default 0.04), white balance Cb -6 and
Cr +15 codes, hue -15 degrees (CAL, the 1986 cast and skin rotation), and black lift 19 codes,
8.0 IRE (CAL, the 1986 tape's p1 19 and p5 42, the same value as the Aged deck's lift).

Measured on the calibration basis (frames 30, 45 and 60, after the YouTube-like encode) against
the 1986 tape:

| measurement | 1986 tape | home-movie-1986 (yt) | camcorder (yt) |
|---|---:|---:|---:|
| sat p95 | 26.96 | 26.23 | 37.31 |
| sat mean | 16.25 | 15.61 | 15.34 |
| Y p1 | 19.19 | 21.49 | 7.43 |
| Y p50 | 110.07 | 111.26 | 127 |
| Y p99 | 255 | 216.14 | 249.54 |
| neutral Cb | -1.5 | -0.95 | -0.58 |
| neutral Cr | 3.29 | 6.7 | 3.57 |
| skin hue | 109.67 | 114.17 | 123.04 |

A full stop under (with the toe at 0.12) puts Y p50 at 47
against the tape's 110 and sat p95 at 19.4, outside the tapes' 20 to 38, so the Look uses -0.3.
The whites stop at p99 216 where the tape clips at 255: lifting them would also lift the mid
tones away from the tape's 110. Tape Transfer measures sat p95 26.24 on the same basis.

## Tape Transfer (`transfer-1986`)

The Shoebox tape as the capture house sent it back:
the same values plus the capture border (left 15,
top 5), the tracking noise burst, the big head switch band (12 visible lines per field, height
15, 120 px, the Worn band) and the OSD off.

Sources: the border from the two 1991 tapes' capture (CAL, edge blanking), the band from
a 1991 tape (CAL, head switch), the rest as Shoebox.

## Rental (`rental`)

An EP rental played a hundred times on a tired deck. Pickers: Source Digital, Tape EP, Link
Composite (notch), Deck Worn, Capture Bob, Audio EP Linear, border off, tracking on. Overrides:
dropouts 25 a minute (the Worn rate, BRIEF). EP Linear carries the EP tape speed itself,
so the sound matches the tape (docs/SIGNAL-CHAIN.md, "Audio").

Wear: a tracking tear now and then and snow. A hundred plays stretch the tape's edge, so the
heads ride off their tracks for a moment, and wear the oxide thin, so the carrier drops out in
streaks.

## Dub of a Dub (`dub-of-a-dub`)

A copy of a copy of an LP tape on a worn deck. Pickers: Source Digital, Tape LP, Link Composite
(comb1), Deck Worn, Capture Weave, Audio Hi-Fi, border off, tracking off. Overrides: the
generation layer on, Generation 3 (the deck's L3 to L8 run twice more after the first playback,
each pass with its own noise). Sources: BRIEF, and the mechanism is SIGNAL-CHAIN's second generation.

Wear: snow and Hi-Fi dropouts. Every generation's tape drops out in its own places and the
recorder copies each streak, so the snow stacks up. A copy's Hi-Fi rides marginal tracking, and
where it drops the deck falls back to the linear track.

## Attic Tape (`attic-tape`)

A camcorder tape that sat for decades in an attic, played on a worn deck: the Aged fade and the
Worn damage together. Pickers: Source Camcorder, Tape SP, Link Composite (comb1), Deck Worn,
Capture Weave, Audio Worn Linear, border off, tracking on. Overrides: chroma gain 0.8 and black lift
+19 codes (8.0 IRE), the Aged deck's values (CAL, the two faded tapes and the 1986 blacks), and
dropouts 25 a minute.

Wear: creases, a clogging head and a wow glide. Thirty years of heat and damp crease the tape
and soften its binder, the shed oxide clogs a head now and then, and a sticky spot drags the tape so
the pitch sags and catches up. The Hi-Fi dropout does not fit: Attic Tape plays the linear track,
and the Hi-Fi dropout runs only on Hi-Fi.

## Off-Air (`off-air`)

Taped off broadcast TV: composite all the way. Pickers: Source Digital, Tape SP, Link Composite
(notch at both ends), Deck Clean, Capture Weave, Audio Hi-Fi, border off, tracking off.
Overrides: FM moire 0.05 (half its physical range, the amplitude is INFERRED, SIGNAL-CHAIN L3).

## Wedding Video (`wedding-video`)

A videographer's camcorder footage, edited to a master and dubbed to the couple's copy. Pickers:
Source Camcorder, Tape SP, Link Composite (comb2, a good deck's comb), Deck Clean, Capture Weave,
Audio Hi-Fi, border off, tracking off. Overrides: the generation layer on, Generation 2 (the
couple's tape is one copy down from the master). Wear: none, a careful pro on good decks. It sits
between Camcorder (first generation, S-Video) and Dub of a Dub (third, worn).

## Six Hour Tape (`six-hour-tape`)

A whole night of TV on one EP tape, on a good deck. Pickers: Source Digital, Tape EP, Link S-Video,
Deck Clean, Capture Weave, Audio EP Linear, border off, tracking off. Overrides: the tuner's
composite into the deck, as Off the TV (`composite-link` on, comb2). EP runs the tape at a third of
SP's speed, so the luma and chroma cuts are EP's and the linear sound is EP Linear's narrow band.
Wear: none. Rental is the same speed on a worn deck with its wear, this one the fresh tape.

## Hot Car (`hot-car`)

A movie left a summer in a hot car, played on a good deck. Pickers: Source Digital, Tape SP, Link
Composite (comb1), Deck Clean, Capture Weave, Audio Hi-Fi, border off, tracking on. Overrides: time
base jitter 2 px (the Clean deck's 0.5 four times over, INFERRED: heat stretches the tape unevenly,
so the line timing wanders more than the servo holds).

Wear: creases, tracking tears and a wow glide. The heat warps the shell and the tape's edge, the
warped edge folds as it passes the heads (a dark crease, 6 passes a minute), the stretched tape no
longer matches the track angle so the heads ride off now and then (a tear anywhere in the field),
and the stretched spots drag at the capstan (the wow glide).

## Sticky Shed (`sticky-shed`)

An LP tape whose binder has gone sticky (sticky shed: the binder takes up moisture and softens, the
AV Artifact Atlas's soft binder syndrome, which `FlutterBurst` cites). Pickers: Source Digital, Tape
LP, Link Composite (comb1), Deck Aged (the faded chroma and lifted blacks), Capture Weave, Audio
Hi-Fi, border off, tracking off. Overrides: dropouts 40 a minute (the shed oxide leaves bare tape).

Wear: a clogging head, snow, scrape flutter and a muffled clog in the sound. Oxide comes off onto the
heads and clogs them (4 episodes a minute), the bare spots drop the carrier (snow, 200 a second),
the tape sticks and slips on the guides (scrape flutter), and the Hi-Fi heads sit on the same drum,
so the sound muffles with the picture's clog (the audio clog follows the picture).

## The film Looks

Each is a scan (the Film on, the Tape off, as Super 8 is), on the clean Looks' pickers with Hi-Fi,
which plays nothing while the Tape is off. Every value is a slider of the Film stage
(`docs/FILM.md`), the amounts INFERRED by eye on the stills.

- **Summer Reel** (`regular8-summer`): Regular 8 Kodachrome 40 in daylight. Format Regular 8 (the
  4.8 mm frame, so grain, blur and halation scale up against Super 8), saturation 1.35 and contrast
  1.25 (Kodachrome's rich dyes and high contrast), halation 0.3 from a 0.6 threshold so the
  sun's glints bloom.
- **Living Room** (`super8-living-room`): Super 8 Ektachrome 160 Type A under lamps at night. Light
  Low light (a stop under on its own, and the residual warm cast of lamps dimmer than the stock's
  3400 K), Underexposure 0.5 more, auto exposure drift 0.4 (the camera's meter hunting), grain 0.75,
  halation 0.3 from a 0.55 threshold.
- **Estate Sale** (`super8-estate-sale`): Super 8 Ektachrome 160 from the seventies. Fade 50 years
  (E-4 era Ektachrome keeps about 30, cyan and yellow first, so it runs magenta), Damage on: dust
  0.5, hair 0.25, scratches 0.3, two splices a minute, seed 74.
- **16mm News** (`sixteen-news`): 16mm Vision3 500T handheld outdoors. Format 16mm, stock Vision3
  500T in daylight (the camera's 85 filter, its 0.68 stop loss), 24 fps, grain 0.65, drift 0.3.
  A negative, so the gentler curve and white dust.
- **Cinema 35** (`thirtyfive-vision`): 35mm Vision3 50D in daylight. Format 35mm (the pin
  registered gate's sixth of Super 8's weave), 24 fps, flicker 0, drift 0 (no auto exposure on a
  cine camera), vignette 0.15, softness 0.1.

## The Telecine Looks

- **Mall Transfer** (`mall-transfer`): Regular 8 Kodachrome through the Home route at the Mid-grade
  tier, the mall kiosk's mirror box: a five blade projector at 24 fps, a CCD camera, a 12 percent hot spot,
  half a degree of keystone. Onto SP through a clean deck's composite (comb1), Audio Linear.
- **Pro Scan** (`pro-scan`): 16mm Vision3 50D at 24 fps on the Pro route at the Pro tier, a flying
  spot scanner with the grade's fade correction, 2:3 pulldown, almost no dust, and the Tape off,
  so the transfer comes straight out.

## The Display Looks

Both film the tube as Filmed TV does (every CRT layer and the camera on), Fresh SP's tape on the
clean pickers.

- **Tripod TV** (`tripod-tv`): framing Whole (the bezel, the curved corners and the room), the 4:3
  camera at 1440 by 1080, the hand still (drift, shake and yaw 0), glare 0.1.
- **Up Close** (`up-close`): the mask's Dots (shadow mask) at the widest triad and full strength,
  as the Close-up Mask Display preset sets them, and the lens in focus (defocus 0), so the phosphor
  triads read.

## Wear

The Damage values each worn Look sets. Every Strength sits between 0.3 and 0.6, inside the
0 to 1 range, and every Rate well off both ends of its range, so the sliders have room either way.
Each Seed is fixed per Look, so two renders land the same events (`testAWornLookRendersTheSameBytesTwice`).
Hot Car's seed is 6 because seed 5 lands no picture event in the first 10 s of a render, and 6
lands a crease at 1 s.

| Look | layer | Strength | Rate | Seed | other |
|---|---|---:|---:|---:|---|
| Rental | Tracking tear | 0.4 | 3 a minute | 11 | |
| Rental | Snow | 0.3 | 60 a second | 11 | |
| Dub of a Dub | Snow | 0.35 | 120 a second | 23 | |
| Dub of a Dub | Hi-Fi dropout | 0.4 | 2 a minute | 23 | |
| Attic Tape | Crease | 0.5 | 4 a minute | 37 | |
| Attic Tape | Head clog | 0.5 | 1.5 a minute | 37 | |
| Attic Tape | Wow glide | 0.5 | 2 a minute | 37 | |
| Hot Car | Crease | 0.45 | 6 a minute | 6 | Line Dark |
| Hot Car | Tracking tear | 0.5 | 4 a minute | 6 | Position Anywhere |
| Hot Car | Wow glide | 0.6 | 4 a minute | 6 | |
| Sticky Shed | Head clog | 0.6 | 4 a minute | 19 | |
| Sticky Shed | Snow | 0.4 | 200 a second | 19 | |
| Sticky Shed | Flutter burst | 0.5 | 4 a minute | 19 | |
| Sticky Shed | Head clog (muffled) | 0.5 | 4 a minute | 19 | Follow the picture |

Sources: the mechanisms are SIGNAL-CHAIN's Damage section. The values are INFERRED, chosen mid range
so each Look shows its wear within a few seconds without drowning the picture.

## User presets

You can save, import and export your own.
Look > Save Preset... writes the whole chain under a name to
`~/Library/Application Support/Home Video/Presets/<name>.homevideopreset`: every effect layer's switch and
parameter values and the audio preset with its layers' values, taken from the layers' own
parameter lists (`Sources/HomeVideoCore/UserPresets.swift`). Saving again under the same name replaces
it. Framing and the Output size are not saved, as with the built-in Looks: they belong to the clip.

A saved preset is a Look whose overrides are every saved value, on an empty picker selection
with the saved audio preset. So it applies exactly as a built-in Look does (every layer reset,
then each value through `setParameter`), and it reads back the same way: the Look menu shows its
name while every value matches and Custom once anything outside Damage moves. The menus (the sidebar's and the
Look menu in the menu bar) list the built-in Looks under their section headers, then the saved
presets under the Custom header, built
in first when a chain matches both. The pickers under Tune read whatever the values say, often
Custom.

Import Preset... copies a file into the folder under the name inside it, Export Preset... writes
the shown preset out (or the current chain, when a built-in Look or Custom is shown), and Manage
Presets... lists them with Reveal in Finder and Delete. `homevideo-render --preset-file <path>` applies
one, after `--look` and before `--preset` and `--set`. A malformed file (bad JSON, a version other
than 1, an unknown layer or parameter, a value of the wrong type, a choice outside its options)
is refused with nothing changed.
