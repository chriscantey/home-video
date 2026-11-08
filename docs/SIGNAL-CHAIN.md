# Home Video signal chain

The chain is a list of layers in the order of the physical signal path: output card, the record
electronics, the tape, the playback electronics, the capture card. Each layer models one mechanism
and carries a toggle plus the parameters that mechanism needs. The defaults come from published figures
or from ntsc-rs's tuned values where no published figure exists, and each default says which. READ
marks a published figure, INFERRED a value set by arithmetic or by eye. With every layer off the
picture is the source.

## Working signal

- Raster: 720 by 480, the Rec. 601 NTSC active picture, sampled at 13.5 MHz. One sample is 1/13.5 us,
  so a cutoff of f MHz is f/13.5 cycles per sample. 720 samples of 13.5 MHz is 53.3 us of line.
- Domain: component YIQ in float (RGBA16Float textures: Y in R, I in G, Q in B, A unused). Y is 0 to 1
  for black to white. The tape never sees a composite signal: VHS records luma as FM and chroma as a
  separate color-under carrier, so the VHS stage is a component process. Composite matters only at
  the two links (output card to VCR, VCR to capture card), and those are their own layer, off by
  default (S-Video at both ends).
- Fields: NTSC is interlaced, and the head switch, the noise seeds and the vertical chroma blend are
  per field. Each layer that depends on it runs over one field at a time (the even lines, then the
  odd lines, with their own field index). A progressive source gives both fields from one frame
  unless the Fields layer's "temporal fields" option is on.
- Filters along a line are causal IIR, one thread per line (or per line and field), left to right.
  Analog filters are causal, which is why smear and lag trail to the right of an edge. A symmetric
  FIR would smear both ways and look wrong. 480 threads each walking 720 samples through a few
  biquads is well inside real time on a Radeon Pro 5500M.
- Noise is hash-based (a PCG integer hash of seed, layer id, frame, field, line,
  sample), so every frame is reproducible and the export matches the preview. Colored noise is white
  noise pushed through the same per-line IIR as the signal it rides on.
- Horizontal position changes (head switch skew, time base jitter) are per-pixel gather kernels with
  linear interpolation, one thread per pixel.

## The path: five stages

The layers below sit in five stages, in the order a picture really went: **Film** (the source,
off by default), **Telecine** (film to video, or the clip itself with the Film off), **Tape** (the VHS round trip, L1 to L9
and their neighbors, on by default), **Display** (the tube, any CRT layer on) and **Re-capture**
(a camera filming the tube, needs the Display). Each is a switch `SignalChain` asks "is it on",
and an off stage passes the picture straight to the next one. The defaults are Tape on and every
other stage off, the VHS chain alone.

One rule for the canvas. Each stage takes whatever the stage before it gives, and at Output size
Auto, the default, the file is the last stage's picture at its own size, which
`SignalChain.naturalOutput` names:

| Last stage on | Picture | Size | Pixels and tags |
|---|---|---|---|
| Tape | the capture | 720 by 480 | 10:11 shown 4:3, SMPTE-C, 601 |
| Telecine, Tape off | the transfer as digital video | 720 by 480 | as the tape's, it is NTSC video |
| Film, Tape off | the film scan | 1440 by 1080, whatever the Scan detail | square, 709 |
| none (every stage off) | the source untouched, upright | the source's own | square, 709 |
| Display | the tube's canvas | 1440 by 1080, whatever the Display's Detail | square, the raster's tags |
| Re-capture | the camera's frame | 1920 by 1080, 1440 by 1080 or 1080 by 1920 | as the Display's |

The Output size on the Look tab picks another size for the file: Match source, SD 720 by 480,
HD 1920 by 1080, 4K 3840 by 2160, Phone 1080 by 1920 or Custom. The last stage's picture is then
fitted inside it whole, never stretched or cropped, with black bars where the shapes differ. A
picked SD file has the raster's 10:11 pixels and 601 tags, and any other picked size of the
raster's picture has square pixels with the raster's tags. For a picked size that is not 4:3 the
Picture choice can fill the frame instead: every stage then works at the frame's shape, the
scan, the tube and the camera's frame keep their height and take that shape, and the raster
stays 720 by 480 with the wide picture squeezed into it. `homevideo-render` takes the same
choices as `--size` and `--fit inside|fill`.

The Display draws its own 480 visible lines from what it is fed: the tape's raster, a Telecine
transfer (both 720 by 480 already), the framed source (Framing alone onto the raster, with the
Tape off and no Film), or a Film scan, which is fitted to the 720 by 480 grid first (the whole 4:3
picture with Framing's box filter, as a player's output would feed a set). The status line and
the export sheet say the file's size. The Tape switch is `VHSLayers.tape` (TapeStage.swift),
reached by `--set tape=off`, `-homevideoSet tape=off` and the Tape stage's switch in the sidebar.

## Layers in order

### L0 Framing (scaffold, always on)

Crop to fill with pan (`cropCenter`, the default), Fit inside (`letterbox`) or Stretch
(`fullRaster`), from any source size to 720 by 480, or with every stage off onto the file's own
canvas. Output is RGB in
the source's Rec. 709 encoding.

As built: the track's preferredTransform sets a `rotation` parameter (0, 90, 180, 270), applied
before the framing math, so a portrait iPhone clip is pillarboxed in letterbox. Each output pixel
box filters its source footprint (up to 8 by 8 bilinear taps), which lifts chain-off PSNR on a
1080p test clip from 38.0 to 41.5 dB.

Center crop zoom: `zoom` (1 to 2, default 1) divides the largest 4:3 window's width and
height, and `pan` (x) and `panY` (y), each -1 to 1, place it along each axis with room: `x = (1 -
w)(pan + 1) / 2`, `y = (1 - h)(panY + 1) / 2`, all clamped, so the window never leaves the
picture. At zoom 1 a wide source moves only sideways and a portrait one only up and down (panY),
exactly the framing before zoom. Under Fit inside the zoom grows the fitted picture and the bars
shrink, and the pans move it once zoomed. Stretch ignores all three. The box prefilter
follows the smaller window, so a zoomed crop of a 1080p clip takes fewer taps per pixel.

### Film: the Film source (off by default)

A source stage ahead of the output card and the camera: what a home movie camera and its stock do
to the picture (Format, Stock, Light, Tone, Grain, Halation, Weave, Shutter and flicker, Optics,
Fade, Damage). Off unless its master switch is on, and then it replaces the Camera, which does
not run. The layers live on `VHSLayers.film`, outside `VHSLayers.all`, so with Film unused the
chain, its plan and its fingerprint are the same as without it. On, `SignalChain.encode` hands the frame to the
Film: Framing places the source on the film canvas, the Film layers run there, and then with the
Tape off that canvas is the picture (the **Scan**, 1440 by 1080 square pixels, drawn at 1440 by 1080 or 2880 by 2160 by the Scan
detail, the VHS chain bypassed), and with the Tape on the film is rendered at the 720 by 480 raster in
Framing's place and the rest of the chain runs as the Look sets it. With its Shutter layer on, the Film holds frames to 18 or
24 fps. Figures, order and sources: `docs/FILM.md`. Kernels: `Shaders/Film.metal`.

### Telecine: the film to video transfer (off by default)

