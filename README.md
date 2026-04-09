# DylibLoader — Proof of Concept

A LiveContainer-compatible tweak that downloads and loads a payload dylib at
runtime via `dlopen()`.

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                    LiveContainer Process                       │
│                                                                │
│  ┌─────────────┐     ┌──────────────┐     ┌────────────────┐ │
│  │ TweakLoader  │────▶│ DylibLoader  │────▶│  ExamplePayload │ │
│  │ (LC built-in)│     │ (stub tweak) │     │  (downloaded)   │ │
│  └─────────────┘     └──────────────┘     └────────────────┘ │
│         │                    │                     │           │
│    loads tweaks        downloads &             hooks &        │
│    from folder         dlopen's payload       patches app    │
└──────────────────────────────────────────────────────────────┘
```

## Timing / Early Injection

**The key question: when does the downloaded dylib get loaded?**

### First launch (no cache)
1. LiveContainer's TweakLoader loads `DylibLoader.dylib` via `dlopen()`
2. DylibLoader's `__attribute__((constructor))` fires — **before the app's `main()`**
3. Constructor blocks while downloading the payload (synchronous, up to 30s timeout)
4. `dlopen()` on the downloaded payload — its constructors fire immediately
5. App's `main()` runs — all hooks from the payload are already active

**Limitation:** The blocking download adds startup latency on first launch. Network
errors mean no payload on first run.

### Subsequent launches (cached)
1. TweakLoader loads `DylibLoader.dylib`
2. Constructor finds the cached payload in Documents/
3. Immediately `dlopen()`s the cached file — **zero network delay**
4. Payload constructors fire, hooks installed
5. App's `main()` runs with all hooks active

### Why this works for early hooks
- `__attribute__((constructor))` functions run at `dlopen()` time
- ObjC `+load` methods also run at `dlopen()` time
- Both happen **before** `main()` because TweakLoader itself is loaded before `main()`
- Method swizzling (via `method_setImplementation` or MSHookMessageEx) patches the
  method dispatch table, so all future calls go through the hook — even if the
  swizzled class was already loaded

### What WON'T work
- Hooking code that already executed in `+load` or another constructor that ran
  before your payload was loaded (order depends on dylib load order)
- Patching inline function calls or already-JIT'd code
- Hooking C functions that were resolved before your fishhook rebinding (use
  `_dyld_register_func_for_add_image` to catch future loads)

## Files

| File | Purpose |
|------|---------|
| `DylibLoader.m` | The stub tweak — downloads, caches, and loads the payload |
| `ExamplePayload.m` | Sample payload that hooks `-[NSBundle bundleIdentifier]` |
| `Makefile` | Theos build configuration |

## Usage

1. Build both dylibs with Theos: `make`
2. Host `ExamplePayload.dylib` on a web server
3. Update `PAYLOAD_URL` in `DylibLoader.m` to point to it
4. Place `DylibLoader.dylib` in LiveContainer's tweaks folder
5. Launch an app via LiveContainer
6. Check `Documents/dylib_loader.log` in the app's container for output

## Log Output Example

```
[2026-04-09 12:00:00.001] ========================================
[2026-04-09 12:00:00.002] DylibLoader starting
[2026-04-09 12:00:00.003] Process: SomeApp (PID 1234)
[2026-04-09 12:00:00.003] Bundle: com.example.someapp
[2026-04-09 12:00:00.004] Documents: /var/mobile/.../Documents
[2026-04-09 12:00:00.004] Cache path: /var/mobile/.../Documents/cached_payload.dylib
[2026-04-09 12:00:00.005] Found cached payload, loading immediately
[2026-04-09 12:00:00.006] Attempting to dlopen: /var/mobile/.../Documents/cached_payload.dylib
[2026-04-09 12:00:00.010] [Payload] ★ Payload constructor fired!
[2026-04-09 12:00:00.011] [Payload] ★ Hook installed: -[NSBundle bundleIdentifier]
[2026-04-09 12:00:00.012] [Payload] ★ Payload init complete. All hooks active.
[2026-04-09 12:00:00.012] SUCCESS: Payload loaded from /var/mobile/.../Documents/cached_payload.dylib
```
