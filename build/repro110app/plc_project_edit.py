#!/usr/bin/env python3
"""Recipe edit of the pinned PLCrashReporter Xcode project (REPRO-110).

Why: on the pinned revision the Xcode build service (SWBBuildService) dies in CreateBuildDescription for the static
library target "CrashReporter macOS" and for the framework that depends on it, on Xcode 26.6 and 27.0, with any
parallelism (diagnosis run 38498482213). A bisect of a COPY of the project (run 38501023892) showed that the crash needs
the combination of the custom build rule and the protobuf source in that target's Sources phase: removing either one
builds (59 compile steps, one libtool step); removing the MIG source breaks the build, other targets are irrelevant.

What: remove the single PBXBuildFile "PLCrashReport.proto in Sources" (its definition and its entry in the Sources phase).
The repository already contains the generated PLCrashReport.pb-c.c/.h that the build compiles, so the .proto file
produced no object either way (it only ever produced the warning "no rule to process file ... PLCrashReport.proto" in the
variant that kept the file without the rule). The pinned source tree is never modified in place by this module: the driver
calls it on the checked-out project file of its own work directory and records the before/after bytes.
"""
import hashlib
import re

PINNED_BYTES = 318366
PINNED_SHA256 = '6168cf17e8abda407455179c59b769c0c1f491e3ffe77cfd312caa34c8b626ad'
PROTO_BUILD_FILE = 'C2B72B2124534E5200D03ABD'
PROTO_FILE_REFERENCE = '059670C70EEFAC3A008A0601'
NAME = 'static-library-without-protobuf-source'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def apply(data, pin=(PINNED_BYTES, PINNED_SHA256)):
    """Return (edited bytes, report) for the exact pinned project file; refuse anything else.

    ``pin`` exists only so the offline tests can use a synthetic project; the driver never passes it.
    """
    if (len(data), sha(data)) != tuple(pin):
        raise ValueError('PLCrashReporter project file differs from the pinned bytes')
    text = data.decode('utf-8')
    # The same selection the bisect used (lines that start with the id and end with , or ;).
    pattern = re.compile(r'^[ \t]*' + PROTO_BUILD_FILE + r'\b[^\n]*[,;][ \t]*\n', re.M)
    rows = pattern.findall(text)
    definitions = [row for row in rows if 'isa = PBXBuildFile' in row]
    entries = [row for row in rows if 'isa = PBXBuildFile' not in row]
    if len(rows) != 2 or len(definitions) != 1 or len(entries) != 1:
        raise ValueError('Protobuf build file must appear once as a definition and once as a phase entry')
    if 'fileRef = ' + PROTO_FILE_REFERENCE not in definitions[0] or not definitions[0].rstrip().endswith(';'):
        raise ValueError('Protobuf build file definition differs')
    if not entries[0].rstrip().endswith(','):
        raise ValueError('Protobuf Sources phase entry differs')
    edited = pattern.sub('', text)
    if text.count('\n') - edited.count('\n') != 2 or PROTO_BUILD_FILE in edited:
        raise ValueError('Protobuf edit changed more than the two expected lines')
    out = edited.encode('utf-8')
    report = dict(name=NAME, build_file=PROTO_BUILD_FILE, file_reference=PROTO_FILE_REFERENCE, removed_lines=2,
                  before=dict(bytes=len(data), sha256=sha(data)), after=dict(bytes=len(out), sha256=sha(out)),
                  removed_row_sha256=[sha(row.encode('utf-8')) for row in rows])
    return out, report
