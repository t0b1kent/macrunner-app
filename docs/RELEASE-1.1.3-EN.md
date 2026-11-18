# MacRunner 1.1.3

## What's new in MacRunner 1.1.3

- **Retina fullscreen for 32-bit Direct3D 9.** HyperBridge DX9 now switches the display mode when a game enters fullscreen. The maintainer verified Gothic 3 filling the screen at 1512 × 982 and launching on the first attempt. Version 1.1.2 already added the full Direct3D 9 display-mode list.
- **Direct3D 12 fullscreen edges.** Wine now sizes the fullscreen surface and its mask to the client area. The maintainer verified Elden Ring fullscreen without the light strips along the right and bottom edges.
- **Persistent Direct3D 9 pipeline cache.** When Metal rejects an existing archive, HyperBridge DX9 rebuilds it with entries that can be serialized. In the maintainer's Gothic 3 check of this fix, the second launch reported 119 cache hits and 7 misses.
- **DirectX from the game's installer.** MacRunner keeps supported DirectX 9 files supplied by the installer so it can install them when the game launches.

## 32-bit graphics

HyperBridge DX9 runs 32-bit Direct3D 9 through Metal, and DXMT provides the 32-bit Direct3D 11 path. MacRunner offers Automatic, Fast, and Exact calculation accuracy for 32-bit games. The CPU translator is the same as in 1.1.2.

## Known issues

- Gothic 3 returns exit code 1 after a normal quit, which can trigger “The game exited with an error.”
- A small Wine window can briefly appear when switching between games with different graphics configurations.

Apple Silicon, macOS 26.5 or later. Build 122 is signed with Developer ID and notarized by Apple.
