# CollieHarness

The smallest possible host app for Collie's UI — a button that calls
`Collie.presentReport()`, over a colourful screen that is worth drawing on.

It exists because **the flow starts with a shake, and a shake cannot be triggered by a
script on the simulator** (the Simulator's `Device ▸ Shake` menu needs Accessibility
permission, and neither `simctl` nor UI-automation tools expose the gesture). Without a
harness, every UI change had to be verified by hand inside a real host app — which is how
two markup implementations shipped broken. Here the banner, the form and the markup editor
are one tap away and fully drivable.

The harness links the package **from this checkout** (`path: ../..`), so a change to
`Sources/Collie` is on screen after one rebuild.

## Run it

```sh
brew install xcodegen                 # once
cd Examples/CollieHarness
xcodegen generate                     # writes CollieHarness.xcodeproj (not committed)
xcodebuild -project CollieHarness.xcodeproj -scheme CollieHarness \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build build
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/CollieHarness.app
xcrun simctl launch --console-pty booted com.collie.harness
```

`--console-pty` prints the app's stdout, including Collie's `diagnostics` output. To pass an
environment variable, prefix it with `SIMCTL_CHILD_` — anything after the bundle id becomes
a launch *argument*, not an env var.

## Drive it

Any simulator UI-automation tool works. With [AXe](https://github.com/cameroncooke/AXe):

```sh
UDID=$(xcrun simctl list devices booted -j | python3 -c 'import json,sys;print(next(d["udid"] for v in json.load(sys.stdin)["devices"].values() for d in v))')
axe describe-ui --udid $UDID          # element frames — every control is labelled
axe tap -x 201 -y 505 --udid $UDID
axe swipe --start-x 120 --start-y 250 --end-x 280 --end-y 420 --duration 0.7 --udid $UDID
axe record-video --udid $UDID --output flow.mp4
```

Synthetic swipes do land as PencilKit strokes, so the markup editor can be verified
end-to-end. To inspect a transition frame by frame, tile the recording:

```sh
ffmpeg -i flow.mp4 -frames:v 1 -vf "fps=8,scale=120:-1,tile=10x3:margin=3:padding=3" contact.png
```

## What it is not

Not an integration example — copy `Integration/CollieIntegration.swift` for that. The
configuration here points at `example.invalid` on purpose: the remote kill switch fails open
and a send is queued, which is the offline path a tester without VPN takes.
