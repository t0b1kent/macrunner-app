# MacRunner 1.1.5 (125) source references

| Component | Source |
| --- | --- |
| MacRunner Control Center and Windows helper | [Application source](../build/repro110app/source) |
| HyperBridge (based on FEX-Emu) | [FEX32 and FEX64 source trees](https://github.com/t0b1kent/hyperbridge/tree/v1.1.5/fex/source) |
| 32-bit HBDX9 | [1.1.5 compilation inputs](https://github.com/t0b1kent/dxmt/tree/v1.1.5/release-sources/hbdx9-1.1.5) |
| HBDX9 fullscreen source from 1.1.4 | [1.1.4 DXMT tag](https://github.com/t0b1kent/dxmt/tree/v1.1.4/src/hbdx9) |
| Wine | [1.1.5 Wine tag](https://github.com/t0b1kent/macrunner-wine/tree/v1.1.5) |
| cnc-ddraw 7.1.0.0 | [Upstream source and release](https://github.com/FunkyFr3sh/cnc-ddraw/tree/v7.1.0.0) · [MIT license](../licenses/cnc-ddraw-MIT.txt) |

The Apple Silicon package was assembled locally from the accepted engine and a SwiftPM release build. The retained 1.1.4 release assembly recipe describes that earlier source-build workflow.

In build 125, MacRunner sets the DirectDraw load order for the game launch tree so a child executable such as `MM7-Rel.exe` inherits it.
