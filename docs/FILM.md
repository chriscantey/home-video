# Film: the Film source

What a home movie camera and its stock do to the picture.

## Where it sits

Film is a source stage, ahead of the output card and the camera, since film is what shot the
picture. It is off at launch. Its switch is in the Look tab's Stages list, and while it is on
the stage has its own tab, the first after Look. With Film unused the chain, its fingerprint, the
sidecar and preset files, the Looks and the first screen are unchanged.

While Film is on it replaces the camcorder: the Camera layer does not run, and the Tune Source
picker (Digital, Camcorder) is greyed with the note "Film is on: the film camera shot it."

Where the film goes is set by the stage switches, not by a choice in the Film tab:

- **Tape off**, with the Telecine off, is the Scan: a modern film scan. The VHS chain is bypassed and the picture is
  written at 1440 by 1080, 4:3 square pixels, 709 tagged. The Film tab's Scan detail (Standard
  draws the film on a 1440 by 1080 canvas, Fine on 2880 by 2160) is how fine the film is
  scanned, never the file's size: at Auto both write 1440 by 1080, and the Output size
  on the Look tab sets any other size. Framing's crop, pan, zoom and rotation place the source on the scan canvas
  as they do on the raster. The film Looks are scans, so they switch the Tape off.
- **Tape on** (the default): the film picture goes on through the VHS chain as the Look sets it,
  at the 720 by 480 raster. With the Telecine on, its transfer takes that place
  (docs/TELECINE.md).

An older sidecar or preset that names Film's output loads into the switches: with the Film on,
output Scan loads as Tape off (and Telecine off, which Scan ignores), output Tape as Telecine off,
output Telecine as it reads. `--set film.output=scan` is folded the same way, into
`--set tape=off`. With the Film off the choice does nothing.

With the Shutter layer on, frames are held to 18 or 24 fps on both outputs: every source frame
inside one film frame shows the same picture (grain, weave and flicker included). The file keeps
the source's frame rate, so a 30 fps clip at 18 fps shows three film frames over every five
source frames.

## Order

The picture goes through the layers in the order they act: the shutter's exposure, the light,
the lens (Optics), the emulsion's blur (Format) and its halation at exposure, the dyes (Stock)
and the curve (Tone) at the develop, the grain of the developed image, the years in the can
(Fade), the dirt at the scan (Damage), and the frame's place in the gate (Weave). Every kernel
(`Sources/HomeVideoCore/Shaders/Film.metal`) reads and writes display values (gamma 2.2) and
works in linear inside, so any layer can be switched off alone.

Sizes scale with the frame. Grain, blur and halation sliders are given for Super 8 and scale by
5.46 mm over the frame width: Regular 8 1.14, Super 8 1, 16mm 0.53, 35mm 0.25 (READ widths, the
ratio INFERRED). Weave scales by its own table, Super 8 and Regular 8 1, 16mm one third, 35mm one
sixth (INFERRED from the 0.3 and 0.1 percent defaults). Pixel sizes are at 1080 lines.

## The layers as built

`id` is the layer, `parameter` its value, then the default, the range (or the options), and
whether the default is READ from a published source or INFERRED. `FilmTests.testDefaultsAndRangesMatchTheDoc`
checks every row against the code.

