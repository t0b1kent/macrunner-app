# MacRunner 1.1.5 (build 125)

- Fixed cnc-ddraw for games started by a separate launcher. The Might and Magic VII launcher now passes the DirectDraw load order to the game it starts.
- Added cnc-ddraw support for legacy 32-bit DirectDraw games, including Might and Magic VI, VII, and VIII. MacRunner enables compatibility automatically for eligible games. The game page has a switch to change it. Existing wrappers and settings are preserved.
- Updated the 32-bit and 64-bit HyperBridge translation engines. The 32-bit update includes fixes for the Ubisoft Connect startup hang and for translator threads left waiting during shutdown.
- Updated the 32-bit Direct3D 9 renderer to submit some GPU work earlier. Improved background-process cleanup after closing compatible launchers such as Ubisoft Connect.
- Improved the appearance of borderless windows during launch and shutdown. A brief white flash can still appear in some games.

cnc-ddraw 7.1.0.0 is distributed under the MIT license. [cnc-ddraw release](https://github.com/FunkyFr3sh/cnc-ddraw/releases/tag/v7.1.0.0)

## Measured

Early GPU-query submission (new in 1.1.5) raised the average frame rate in a busy Gothic 3 town scene with combat from **51.2 to 66.5 FPS** on a MacBook Pro with an M1 Pro (same build and save, option off vs on, about 5 minutes each; the scene changes during combat, so expect some variation).

**In development:** Heroes of Might and Magic III Remake (Ubisoft Connect, DirectX 12) already starts and runs in our development build. Graphics flickering is still being fixed, so it is not part of 1.1.5 yet.
