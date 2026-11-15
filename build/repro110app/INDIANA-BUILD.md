# Indiana MoltenVK source build for c33r

`build_indiana.py` selects the source snapshot from the already published
1.0.6-indiana archive. That archive also contains generated `Package` outputs:
they are excluded, as are its bundled external trees except the explicitly
selected patched SPIRV-Cross source. The four other dependencies come from the
separately hash-pinned archives in `moltenvk-indiana.lock.json`.

The archive audit verified SHA256, 271 MoltenVK core files and 4,797 SPIRV-Cross
files. The latter match the retained rebuild source byte-for-byte. Three core
files differ from that source; the precise postimages now accompany this recipe
with both archive preimage and retained rebuild postimage hashes. They also
match the saved `ind1` producer tree. All other selected core source is equal.
The postimage inventory is checked before the producer's explicit revision
assignment is applied to `Scripts/gen_moltenvk_rev_hdr.sh`. Publication-only
`macrunner` notes are not compiler inputs. No runtime library has been changed.

Prepare archives as `indiana.tar.gz`, `Vulkan-Headers.tar.gz`,
`SPIRV-Headers.tar.gz`, `SPIRV-Tools.tar.gz`, and `cereal.tar.gz` in one directory.
The cloud orchestrator fetches their lock URLs and retains download receipts;
this driver performs no downloads. `--stage plan` lists the required pins.
`--stage source --archives DIR --work NEW_DIR` verifies all archives, selects
only source files, applies the sealed postimages, and constructs the build tree.
No unverified source is substituted when an archive is missing.

`--stage compile` additionally requires an ARM64 macOS cloud job, Xcode27.0
27A266a/SDK27.0 and explicit `--cmake`/`--ninja` paths restored from the existing
source-built Wine dependency producer. Tool hashes are recorded. The driver
uses the existing native producer's two Xcode schemes, target macOS12.0, two
workers, no release signing, and a source-built SPIRV-Tools header preparation.
It accepts only ARM64 output with the pinned minimum OS and system dynamic
dependencies. It records raw equality with the c33r library without altering
outputs to force a match. Logs and the result receipt remain in the new work
directory; there is no install or game launch.

The source archive audit and offline driver tests are complete. Full preparation
from the materialized archives on a clean cloud worker, compilation, binary
comparison, final assembly and runtime acceptance remain required. Historical
p17 binaries are not claimed to be byte-reproducible from the unmodified source
archive. The unchanged c33r reference is
`5590d653e7b9d849ed762501aae5bcf849d96f3e772ad0ce5b4d9a623aceb3eb`.