| layer | parameter | default | range | source | note |
|---|---|---|---|---|---|
| film | enabled | off | | INFERRED | the master switch, off |
| film | scan | 1440 | 1440, 2880 | INFERRED | 1440 by 1080 or 2880 by 2160 |
| film-format | enabled | on | | INFERRED | |
| film-format | format | super8 | regular8, super8, sixteen, thirtyFive | READ | frame widths 4.8, 5.46, 10.26, 22.0 mm |
| film-format | blur | 1.6 | 0 to 4 | INFERRED | px at 1080 on Super 8, stock lp/mm not found |
| film-stock | enabled | on | | INFERRED | |
| film-stock | stock | kodachrome40 | kodachrome40, ektachrome160, fujiR25N, vision50D, vision500T | READ | the five stocks |
| film-stock | saturation | 1.25 | 0.8 to 1.4 | INFERRED | a stock brings its own value |
| film-light | enabled | on | | INFERRED | |
| film-light | light | daylight | daylight, tungsten, fluorescent, lowLight | READ | four shooting situations |
| film-light | under | 0 | 0 to 2 | READ | underexposure, stops |
| film-tone | enabled | on | | INFERRED | |
| film-tone | latitude | 7 | 6 to 14 | READ | reversal 6 to 8 (7), negative about 12 |
| film-tone | contrast | 1.1 | 0.5 to 2.5 | INFERRED | Kodachrome's "relatively high" READ, the figure INFERRED |
| film-tone | drift | 0.15 | 0 to 1 | INFERRED | auto exposure drift |
| film-grain | enabled | on | | INFERRED | |
| film-grain | strength | 0.5 | 0 to 1 | INFERRED | |
| film-grain | size | 1.2 | 0.5 to 3 | READ | px at 1080, 1.2 for Super 8 |
| film-grain | seed | 0 | 0 to 999 | INFERRED | |
| film-halation | enabled | on | | INFERRED | |
| film-halation | strength | 0.15 | 0 to 0.5 | INFERRED | |
| film-halation | radius | 1 | 0 to 5 | READ | percent of width (the backing kills the far ring) |
| film-halation | threshold | 0.75 | 0.3 to 1 | INFERRED | linear luminance where the glow starts |
| film-weave | enabled | on | | INFERRED | |
| film-weave | amount | 0.3 | 0 to 1 | READ | percent of width on Super 8 (16mm 0.1), magnitude unsourced |
| film-weave | seed | 0 | 0 to 999 | INFERRED | |
| film-shutter | enabled | on | | INFERRED | |
| film-shutter | fps | 18 | 18, 24 | READ | the rates |
| film-shutter | angle | 180 | 90 to 230 | INFERRED | home shutter angle unsourced |
| film-shutter | flicker | 1.5 | 0 to 5 | INFERRED | percent |
| film-optics | enabled | on | | INFERRED | |
| film-optics | softness | 0.25 | 0 to 1 | INFERRED | lens figures not found |
| film-optics | vignette | 0.35 | 0 to 1.5 | INFERRED | stops at the corner |
| film-optics | ca | 0.4 | 0 to 2 | INFERRED | px at 1080 |
| film-fade | enabled | on | | INFERRED | at 0 years it changes nothing |
| film-fade | years | 0 | 0 to 50 | READ | |
| film-damage | enabled | off | | READ | damage off by default |
| film-damage | dust | 0.4 | 0 to 1 | INFERRED | fresh specks every frame, up to 14, a third of frames clean |
| film-damage | hair | 0.2 | 0 to 1 | INFERRED | up to 4 a minute at full, 0.5 to 3 s each |
| film-damage | scratches | 0.2 | 0 to 1 | INFERRED | up to 6 a minute at full, 2 to 12 s each |
| film-damage | splices | 1 | 0 to 6 | INFERRED | per minute, two frames each |
| film-damage | fog | 0 | 0 to 1 | INFERRED | roll end fog: full for the first 2 s, then a quarter |
| film-damage | frameLine | 0 | 0 to 1 | INFERRED | up to 6 percent of the height at the top |
| film-damage | seed | 0 | 0 to 999 | INFERRED | |

## What each layer does

- **Format**: a Gaussian blur, the emulsion and lens at the frame's scale, sigma = blur x scale.
  It also scales the grain, the halation radius and (by its own table) the weave.
- **Stock**: saturation about the luminance and the stock's own cast. The stock also sets the
  polarity (reversal or negative), the grain's size and amount, the halation (Vision3 has a
  rem-jet backing, READ, so 0.3 of reversal's, INFERRED), the curve, and the fade rates. Picking
  a stock moves the Saturation, Contrast and Latitude sliders to its values.

  | stock | type | balance | saturation | grain size, amount | contrast | READ |
  |---|---|---|---|---|---|---|
  | Kodachrome 40 | reversal | tungsten 3400 K | 1.25 | 0.85, 0.8 | 1.1 | RMS 9 "extremely fine", 3400 K, "relatively high" contrast |
  | Ektachrome 160 | reversal | tungsten (Type A, INFERRED) | 1.05 | 1.3, 1.3 | 0.8 | ASA 160 |
  | Fuji R25N | reversal | daylight | 1.2 | 0.9, 0.9 | 1.0 | 25 ASA daylight |
  | Vision3 50D | negative | daylight | 0.92 | 0.7, 0.65 | 1.0 | "finest grain", rem-jet |
  | Vision3 500T | negative | tungsten | 0.88 | 1.4, 1.21 | 1.0 | 500 tungsten from the name, the amount from Kodak's RMS granularity against 50D's (8.76 over 4.71) |