Between the Film and the tape: how the film became NTSC video. Off unless its master switch is
on, and then it takes Framing's place: the film (with the Film off, the framed source, as if the
clip were the film) goes through the transfer to 29.97
interlaced at the 720 by 480 raster, and with the Tape on the rest of the chain runs on that as
the Look sets it, the Camera skipped. With the Tape off the transfer is the picture, written as
digital video at the raster (a straight transfer to digital). The layers live on `VHSLayers.telecine`, outside `VHSLayers.all`, so
with Telecine unused the chain, its plan and its fingerprint are the same as without it. Every output frame is
two fields 1/59.94 s apart, the first in time on the odd rows (bottom field first). Two routes:
**Home transfer**, a free running projector (14 to 26 fps, its blades flashing each frame 2, 3 or
5 times) shot by a camcorder whose exposure, row by row on a tube, weighs the flashes, so a field
can hold two film frames and its light beats against the flash rate (18 fps by 3 blades, 54
flashes against 59.94 fields, 5.94 Hz), and **Pro telecine**, whose pulldown counts fields (2:3
for 24 fps, 3:3:4 for 18, 3:4:4:4 for 16). Per film frame the Gate (weave, a splice, overscan,
dust) and at Home the projector's light and the screen's geometry. Per field at Home the Camera
(softness, glow, tube lag, hunting), on Pro the Scanner (afterglow, noise, CCD streaks) and the
Grade (fade correction, lift, gamma, gain). Figures, order and sources: `docs/TELECINE.md`.
Kernels: `Shaders/Telecine.metal`.

### Camera: the camcorder ahead of the deck (off by default)

Mechanism: on camcorder footage much of the look is the camera, not the deck: a soft lens and tube or CCD, highlights
that clip and bloom, crushed or murky blacks, a white balance cast, a little lens falloff.

