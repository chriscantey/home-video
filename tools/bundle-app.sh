#!/bin/bash
# tools/bundle-app.sh: wrap the SwiftPM release build into "<displayName> <version> b<n>.app".
#
# The app is Home Video. Its display name, version and build come from AppInfo in
# Sources/HomeVideo/HomeVideoApp.swift.
#
# Run on the Mac, after the release build for the chosen arch. With no --product, SwiftPM builds
# both executables the bundle carries, the app and homevideo-render:
#   x86_64: swift build -c release
#   arm64:  swift build -c release --arch arm64 --scratch-path .build-arm64
#   universal: both of the above first. No SwiftPM flag emits a fat binary in one pass, so the
#              script joins .build/release/<exe> (x86_64) and .build-arm64/release/<exe>
#              (arm64) with `lipo -create`, for each executable. The resource bundle comes from the x86_64 build (both
#              builds copy the same files). Before signing, `lipo -archs` must read both slices
#              and every slice's minos (LC_BUILD_VERSION) must be at or below
#              LSMinimumSystemVersion.
#              Universal is the delivery: one bundle that runs on any Mac, Intel or Apple Silicon.
#
# Produces:
#   Contents/MacOS/HomeVideo                           the executable
#   Contents/MacOS/homevideo-render                    the command line renderer, the same
#                                                      arch as the app, signed as nested code
#                                                      before the app with the same identity
#                                                      and runtime. It sits beside the app's
#                                                      executable, not in Contents/Helpers, so
#                                                      Bundle.main is the app and it finds the
#                                                      shaders in Contents/Resources as the app
#                                                      does (ShaderLibrary), and a symlink to it
#                                                      on PATH resolves to the same place
#   Contents/Resources/HomeVideo_HomeVideoCore.bundle/ HomeVideoCore's resources, plus a
#                                                      default.metallib compiled here with
#                                                      xcrun metal (SwiftPM's command line
#                                                      build copies .metal sources instead of
#                                                      compiling them; the app falls back to
#                                                      compiling those at runtime)
#   Contents/Resources/AppIcon.icns                    the flat icon for macOS 14 and 15, from
#                                                      assets/AppIcon.icns
#   Contents/Resources/Assets.car                      the Liquid Glass icon for macOS 26 and
#                                                      later, assets/AppIcon.icon compiled by
#                                                      actool (needs Xcode, required for devid)
#   Contents/Resources/Licenses/                       the app's GPL-3 LICENSE and licenses/*.txt
#                                                      (Sparkle and what it bundles)
#   Contents/Frameworks/Sparkle.framework/             the updater, copied whole and
#                                                      signed inside out by embed_framework below
#   Contents/Info.plist                                bundle id, version and build from AppInfo,
#                                                      and the update keys for the line
# and a signature: ad hoc by default, Developer ID with the hardened runtime on request, then
# notarized and stapled when a notary profile is named.
#
# Env:
#   HOMEVIDEO_ARCH            x86_64 (default), arm64 or universal
#   HOMEVIDEO_BUNDLE_ID       default co.wonders.homevideo. Use a private id of your own for
#                             test builds
#   HOMEVIDEO_OUT             output folder, default $HOME/build/<displayName>
#   HOMEVIDEO_SIGN            devid or adhoc. Default: devid when HOMEVIDEO_IDENTITY and
#                             HOMEVIDEO_SIGN_KEYCHAIN are both set, adhoc otherwise. devid
#                             without both stops with a FATAL line.
#   HOMEVIDEO_IDENTITY        codesign identity, a "Developer ID Application: ..." name
#   HOMEVIDEO_SIGN_KEYCHAIN   path of the keychain file holding that identity
#   HOMEVIDEO_NOTARY_PROFILE  notarytool keychain profile stored in that keychain. Unset: not
#                             notarized.
#   HOMEVIDEO_UPDATE_LINE     release, beta or none (default). Picks the update feed written into
#                             Info.plist. none is the dev line: no feed, so the app never checks
#                             and shows no update item.
#   HV_BETA_FEED_URL          the unlisted beta feed, required on the beta line.
#   HOMEVIDEO_BETA            the beta number, required on the beta line and refused on the others.
#                             The beta line's CFBundleShortVersionString reads "<version> beta <n>".
#   HOMEVIDEO_PLIST_ONLY      a path: write only the Info.plist there, print the updates line and
#                             stop, with no build needed. The plist test runs the script this way.
#   HOMEVIDEO_LICENSES_ONLY   a folder: copy only the Licenses folder into it and stop, with no
#                             build needed. The licenses test runs the script this way.
#
# With HOMEVIDEO_SIGN=devid the keychain password comes on stdin, one line ending in a newline,
# never on argv: `printf '%s\n' "$PW" | HOMEVIDEO_SIGN=devid ... tools/bundle-app.sh`. Without the
# newline `read` returns 1 at EOF and set -e ends the run right after ">> codesign (devid)".
# The script carries no identity, keychain or profile of its own. Every one comes from the caller.
set -euo pipefail
cd "$(dirname "$0")/.."

