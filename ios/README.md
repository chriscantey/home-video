# Home Video for iPhone

The phone app is the fun part of Home Video without the pro workflow: one
clip at a time, a Look, every stage's controls, an export to Photos. iOS 26 and later, iPhone
only, bundle id `co.wonders.homevideo.mobile`. No network code, no Sparkle, no analytics.

## Layout

| Path | What |
|---|---|
| `HomeVideoMobile.xcodeproj` | Hand written Xcode project (objectVersion 77, folder synchronized groups). No generator, no packages |
| `HomeVideoMobile/MobileModel.swift` | The chain, the renderer, one clip, the Look rule, resets, the export |
| `HomeVideoMobile/ContentView.swift` | The screen: preview and transport on top, Simple under it, the sheets, landscape |
| `HomeVideoMobile/PreviewArea.swift` | The preview's gestures, the transport, the trim scrubber |
| `HomeVideoMobile/SimplePanel.swift` | The Look carousel and Framing |
| `HomeVideoMobile/AllControlsView.swift` | Every stage in flow order, its switch, presets, layers and reset |
| `HomeVideoMobile/ControlRows.swift` | Rows built from a layer's own `parameters`, as the Mac's `LayerControls` |
| `HomeVideoMobile/LookStills.swift` | The carousel's stills: the current frame through each Look, once per clip |
| `HomeVideoMobile/FullScreenPlayer.swift` | The picture alone, from the preview's button, centered on the screen |
| `HomeVideoMobile/Margins.swift` | The one horizontal margin rule, and scrollers that run into the trailing gutter |
| `HomeVideoMobile/TempFiles.swift` | The app's own files under tmp (the picked clip, the export kept for Share, a camera recording) and the launch sweep |
| `HomeVideoMobile/DebugProbes.swift` | DEBUG only: one point elements that carry numbers for the UI tests (`loadTiming`, `clipName`, `tmpListing`, `stillsTiming`) |
| `HomeVideoMobile/AboutView.swift` | About Home Video (More menu), a grouped list: the tape sleeve (`AboutAssets.xcassets`), the version from the bundle, the Mac version, a row that opens `siteURL` (homevideo.app) in the browser, and Privacy Policy and Support rows (homevideo.app/privacy/ and /support/, App Review Guideline 5.1.1). It opens at the large detent so both show without a drag |
| `HomeVideoMobile/PrivacyInfo.xcprivacy` | The privacy manifest: no tracking, no collected data, the required-reason APIs the app calls (UserDefaults CA92.1, file timestamps C617.1) |
| `HomeVideoMobile/LoadingCard.swift` | The card while a pick comes in: a ring with the percent (a spinning arc when the total isn't known), "Opening video…" or "Downloading clip…" under it, Cancel. `idleWhile(loading:)` dims the controls under it |
| `HomeVideoMobile/ExportSheet.swift` | Size, codec, quality, sound, progress, Saved to Photos with Share |
| `HomeVideoMobile/CameraView.swift` | The camera screen: the editor's Look header, carousel, All Controls sheet and column, lens buttons, pinch, tap to focus, crop, record. The fps, chain, lag, dropped, heat and zoom readout (`cameraReadout`) and the frame counts on the saved line are DEBUG only. A Release build shows no numbers |
| `HomeVideoMobile/CameraModel.swift` | The chain per camera frame, the capture angle from the screen, lens and focus, recording |
| `HomeVideoMobile/CameraFeed.swift` | The capture session and its lens, and the DEBUG fixture feed that plays a sensor |
| `HomeVideoMobile/CameraRecorder.swift` | The writer for the camera, in the export's codec and quality |
| `HomeVideoMobileUITests/` | The UI tests: the whole path, the picker alone, Dynamic Type XL, rotation and trim, the preview's sound, the camera, the bar and About, the camera's live probes, loading a clip and the session (`HomeVideoMobileLoadUITests`) |

The app target compiles `../Sources/HomeVideoCore` into itself and copies its `Shaders` folder
as plain files. The shaders are compiled at launch (`ShaderLibrary`, `makeLibrary(source:)`).
That way xcodebuild never compiles a `.metal` file, which it cannot do without the Metal
Toolchain component, and the Mac's SwiftPM package keeps compiling its own. A new `.metal` file in
`Shaders` must be added to the exception list in `project.pbxproj` ("Exceptions for
HomeVideoCore"), or xcodebuild will try to compile it. Core's internal names are visible to
the app, since they are one module here.

## Privacy

- Picking uses the system Photos picker, which runs outside the app and hands back only the
  clip chosen, so there is no library permission prompt.
- Saving asks for add-only access (`NSPhotoLibraryAddUsageDescription`), so the app can put a
  video in the library and never read it.

## Build and test

```bash
cd ios
xcodebuild -project HomeVideoMobile.xcodeproj -scheme HomeVideoMobile \
  -destination "generic/platform=iOS Simulator" build-for-testing
xcrun simctl addmedia <udid> <a fixture with sound>
xcrun simctl privacy <udid> grant photos-add co.wonders.homevideo.mobile
TEST_RUNNER_HV_TEST_CLIP=<fixture path> TEST_RUNNER_HV_SHOTS=<folder> \
  xcodebuild -project HomeVideoMobile.xcodeproj -scheme HomeVideoMobile -destination "id=<udid>" \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 420 test
```

- `HV_TEST_CLIP` opens the fixture by the DEBUG-only launch argument `-homevideoTestClip`, so
  the main test runs everything after the picker. `testPicker` drives the system picker alone,
  on a simulator whose library has been used before (a freshly erased one ignores the tap).
- `HV_SHOTS` is where the tests write their screenshots. A landscape screenshot taken inside the
  test comes back mangled, so the test writes `<name>.take` and the script running the tests
  takes it with `simctl io screenshot`.
- `HV_PRIVATE=1` turns every screenshot off, for a run on a private clip: nothing of the
  clip leaves the run but the `HVDIAG` numbers.
- `HV_CAMERA_FIXTURE` plays a file as the camera (`-homevideoCameraFixture`, DEBUG only). The
  file is the world upright: the feed shows a portrait part of it with the phone upright and a
  landscape part on its side, turned by the Simulator's rotation and then by the app's capture
  angle, as a sensor and the capture connection would. A wrong angle shows as a turned picture.
  `-homevideoCameraAngleError 90` (through `HV_EXTRA_ARGS`) adds a wrong turn on purpose, the
  negative control for the rotation test.
- `HV_AUDIO_DUMP` sets `HOMEVIDEO_AUDIO_DUMP` on the app: the preview tap writes `in.wav`,
  `out.wav` and `dump.log` there. `testPlaysClipAudio` reads `in.wav` back and fails
  on silence, so it needs this set.
- `HomeVideoMobileLoadUITests` picks the clip over two minutes long from the simulator's
  library, so add a long fixture first (`simctl addmedia`). Its DEBUG launch arguments:
  `-homevideoHoldLoad <seconds>` keeps the load's progress up that long once the file is in (a
  local clip loads too fast to see), `-homevideoRestoreSession YES` lets a test build reopen the
  last clip at launch (a release build always does, a test build otherwise starts empty), and
  `-homevideoPlantLeftovers YES` writes a file into each tmp folder and Caches after the launch
  sweep, for the next launch to sweep. For the download line (`testDownloadLine`):
  `-homevideoHoldArrival <seconds>` holds the file back before the app takes it, as a download
  would, `-homevideoLocalLimit <seconds>` stretches the 1 s after which a late file reads
  "Downloading clip…", `-homevideoShowProgress <fraction>` shows a Progress at that fraction in
  place of the picker's, and `-homevideoRecordOpen YES` makes About's Mac row record its URL in
  the `aboutOpened` probe instead of opening it.
- `xcodebuild test` can sit for minutes writing the result bundle after a failure. Run it with a
  watchdog that stops it once the tally line is printed.

The export lands in the simulator's `data/Media/DCIM/100APPLE/` as the newest `.MP4`.
