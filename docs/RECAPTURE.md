# Re-capture: to a CRT and back

The CRT is a round trip like the tape: the tube from the Display stage (`docs/CRT.md`) plays the
picture, a newer camera films its screen, and that recording is the output. Code:
`Sources/HomeVideoCore/RecaptureLayers.swift`, kernels in
`Sources/HomeVideoCore/Shaders/Recapture.metal`.

R/I: READ means the figure is published, in the source its bracketed number names below.
INFERRED means it is ours, by arithmetic or by eye.

Sources: [1] Wikipedia, "Kinescope". [2] Linköping University's rolling shutter tutorial
(Computer Vision Laboratory). [3] Wikipedia, "Moiré pattern". [4] Wikipedia, "Bayer filter".
[5] Wikipedia, "Phosphor". [6] Wikipedia, "Color temperature". [7] GSMArena's iPhone 8 Plus
review. [8] Wikipedia, "Macroblock".

## Where it sits

After the Display canvas. The camera films the drawn canvas, and sampling that canvas at the
sensor's own grid is what makes moire, so with Re-capture on the tube is drawn at the 2880 by 2160
canvas whatever the Display's Detail says, then resampled through the camera to the camera's size
(1920 by 1080 for the phone, 1440 by 1080 for the 4:3 camera, 1080 by 1920 for the phone held
upright). The preview and the export draw the
camera's frame.

It runs only with its switch on and a CRT layer on. Its switch is off by default, and its group
sits last in the Display tab, dimmed with "needs Display" while every CRT layer
is off. Unused, nothing in it runs: the picture is the Display stage's byte for byte, and with the
Display off the raster's (`RecaptureTests.testUnusedIsTheDisplayAndTheRasterByteForByte`). Its
seven layers are on by default, so switching the stage on gives a phone filming a TV in a dim room
at once, and each can be switched off alone.

## Framing and Camera

**Framing:** Tight by default. The camera frames inside the picture, so no bezel, corner or curve
shows. The scale is the largest that keeps
every corner of the frame inside the picture less a 10 percent margin, with the hand moved as far
as its Drift and Shake reach and through its keystone, so the edge never shows even with the hand
at its widest (`testTightShowsNoBezel`). Whole shows the tube: the screen 78 percent of the frame's
height, its rounded corners, the Geometry's curve if that is on, a dark bezel and the room. On a
frame narrower than the 4:3 screen (the upright phone) the screen is 78 percent of the frame's
width instead, so the whole picture goes across with the room above and below.

**Camera:** the phone, 1920 by 1080, by default: what people film a TV with now. Tight on 16:9
crops the 4:3 picture top and bottom rather than pillarboxing it, since a hand filming a screen
fills the frame with it. The 4:3 camera is 1440 by 1080, the picture's own shape. The 9:16 phone
is the phone held upright at 1080 by 1920: Tight's same rule keeps the picture's height
less the margin and crops its sides, and the file at Auto is 1080 by 1920. Its sensor's rows stand
on end, so the rolling readout sweeps across the frame, left to right, rather than down it
(INFERRED: a phone's sensor reads a row at a time down its short side, turned a quarter
counterclockwise from landscape). A picked SD size, or HD with the Picture choice at 4:3 inside
(the default), fits the upright frame inside the file whole, black bars at the sides, as any
stage of another shape is fitted. With Fill the frame the camera's frame takes the picked shape.

**The rate:** the export keeps the clip's frame rate. The camera rate sets the shutter's clock
(frame n is at n over the camera rate), so the bar moves per frame as that camera's would.
Retiming the file to 24 or 60 frames a second is not done.

## The layers

1. **Shutter** (`recapture-shutter`): the beam passes each height once a field, 59.94 fields a
   second [1]. Each sensor row integrates the phosphor's light over its exposure: a landing inside
   the window counts its share of the decay, one outside counts its tail. So a shutter under a
   field leaves a dark bar over 1 minus S f of the height, and the bar moves each frame by the
   fraction of the fields per frame (25 fps 0.398 a frame, 30 fps minus 0.002, 29.97 still). A
   rolling shutter starts each row Readout later (iPhone 4s 22.08 ms [2]), which stretches the bar
   and turns its drift. No bar is drawn: it is the integral, per row (`rc_caught`).
2. **Sensor** (`recapture-sensor`): a Bayer mosaic, half green, a quarter red, a quarter blue [4],
   then a bilinear demosaic. The grille's phosphors undersampled on that grid are the moire [3],
   so it moves with the triad, the framing and the hand, and it goes with the Mask off
   (`testTheMoireGoesWithTheMask`). The low pass filter blurs before the sampling [4], noise is
   shot and read noise.
3. **Exposure** (`recapture-exposure`): a gain in stops over the light, a slow seeded hunting
   around it, the white balance, then the sensor's full well clips the highlights at 1. The tube's
   white is 9300 K with its Transfer on [6], the camera aims for 6500 K [6], and the default 7500 K
   meets it partway, so a filmed TV stays a little blue.
4. **Lens** (`recapture-lens`): defocus spreads each sensor site's samples over a disc, which also
   softens the moire, and the vignette darkens the corners in the cosine fourth shape.
5. **Hand** (`recapture-hand`): drift (slow) and shake (fast), seeded sums of waves, move the
   frame. Yaw and pitch turn the screen off the camera's axis, which keystones it.
6. **Glare** (`recapture-glare`): a lamp's soft reflection fixed to the glass, and the room's
   light lifting the screen's black.
