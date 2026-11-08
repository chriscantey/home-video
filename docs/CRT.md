# CRT: the Display stage

The Display stage puts the captured picture on a consumer NTSC tube: six layers after the
capture, each a named mechanism, each off by default, every value a slider. Only the Looks that film the
screen turn them on.
Code: `Sources/HomeVideoCore/CRTLayers.swift`, kernels in `Sources/HomeVideoCore/Shaders/CRT.metal`.

R/I: READ means the figure is published, in the source its bracketed number names below.
INFERRED means it is ours, by arithmetic or by eye.

Sources: [1] Wikipedia, "Dot pitch". [2] Wikipedia, "Phosphor". [3] Wikipedia, "Overscan".
[4] crt-royale's user settings (libretro slang-shaders), values only. [5] Wikipedia, "Color
temperature". [7] Wikipedia, "NTSC". [8] Wikipedia, "Gamma correction".

## The canvas

A TV's triad is about one source pixel wide, and 480 scanlines in a 480 line raster leave no
room for a gap. So with any CRT layer on the stage draws the 720 by 480 raster onto its own 4:3
canvas with square pixels at the Display's Detail, and the preview and the export draw that
canvas, which the file fits to its Output size (1440 by 1080 at Auto, whatever the Detail).
At 1440 by 1080 a scanline is 2.25 canvas pixels tall, at 2880 by 2160 it is 4.5. With all six
off the stage does not run: the raster, the preview, the export and every byte of the default
picture are unchanged (`CRTTests.testAllOffIsTheRasterByteForByte`).

The stage runs in linear light. Transfer decodes the signal (gamma 2.2, the encode, when
Transfer is off), the beam, mask and glow act on light, and the last kernel encodes with 1/2.2
for the file. Nothing in it is random: the only thing that moves frame to frame is which field
is drawn brighter, from the frame number, so a render repeats byte for byte.

Kernels, in order: `crt_transfer` (raster size), `crt_scan` (beam and geometry onto the canvas),
`crt_mask`, `crt_glow_down`, `crt_blur` (twice per blur, at a quarter of the canvas),
`crt_glow`, `crt_glass` (glass and the encode). Geometry has no kernel of its own: where the beam
lands is the scan, and bending the picture after the scanlines are drawn would resample them.

## The layers

1. **Transfer** (`crt-transfer`): the tube decodes at 2.35 to 2.55 a signal encoded for 2.2 [8],
   crt-royale's crt_gamma 2.5 over lcd_gamma 2.2 [4]. Black lift is the brightness knob a
   little high. The white point moves D65 to a color temperature on the CIE daylight locus,
   scaled so the strongest gun is at full (a 9300 K white is bluer and a little dimmer, as on a
   set). SMPTE C's white is 6500 K, NTSC-J recommends 9300 K, US consumer sets shipped bluer than
   6500 K [5]. The phosphors are SMPTE C [7], the primaries the export is tagged with, so no
   primaries matrix runs: the white point is the change.
2. **Beam and scanlines** (`crt-beam`): every raster line is a Gaussian spot whose sigma, in line
   spacings, runs from Spot dark at black to Spot bright at full, per gun on that gun's level,
   so dark lines are thin with a gap and highlights fatten and bloom [4]. Each canvas pixel
   integrates the spot over its height, so a thin line keeps its light and does not alias.
   Interlace: the 480 lines are two fields of 240 at 60 a second [7]. The field drawn last is
   at full and the other at 1 minus Field fade, alternating every frame, with the mean held.
3. **Mask** (`crt-mask`): colored phosphors. A shadow mask's dots (three phosphor columns per
   triad, rows a triad tall with a quarter gap, alternate triads offset half a row) or an
   aperture grille's stripes, red, green and blue in turn, each passing only its own gun's
   light. Triad in canvas pixels, crt-royale's 3.0 [4]. Strength mixes the mask in, divided by
   its mean so the picture keeps its level: at 1 a red phosphor shows red only. Coverage is
   worked out exactly across the pixel and on four rows down, so a triad of 2.5 px does not
   stair. This is the layer most likely to read as a filter, so the default strength is low. Up close is where it shows: with a CRT layer on, the preview's pinch and drag
   zoom the Display canvas (to 16 times, square pixels past 2 to 1), and a double-click goes back.
4. **Glow** (`crt-glow`): refractive diffusion mixes a blur of the light into the picture,
   weight 0.075 [4]. Halation adds a wider blur on top, default 0 [4]. The blur widths, 1 and 4
   percent of the canvas height, are INFERRED: the source gives weights, not radii.