# >>> embed_framework: nothing in this block or in tools/sign-framework.sh names the app, so both
# copy into another app as they are.
#
#   embed_framework <app bundle> <framework source> <identity> [codesign args...]
#
# Copies the framework whole into <app>/Contents/Frameworks (ditto keeps its symlinks, its XPC
# services, its helper app and its tools), adds the rpath @executable_path/../Frameworks to the
# app's executable when it is missing (SwiftPM links with @loader_path only), then has
# tools/sign-framework.sh sign it inside out. The caller signs the app itself last, without
# --deep. For Developer ID pass the identity and --keychain <file>: the script adds the hardened
# runtime and the timestamp. For ad hoc pass "-" alone: no hardened runtime, so no library
# validation, which would refuse a framework with no team id.
embed_framework() {
    local app="$1" src="$2" identity="$3"
    shift 3
    [ -d "$src" ] || { echo "FATAL: embed_framework: $src missing" >&2; return 1; }
    local exe fw rpaths
    exe="$app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
    fw="$app/Contents/Frameworks/$(basename "$src")"
    mkdir -p "$app/Contents/Frameworks"
    rm -rf "$fw"
    ditto "$src" "$fw"
    # grep -c reads all of otool's output, so pipefail never sees a broken pipe.
    rpaths=$(otool -l "$exe" | grep -c 'path @executable_path/../Frameworks ' || true)
    if [ "$rpaths" = 0 ]; then
        # It warns that the linker's signature is now invalid, which the app's signing replaces.
        install_name_tool -add_rpath @executable_path/../Frameworks "$exe" 2>/dev/null
    fi
    bash tools/sign-framework.sh "$identity" "$app" "$(basename "$src")" "$@"
}
# <<< embed_framework

SIGN_KEYCHAIN=${HOMEVIDEO_SIGN_KEYCHAIN:-}
IDENTITY=${HOMEVIDEO_IDENTITY:-}
NOTARY_PROFILE=${HOMEVIDEO_NOTARY_PROFILE:-}
if [ -z "${HOMEVIDEO_SIGN:-}" ]; then
    if [ -n "$IDENTITY" ] && [ -n "$SIGN_KEYCHAIN" ]; then HOMEVIDEO_SIGN=devid; else HOMEVIDEO_SIGN=adhoc; fi
fi
case "$HOMEVIDEO_SIGN" in
    devid)
        [ -n "$IDENTITY" ] || { echo "FATAL: HOMEVIDEO_SIGN=devid needs HOMEVIDEO_IDENTITY" >&2; exit 1; }
        [ -n "$SIGN_KEYCHAIN" ] || { echo "FATAL: HOMEVIDEO_SIGN=devid needs HOMEVIDEO_SIGN_KEYCHAIN" >&2; exit 1; }
        [ -f "$SIGN_KEYCHAIN" ] || { echo "FATAL: HOMEVIDEO_SIGN_KEYCHAIN is not a file: $SIGN_KEYCHAIN" >&2; exit 1; }
        ;;
    adhoc) ;;
    *) echo "FATAL: HOMEVIDEO_SIGN must be devid or adhoc, got $HOMEVIDEO_SIGN" >&2; exit 1 ;;
esac