- **Light**: the residual cast after the camera's filter and the exposure. A home camera puts its
  85 filter in for tungsten stock in daylight and carries nothing for daylight stock under lamps.
  Kodachrome 40's 85A costs 0.68 stops (READ, 40 to 25), an 80A on daylight stock 2 stops (READ,
  50D EI 12, not fitted on a home camera, so lamps read orange). Uncorrected cool white
  fluorescent reads green (READ, the data sheet's CC20M correction). The meter makes up a filter's
  loss in good light, so the loss counts only under fluorescent and low light, where the lens is
  wide open (INFERRED). Low light adds one stop of underexposure and a warmer lamp (INFERRED).
  A negative's scan is timed, so a third of the cast remains (INFERRED). Underexposure adds on top.
- **Tone**: per channel, so the toe crosses colors over as reversal does. Reversal: an S curve over
  the latitude around mid gray, blacks crushed and whites clipped. Negative, as scanned and timed:
  mid gray stays where it was, the straight line runs up to it, and above it a shoulder keeps
  highlights about two stops past white (READ, Vision3 "up to two stops"), with a toe lifted by
  the base. Auto exposure drift wanders the exposure slowly (two sines at 0.23 and 0.61 Hz, INFERRED).
- **Grain**: a new field every film frame from the seed and the film frame number, two octaves of
  value noise at the grain size, 70 percent shared by the three dye layers and 30 percent each its
  own at that layer's size, each layer by its own amount and size (`FilmStock.grainPerChannel`,
  per stock, blue the grainiest: measured on public domain scans for Kodachrome and Ektachrome, INFERRED
for Fuji R25N, READ
  from Kodak's granularity graphs for Vision3, the amounts scaled to a luminance mean of 1),
  weighted by the stock's curve against each layer's encoded value (`FilmStock.grainCurve`,
  five points per stock, measured on scans, INFERRED for Fuji R25N and Vision3 500T: a color reversal original loses its grain toward the
  highlights, a negative stays flat from the shadows up). An underexposed
  negative's grain rises as it is printed up (INFERRED, half a stop of grain per stop under).
  The field goes through the scan's softening only: the Format Gaussian, with its
  own taps, at 0.3 of its sigma (`FilmLayers.grainScanShare`). The picture keeps the whole Format
  blur and the Optics lens, which the grain never goes through, so the grain is about twice as
  fine as the picture's MTF50 (1.65 to 2.11 on the film Looks, against 1.68 to 2.13 measured on
  8 scans) and never finer than the scan (`GrainMTFTests`). The RMS the softening takes is put
  back from the noise's autocorrelation, so Strength keeps its meaning.
- **Halation**: light over the threshold reflects off the base and comes back red (READ, "slight
  red halo around the brightest elements"), a 48 tap spiral over the radius, tint 1, 0.18, 0.04.
  At the film stage only: never the CRT glow or the video camera's lag.
- **Weave**: the whole frame moved in the gate, smoothed over about four frames with a little of
  each frame's own, vertical 0.8 of horizontal (INFERRED). The edges it reveals are the gate's black.
- **Shutter and flicker**: holds frames to 18 or 24 fps. The shutter is open angle/360 of a film
  frame, and where that covers more than one source frame the previous source frame is blended in
  (a 30 fps source at 18 fps and 230 degrees blends about 6 percent). Flicker varies each film
  frame's exposure by up to the slider's percent (the camera's governor, INFERRED).
- **Optics**: a 3 by 3 lens blur, a vignette falling as r^4 to the stops at the corner, and lateral
  CA (red outward, blue inward, growing with the radius).
- **Fade**: each dye loses density at its own rate (1/e years for cyan, magenta, yellow):
  Kodachrome 2000, 2000, 830 (the yellow from 20 percent in 185 years, READ), Ektachrome 45, 160,
  60 (E-4 dye life about 30 years READ, cyan and yellow first INFERRED, so it runs magenta), Fuji
  120, 220, 150, the Vision3 negatives 400, 600, 500 (INFERRED).
- **Damage** (off): dust and hair block light, so dark on a reversal original and white on a
  negative's scan (INFERRED). Scratches the other
  way: an emulsion scratch on reversal lets light through, on a negative it prints dark
  (INFERRED). A splice is two frames with the cement overlap's lighter band. Roll end fog is warm
  light leaked from the left edge. The frame line is the dark bar between frames at the top.
  Dust is fresh on every frame. Hair, scratches and splices come from `DamageSchedule`, sporadic
  and seeded like the tape Damage layers, so a render repeats exactly.

## The film Looks

Seven Looks switch Film on as a scan, the two below and the five in docs/LOOKS.md ("The film
Looks"), and the three Telecine Looks switch it on for the transfer. Every other Look switches it
off, and Shuffle never rolls a film Look.

The names are short on purpose: the Look menu takes its width from its longest name, and a
longer name widens the menu on the first screen.

- **Super 8** (id `super8-kodachrome`): the Film defaults. The home movie everyone pictures: Super 8, Kodachrome
  40 through the camera's 85 in daylight, 18 fps.
- **16mm Faded** (id `sixteen-ektachrome-faded`): 16mm Ektachrome 160 under lamps, 35 years in the can, light dust,
  a hair now and then and a scratch, seed 16. The other famous film failure: the magenta drift.

## Unsourced

Stock resolving power (lp/mm), RMS for Ektachrome 160, Fuji and 500T, Super 8 weave magnitude,
home shutter angle, auto exposure behavior, camera stock base thickness and a measured halation
radius, lens figures. Each default above that rests on one of these says INFERRED.
