# Bottle preparation helpers

These are the original MacRunner helper sources used by the accepted 1.1.0 bottle setup. The two registration views use the same checked-registration source; device discovery remains a separate native ARM64 executable. The INF is part of the required resource family.

The whole-application GitHub composer builds all three PEs with the llvm-mingw 20260505 toolchain already verified by the runtime source receiver, checks their ARM64/i386 machine types, and places the four files in the application's SwiftPM module resource bundle. No prebuilt helper executable is an input. The source, INF, toolchain and previous-release reference hashes are pinned in `../bottle-tools.lock.json`.

Build with `python3 -I -B build/repro110app/build_bottle_tools.py --work <fresh-output> --mingw-bin <verified-toolchain>/bin`. This builds files and retains compile logs; it does not run Wine, sign code or install into a user's bottle. The composer supplies the verified toolchain, then invokes resource placement. A missing family member, a wrong PE machine, changed source bytes or conflicting resource fails the package build.

The PE link timestamps match the previous release. Each report records whether the resulting bytes also match that release; functional acceptance still requires the bottle and application runtime gates.
