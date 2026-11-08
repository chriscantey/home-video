# Telecine: the film to video transfer

How a film became NTSC video, between the Film source and the tape.

## Where it sits

Telecine is a stage of its own, off at launch. Its switch is in the Look tab's Stages list, and
while it is on the stage has its own tab, after Film's. It needs nothing else on: with the Film
off it transfers the clip itself (below). With Telecine
unused the chain, its fingerprint, the sidecar and preset files, the Looks and the first screen
are unchanged.

While Telecine and Film are on, the path is the film, then the transfer to NTSC 29.97 interlaced
at the 720 by 480 raster, then the VHS chain as the Look sets it, the Camera skipped. With the
Tape switched off the transfer itself is written, as digital video at the raster: a
straight transfer to digital. The stage's own switch routes it, and an older file's output
choice is folded into the switches (docs/FILM.md).

Two routes, a choice in the tab, each showing only its own layers:

- **Home transfer**: a projector aimed at a screen (or a mirror box) and a camcorder shooting it.
  Cadence (the projector's speed), Shutter flicker, Projector light, Geometry, Camera, Gate.
- **Pro telecine**: a flying spot or CCD scanner. Cadence (the pulldown), Scanner, Grade, Gate.

A Quality choice, Mall, Mid-grade or Pro, sets the route's layers to the tier table
below as a starting point. The sliders stay free after it. The tier table is INFERRED.

With the Film off the stage transfers the framed source, as if the clip were the film:
each film frame is the clip's picture at that moment. Home's projector runs at its own speed as
always. Pro's "As shot" has no Film frame rate to read and takes 24 fps, 2:3 (INFERRED, the
speed a telecine is built around). The gate's dust reads dark, the clip standing in for a
positive, and the grade's fade correction has no fade to undo. The Telecine Looks still turn
the Film on.

## The fields

Every output frame is two fields, 1/59.94 s apart (READ, 60000/1001). The first in time goes on
the odd rows, the second on the even rows, bottom field first as NTSC DV is. Each field shows the
film frame the transfer puts there, so where two fields of one frame hold different film frames
a moving edge combs, as a real transfer does.

- **Pro**: the pulldown counts fields. 24 fps film runs at 23.976 (READ) as 2:3, A-A-B-B-B-C-C-D-D-D,
  10 fields from 4 frames (READ). 18 fps (17.982) as 3:3:4, 10 fields from 3 frames (READ). 16 fps
  (15.984) as 3:4:4:4, 15 fields from 4 frames (READ). "As shot" takes the Film's own frame rate.
- **Home**: the projector runs free at its own speed and the camera knows nothing of it. The
  projector's shutter has its blades, each frame flashed once per blade, and the film moves
  behind the last one (INFERRED, open half of each cycle). The camera gathers each row's light
  over its exposure: a tube reads each row a field after its last read, at its own time down the
  field, so the brightness changes roll through the picture as a band. A CCD exposes the whole
  field over its shutter. The weights per row, how much of the first film frame and how much of
  the next, are worked out on the CPU from that arithmetic (`TelecineLayers.exposure`) and nothing
  is drawn. At 18 fps with 3 blades, 54 flashes against 59.94 fields beat at 5.94 Hz (INFERRED,
  by arithmetic), and `TelecineTests` measures the peak there. 20 fps with
  3 blades, 60 flashes, is the READ fix and beats at 0.06 Hz. A five blade telecine projector
  (READ) runs at 24 fps: 120 flashes, two a field, beating at 0.12 Hz. At 18 fps the same five
  blades are 90 flashes, a 29.9 Hz beat, and a CCD's fields alternate at 0.67 and 1.33 of the
  light, so the Mid-grade tier runs its projector at 24 (`testHomeTierFlickerFollowsTheTierTable`).

The picture keeps the clip's timing: a projector at 20 fps would play 18 fps film 11 percent fast,
but the transfer's speed here sets only the cadence and the beat, so the sound stays in sync.
Film frames are drawn from the source frame present when a field first needs them, each once.

## Order

