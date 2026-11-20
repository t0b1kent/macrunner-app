# MacRunner 1.1.4

## What's new in MacRunner 1.1.4

- **Faster 32-bit games.** The 32-bit CPU translator has faster x87 floating-point math, and the Gothic 3 profile turns on a fast path for Wine's thread-affinity query. In our test scene, the unpatched GOG version of Gothic 3 went from about 32 fps in 1.1.3 to about 100 fps in 1.1.4 on a MacBook Pro with an M1 Pro (full screen, 1512 × 982). We measured 98.8, 102.6 and 101.9 fps on 1.1.4 builds and 32.4 fps on 1.1.3 with the same test setup. This is one game, one scene and one Mac. It is not a promise for other games or machines.
- **Gothic 3 exit.** A normal quit no longer shows a false "The game exited with an error" message.
- **Switching games.** The Wine window no longer flashes when you switch between games that use different graphics layers.
- **Retina scaling.** Automatic Retina scaling now applies to games only, so normal-size windowed programs such as the Steam sign-in window are no longer drawn at half size.
- **Steam.** Preparing a bottle no longer starts Steam's autostart entries, and a networking fix lets Steam see the complete list of network interfaces.

## Not verified on this build

- Elden Ring and Crysis were not run live on 1.1.4. This release makes no claim about them, including the white or black rectangle some setups show with Elden Ring.
- The thread-affinity fast path is enabled only for Gothic 3.

Apple Silicon, macOS 26.5 or later. Build 123 is signed with Developer ID and notarized by Apple.