APPINFO=Sources/HomeVideo/HomeVideoApp.swift
# The display name (AppInfo.displayName) names the .app and fills CFBundleName and
# CFBundleDisplayName. The bundle id does not follow it.
NAME=$(grep -oE 'static let displayName = "[^"]+"' "$APPINFO" | grep -oE '"[^"]+"' | tr -d '"')
VERSION=$(grep -oE 'static let version = "[^"]+"' "$APPINFO" | grep -oE '"[^"]+"' | tr -d '"')
BUILD=$(grep -oE 'static let build = [0-9]+' "$APPINFO" | grep -oE '[0-9]+$')
[ -n "$NAME" ] && [ -n "$VERSION" ] && [ -n "$BUILD" ] \
    || { echo "FATAL: could not read AppInfo from $APPINFO" >&2; exit 1; }

ARCH=${HOMEVIDEO_ARCH:-x86_64}
BUNDLE_ID=${HOMEVIDEO_BUNDLE_ID:-co.wonders.homevideo}
OUT=${HOMEVIDEO_OUT:-$HOME/build/$NAME}

MIN_OS=14.0   # LSMinimumSystemVersion below, and the floor every slice's minos is checked against

# Updates, by line. The release feed is on the app's own site. The beta feed is unlisted, so it
# never lives in this repo: the beta line reads it from HV_BETA_FEED_URL.
# The public key checks every update's EdDSA signature. Its private half is never in this repo. A
# dev build (none) carries no update key at all.
SPARKLE_PUBLIC_KEY="5DEOh6AC+kCk0wZDOBlfbBtr4MsIzieG1VrKttvitXM="   # generate_keys --account HomeVideo
UPDATE_LINE=${HOMEVIDEO_UPDATE_LINE:-none}
case "$UPDATE_LINE" in
    release) FEED_URL=https://homevideo.app/updates/appcast.xml ;;
    beta)    FEED_URL=${HV_BETA_FEED_URL:-}
             [ -n "$FEED_URL" ] || { echo "FATAL: HOMEVIDEO_UPDATE_LINE=beta needs HV_BETA_FEED_URL, the unlisted beta feed" >&2; exit 1; } ;;
    none)    FEED_URL="" ;;
    *) echo "FATAL: HOMEVIDEO_UPDATE_LINE must be release, beta or none, got $UPDATE_LINE" >&2; exit 1 ;;
esac
# The word on the box follows the line: "0.2.0 beta 1" on the beta
# line, the version alone on release and none. The beta number comes from HOMEVIDEO_BETA at bundle
# time, required on beta and refused elsewhere, so a beta cut never goes out unnumbered and a
# release never carries a stray beta word. CFBundleVersion stays the build on every line, since
# Sparkle compares that.
BETA=${HOMEVIDEO_BETA:-}
if [ "$UPDATE_LINE" = beta ]; then
    [ -n "$BETA" ] || { echo "FATAL: HOMEVIDEO_UPDATE_LINE=beta needs HOMEVIDEO_BETA, the beta number (HOMEVIDEO_BETA=1 for $VERSION beta 1)" >&2; exit 1; }
    [[ "$BETA" =~ ^[1-9][0-9]*$ ]] || { echo "FATAL: HOMEVIDEO_BETA must be a whole number from 1, got $BETA" >&2; exit 1; }
    SHORT_VERSION="$VERSION beta $BETA"
else
    [ -z "$BETA" ] || { echo "FATAL: HOMEVIDEO_BETA is for the beta line only, refused on $UPDATE_LINE" >&2; exit 1; }
    SHORT_VERSION="$VERSION"
fi
UPDATE_PLIST=""
if [ -n "$FEED_URL" ]; then
    # SUEnableAutomaticChecks is left out on purpose, so Sparkle asks on the second launch.
    # SUEnableSystemProfiling is never written: no profile is sent. SUVerifyUpdateBeforeExtraction
    # goes with SURequireSignedFeed: without it Sparkle 2.10 refuses to start ("Fatal updater error
    # (5)"), since a signed feed means little if the archive is opened before its own signature is
    # checked.
    UPDATE_PLIST=$(printf '\t<key>%s</key>\n\t%s\n' \
        SUFeedURL "<string>$FEED_URL</string>" \
        SUPublicEDKey "<string>$SPARKLE_PUBLIC_KEY</string>" \
        SUScheduledCheckInterval "<integer>86400</integer>" \
        SURequireSignedFeed "<true/>" \
        SUVerifyUpdateBeforeExtraction "<true/>")
fi
ICON_NAME_PLIST=""