Per film frame, at the gate: the Film's own layers, then the Gate (weave, a splice, overscan,
dust), then at Home the Projector light and the Geometry of the screen in the camera's frame.
Per field: the compose (the cadence, and at Home the flicker's weights), then at Home the Camera,
or on Pro the Scanner and the Grade. Then the interlace. Kernels: `Shaders/Telecine.metal`.

## The layers as built

`id` is the layer, `parameter` its value, then the default, the range (or the options), and
whether the default is READ from a published source or INFERRED. Every default is the Mall tier of its
route, since Mall is the stage's default quality. `TelecineTests.testDefaultsAndRangesMatchTheDoc`
checks every row against the code.

| layer | parameter | default | range | source | note |
|---|---|---|---|---|---|
| telecine | enabled | off | | INFERRED | the master switch, off |
| telecine | route | home | home, pro | INFERRED | a home transfer or a pro telecine |
| telecine | quality | mall | mall, mid, pro | INFERRED | the tier table is INFERRED |
| telecine-cadence | enabled | on | | INFERRED | |
| telecine-cadence | speed | film | film, 24, 18, 16 | INFERRED | Pro: as shot, the cadences 2:3, 3:3:4, 3:4:4:4 by film speed READ |
| telecine-cadence | projector | 18 | 14 to 26 | READ | Home: fps, Super 8's 18 |
| telecine-flicker | enabled | on | | INFERRED | |
| telecine-flicker | blades | 3 | 2, 3, 5 | READ | three blades typical, five on telecine projectors |
| telecine-flicker | camera | tube | tube, ccd | INFERRED | a tube rolls a band, a CCD pulses the whole field |
| telecine-flicker | shutter | 60 | 60 to 250 | INFERRED | 1/s, one transfer used 100 to 150 (READ) |
| telecine-light | enabled | on | | INFERRED | |
| telecine-light | hotspot | 35 | 0 to 50 | INFERRED | percent |
| telecine-light | falloff | 40 | 0 to 60 | INFERRED | percent |
| telecine-light | lamp | 3000 | 2800 to 3400 | INFERRED | K against the camera's 3200 preset |
| telecine-geometry | enabled | on | | INFERRED | |
| telecine-geometry | keystone | 4 | 0 to 10 | INFERRED | degrees |
| telecine-geometry | edge | 0.6 | 0 to 1 | INFERRED | the gate's edge on the screen |
| telecine-geometry | texture | 0.6 | 0 to 1 | INFERRED | the screen's surface, READ as a cause of loss |
| telecine-camera | enabled | on | | INFERRED | |
| telecine-camera | softness | 0.5 | 0 to 1 | INFERRED | 1.5 px sigma at full |
| telecine-camera | lag | 0.5 | 0 to 1 | INFERRED | trails READ, no decay figure found |
| telecine-camera | hunt | 0.6 | 0 to 1 | INFERRED | iris up to half a stop, white balance a few percent |
| telecine-camera | glow | 0.4 | 0 to 1 | INFERRED | the camera's own bloom |
| telecine-camera | seed | 0 | 0 to 999 | INFERRED | |
| telecine-scanner | enabled | on | | INFERRED | |
| telecine-scanner | afterglow | 0.3 | 0 to 1 | INFERRED | Mall is an early flying spot |
| telecine-scanner | noise | 0.4 | 0 to 1 | INFERRED | CCD and photomultiplier noise unsourced |
| telecine-scanner | streaks | 0 | 0 to 1 | INFERRED | a CCD's column streaks, none on a flying spot |
| telecine-scanner | seed | 0 | 0 to 999 | INFERRED | |
| telecine-grade | enabled | on | | INFERRED | neutral at its defaults |
| telecine-grade | liftR | 0 | -0.1 to 0.1 | INFERRED | per channel primaries READ |
| telecine-grade | liftG | 0 | -0.1 to 0.1 | INFERRED | |
| telecine-grade | liftB | 0 | -0.1 to 0.1 | INFERRED | |
| telecine-grade | gammaR | 1 | 0.5 to 2 | INFERRED | |
| telecine-grade | gammaG | 1 | 0.5 to 2 | INFERRED | |
| telecine-grade | gammaB | 1 | 0.5 to 2 | INFERRED | |
| telecine-grade | gainR | 1 | 0.5 to 1.5 | INFERRED | grading by gain per channel READ |
| telecine-grade | gainG | 1 | 0.5 to 1.5 | INFERRED | |
| telecine-grade | gainB | 1 | 0.5 to 1.5 | INFERRED | |
| telecine-grade | fade | 0 | 0 to 1 | INFERRED | none at Mall, per reel at Mid, scene by scene at Pro |
| telecine-gate | enabled | on | | INFERRED | |
| telecine-gate | dust | 0.7 | 0 to 1 | INFERRED | heavy and uncleaned at Mall |
| telecine-gate | bump | 1 | 0 to 1 | INFERRED | jump and flash at Mall |
| telecine-gate | weave | 0.6 | 0 to 1 | INFERRED | px, magnitude unsourced |
| telecine-gate | overscan | 8 | 0 to 10 | INFERRED | percent, large at Mall |
| telecine-gate | seed | 0 | 0 to 999 | INFERRED | |

## The tier table

What each Quality tier sets. All INFERRED.

| route | layer.parameter | Mall | Mid-grade | Pro |
|---|---|---|---|---|
| Home | cadence.projector | 18 | 24 (5 blades, 120 flashes, two a field) | 20 (the READ flicker fix) |
| Home | flicker.blades | 3 | 5 | 3 |
| Home | flicker.camera | tube | CCD | CCD |
| Home | flicker.shutter | 60 | 60 | 60 |
| Home | light.hotspot, falloff, lamp | 35, 40, 3000 | 12, 15, 3150 (a mirror box) | 3, 5, 3200 |
| Home | geometry.keystone, edge, texture | 4, 0.6, 0.6 | 0.5, 0.25, 0.1 | 0, 0, 0 |
| Home | camera.softness, lag, hunt, glow | 0.5, 0.5, 0.6, 0.4 | 0.3, 0.15, 0.25, 0.2 | 0.15, 0.05, 0.05, 0.1 |
| Pro | cadence.speed | as shot | as shot | as shot |
| Pro | scanner.afterglow, noise, streaks | 0.3, 0.4, 0 | 0.15, 0.25, 0.15 | 0.05, 0.1, 0.05 |
| Pro | grade.fade | 0 | 0.5 | 1 |
| both | gate.dust, bump, weave, overscan | 0.7, 1, 0.6, 8 | 0.3, 0.6, 0.35, 5 | 0.05, 0.3, 0.1, 3 |

## What each layer does

- **Cadence**: which film frame each field shows, as above. Off, both fields of a frame show the
  film frame at the frame's time, a transfer locked to the frame.
- **Shutter flicker** (Home): the projector's flashes integrated by the camera, row by row. Blades
  and the projector speed set the flash rate, the camera's exposure sets how deep the beat goes.
  A CCD shutter faster than 1/60 samples the flashes more sharply and deepens it. Off, each field
  sees the frame on the screen at its time, steady.
- **Projector light** (Home): the lamp's hot spot at the center, falloff to the corners (r squared),
  the lamp's color by Planck's law at 610, 550 and 465 nm against the camera's 3200 K preset,
  luminance kept.
- **Geometry** (Home): keystone, the camera off the projector's axis so the picture widens toward
  the top. The gate's edge: the projected picture smaller than the camera's frame, its rounded
  corners soft on the unlit screen. The screen's texture: a fine matte grain fixed in the camera's
  frame, so the picture slides over it as it weaves.
- **Camera** (Home): softness (a 5 by 5 Gaussian), glow (light over the knee spread on rings of 3
  and 7 px), tube lag (the charge over the knee left on the target, decaying field by field, so a
  moving highlight trails, white or colored, READ), and the iris and white balance hunting (two
  slow wanders, about 0.3 and 0.7 Hz). The glow is this stage's own: halation is the Film's, the
  glass glow the CRT's.
- **Scanner** (Pro): the flying spot's afterglow, a streak decaying to the right of whites (READ,
  "decaying white streak to the right of any white information"), with a 20 us tail (READ, the
  corrector's delay span 20 to 50 us) at 13.7 raster px per us. The photomultiplier's shot noise,
  growing with the light. A CCD line sensor's column streaks, one gain per element, so a streak runs
  the height of the frame.
- **Grade** (Pro): the fade correction, then lift, gamma and gain per channel. The fade correction
  balances the Film's dye loss (its Fade years and stock) with a power per channel and puts back
  half the lost contrast. The fade takes each channel to the power k, which leaves white and black
  neutral, so the correction takes each to the power s/k, one contrast s for all three halfway from
  the fade's mean k back to 1: every tone of a faded Ektachrome comes back gray, its white still
  white, a little flat. A gain per channel alone would pin mid gray to 0.18 and tint white the
  other way.
- **Gate** (both): the transfer gate's weave, smoothed over about three frames. A splice through the
  gate once a minute, the frame jumping up to 10 lines for two frames with a flash on the first.
  The overscan crop. Dust and hair the transfer did not clean off. Dust blocks the light, so it is
  dark on a reversal original and light on a negative, as the Film's damage is.

## The Look

Three Looks send the film through the Telecine. **8mm to Tape** (id `home-movie-transfer`): the
Film defaults (Super 8 Kodachrome 40, 18 fps), Home transfer at Mall quality, onto an SP tape on an
aged deck over composite, Linear audio. The classic home movie transferred to tape. **Mall
Transfer** and **Pro Scan** are in docs/LOOKS.md ("The Telecine Looks"). No other Look turns
Telecine on, and Shuffle never rolls one of them. The name is short on purpose, since the Look menu
takes its width from its longest name.

## Unsourced

Lamp color and hot spot, the blade duty, tube lag decay, weave and frame line, grading levels,
scanner noise and CCD streak amplitude, the tier figures. Each default above that rests on one of
these says INFERRED.
