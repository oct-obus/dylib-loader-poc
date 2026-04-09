# DylibLoader

A LiveContainer-compatible tweak that downloads and loads a payload dylib at
runtime. Uses a manifest (`payload.json`) for version-based auto-updates.

## Architecture

```
LiveContainer Process
  |
  TweakLoader (LC built-in)
    |
    DylibLoader.dylib (this tweak)
      |
      1. Checks payload.json manifest for updates
      2. Downloads payload if new version available
      3. Saves to Tweaks/ folder
      4. LC signs it on next launch via signTweaks()
      5. TweakLoader loads the signed payload
      |
      ExamplePayload.dylib (downloaded)
        |
        Hooks, patches, etc.
```

## Manifest Format

`payload.json` hosted on GitHub:

```json
{
  "version": 3,
  "url": "https://raw.githubusercontent.com/.../ExamplePayload.dylib",
  "bundle_id": null
}
```

- `version`: Integer. Loader compares against stored version; downloads only when bumped.
- `url`: Direct download URL for the payload dylib.
- `bundle_id`: If set (e.g., `"com.example.app"`), only injects into that app. If `null`, injects into all apps.

## Loading Flow

### First launch (no cached payload)
1. TweakLoader loads `DylibLoader.dylib`
2. Constructor fires, no cached payload found
3. After app launch, fetches `payload.json` manifest
4. Downloads payload, saves to cache and Tweaks/ folder
5. Shows "Restart to activate" in floating panel
6. User closes and reopens from LiveContainer
7. LC's `signTweaks()` signs the new dylib
8. TweakLoader loads the now-signed payload

### Subsequent launches (payload signed and cached)
1. TweakLoader loads `DylibLoader.dylib`
2. Constructor finds payload in Tweaks/, `dlopen()` succeeds
3. Manifest check confirms version is current
4. Brief "Payload active" indicator, auto-dismisses

### Update available
1. Manifest shows higher version number
2. Downloads new payload, replaces cache and Tweaks/ copy
3. Shows "Restart to activate"
4. On next launch from LC, signed and loaded automatically

## UI

Floating draggable panel (top-right):
- Drag to reposition
- Minimize (-) to collapse to title bar
- Close (x) to dismiss
- Status colors: green (success), blue (info/restart needed), red (errors only)

## Files

| File | Purpose |
|------|---------|
| `DylibLoader.m` | Main loader tweak with floating panel UI |
| `ExamplePayload.m` | Sample payload showing UIAlertController on load |
| `payload.json` | Version manifest for auto-updates |
| `Makefile` | Theos build configuration |

## Usage

1. Build: `make` (requires Theos)
2. Place `DylibLoader.dylib` in LiveContainer's Tweaks folder
3. Host `ExamplePayload.dylib` and `payload.json` (GitHub raw works)
4. Launch an app via LiveContainer
5. To update: push new dylib, bump version in `payload.json`