write_plist() {
cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>$NAME</string>
	<key>CFBundleExecutable</key>
	<string>HomeVideo</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
$ICON_NAME_PLIST
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$SHORT_VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD</string>
	<key>LSMinimumSystemVersion</key>
	<string>$MIN_OS</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.video</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
$UPDATE_PLIST
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key>
			<string>Movie</string>
			<key>CFBundleTypeRole</key>
			<string>Viewer</string>
			<key>LSHandlerRank</key>
			<string>Alternate</string>
			<key>LSItemContentTypes</key>
			<array>
				<string>public.movie</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
PLIST
plutil -lint "$1" >/dev/null
}

# The notices that ship with the binary: the app's own GPL-3 LICENSE and every third-party license
# under licenses/ (Sparkle's MIT, whose file also carries its bundled bsdiff, sais, ed25519 and
# SUSignatureVerifier notices), into Contents/Resources/Licenses. Help > Acknowledgements opens it.
copy_licenses() {
    local dest="$1/Licenses"
    [ -f LICENSE ] || { echo "FATAL: LICENSE missing" >&2; return 1; }
    [ -f licenses/sparkle-LICENSE.txt ] || { echo "FATAL: licenses/sparkle-LICENSE.txt missing" >&2; return 1; }
    mkdir -p "$dest"
    cp LICENSE "$dest/HomeVideo-LICENSE.txt"
    cp licenses/*.txt "$dest/"
}

if [ -n "${HOMEVIDEO_LICENSES_ONLY:-}" ]; then
    copy_licenses "$HOMEVIDEO_LICENSES_ONLY"
    ls "$HOMEVIDEO_LICENSES_ONLY/Licenses"
    exit 0
fi

if [ -n "${HOMEVIDEO_PLIST_ONLY:-}" ]; then
    write_plist "$HOMEVIDEO_PLIST_ONLY"
    echo "    updates:    $UPDATE_LINE ${FEED_URL:-none}"
    echo "    version:    $SHORT_VERSION ($BUILD)"
    exit 0
fi

case "$ARCH" in
    x86_64)    BUILD_DIR=.build/release ;;
    arm64)     BUILD_DIR=.build-arm64/release ;;
    universal) BUILD_DIR=.build/release; ARM_BUILD_DIR=.build-arm64/release ;;
    *) echo "FATAL: HOMEVIDEO_ARCH must be x86_64, arm64 or universal, got $ARCH" >&2; exit 1 ;;
esac

EXE="$BUILD_DIR/HomeVideo"
RENDER="$BUILD_DIR/homevideo-render"
RES="$BUILD_DIR/HomeVideo_HomeVideoCore.bundle"
EXES=("$EXE" "$RENDER")
if [ "$ARCH" = universal ]; then
    ARM_EXE="$ARM_BUILD_DIR/HomeVideo"
    ARM_RENDER="$ARM_BUILD_DIR/homevideo-render"
    for f in "$ARM_EXE" "$ARM_RENDER"; do
        [ -x "$f" ] || { echo "FATAL: $f missing; build arm64 first:" >&2
            echo "  swift build -c release --arch arm64 --scratch-path .build-arm64" >&2; exit 1; }
    done
    EXES+=("$ARM_EXE" "$ARM_RENDER")
fi
for f in "$EXE" "$RENDER"; do
    [ -x "$f" ] || { echo "FATAL: $f missing; run the release build first (swift build -c release, no --product)" >&2; exit 1; }
done
[ -d "$RES" ] || { echo "FATAL: $RES missing" >&2; exit 1; }
# Each input must be the single slice it claims to be, so a stray fat or wrong-arch build never
# slips into the join.
if [ "$ARCH" = universal ]; then
    for f in "$EXE" "$RENDER"; do
        [ "$(lipo -archs "$f")" = x86_64 ] || { echo "FATAL: $f is $(lipo -archs "$f"), wanted x86_64" >&2; exit 1; }
    done
    for f in "$ARM_EXE" "$ARM_RENDER"; do
        [ "$(lipo -archs "$f")" = arm64 ] || { echo "FATAL: $f is $(lipo -archs "$f"), wanted arm64" >&2; exit 1; }
    done
else
    for f in "$EXE" "$RENDER"; do
        [ "$(lipo -archs "$f")" = "$ARCH" ] || { echo "FATAL: $f is $(lipo -archs "$f"), wanted $ARCH" >&2; exit 1; }
    done
fi
# A stale executable would be stamped with a build number it was not compiled from. For a
# universal build both slices are checked, or one machine would run another build's code.
for exe in "${EXES[@]}"; do
    for src in $(find Sources -name '*.swift' -o -name '*.metal'); do
        if [ "$src" -nt "$exe" ]; then
            echo "FATAL: $src is newer than $exe; rebuild first" >&2
            exit 1
        fi
    done
done

APP="$OUT/$NAME $VERSION b$BUILD.app"
echo ">> $APP ($ARCH, $BUNDLE_ID)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ "$ARCH" = universal ]; then
    lipo -create "$EXE" "$ARM_EXE" -output "$APP/Contents/MacOS/HomeVideo"
    lipo -create "$RENDER" "$ARM_RENDER" -output "$APP/Contents/MacOS/homevideo-render"
else
    cp "$EXE" "$APP/Contents/MacOS/HomeVideo"
    cp "$RENDER" "$APP/Contents/MacOS/homevideo-render"
fi
cp -R "$RES" "$APP/Contents/Resources/"
copy_licenses "$APP/Contents/Resources"
# The app icon, two files. assets/AppIcon.icns is the flat picture macOS 14 and 15 draw
# (CFBundleIconFile). assets/AppIcon.icon is the Liquid Glass document macOS 26 and later draw (CFBundleIconName),
# compiled here by actool into Contents/Resources/Assets.car before signing, so the car is
# inside the signature. actool comes with Xcode only: without it an ad hoc build ships the icns
# alone, and a devid build stops, since a notarized build always carries the car.
[ -f assets/AppIcon.icns ] || { echo "FATAL: assets/AppIcon.icns missing" >&2; exit 1; }
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
if xcrun --find actool >/dev/null 2>&1; then
    [ -f assets/AppIcon.icon/icon.json ] || { echo "FATAL: assets/AppIcon.icon missing" >&2; exit 1; }
    echo ">> Assets.car (actool, AppIcon.icon)"
    # actool also writes its own flattened AppIcon.icns into the output folder. It is left in
    # $TMP: the shipped icns is ours. The partial plist is ignored, the keys are written below.
    # actool fails without saying why when the output folder does not exist.
    mkdir -p "$TMP/car"
    xcrun actool assets/AppIcon.icon --compile "$TMP/car" --app-icon AppIcon --include-all-app-icons \
        --platform macosx --minimum-deployment-target "$MIN_OS" --target-device mac \
        --development-region en --enable-on-demand-resources NO \
        --output-format human-readable-text --output-partial-info-plist "$TMP/car/partial.plist" >/dev/null \
        || { echo "FATAL: actool could not compile assets/AppIcon.icon" >&2; exit 1; }
    [ -s "$TMP/car/Assets.car" ] || { echo "FATAL: actool wrote no Assets.car" >&2; exit 1; }
    cp "$TMP/car/Assets.car" "$APP/Contents/Resources/Assets.car"
    ICON_NAME_PLIST=$'\t<key>CFBundleIconName</key>\n\t<string>AppIcon</string>'
elif [ "$HOMEVIDEO_SIGN" = devid ]; then
    echo "FATAL: xcrun actool missing; a devid build must carry Assets.car (install Xcode)" >&2
    exit 1
else
    echo "!!  no actool: Assets.car skipped, the icns alone is the icon (ad hoc build)"
fi

# Xcode 26 ships the Metal compiler as a separate download
# (xcodebuild -downloadComponent MetalToolchain). Without it, skip the metallib: the app
# compiles the copied .metal sources at runtime (ShaderLibrary), which costs a few ms at launch.
METALLIB="$APP/Contents/Resources/HomeVideo_HomeVideoCore.bundle/default.metallib"
if xcrun -sdk macosx metal -v >/dev/null 2>&1; then
    echo ">> metallib"
    AIRS=()
    for m in Sources/HomeVideoCore/Shaders/*.metal; do
        air="$TMP/$(basename "$m" .metal).air"
        xcrun -sdk macosx metal -mmacosx-version-min=14.0 -c "$m" -o "$air"
        AIRS+=("$air")
    done
    xcrun -sdk macosx metallib "${AIRS[@]}" -o "$METALLIB"
else
    echo ">> metallib skipped: no Metal Toolchain; shaders compile from source at runtime"
fi
ls "$APP/Contents/Resources/HomeVideo_HomeVideoCore.bundle/"*.metal >/dev/null 2>&1 || [ -f "$METALLIB" ] \
    || { echo "FATAL: neither default.metallib nor .metal sources in the resource bundle" >&2; exit 1; }

write_plist "$APP/Contents/Info.plist"

# Assert the joined binary holds both slices rather than trusting that lipo ran.
if [ "$ARCH" = universal ]; then
    for exe in HomeVideo homevideo-render; do
        SLICES=$(lipo -archs "$APP/Contents/MacOS/$exe")
        case "$SLICES" in
            *x86_64*arm64*|*arm64*x86_64*) echo "OK  $exe: $SLICES" ;;
            *) echo "FATAL: Contents/MacOS/$exe is [$SLICES], wanted x86_64 and arm64" >&2; exit 1 ;;
        esac
    done
fi
# No slice may demand a newer macOS than the bundle declares. A binary built with no version-min
# flag takes the build host's OS as its minimum and the linker only warns, so this is the gate.
# Checked per slice: a fat binary can disagree with itself, and `otool -l` on it prints one
# LC_BUILD_VERSION per architecture. The two executables are the only files of ours.
# Sparkle.framework, embedded at signing, is Sparkle's own universal build, with a floor far below ours.
for exe in HomeVideo homevideo-render; do
    while read -r slice_min; do
        [ -n "$slice_min" ] || continue
        lower=$(printf '%s\n%s\n' "$MIN_OS" "$slice_min" | sort -V | head -1)
        if [ "$lower" != "$slice_min" ]; then
            echo "FATAL: a slice of $exe needs macOS $slice_min but LSMinimumSystemVersion is $MIN_OS." >&2
            echo "       Package.swift platforms, MIN_OS here and the metal -mmacosx-version-min move together." >&2
            exit 1
        fi
        echo "OK  $exe slice minos $slice_min within $MIN_OS"
    done < <(otool -l "$APP/Contents/MacOS/$exe" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; f=0}')
done

if [ "$HOMEVIDEO_SIGN" = adhoc ]; then
    echo ">> Sparkle.framework (ad hoc)"
    embed_framework "$APP" "$BUILD_DIR/Sparkle.framework" -
    echo ">> codesign (ad hoc)"
    # The renderer is nested code: signed before the app, so the app's seal covers it.
    codesign --force --sign - --identifier "$BUNDLE_ID.homevideo-render" "$APP/Contents/MacOS/homevideo-render"
    # No --deep: the framework is signed already, piece by piece (embed_framework).
    codesign --force --sign - "$APP"
    codesign --verify --deep --strict "$APP"
else
    echo ">> codesign (devid)"
    sign_one() {  # retry x3: Sequoia codesign has a transient CS-subsystem race
        local f="$1" attempt
        for attempt in 1 2 3; do
            codesign --force --sign "$IDENTITY" "${SIGN_EXTRA[@]}" ${SIGN_ID[@]+"${SIGN_ID[@]}"} "$f" 2>/dev/null && return 0
            sleep 0.5
        done
        codesign --force --sign "$IDENTITY" "${SIGN_EXTRA[@]}" ${SIGN_ID[@]+"${SIGN_ID[@]}"} "$f"
    }
    SIGN_ID=()
    # The password reaches `security -i` on stdin, never an argv: process command lines are readable
    # by every local process and may be recorded by endpoint security software. `security -i` reads
    # one command per line and takes a double-quoted argument with backslash escapes.
    sec_quote() { printf '"%s"' "$(printf '%s' "$1" | sed 's/[\\"]/\\&/g')"; }
    IFS= read -r SIGN_PW
    printf 'unlock-keychain -p %s %s\n' "$(sec_quote "$SIGN_PW")" "$(sec_quote "$SIGN_KEYCHAIN")" | security -i
    unset SIGN_PW
    security show-keychain-info "$SIGN_KEYCHAIN" >/dev/null 2>&1 \
        || { echo "FATAL: could not unlock $SIGN_KEYCHAIN" >&2; exit 1; }
    security set-keychain-settings "$SIGN_KEYCHAIN"     # no auto-lock mid-run
    # Hardened runtime plus a secure timestamp on every signature: the notary service rejects a
    # submission without both. Sparkle.framework is signed first, inside out, by embed_framework
    # with the same identity, and the app last, so library validation accepts the framework (same
    # team) and the app's seal covers the signed framework. HomeVideo_HomeVideoCore.bundle is a
    # SwiftPM resource folder with no Info.plist and no code, which codesign refuses to sign on its
    # own ("bundle format unrecognized"), so the app's signature seals its files as resources instead.
    SIGN_EXTRA=(--keychain "$SIGN_KEYCHAIN" --options runtime --timestamp)
    echo ">> Sparkle.framework (devid)"
    embed_framework "$APP" "$BUILD_DIR/Sparkle.framework" "$IDENTITY" --keychain "$SIGN_KEYCHAIN"
    # The renderer: nested code in Contents/MacOS, signed before the app with the same identity,
    # hardened runtime and timestamp, so the notary service accepts it and the app's seal covers it.
    echo ">> homevideo-render (devid)"
    SIGN_ID=(--identifier "$BUNDLE_ID.homevideo-render")
    sign_one "$APP/Contents/MacOS/homevideo-render"
    SIGN_ID=()
    # The app's own entitlements, if it ever has any, are the app's alone, never the framework's
    # or the renderer's.
    [ -f assets/Entitlements.plist ] && SIGN_EXTRA+=(--entitlements assets/Entitlements.plist)
    sign_one "$APP"
    echo ">> verify"
    codesign --verify --deep --strict --verbose=2 "$APP"

    # Notarize and staple, so Gatekeeper opens a downloaded copy on any Mac. Apple usually answers
    # in one to three minutes. On a rejection, read the log before resubmitting:
    # xcrun notarytool log <submission id> --keychain-profile "$HOMEVIDEO_NOTARY_PROFILE" --keychain "$HOMEVIDEO_SIGN_KEYCHAIN"
    if [ -n "$NOTARY_PROFILE" ]; then
        echo ">> notarize + staple ($NOTARY_PROFILE)"
        NZIP="$TMP/notarize.zip"
        ditto -c -k --keepParent "$APP" "$NZIP"
        xcrun notarytool submit "$NZIP" --keychain-profile "$NOTARY_PROFILE" \
            --keychain "$SIGN_KEYCHAIN" --wait
        xcrun stapler staple "$APP"
        rm -f "$NZIP"
    else
        echo "!!  not notarized: HOMEVIDEO_NOTARY_PROFILE is unset"
    fi
fi

echo "    app:        $APP"
echo "    arch:       $(lipo -archs "$APP/Contents/MacOS/HomeVideo")"
echo "    render:     Contents/MacOS/homevideo-render, $(lipo -archs "$APP/Contents/MacOS/homevideo-render")"
echo "    bundle id:  $BUNDLE_ID"
echo "    updates:    $UPDATE_LINE ${FEED_URL:-none}"
echo "    sparkle:    $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Frameworks/Sparkle.framework/Resources/Info.plist"), rpath $(otool -l "$APP/Contents/MacOS/HomeVideo" | grep -c 'path @executable_path/../Frameworks ' || true)"
echo "    version:    $SHORT_VERSION ($BUILD)"
if [ -f "$APP/Contents/Resources/Assets.car" ]; then
    echo "    icon:       AppIcon.icns + Assets.car (CFBundleIconName AppIcon)"
else
    echo "    icon:       AppIcon.icns only, no Assets.car"
fi
if [ -f "$METALLIB" ]; then
    echo "    shaders:    default.metallib, $(stat -f %z "$METALLIB") bytes"
else
    echo "    shaders:    .metal sources, compiled at runtime"
fi
if [ "$HOMEVIDEO_SIGN" = devid ]; then
    echo "    codesign:   $(codesign --verify --strict "$APP" 2>&1 && echo valid || echo FAILED)"
    echo "    notarized:  $(xcrun stapler validate "$APP" >/dev/null 2>&1 && echo stapled || echo 'no ticket')"
    echo "    gatekeeper: $(spctl -a -t exec -vv "$APP" 2>&1 | awk -F'=' '/source/{print $2; exit}')"
fi