7. **Processing** (`recapture-processing`): a range weighted noise reduction, an unsharp mask
   (radius 1.2 px) that rings at edges, the camera's encode, then the codec: Rec. 709 Y'CbCr,
   chroma averaged 2 by 2 (4:2:0 [8]), an 8 by 8 luma and 4 by 4 chroma transform with a dead zone
   quantizer whose step comes from the bitrate (16 Mbps, the iPhone 8 Plus's H.264 1080p30 [7]),
   rounded to 8 bits. The transform size is ours (H.264's is 4 by 4 [8]), chosen so the blocks
   show in the dark at low bitrates as a phone's do.

Kernels, in order: `rc_optics` (Hand, Lens, Glare and Shutter: everything that happens to the
light before it reaches a well, one kernel because each of the 16 samples per site carries its own
place, focus and time, and `rc_optics_across` in its place for the phone held upright, whose
rows read across the frame), `rc_sensor` (Exposure and the wells), `rc_demosaic` (Sensor), then
Processing's `rc_denoise`, `crt_blur` twice, `rc_sharpen` and `rc_codec`. Exposure and the
Sensor share `rc_sensor` because the clip at the full well comes after the gain and before the
mosaic.

## Defaults and ranges

`RecaptureTests.testDefaultsAndRangesMatchTheDoc` reads this table and checks every row against
the layers. A choice lists its options in Min.

| Layer | Parameter | Default | Min | Max | R/I | Basis |
|---|---|---|---|---|---|---|
| recapture | framing | tight | tight, whole | | INFERRED | a hand filming a screen crops into the picture |
| recapture | camera | phone-1920x1080 | phone-1920x1080, camera-1440x1080, phone-1080x1920 | | INFERRED | a phone is what films a TV now, sideways or held upright |
| recapture | seed | 1 | 0 | 999 | INFERRED | a take |
| recapture-shutter | rate | 30 | 24, 25, 29.97, 30, 60 | | READ | 24, 25, 29.97 and 30 frames [1], a phone's 30 |
| recapture-shutter | shutter | 70 | 30 | 500 | INFERRED | a seventh of each field missed, a soft bar, by eye (1/80 darkened 40 percent of the frame) |
| recapture-shutter | kind | rolling | rolling, global | | READ | phones read out rolling [2] |
| recapture-shutter | readout | 22.08 | 0 | 33 | READ | iPhone 4s 22.08 ms [2] |
| recapture-shutter | decay | 2 | 0.05 | 4 | INFERRED | P22 blue 200 ns READ [5], red and green no figure, 2 ms leaves the bar dim, not black |
| recapture-sensor | mosaic | 1 | 0 | 1 | READ | the Bayer split [4] |
| recapture-sensor | olpf | 0.25 | 0 | 1 | INFERRED | an OLPF READ [4], its width by eye |
| recapture-sensor | noise | 0.01 | 0 | 0.05 | INFERRED | no figure found |
| recapture-exposure | bias | 0.3 | -2 | 2 | INFERRED | a bright screen clipping a little, by eye |
| recapture-exposure | hunt | 0.15 | 0 | 1 | INFERRED | no figure found |
| recapture-exposure | period | 4 | 1 | 10 | INFERRED | no figure found |
| recapture-exposure | white | 7500 | 5000 | 9300 | INFERRED | 9300 K tube and 6500 K camera READ [6], partway |
| recapture-lens | defocus | 0.6 | 0 | 4 | INFERRED | by eye |
| recapture-lens | vignette | 0.2 | 0 | 0.6 | INFERRED | the cosine fourth shape, its depth by eye |
| recapture-hand | drift | 0.5 | 0 | 3 | INFERRED | no figure found |
| recapture-hand | shake | 0.8 | 0 | 4 | INFERRED | no figure found |
| recapture-hand | yaw | 4 | -20 | 20 | INFERRED | off axis reduces moire, 30 degrees READ [3] |
| recapture-hand | pitch | -2 | -15 | 15 | INFERRED | a camera held a little high |
| recapture-glare | strength | 0.04 | 0 | 0.3 | INFERRED | no figure found |
| recapture-glare | size | 0.25 | 0.05 | 0.6 | INFERRED | no figure found |
| recapture-glare | x | 0.78 | 0 | 1 | INFERRED | a lamp to the right |
| recapture-glare | y | 0.22 | 0 | 1 | INFERRED | and high |
| recapture-glare | room | 0.006 | 0 | 0.05 | INFERRED | a dim room |
| recapture-processing | sharpen | 0.8 | 0 | 2 | INFERRED | unsharp amount 50 to 150 percent is common advice (Wikipedia, "Unsharp masking") |
| recapture-processing | denoise | 0.4 | 0 | 1 | INFERRED | by eye |
| recapture-processing | bitrate | 16 | 2 | 50 | READ | H.264 1080p30, 16 Mbps [7] |

## The Looks

Four Looks film the screen, every CRT layer and the camera on. Two are here, **Filmed TV**
(Fresh SP's tape) and **Phone Dub** (Dub of a Dub's deck, three generations, a fifth of a stop
more exposure, more drift and 8.5 Mbps, the HEVC rate [7], and the 9:16 phone held upright with
Tight, so its file at Auto is 1080 by 1920), and Tripod TV and Up Close are in docs/LOOKS.md ("The
Display Looks"). Every other Look switches the camera off (its values
kept) and leaves the Display as it is. A filmed Look reads back only with its Display and camera as it set them. Shuffle
rolls tapes, not cameras: it never picks a filmed Look.

## What is not modeled

Retiming the file to the camera's rate, the interlace's line parity under the shutter (the beam
passes every height once a field here, and the Display's field fade carries the rest), the
vertical blanking interval, motion blur from the hand inside one exposure, rolling shutter skew of
the hand's motion, lens distortion, and the encoder's motion search and deblocking.