Modeled as (in the framing's RGB, before L1, one 7 by 7 gather per pixel): a Gaussian soft focus
both ways, exposure, a bloom of the luma above 0.85, a toe c^2 (1 + t) / (c + t) that keeps 0 and
1 and flattens the shadows, a soft per channel highlight clip above 0.85, a white balance in Rec.
601 Y Cb Cr (a Cb and Cr shift in studio codes, then a hue turn of the Cb Cr plane), and a
vignette 1 - v r^2 / 2 with r = 1 at the corners.

Parameters and defaults: soft focus 1.6 MHz at -3 dB (sigma 1.12 px, with SP's 2.4 MHz this
lands near the -10 dB point of the sharpest measured tape), exposure 0 stops, bloom 0.6, black
crush 0.04, Cb 0, Cr 0, hue 0, vignette 0.15 (bloom, crush and vignette INFERRED by eye). The
Source preset's Camcorder sets the tungsten balance measured on a 1986 tape: Cb -3, Cr +5 codes,
hue -15 degrees. Look: a softer, warmer picture with glowing highlights and darker
corners.

### L1 Output card: RGB to YIQ

Mechanism: the computer's video output card converts to the NTSC component signal. Convert 709 RGB to
YIQ with the Rec. 601 matrix (SMPTE-C primaries), so the simulated raster is tagged and treated as SD.
No parameters. Cost: one pass per pixel. Always on when any later layer is on (it is the domain
change), and the matching inverse sits in L9.

As built: the FCC YIQ matrix on the gamma encoded RGB, and an inverse computed in Swift rather
than typed, so L1 then L9 is identity within float precision (tested within 1/255). The toggle
locks on while any of L2 to L8 is on, and L9 follows L1. With all of them off neither runs and
the output is the Framing output bit for bit.

### L2 Composite link (off by default)

Mechanism: with a composite cable rather than S-Video, luma and chroma share one wire. Chroma is
modulated onto the 3.58 MHz subcarrier and the receiver separates them imperfectly, which gives dot
crawl along colored vertical edges and cross color (rainbows) on fine luma detail. Modeled as in
ntsc-rs and composite-video-simulator: at 4 samples per subcarrier cycle the carrier is the table
[1, 0, -1, 0] for I and [0, 1, 0, -1] for Q, phase flipping per line and per frame. The composite
sample is Y + I*c_i + Q*c_q, and separation is a notch (default), a 1-line comb or a 2-line comb. Working
at 13.5 MHz the subcarrier is 3.579545/13.5 = 0.2652 cycles per sample, not exactly a quarter, so the
carrier is generated with a running phase accumulator rather than the 4-entry table. The look is the
same.

Parameters: on/off (default off, S-Video), separator (notch, comb1 or comb2, default notch).
The same implementation serves twice, here and in L9 for the capture card's own separator.

As built: the notch is a biquad at the subcarrier with Q 1. The combs use the lines two raster
lines away (the same field). After demodulation both I and Q get a 2nd order lowpass at 1.3 MHz.
Dot crawl shows as a dotted line along each colored vertical edge.

comb2 is a band-split comb. A full-band comb takes (2c - up - down) / 4 over the whole line as
chroma, so any vertical luma change (an edge, texture, a face) is thrown into chroma, lowpassed at
1.3 MHz and lost from luma. Better TVs and decks comb only the band where chroma lives (3.58 MHz
plus or minus 1.3), so comb2 runs the comb, gives its low band back to luma (two 3rd order Butterworths in series at
2.2 MHz, designed on the CPU per line like the other filters) and keeps only the high band as
chroma. A vertical luma edge then passes as S-Video does (within 1 percent, in `VHSLayerTests`),
while a flat color bar still separates. The filter leaks about 5 percent of the chroma into luma
at 3.58 MHz. Vertically changing luma above about 2 MHz is still combed out, which is the real
comb's loss of diagonal detail. comb1 is full band, the cheaper design.

### Frame: blanking and H offset (on by default)

Mechanism: the capture card digitizes 720 samples of a line whose active picture is shorter, so
blanking shows at the sides. Recordings sit a little left, so the right bar is the wider one, and some
captures carry a few dark rows at the top. Its absence is the clearest tell of a digital source.

Modeled as (one gather per pixel, before L2): setup black with no chroma outside [left bar, 720 -
right bar) and above the top rows. Inside, the picture is read `offset` samples to the right (it moves
left). Runs before L3 and L4, so the bar edges soften and pick up the chroma lag like the picture.

Parameters and defaults (measured on four home tapes captured at 720): right bar 17 px (14 to
17 on every tape), left bar 0 and top rows 0 (12 to 14 px and 5 rows show only on the 1991 pair, so
the Capture border switch sets 15 and 5), H offset 2 px (INFERRED). Look: a black bar down the
right edge with a soft, slightly colored inner edge.

As built: the left bar and top rows are the "Capture border" switch, off by default and owned by
no Source choice, since that border is one capture house's habit.

### L3 Record: luma FM and the tape bandwidth

Mechanism: luma is pre-emphasized (a high frequency boost before the FM modulator) and FM recorded
with a 1 MHz deviation (sync tip 3.4 MHz, peak white 4.4 MHz). The lower FM sideband has to fit above
the color-under band, which caps luma at about 3 MHz, 240 to 250 TV lines in SP, less in LP and EP.
Modeled as a per-line causal lowpass on Y at the luma cutoff: a 3rd order Butterworth (one biquad plus
one pole), the shape prior art settled on.

Parameters: tape speed preset (SP, LP, EP) setting luma cut 2.4, 1.9, 1.4 MHz (ntsc-rs tuned values,
where the spec figure is "up to 3 MHz" for SP, and 3.0 is the top of the slider), and a free luma cut
slider 1.0 to 5.5 MHz (to reach the S-VHS Look's 5.0, docs/LOOKS.md). Default SP, 2.4 MHz. Look: everything softens horizontally and only
horizontally, and vertical detail is untouched. On a frequency sweep an exported frame's
modulation at the 3.0 MHz equivalent is under 30 percent of its depth at 0.5 MHz.

The emphasis clip (on by default) is the source of the halo, in place of L6's symmetric peaking.
Mechanism: pre-emphasis boosts mid and high luma by up to 13 to 14 dB, nonlinear
emphasis gives small signals the boost and large ones less, and the boosted overshoot is clipped
where the FM carrier would leave its deviation range: white clip 5.3 MHz, dark clip 2.9 MHz,
against sync tip 3.4 and white 4.4 MHz (READ, US patent 4,597,021). At 140 IRE per MHz
that is 226 IRE and -110 IRE. On playback the de-emphasis undoes the boost, but not the clip.

Modeled as (one thread per line, causal): a high shelf e = x + g k (x - L), L a one pole lowpass
at 0.5 MHz (k = 1 - c), with the boost g falling from 13 dB toward 8 dB as an envelope of the
lowpassed input's HF level rises past 0.06 (attack 0.5, release 0.12 per sample), a soft clip
(0.3 Y knee) at 226 and -110 IRE, the 3rd order lowpass, then the de-emphasis, solved per sample
as y = (e + G Ld) / (1 + G) with G from the decoder's own envelope, the exact inverse when nothing
was clipped or filtered. The de-emphasis recursion decays with a time constant of about 18 px
(1.3 us, the VHS figure), and that is the streak length. The 0.5 MHz corner and the 8 dB large
signal boost are INFERRED.

Parameters: emphasis on or off, small and large signal boost (dB), white and dark clip (IRE), FM
moire (an option, below). Look: a big edge overshoots, its clipped overshoot comes back as a thick
streak to its right (dark after a rise into white, light after a fall into black), while small detail passes untouched (L6's canceller then
flattens it).

FM moire (option, default 0): the folded lower sideband beats with high frequency luma, a diamond
cross hatch on fine detail (READ, the vhs-decode wiki). Modeled as y += m gate cos(2 pi
(0.3 x + line / 4 + frame / 2)), gated by the decoder's HF envelope (full at 0.1), so it shows only
on detail. Amplitude INFERRED.

### L4 Record: color-under chroma

Mechanism: chroma is heterodyned down to a 629 kHz carrier and recorded in a band about 300 kHz
wide, roughly a tenth of luma. The narrow filters have group delay, so chroma arrives late, trailing
luma to the right by a few pixels. On playback the adjacent track's chroma crosstalk is canceled by
a 1H comb, which averages chroma with the previous line of the same field (vertical chroma blend).

Modeled as: a per-line causal 2nd order Butterworth lowpass on I and on Q at the chroma cut, then a
horizontal delay of the chroma samples, then a vertical blend (I,Q of this line averaged 50/50 with
the previous line of the same field), then a small per-line chroma phase error (a hue rotation drawn
per line from the noise hash, slow across lines) modeling the color-under PLL.

Parameters: chroma cut 320, 300, 280 kHz by preset (ntsc-rs, spec is 300 kHz), slider 100 kHz to 1
MHz. Chroma delay 1 px on the Clean deck and 2 on Worn (ntsc-rs's 4 samples at 14.3 MHz is 3.8
px at 13.5, composite-video-simulator uses 9), physical range 0 to 16 px. Vertical blend on/off (default on). Phase
noise 0 to 10 degrees (default 1). Look: color
bleeds and smears to the right past edges, saturated reds worst, color detail gone at a scale of 20
to 25 px. Chroma's transition is at least 4 times as wide as luma's, and the chroma edge sits right
of the luma edge by the delay.

As built:
- Y/C timing. The 320 kHz filter's own group delay is about 9.5 px, so with an explicit 4 px on
  top chroma would lag 9.7 px net, against 0.3 to 1.2 px measured on home tapes. A
  deck equalizes this with a Y delay line and regenerates sync with Y, so the picture does not
  move. Modeled by reading chroma ahead by the filter's DC group delay (sum k b_k / sum b_k - sum k
  a_k / sum a_k), so the net lag is the explicit delay: default 1 px, Worn 2. The delay is the
  deck's, not the tape speed's.
- Color droop: chroma comes from the line one field line up (default 1, range 0 to 4), so the top
  of a colored area is colorless and the color runs past its bottom (READ: doom9's "Color
  droop", ntsc-rs `chroma_delay_vertical`).
- The 1H comb runs in L5 after the noise whenever L5 is on (below), and L4 runs it only when L5 is off.
- Chroma gain, default 1.0, 0.8 under the Aged deck (two faded tapes measure 0.70 of our
  saturation).

### L5 Tape: noise

Mechanism: the tape and heads add noise. Luma noise is noise on an FM carrier, which after
demodulation rises with frequency (triangular spectrum), so it is fine grain that the playback
lowpass turns into short horizontal flecks. Chroma noise is amplitude noise in a 300 kHz band, so it
is coarse, horizontally streaky color blotching, and at equal signal to noise it is the more visible.
Video S/N on a good deck is 42 to 45 dB (the JVC HR-3300 spec says more than 42).

Modeled as: per sample white noise from the hash, for Y shaped by a high boost (first difference)
and then the same lowpass as L3 so it sits in band, and for I and Q shaped by the L4 chroma lowpass
(causal, per line), at a higher amplitude. Noise differs per frame and per field (seed includes both).

Parameters: luma S/N in dB (default 45, range 30 to 60, amplitude 10^(-SNR/20) of the 0 to 1 Y
range), chroma S/N in dB (default 45, Worn 38, range 20 to 60). Look: breathing grain, color blotches that
smear sideways.

As built: S/N is the RMS of the noise after its shaping filter (in band, the way a deck's video
S/N is measured), not before, since 45 dB before shaping leaves the luma grain far under one 8 bit
step once the lowpass removes most of it. The CPU divides the white amplitude by the
shaping filter's noise gain (sqrt of the sum of its squared impulse response). Consecutive
exported frames of a still differ with it on and are identical with it off.

- Chroma S/N default 45 dB (Worn 38): the noisiest measured tape's chroma reads 0.59 after a
  YouTube like encode, 45 dB gives 0.60. Luma is 45 (Worn 40).
- The playback 1H comb runs here, after the noise. The noise is added on tape and the comb is on
  playback, so physically the chroma noise passes it and comes out paired over lines, vertically
  streaky (the "mist"). The comb halves the power of the noise
  it averages, so the chroma amplitude is raised by sqrt 2 while it runs, keeping the S/N what a
  deck's output measures. Then a per line saturation wobble, default 3 percent (INFERRED).
- The second head's field is noisier: its noise times 1.1 (INFERRED from the vhs-decode wiki's "one
  field with a much different SNR than the other").
Tests: chroma noise correlation between a line and the previous line of its field is above 0.35
with the comb and under 0.1 without, and the odd field's luma noise RMS is 1.1 times the even field's.

### Dropouts and the compensator (on by default)

Mechanism: a speck of missing oxide drops the FM carrier for 5 to 25 us. The deck's dropout
compensator (DOC) fills the gap with the same span of the previous line of the same field from its
1H delay, so a dropout reads as a short misplaced smear, and when the DOC misses one, a white fleck.

Modeled as (after L5, one gather per pixel, events per line from the CPU hash): each field line
has a dropout with probability rate / 60 / 59.94 / 240. Its length is uniform over 67 to 340 px
(5 to 25 us), its center uniform along the line. Ten percent are raw white flecks (Y 1 with a
little noise, no chroma, 3 px soft ends), the rest copy the span from two raster lines up.

Parameters and defaults: rate 3 a minute ("two or three a minute" on very good tape, READ, US
patent 3,525,930, a broadcast tape figure), Worn 25 (the half inch tape allowance), range 0 to 5000. Missed by DOC
0.1. Look: an occasional short streak or a white fleck, far apart at the default.

### Second generation (option, off by default)

Mechanism: a dub. The played back signal is recorded on a second tape and played again (READ:
"color bleeding, chroma noise", "more luminance noise, edge ringing").

Modeled as: private copies of L3, L4, L5, dropouts, L6, L7 and L8 that take every toggle and
parameter from the main layers each frame, run after L8 with a different frame number in every
hash, so the second deck's noise, dropouts and jitter are its own. The second emphasis clip acts
on edges that already carry streaks, so they compound. Look: softer, noisier, double outlines on
big edges, a second head switch band.

### L6 Playback: edge halo (de-emphasis overshoot, sharpening, ringing)

Mechanism: FM pre-emphasis with white clip on record, then de-emphasis on playback, together with
the deck's detail enhancer (a peaking or aperture correction filter, the "sharpness" control) put a
light and a dark halo on either side of a vertical edge, with a short ring after it. No published figure gives the enhancer's values, so the defaults are
ntsc-rs's tuned values.

Modeled as: peaking, Y' = Y + k * (Y - lowpass(Y)) with the lowpass at the luma cut (k default 0,
Worn 0.2, range 0 to 1, where ntsc-rs's "sharpen" intensity is 0.25), then ringing as a resonant 2nd order IIR on Y near the
cut (center 0.45 of the luma cut, Q from a "ring" parameter, strength scaled by an intensity,
defaults from ntsc-rs: frequency 0.45, power 4, intensity 4, mapped to our units below). Then the noise canceller: a coring step that removes HF detail under a
threshold (default 2 percent of Y range, range 0 to 10), which smears fine texture and leaves edges.

As built, the ringing unit mapping: the prior art's ringing is a notch biquad, so this is a notch
too, and the halo mixes toward the notched signal, Y' = Y + m (notch(Y) - Y). Ring frequency is a
fraction of the luma cut (0.45 puts the notch at 1.08 MHz in SP). Power is the notch's Q (4, a ring
that decays by 1/e in about 16 px). Intensity sets the mix at 0.05 per unit (4 is m = 0.2, an echo
of a few percent of the edge height). Coring is soft (the detail above the threshold keeps its
excess) against a second luma cut lowpass.

Parameters: peaking k, ring frequency, ring power, ring intensity, coring threshold. Look: bright and dark edge
outlines, a faint echo to the right of hard edges, fine texture gone.

The halo comes from L3's emphasis clip, which streaks big edges only, where symmetric peaking
marks every edge. Peaking defaults to 0 (Worn 0.2, a deck's sharpness knob).
The canceller cores above half the luma cut (1.2 MHz in SP, "Canceller band", 0.25 to 1 times the
cut, INFERRED), since at the full cut it meets only the noise L3 has not removed and cannot
flatten texture. Test: a 2.4
percent square texture at 1.7 MHz comes out under 1 percent peak to peak while the edge above it
keeps its streak.

### L7 Playback: head switch

Mechanism: the two video heads alternate every field, and the switch happens 6.5 lines (plus or
minus 1.5) before vertical sync. On a CRT that is in overscan, but a capture card digitizes the whole
active area, so the band shows at the bottom of the 480 as a few lines that are skewed sideways
(the two heads' timing never matches exactly) with a burst of noise.

Modeled as (ntsc-rs's shape, which matches what captures show): the bottom H lines, the shift grows
with line index as shift_max * ((i + offset) / H)^1.5 plus a small random term, a mid-line start at
0.95 of the line width with jitter, and a decaying transient, with a noise burst on those lines at a
higher amplitude than L5.

Parameters: height 6 lines, offset 3 (so 3 visible lines), max shift 24 px, mid-line start 0.95,
noise burst gain. The offset and the mid-line start are ntsc-rs's defaults. Its height 8 and max
shift 72 px make a bigger band than home captures show (below). Per field. Look: the familiar torn
strip at the very bottom.

As built: heights count field lines, so the 3 visible lines per field are 6 raster lines of the
woven frame. The band's content moves right and the gap it leaves is black (blanking). The mid-line
start applies to the first visible band line. The shift jitters by up to 2 px per line. Each
shifted span starts with a transient of half the line's shift again, decaying as (1 - d/32)^3 over
32 px, and the noise burst is 0.08 of the Y range when on.

As built: the noise burst is the "Tracking noise" switch, 0 (off) by default and owned by no Deck
choice, so a 1986 look need not bring static with it.

The default band is small: home tape captures show a thin line or a short band at the bottom, 0,
12, 18 and 0 rows on four tapes (they may have been cropped in capture), not a 10 row skewed band. Default height 6 with 3 hidden, so 3 visible lines per field (6 raster
rows), max shift 24 px. Worn keeps the big band: 12 visible lines per field (height 15) and 120 px.

### L8 Playback: time base

Mechanism: consumer decks have no time base corrector, so the line start wanders by a fraction of a
pixel from line to line and field to field, and the first lines after vertical sync skew more
(flagging at the top), because the head change and the tape path settle over a few lines.

Modeled as: per line horizontal offset from a smooth 2D noise over (line, time) (value
noise with two octaves, ntsc-rs's edge wave idea), amplitude default 0.5 px (ntsc-rs), range
0 to 4, plus a top flagging term: the first N lines (default 8) get an extra offset that decays
toward zero by line N, amplitude default 2 px, range 0 to 20. Subpixel resample. Look: the picture
breathes sideways very slightly, straight vertical lines wobble, and the top edge leans.

As built: value noise (smoothstep between hashed lattice values) at a scale of 24 field lines by 6
fields, plus a second octave at half the scale and half the weight, normalized so the offset never
exceeds the amplitude. Flagging is amplitude (1 - line/N)^2 per field, computed with the per line
offsets on the CPU.

The second head's lines sit 0.25 px right of the first's (INFERRED from the head and field
asymmetry in L5), a faint static combing in weave. Parameter "Second field
offset", 0 to 2 px.

### L9 Capture: separator, YIQ to RGB, fields

Mechanism: the capture card samples the 720 raster (already our raster), separates Y and C if it
came over composite (the L2 model again, with the card's own separator, off by default), converts
to RGB, and the capture software deinterlaces.

Modeled as: optional L2 pass, YIQ to 709 RGB (the inverse of L1, so with everything else off the
round trip is identity to float precision), then Fields: weave (the two fields interleaved
as one frame, and with "temporal fields" on the second field comes from the next source frame, so
motion combs like a real capture), or bob (line double the current field, halving vertical
resolution, no combing). The default is weave with temporal fields off.

As built: in a live preview the next source frame is not known yet, so temporal weave takes the
even lines (the first field) from the previous source frame instead. The motion combs the same.
Bob keeps the odd (latest) field and rebuilds the even lines from the field lines above and below.
RGB is clipped to 0 to 1 here, as the card's converter would. `Layer.reset()` clears the previous
frame before an export.

A third deinterlace, field blend: each line is half its own and a quarter of each
neighbor (the other field), the capture software's "blend", so motion ghosts instead of combing
and nothing shifts vertically.

### Levels (on, identity by default)

Mechanism: the capture's levels. Setup left in or taken out lifts or drops black ("7.5 IRE" left in
"displays as a washout", READ), a faded tape's blacks rise, highlights clip at the card's
top code and the clipped excess blooms. The black level drifts slowly and the AGC pumps.

Modeled as (last before L9, in YIQ, one gather per pixel): per field black and gain, Y' = black +
gain Y and I, Q times the gain. Black is the offset plus a drift (value noise over about 4 s),
gain is the gain times 1 plus pumping (value noise over about half a second). With the clip on,
the excess over the clip's 0.08 knee spread over a 7 by 3 Gaussian is added back as bloom, then a
soft clip at the clip level.

Parameters and defaults: black offset 0 IRE (range -4 to +10), gain 1, clip off, clip level Y
1.091 (code 255), bloom 0.5, black drift 0.5 IRE, AGC pumping 1 percent. The static levels are
identity because a clean SP capture of a digital source sits where the source does. The
Camcorder source sets gain 1.15 into the code 255 clip, the Aged deck a
black lift of 19 codes (8 IRE). Drift and pumping are INFERRED (no published figure). Look: under
Camcorder, hot highlights that glow, and under Aged, milky blacks.

### Display: the tube (off by default)

Mechanism: the captured tape is watched on a consumer NTSC CRT. The tube decodes the signal at its
own gamma (2.35 to 2.55 over the 2.2 encode) with a bluer white (9300 K), an electron beam draws
each field line as a spot that widens with the level, the light lands on red, green and blue
phosphors through a shadow mask or an aperture grille, spreads in the glass, the deflection
overscans and bows the raster, and the faceplate tints it and picks up the room.

Modeled as: a stage after L9, outside the raster chain, run by `SignalChain.encodeOutput` when any
of its six layers is on. It draws the 720 by 480 raster (the stage before it, fitted to the raster
when that is a Film scan) onto a 4:3 canvas (the frame's shape under Fill the frame) at the Display's Detail
(1440 by 1080 by default) in linear light: Transfer (`crt_transfer`), Beam and Geometry
(`crt_scan`, the spot integrated over each canvas pixel's height), Mask (`crt_mask`, colored
phosphors, each passing only its own gun), Glow (`crt_glow_down`, `crt_blur`, `crt_glow`), Glass
and the 1/2.2 encode (`crt_glass`). Nothing is random: the brighter field alternates on the frame
number. Every default, range and source is in `docs/CRT.md`. With all six off the stage does not
run and the raster is the output, byte for byte.

### Re-capture: a camera filming the tube (off by default)

Mechanism: the round trip people make to get the look, a TV playing the tape and a newer camera
filming its screen back into the computer. The camera's shutter against the 59.94 field refresh
leaves a rolling bar that drifts at the beat of the two rates, its sensor's Bayer grid
undersamples the phosphors into moire, its auto exposure clips and hunts and its white balance
meets the 9300 K white partway, its lens is a little off focus and vignettes, a hand holds it off
axis, a lamp reflects in the glass, and the phone sharpens, smooths and compresses.

Modeled as: a stage after the Display, run by `SignalChain.encodeOutput` when its switch and a CRT
layer are on. The tube is drawn at the 2880 by 2160 canvas, then the camera samples it at its own
size (1920 by 1080, 1440 by 1080 or 1080 by 1920): `rc_optics` (Hand, Lens, Glare and the Shutter's per row
integral of the decaying phosphor, 16 samples a site), `rc_sensor` (Exposure, the full well, the
mosaic), `rc_demosaic`, then Processing (`rc_denoise`, `crt_blur`, `rc_sharpen`, `rc_codec`).
Seeded and deterministic. Every default, range and source is in `docs/RECAPTURE.md`. Unused, it
does not run and the Display's canvas is the output, byte for byte.

## Strength ranges

Every strength or amount slider runs well past every preset, typically 3x to 5x the end of its
physical range. Sidecars and presets store raw values, so they read the same at any range. Up to
the physical end the range models a real deck or tape. Past it the slider models a deck or tape
in far worse shape than any preset. For an S/N or a clip, stronger is lower, so the floor goes
down instead of the top up. No shader clamps any of these values, so the preview follows the
slider all the way. The soft clips (L3's deviation clip, the levels clip, the camera's highlight
clip) take tanh as 1 past an argument of 20, since Metal's fast math tanh returns NaN past about
44, which the 32 dB boost reaches.

| Layer | Parameter | Physical end | Slider end | Multiple | What the slider end means |
|---|---|---|---|---|---|
| L3 | FM moire | 0.1 | 0.5 | 5x | a beat of half the Y range on fine detail, a deck so far out of alignment that the lower sideband folds deep into the luma band |
| L3 | Small and large signal boost | 20 dB | 32 dB | 4x amplitude | 40x HF boost, every edge runs into the deviation clip and streaks |
| L3 | White clip | 110 IRE | 60 IRE | floor down 50 IRE | a deviation so narrow that midtones clip, the streak starts well below white |
| L4 | Chroma delay | 16 px | 48 px | 3x | 3.6 us, a Y delay line badly out, color slid far right of the picture |
| L4 | Color droop | 4 lines | 12 lines | 3x | color 12 field lines below the picture |
| L4 | Phase noise | 10 deg | 45 deg | 4.5x | a color-under PLL that barely holds lock, hue swinging from red toward green |
| L4 | Chroma gain | 2 | 4 | 2x | a chroma AGC stuck at full gain, color past the gamut |
| L5 | Luma S/N | 30 dB | 18 dB | 4x amplitude | 16x the noise power of a worn EP tape (30 dB), grain as loud as the picture's detail |
| L5 | Chroma S/N | 20 dB | 8 dB | 4x amplitude | 16x the noise power at the 20 dB physical end, color made of streaky blotches |
| L5 | Second field noise | 2x | 4x | 2x | one head four times noisier than the other, a clogged head |
| L5 | Saturation wobble | 20 % | 60 % | 3x | saturation swings by more than half from line to line |
| L6 | Peaking | 1 | 4 | 4x | a sharpness knob turned past its end, every edge outlined |
| L6 | Ring power (Q) | 8 | 24 | 3x | a ring lasting about 50 px after each edge |
| L6 | Ring intensity | 10 | 40 | 4x | a mix of 2 past the notched signal, an echo as tall as the edge |
| L6 | Noise canceller | 10 % | 30 % | 3x | all fine texture under 30 percent of Y flattened into wax |
| L7 | Height | 24 field lines | 96 field lines | 4x | the band climbing to 40 percent of the picture, a deck badly out of tracking |
| L7 | Max shift | 200 px | 720 px | 3.6x | a full line, the band torn off the right edge |
| L7 | Noise burst | 0.5 | 2 | 4x | a band of solid snow |
| L8 | Jitter | 4 px | 16 px | 4x | a stretched tape on a deck with no TBC, verticals visibly wavy |
| L8 | Flagging lines | 30 | 90 | 3x | the lean covering the top third of the picture |
| L8 | Flagging | 20 px | 80 px | 4x | the top of the picture leaning hard, wrong back tension |
| L8 | Second field offset | 2 px | 8 px | 4x | a heavy static comb on every vertical |
| Dropouts | Rate | 5000 a minute | 20000 a minute | 4x | about 5.6 a field, oxide shedding off a chewed tape |
| Levels | Black offset | 10 IRE | 30 IRE | 3x | a tape so faded its blacks sit at dark gray |
| Levels | Bloom | 2 | 6 | 3x | clipped highlights bleeding over their neighbors |
| Levels | Black drift | 4 IRE | 16 IRE | 4x | the picture breathing light and dark over seconds |
| Levels | AGC pumping | 5 % | 20 % | 4x | a gain riding hard on every field |
| Camera | Highlight bloom | 2 | 6 | 3x | highlights glowing over their neighbors |
| Camera | Black crush | 0.3 | 1 | 3.3x | the shadows gone to black |
| Camera | White balance Cb, Cr | 20 codes | 60 codes | 3x | a camcorder on its daylight setting indoors, or the reverse |
| Camera | Vignette | 0.6 | 1 | 1.7x | the corners at black, as far as the lens model goes (past 1 they would go negative) |
| Second generation | Generation | 4 | 6 | 5 dubs | five dubs in a row, about five chains of GPU time at the top |

Not extended, since they are settings rather than strengths: the cuts (a lower cut is a slider
of its own, and the Butterworth sections lose precision far under 100 kHz), the ring frequency,
the canceller band, the hidden lines and mid-line start, the dark clip, the level gain and clip
level, the hue, the exposure, the soft focus, the frame's bars, and the missed by DOC share (a
probability, already 0 to 1).

## Presets

- Source (first): Digital (camera off, levels identity) or Camcorder (camera on with the
  tungsten balance, levels gain 1.15 with the clip). The left bar and top rows are the Capture
  border switch, owned by neither.
- Deck: Clean, Worn and Aged. Clean: luma 45, chroma 45 dB, peaking 0, head switch 3 lines
  and 24 px, chroma delay 1 px, dropouts 3 a minute. Worn: 40 and 38 dB, peaking 0.2, head switch
  12 lines and 120 px, doubled jitter and flagging, chroma delay 2 px, dropouts 25 a minute. Aged:
  Clean with chroma gain 0.8 and black +19 codes.
- Tape: owns the two cuts only. The chroma delay is the Deck's.
- Link: S-Video (L2 and the capture card's composite input off) or Composite (both on, with
  the same separator).
- Capture: Weave, Bob, Blend.
- `homevideo-render --preset` takes `source=digital|camcorder`, `deck=aged` and `capture=blend`.

## Looks

Named presets above the pickers (docs/LOOKS.md): a Look is a picker selection plus a few layer
values. Choosing one resets every layer, then applies both, through `setParameter`, and it reads back
when every layer switch and value matches, else Custom. The default chain reads back as Fresh SP
(id `clean-sp`). The pickers and the layers sit in one Tune list on the Tape tab, with each layer
a collapsed group. Source does not own the border and Deck does not own the tracking noise: both
are switches (`border=on|off`, `tracking=on|off`). The second generation layer has a Generation
count (2 by default, 3 for a dub of a dub).

## Order, and why

Camera (off, RGB), L1 domain change, Frame (blanking), L2 link (off), Damage (off, see "Damage"), L3 luma record (emphasis,
clip, bandwidth), L4 chroma bandwidth, delay and droop, L5 noise then the playback comb, Dropouts,
L6 halo and canceller, L7 head switch, L8 time base, Second generation (off), the VCR OSD (off),
Levels, L9 capture and fields. The camera is before the deck because it made the picture. The
frame is emitted with the picture, so the tape softens its edges. Noise sits after the bandwidth
limits because it is added by the tape and shaped by playback, and the comb follows the noise
because it is on playback. Dropouts are a playback event the DOC fills from its 1H delay. The halo
sits after noise because the enhancer sharpens the noise too (which is part of the look). Head
switch and time base move whole lines and so come after everything per sample. Levels, the
separator and deinterlace are the last things that happen to a real capture.

## What is not modeled

EP mode's extra crosstalk, and the full line with sync and burst. The
audio track has its own chain in `Sources/HomeVideoCore/Audio/`, below.

## Audio

The audio chain is a list of layers per preset. Export and the preview run the same `AudioChainProcessor`, seeded alike, so they
agree sample for sample.

**Which track.** `Exporter.pickAudioTrack` takes the first AAC track, else the first audio
track. Export decodes that track. The preview puts its processing tap on the same track and makes
the player play it and nothing else: `FrameSource.attachAudio` enables only that item track and
the audio mix holds every other audio track at volume 0. An iPhone clip with spatial audio
carries AAC beside APAC in one alternate group, and the player's own pick is APAC, so without this
the tap would sit on a track nobody hears. The log's `audio=` (enabled tracks) and `tap=` read the
same, `audio=aac tap=aac` on such a clip. Choosing the track through its audible media selection
option leaves the item `unknown/waiting`, so it is not used.

**Presets.** Each preset is a layer list plus values over the layers' defaults
(`AudioPreset.overrides`).

Every preset's list starts with the camcorder mic (`audio-camcorder`, off), and Hi-Fi's ends with a
mono sum (off), which only the Audio wear slider turns on.

**Mic and track.** The app does not pick a preset: it picks where the sound happens, a
mic (`AudioMic`: clean, or camcorder, which is the `audio-camcorder` layer's switch) and a tape
track (`AudioTrack`: hifi, linearnr, linear, worn, ep, off), each track built from the preset of the same
name below. The mic layer is kept across track changes and leads every track's list, Off
included, so the camcorder mic can play with no track. Two more inputs sit on `AudioChain`:
`micStrength`, 0 to 100, where 100 is the mic as modeled, 0 leaves the layer out (the clean mic)
and between them the layer's output is mixed with the scene it heard (`x + k (mic(x) - x)`, the
AGC still riding the whole signal), and `tapeIsOn`, which when false keeps only the mic (no
track, no wear, no audio Damage). The Hi-Fi dropout burst plays on the Hi-Fi track with either
mic. Each preset is one pair, sample for sample: Hi-Fi is
clean plus hifi, Camcorder camcorder plus hifi, Linear, Worn Linear and EP Linear clean plus
their track, Off clean plus off (`AudioSplitTests`).
`homevideo-render` takes the pair as `--audio-mic`, `--audio-track`, `--mic-strength` and
`--audio-tape on|off`, and also takes `--preset audio=`.

| Preset | Layers | Values |
|---|---|---|
| Hi-Fi | compressor 2:1, FM noise, head-switch click, expander 1:2, band 20 Hz to 20 kHz, dropouts to linear | doc defaults |
| Camcorder | Hi-Fi with the camcorder mic on | the mic at its defaults (below) |
| Linear NR (the default) | Linear plus the playback side of a matched B type noise reduction right after the hiss | Linear's values. The noise reduction: a first order shelf 10 dB deep turning at 540 Hz on the hiss alone (the program comes out of a matched pair flat), sliding to no cut as the program's treble rises from -55 to -15 dBFS, 2 ms attack and 60 ms release (below) |
| Linear | mono, saturation, band, head bump, wow and flutter, hiss, line whine, Dolby B mismatch (off) | band 100 Hz to 10 kHz, bump +2 dB at 80 Hz, wow and flutter 0.2% (a quarter of it flutter), hiss -42 dBFS, whine -60 dBFS |
| Worn Linear | Linear plus mute dropouts last | wow and flutter 0.4% (twice Linear's), hiss -36 dBFS (6 dB over Linear's), bump +3 dB Q 0.7, mutes of 5 to 30 ms, 3 a minute (INFERRED) |
| EP Linear | Linear plus azimuth loss after the band | speed EP, band 100 Hz to 6 kHz under an azimuth shelf of -3 dB above 2 kHz (INFERRED), so the whole response is -3 dB near 4 kHz, 0.3% with half of it flutter, 0.15% of flutter against Linear's 0.05% |
| Off | the camcorder mic only (off) | the source track, copied, unless the camcorder mic is on |

Measured on export of a 10 s test signal (a steady 1 kHz tone, a 50 Hz to 16 kHz sweep and white noise
bursts), the -3 dB high edge is 9779 Hz for Linear, 9697 Hz for Worn Linear and 4031 Hz for EP
Linear. The 1 kHz tone, FM demodulated, shows the 11.3 Hz flutter line at 0.013%, 0.028% and
0.042% of deviation in the same order. Rental and Six Hour Tape (EP tapes) use EP Linear, Attic
Tape uses Worn Linear, and Fresh SP and the Display Looks that film its tape use Linear NR. The
other Looks on the linear track keep Linear.

**Linear NR.** The linear track on a good deck whose noise reduction was on at record and
is on, matched, at playback (`audio-nr`, `SlidingHissCut` in `AudioChain.swift`). Sources:
Wikipedia's VHS page, "linear stereo VHS VCRs use Dolby B noise reduction for recording and
playback", and its Dolby noise reduction page, "effective from approximately 1 kHz upwards ... 3 dB at
600 Hz, 6 dB at 1.2 kHz, 8 dB at 2.4 kHz, and 10 dB at 5 kHz", "about 9 dB" A weighted, a low level
signal boosted 10 dB and none at "Dolby Level". A first order shelf 10 dB deep
turning at 540 Hz gives 3.0, 6.0, 8.5 and 9.6 dB at those four frequencies. The matched pair leaves the
program flat, so the model cuts only the hiss the tape added between the two sides, and slides the
cut off as the program's treble (above the turnover) rises from -55 to -15 dBFS: "Dolby Level" is +3 VU,
taken over 0 VU at -18 dBFS, with the full cut 40 dB under it (INFERRED, as are the 2 ms attack and
60 ms release of the control). Neither page gives a linear S/N with the noise reduction on: 42 dB
NTSC (Wikipedia's VHS page) plus "about 9 dB" puts it near 51 dB A weighted (INFERRED). The band, mono,
saturation, head bump, hiss level and the 0.2% wow and flutter of a deck in spec are Linear's.
The line whine is left as Linear plays it. The name keeps off the trademark.

**The camcorder mic.** `Sources/HomeVideoCore/Audio/CamcorderMic.swift`. A camcorder records its built-in mic before the tape, so
the layer runs first, and ahead of the Hi-Fi dropout's dry copy, so a fall to linear keeps the
motor. It adds a bed (the drum and transport whine with two partials, the drum's 29.97 Hz rotation
and rumble, the preamp hiss) and an AGC on the scene plus the bed that lifts quiet passages by up
to the lift and ducks in 30 ms when the sound comes back. There is no zoom motor sound. A saved
preset or sidecar that names the zoom parameters (Zoom sound, Zoom level, Zoom rate, Zoom length)
still loads.
Motor level is the bed in a silent passage with the AGC lifted. The Camcorder Look takes the
Camcorder preset and Shoebox turns the layer on over Linear (docs/LOOKS.md).

| Parameter | Default | Range | Status |
|---|---|---|---|
| Motor level (dBFS) | -44 | -80 to -20 | INFERRED |
| Whine (Hz) | 1250 | 400 to 6000 | a reference clip, 1257 Hz |
| AGC lift (dB) | 12 | 0 to 24 | INFERRED |
| Seed | 0 | 0 to 999 | n/a |

**Audio wear.** One slider, 0 to 100, in `Audio/AudioWear.swift`, beside the audio Damage
layers in the Audio section. 0 is
the preset's own values. It moves every parameter of the preset's layers below along the line from
the preset's value to its worn end, through `setParameter`, so the layer sliders show where it put
them and can be nudged after. On Hi-Fi the mono sum comes on above 50. A sidecar, a saved preset
and the clipboard store it as `audioWear` (left out at 0), and a load applies it before the saved
layer values, so they land as saved. The camcorder mic and the Damage layers have no worn end.
Every worn end is INFERRED: the published figures are a good deck's, not a worn one's.

| Layer | Parameter | Worn end | Against |
|---|---|---|---|
| Band limit (linear) | highpass, lowpass | 250 Hz, 2.5 kHz | EP's 4 kHz, the narrowest published |
| Hiss | level | -28 dBFS | -42 |
| Wow and flutter | depth | 1.5 % | 0.2 % |
| Azimuth loss | treble loss | -12 dB | -3 |
| Tape saturation | drive | 0.9 | 0.3 |
| Head bump | gain | +6 dB | +2 |
| Dropouts (mute) | rate, longest | 20 a minute, 80 ms | 3, 30 ms |
| Band limit (Hi-Fi) | highpass, lowpass | 150 Hz, 6 kHz | 20 Hz, 20 kHz |
| FM channel noise | level | -32 dBFS | -48 |
| Dropouts to linear | rate, length | 20 a minute, 400 ms | 2, 150 ms |
| Head-switch click | level | -42 dBFS | -55 |
| Expander 1:2 | tracking error | 2.5 dB | 0.5 |

## Damage

Twelve optional event layers, four in the picture
(`Sources/HomeVideoCore/DamageLayers.swift`, kernel `damage_events` in `Shaders/Damage.metal`) and eight in
the sound (`Sources/HomeVideoCore/Audio/AudioDamage.swift`). Each has a switch, a Strength (0 to 1, how
hard each event hits, what 1 means is in the table), a Rate (how often) and a Seed (0 to 999).
All are off by default. The worn Looks (Rental, Dub of a Dub, Attic Tape, Hot Car, Sticky
Shed) switch some on at mid Strength with a fixed Seed, every other Look switches them all off,
and the sliders tweak them from there (docs/LOOKS.md, "Wear").

**Rate.** Events a minute (Snow: dropouts a second), set apart from Strength. Each default is the
frequency an earlier version derived from the layer's default Strength, so a sidecar, preset or
clipboard written before Rate existed reads to the default and plays the same event times
(`testTheDefaultRateIsTheOldStrengthFrequency`, `testAnOldSidecarWithoutRateReadsAsTheDefaultRate`). The
Crease's older control, Average gap (`period`), is still read as Rate = 60 / period, in a sidecar,
a user preset file and the settings clipboard (`testAnOldPeriodLoadsAsRateInAPresetFileAndTheClipboard`).
The sidebar shows a Rate whole, 5 not 5.00 (`LayerParameter.readout`). Defaults and ranges: tear 3 (0 to 60), snow 78 a
second (0 to 2,000), clog 1 (0 to 20), crease 5 (0 to 30), flutter 2, azimuth 2, sound clog 1, Hi-Fi
3, glide 2, worn 1.5, crackle 4, mute 3 (the sound's all 0 to 60).

**Timing.** `DamageSchedule` cuts time into slots as long as the longest event. Each slot holds at
most one event, which starts there with probability 1 - exp(-rate x w x slot), at an offset and
with a length from the same hash of (layer, seed, slot). So the events are a pure function of the
seed and the time: a render repeats exactly, a paused frame is stable, another seed is another take,
and the long run rate is the Rate, thinned near the top of a range since events of one kind do not
pile up (40 tears a minute come out near 28, `testTheRateSetsTheFrequencyAndTheStrengthDoesNot`).

**Sporadic.** Damage on a tape comes in bad stretches (the BBC's "occasional bursts"), so w is a
weight per 15 s stretch of tape, 4 u^3 with u uniform from the seed: its mean is 1, half the
stretches carry under half the rate, one in five is nearly clean (w under 0.03) and one in ten
carries 2.9 times it or more. Snow's per line rate and the crease's passes (on average one per
Average gap) take the same weight. Measured over 400 stretches at 1 event a second, the count per
stretch has a variance over 4 times its mean, where a steady rate would have them equal
(`testEventsAreSporadicNotSteady`). The 15 s and the cube are INFERRED.

**Deterministic.** The same seed, strength and clip give the same render frame for frame and
sample for sample. The audio layers count time on their own sample clock and decide everything
on it (the clog's kernel is rebuilt on every 64th sample of that clock, not of each block), so a
run cut into 333 sample blocks equals one cut into 512 (`testEveryAudioLayerIsDeterministicAndBlocksDoNotMatter`,
every layer on at Strength 1), and two `homevideo-render` exports with every Damage layer on decode to
identical video and audio (md5 of the decoded streams). The picture uses the source time (each field at
t and t + 1/59.94 s). The sound uses the processor's sample clock from the start of the export.

**Where.** The picture layers run inside the chain: the damage is on the tape, so they run after
the composite link into the deck and before the playback stages (luma bandwidth, color-under, tape
noise, dropouts, halo, head switch, time base), which soften and smear them as they do the picture.
Head clog, Crease, Snow, Tracking tear, in that order. `VHSLayers.middle` holds the order
(`[frame, compositeLink] + damage.all + [luma, ...]`), so every chain built from `vhs.all` runs it, the
GPU test harness's included (`testThePictureEventsRunBeforeThePlaybackStages`,
`testLayersAreInSignalOrderAndL1FollowsTheMiddle`). They need L1 like any middle layer.
No event layer draws over the finished picture: after them come only the generation loop, the
on-screen display (the deck's own output, by design) and the capture card's levels. The sound layers run after the
preset's own layers (Wow glide, Flutter burst, Azimuth wander, Head clog, Worn stretch, Crackle
burst, Hi-Fi dropout, Dropout to silence). Off stays the
untouched source, and the Hi-Fi dropout runs only on the Hi-Fi track (the Hi-Fi and Camcorder presets). With every Damage layer off
the picture and the sound are identical to the chain without them (`DamageTests`).

| Layer | What it models | Strength 1 means | Source |
|---|---|---|---|
| Tracking tear (`damage-tear`) | heads off track for a few frames: a band skews as the sync slips (and relaxes over the lines after it), a noise bar in its middle, chroma killed in the band | 4 times the skew (60 px at the default 15), the band 1.5 times as tall (18 field lines), a solid noise bar, the chroma killed outright, 15 lines of re-lock (INFERRED by eye). Strength 0.25 is ntsc-rs's skew | band 12 field lines and skew 15 px at its bottom: ntsc-rs `tracking_noise` (height 12, wave_intensity 15, ramping to the bottom). Rate and length (0.1 to 0.5 s) INFERRED, Sencore TT132 says only "from time to time" |
| Snow (`damage-snow`) | RF dropouts the DOC misses: white (4 in 5) or black streaks, or with Compensator on the line above from the same field | streaks 120 px to past a whole line, each a clump of up to ten lines of its field, full white or black, broken into patches along the line (INFERRED by eye). Strength 0.5 is full level. The default Rate, 78 a second, is three times ntsc-rs's default snow (0.00025 x 0.01 per pixel, 26 a second at 720 by 480) | lengths log uniform 8 px (ntsc-rs's shortest transient) to 25 us, 340 px (BBC Monograph 57: "virtually no drop-outs of duration greater than 25 us"). The 1H substitution is the BBC's DOC. White share INFERRED |
| Head clog (`damage-clog`) | oxide on a video head: the carrier falls by Wallace's spacing loss, so S/N falls dB for dB, and the picture softens. "One head" (default) is one field only | a 1.2 um gap at each episode's peak, 44 dB of carrier loss at the 1.49 um carrier wavelength (5.8 m/s over 3.9 MHz), the field nearly all noise, softened up to 4 px, and the color-under carrier (9.2 um at 629 kHz) down 7 dB. 0.5 um and 18.4 dB is Strength 0.42 | 54.6 d / lambda (Nortronics head guide, and 3M "Magnetic Recording Media": 55 dB per wavelength). "Head Clog is one field full of snow" (vhs-decode wiki). Gap, 1.5 to 6 s episodes with 0.5 s ramps, and the 1.5 px soften INFERRED |
| Crease (`damage-crease`) | a fold across the tape crossed by 174 fields in a row: a bright or dark line that scrolls down the picture, noisy lines around it | not a ruled line: the lifted tape is a hump, so the fold is a Gaussian 2 field lines at its sigma, white (or black) at its core, broken into patches along the line where contact comes and goes, with noise, a few pixels of slip and color loss 15 lines either side (INFERRED by eye) | geometry: track 97.34 mm at 5.96 degrees, 96.8 mm along the tape, over 33.34 mm/s at SP, 2.90 s a pass (5.81 LP, 8.70 EP), each line 0.37 mm of track. "horizontal fuzzy lines scrolling down ... the same place" on a creased tape (digitalfaq thread 15395). Average gap 12 s INFERRED |
| Flutter burst (`audio-damage-flutter`) | the tape sticks and slips: a servo hunt at 6 to 12 Hz (60 percent) and scrape flutter at 100 to 200 Hz (40 percent) | a 1.5 percent peak, bursts of 0.5 to 3 s | scrape flutter above 100 Hz (lindos.co.uk), "warbling" (Sencore TT132), stick-slip (AV Artifact Atlas). The depth and rate INFERRED (no source gives a sticking tape's flutter) |
| Azimuth wander (`audio-damage-azimuth`) | the tape skews over the linear head: loss 20 log10 sinc(pi w tan(a) f / v), run exactly as a boxcar of w tan(a) / v | a 30 arcmin peak (first null 3.82 kHz on the 1 mm track at SP), episodes of 2 to 8 s | the formula (Standard Tape Lab manual, Nortronics). 30 arcmin "complete cancellation ... around 10 kHz" on a cassette (US5552944A). A steady wander of 2 arcmin peak to peak over 300 mm of tape (McKnight, AES preprint 1666). Track 1 mm (repair FAQ). Rate and length INFERRED |
| Head clog, sound (`audio-damage-clog`) | oxide on the audio head: Wallace's loss, 54.6 d f / v dB, exponential in frequency, run as its Cauchy kernel (96 taps a side, 2 ms of latency while on). "Follow the picture" (default) takes the picture clog's episodes | a 2 um gap at the peak: 32.8 dB at 10 kHz, 3.3 dB at 1 kHz at SP | Wallace as above. The gap INFERRED |
| Hi-Fi dropout (`audio-damage-hifi`) | bursts of carrier loss: the deck mutes Hi-Fi and plays the linear mono track (the Linear SP chain on the input), offset in time, with a pop at each switch | bursts of 0.5 to 8 s. In one of five the carrier chatters (8 drops a second of 30 to 150 ms), in four of five the deck holds linear for the whole burst. Strength 0.5 is 0.5 to 4 s with two in five held | "switches from Hi-Fi Stereo audio to linear mono audio", "a popping noise" and the two tracks' specs (Sencore TT190). "bursts during which several drop-outs occur within a second or two" (BBC Monograph 57). The offset, 2 ms by default, is an X distance error (SMPTE 32M: 79.244 mm from drum to A/C head, so 0.1 mm is 3 ms at SP), INFERRED. Rates INFERRED |

**Measured** (`homevideo-render` at Strength 0.7, a pink noise plus 3 kHz tone test signal,
read off spectrograms): azimuth episodes take 4 to 8 kHz down 13 dB and 12 to
18 kHz down 21 dB, with the sinc's nulls sweeping down and back. The sound clog takes them down 12.5
and 32 dB. The Hi-Fi dropouts band the sound at the linear track's 10 kHz edge. A flutter burst
spreads the 3 kHz tone's peak by 47 Hz (1.6 percent).

Four more sound layers:

| Layer | What it models | Strength 1 means | Source |
|---|---|---|---|
| Wow glide (`audio-damage-glide`) | a sticky spot drags the tape, the pitch sags, then the capstan servo, locked to the control track's phase, runs fast until it has caught up: the read position follows A (1 - cos 2 pi x) / 2, down then up, and ends in phase | a 3 percent peak deviation, glides of 0.4 to 1.5 s | capstan servo and "Linear audio is changing in pitch (warbling)" (Sencore TT132). The 3 percent (fifteen times the steady 0.2 percent, Sencore TT190), lengths and rate INFERRED |
| Worn stretch (`audio-damage-worn`) | oxide shed from a length of tape: the program drops 3 dB and pink hiss comes in 12 dB over the linear floor, ramping over 0.3 s | stretches of 2 to 10 s, the program down 6 dB and hiss at -18 dBFS inside. Strength 0.5 is 3 dB and -30 dBFS | the floor, -42 dBFS from the linear track's 42 dB S/N (Wikipedia's VHS page, composite-video-simulator). Jump, drop and rate INFERRED |
| Crackle burst (`audio-damage-crackle`) | flakes of oxide and static at the head: steps of either sign from -36 to -12 dBFS decaying in 0.15 ms, 300 a second inside a burst | 600 pops a second in bursts of 0.2 to 1.5 s. Strength 0.5 is 300 | "popping noise or static" (Sencore TT190), "pops and clicks" (tapeheads.net). Density, levels and decay INFERRED |
| Dropout to silence (`audio-damage-mute`) | both tracks lost for a beat and the deck's mute circuit leaves nothing: 50 to 400 ms of silence with 2 ms edges | silences of 50 to 800 ms. Strength 0.5 is 50 to 400 ms | the mute circuit (Sencore TT190). Lengths and rate INFERRED (Worn Linear's 5 to 30 ms mutes are the short steady kind) |

**Not sourced** (INFERRED, listed so they can be replaced by a measurement): the clustering
(15 s stretches, 4 u^3), the tear's rate and length, the clog's gap, episode lengths and
softening, the crease's average gap, the flutter burst's depth and rate, the azimuth episode
rate, the Hi-Fi offset, burst rates and solid share, the snow's white share, and every number of
the four layers above except the hiss floor.