5. **Geometry** (`crt-geometry`): overscan ("Some say 5%, some say 10%" [3]) hides the head
   switch and the blanking bars. Barrel bows straight lines out from the curved faceplate.
   Corner falloff dims the corners. Tilt rotates the raster in the yoke (its id is `tilt` so
   it never reads as framing's rotation, which the clipboard leaves out). Convergence: red lands
   right and down, blue left and up, green on the mark, crt-royale's offsets run 0.1 to 0.6
   lines [4].
6. **Glass** (`crt-glass`): a neutral density tint passes 1 minus Tint of the picture, the room
   reflects off the front (a lift the tint does not dim), and the light scattered in the glass
   gives a faint glow in the blacks (read from the halation blur). No published figures:
   all INFERRED, tuned by eye, subtle by default.

## Defaults and ranges

`CRTTests.testDefaultsAndRangesMatchTheDoc` reads this table and checks every row against the
layers. A choice lists its options in Min.

| Layer | Parameter | Default | Min | Max | R/I | Basis |
|---|---|---|---|---|---|---|
| crt-display | size | 1440x1080 | 960x720, 1440x1080, 2880x2160 | | INFERRED | 1440 is 2 times 720 |
| crt-transfer | gamma | 2.5 | 2.2 | 2.6 | READ | crt_gamma 2.5 [4], CRT gamma 2.35 to 2.55 [8] |
| crt-transfer | lift | 0.01 | 0 | 0.03 | INFERRED | 0 to 3 percent, no published figure |
| crt-transfer | white | 9300 | 6500 | 9300 | READ | 6500 K standard, 9300 K NTSC-J, US sets bluer [5] |
| crt-beam | dark | 0.1 | 0.02 | 0.5 | INFERRED | crt-royale's range 0.02 to 0.3 READ [4], 0.5 our top |
| crt-beam | bright | 0.3 | 0.02 | 0.5 | READ | crt-royale's beam_max_sigma 0.3 [4] |
| crt-beam | fade | 0.15 | 0 | 1 | INFERRED | 60 fields a second READ [7], the fade by eye |
| crt-mask | kind | aperture-grille | shadow-mask, aperture-grille | | INFERRED | both READ [1], the grille by eye: the shadow mask's rows beat with 2.25 px scanlines into a plaid |
| crt-mask | triad | 3 | 2 | 6 | READ | crt-royale's mask triad size 3.0 [4] |
| crt-mask | strength | 0.25 | 0 | 1 | INFERRED | low on purpose, the layer most likely to read as a filter |
| crt-glow | diffusion | 0.075 | 0 | 0.3 | READ | diffusion_weight 0.075 [4] |
| crt-glow | halation | 0 | 0 | 0.2 | READ | halation_weight 0.0 [4] |
| crt-geometry | overscan | 0.05 | 0 | 0.1 | READ | "Some say 5%, some say 10%" [3] |
| crt-geometry | barrel | 0.03 | 0 | 0.1 | INFERRED | by eye, mild |
| crt-geometry | falloff | 0.15 | 0 | 0.3 | INFERRED | by eye |
| crt-geometry | tilt | 0 | 0 | 0.5 | INFERRED | a set tilted in its yoke, default square |
| crt-geometry | convergence | 0.1 | 0 | 1 | INFERRED | crt-royale's offsets 0.1 to 0.6 lines READ [4] |
| crt-glass | tint | 0.1 | 0 | 0.5 | INFERRED | no published figure |
| crt-glass | reflection | 0.01 | 0 | 0.1 | INFERRED | no published figure |
| crt-glass | blackglow | 0.02 | 0 | 0.2 | INFERRED | no published figure |

## Saving, the Looks and the CLI

The CRT layers are saved like the Damage layers: a sidecar, a saved preset and Copy Settings carry
every CRT switch and value and the Display's Detail. They live in `VHSLayers.crt`, outside
`VHSLayers.all`, so only the Looks that film the screen (Filmed TV, Phone Dub, Tripod TV and Up
Close) set and read them. Choosing any other built-in Look, or Reset to it, leaves the Display as
it is, and switching a CRT layer on under one of those does not turn the Look picker to Custom.
A preset or sidecar that carries CRT layers sets them. `homevideo-render --set
crt-beam.enabled=on --set crt-display.size=2880x2160` renders the canvas, and `--list-layers`
marks the stage's layers `display`.

## What is not modeled

Phosphor persistence beyond the field fade (P22 blue decays in 200 ns [2], red and green have no
figure), the picture growing when bright (the anode voltage sag [3]), moire between the mask and
the scanlines beyond what the sampling gives, and the bezel.
