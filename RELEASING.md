# Releasing

Both platforms live in this repository but ship on **independent version lines**, so a change to
one never forces a release of the other.

| Platform | Tag | Consumed as |
|---|---|---|
| iOS | `1.12.0` (example) | Swift Package Manager resolves the tag directly from git |
| Android | `android-0.1.0` (example) | JitPack builds the artifacts from the same tag |

`android-*` tags are not semver, so SPM ignores them entirely — the iOS version line stays clean
no matter how often Android ships.

## The procedure

Releasing is **tag-driven**. Everything after the tag is automated by
[`.github/workflows/release.yml`](.github/workflows/release.yml):

1. Update the relevant changelog with a `## <version> — <date>` section.
   iOS: [`CHANGELOG.md`](CHANGELOG.md) · Android: [`Android/CHANGELOG.md`](Android/CHANGELOG.md).
   For Android, also bump `localVersion` in `Android/build.gradle.kts` so local builds match.
2. Commit.
3. Tag and push:

   ```bash
   git tag 1.13.0        && git push origin 1.13.0        # iOS
   git tag android-0.2.0 && git push origin android-0.2.0 # Android
   ```

The workflow then:

- **verifies before publishing** — `swift test` + the iOS simulator build, or the Android unit
  tests plus all three artifacts *and* both apps compiled against the real artifact **and** the
  no-op (the API-compatibility gate). A tag that doesn't build never becomes a release;
- **writes the release notes from the changelog**, so notes cannot drift from it — a missing
  section fails the release rather than publishing empty notes;
- **attaches the AARs** to Android releases.

Nothing is published by hand, and no credentials are needed: the workflow uses the repository's
own token.

## How Android consumers get it

JitPack builds the tag on first request; no publishing infrastructure, no accounts, no secrets.

```kotlin
// settings.gradle.kts
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://jitpack.io") }
    }
}
```

```kotlin
// build.gradle.kts of the app module
debugImplementation("com.github.ersel95.collie:collie:android-0.1.0")
releaseImplementation("com.github.ersel95.collie:collie-no-op:android-0.1.0")

// Only if you use the Firestore transport:
debugImplementation("com.github.ersel95.collie:collie-firebase:android-0.1.0")
```

The version is the tag itself, so it is always obvious which commit an artifact came from.

`Android/build.gradle.kts` takes the version from `-Pversion` when one is passed (which is what
JitPack does with the tag) and falls back to the local constant otherwise — so a release requires
no edit to the build file beyond the changelog bump.

### Working against an unreleased change

```bash
cd Android && ./gradlew publishToMavenLocal
```

then add `mavenLocal()` to the consumer's repositories. Same coordinates, so switching back to a
released version is a one-line change.

## Version-line rules

- Tag when sources change. Documentation-only changes are not tagged.
- SemVer. iOS is past 1.0; Android is `0.x` while its API settles.
- The Android changelog version and the tag must match — the release fails otherwise, which is
  the point.
