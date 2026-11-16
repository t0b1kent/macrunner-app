# MacRunner 1.1.2 · build 121

MacRunner 1.1.2 repairs startup and display handling in the 1.1.1 runtime.

- Fixed an ARM64EC graphics entry-thunk regression that broke graphics-adapter enumeration and DirectX 12 device creation.
- HyperBridge DX9 now exposes the available display resolutions instead of reporting only the current desktop mode. Display-mode queries also handle invalid parameters and unavailable modes correctly.
- Turning off High resolution (Retina) now saves the explicit choice.
- Retina no longer automatically enables an experimental mouse mode that treats a hidden system cursor as relative input. Games with custom cursors also hide the system cursor in menus.

The application is signed with Developer ID and notarized by Apple. Packaged runtime checks, adapter/device initialization and DX9 display-mode checks passed without launching games.

Fresh gameplay of this final package is pending the maintainer's download-and-test check after publication. The intermittent Gothic 3 first-start error and Retina-on mouse behavior still require confirmation in the game. The previously documented rare shutdown failure remains under investigation.

Download **MacRunner-1.1.2-arm64.zip**, unpack it and replace the previous MacRunner in Applications. Game files are not included. HyperBridge's translator component remains at 1.1.1; it is included in the application.

## Gothic 3 comparison

The owner reports approximately **78 FPS in MacRunner versus 30 FPS in Windows on Arm / Prism for Gothic 3**: **2.6 times the reported frame rate**, or about 160% higher. The retained report does not yet identify all matching scene, resolution, graphics-setting, game-version and VM details. Treat these as owner-reported observations, not a reproducible benchmark of the final signed 1.1.1 package or a measurement of the CPU translator alone.

The owner also reports that Gothic 3 did not launch in the CrossOver/Rosetta configurations they tried. This is a result for those configurations, not a general incompatibility claim: a community reporter describes running Gothic 3 through a Rosetta-based Wine lane in [issue #2](https://github.com/t0b1kent/macrunner-app/issues/2).

## Downloads

[MacRunner](https://github.com/t0b1kent/macrunner-app/releases/tag/v1.1.2) · [DX9 1.1.2](https://github.com/t0b1kent/dxmt/releases/tag/v1.1.2) · [unchanged HyperBridge 1.1.1](https://github.com/t0b1kent/hyperbridge/releases/tag/v1.1.1).
