## Performance: recordings on M1 Pro

November 4, 2026, one Apple M1 Pro machine, macOS 27.0, with Metal HUD and screen recording enabled. MacRunner is the 1.1.0 c32r candidate shown in the owner's recordings. Values below average visible HUD readings sampled every 0.5 seconds in gameplay only; menus, loading and transitions are excluded.

### Elden Ring

Chapel of Anticipation, 1920×1200, High, Fullscreen selected in the game; Metal HUD reports Composited. CrossOver Preview 20261015 uses Rosetta + D3DMetal, with Game Porting Toolkit 4.0b3 identified by the HUD.

| Path | HUD resolution | Mean FPS | Median FPS | HUD 1% low* | GPU, ms | Frame Interval, ms |
|---|---:|---:|---:|---:|---:|---:|
| MacRunner 1.1.0, c32r candidate | 1920×1200 | **44.81** | 42.11 | 30.64 | 22.05 | 22.74 |
| CrossOver Preview 20261015 | 1920×1200 | 24.84 | 25.76 | 17.87 | 23.80 | 41.04 |

Samples: 77 readings at 87.0–125.5 seconds in the MacRunner recording and 117 at 77.0–135.5 seconds in CrossOver (end exclusive). The location is shared, but camera movement, route and time spent standing differ. The ratio of these recordings' means is about 1.80; this is not a controlled speedup measurement or a promise for other scenes. GPU time alone does not establish the cause of the FPS difference.

### Hollow Knight 1.5.12620

King's Pass opening: the landing area, first tunnel and combat. Both versions are 1.5.12620; the native Mac version uses ARM64 / Unity Metal, while MacRunner uses Windows x86-64 / D3D11 → DXMT → Metal.

| Path | HUD resolution | Mean FPS | Median FPS | HUD 1% low* | GPU, ms | Frame Interval, ms |
|---|---:|---:|---:|---:|---:|---:|
| MacRunner 1.1.0, c32r candidate | **3024×1964** | 118.66 | 120.00 | 109.09 | 6.23 | 8.43 |
| Native Mac version | 3024×1898 | 119.71 | 120.00 | 117.07 | 6.07 | 8.35 |

Samples: 45 readings at 77.0–99.5 seconds for MacRunner and 47 at 67.0–90.5 seconds for native. MacRunner renders 3.48% more pixels; its mean FPS is 0.87% lower. The reference single frames at 116 versus 119 FPS differ by about 2.5%, but do not replace these averages. A difference this small from one pass does not establish a repeatable advantage: routes and background activity differ, and the MacRunner recording includes a brightness overlay. That overlay obscures four resolution headers; surrounding readable headers show 3024×1964.

A separate King's Pass series at the same 1280×720 resolution and a 60 FPS cap measured **2.24 ms GPU time** with the D3D11 optimizations (2.26 / 2.24 / 2.23), versus 2.70 without. The native reference in the adjacent series was **2.39 ms**. The direct N Z N Z comparison measured **2.27 versus 2.39 ms**, about 5% less GPU time. These November 4, 01:43–02:07 measurements use a different scene/mode from the Retina videos above; they measure GPU time per frame, not FPS or total frame latency.

*HUD 1% low is the mean of the lowest `ceil(N×0.01)` displayed FPS readings: one reading in three short samples, two for CrossOver. It is **not a true per-frame 1% low**: individual presented-frame timings cannot be recovered from these videos. Mean FPS averages displayed HUD values arithmetically; Frame Interval is averaged separately. Results apply to one machine and these recordings, without repeated controlled runs.
