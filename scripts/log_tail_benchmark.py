#!/usr/bin/env python3
"""Compare a committed LogTail with the working copy on identical idle fixtures."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
reference = sys.argv[1] if len(sys.argv) > 1 else subprocess.check_output(
    ['git', 'rev-list', '--max-parents=0', 'HEAD'], cwd=root, text=True).strip()
before = subprocess.check_output(['git', 'show', f'{reference}:Sources/CaptionCore/LogTail.swift'],
                                 cwd=root, text=True)
after = (root / 'Sources/CaptionCore/LogTail.swift').read_text()

def implementation(text, name):
    return text.split('public struct SessionSnapshot:')[0].replace(
        'public final class LogTail', f'public final class {name}').replace('import Foundation', '')

harness = r'''
let root = FileManager.default.temporaryDirectory.appendingPathComponent("vibecute-bench-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
var before = [BaselineTail](), after = [CurrentTail]()
for i in 0..<80 {
    let url = root.appendingPathComponent("\(i).jsonl")
    try Data("fixture\n".utf8).write(to: url)
    let a = BaselineTail(url: url), b = CurrentTail(url: url)
    precondition(try a.read() == b.read())
    before.append(a); after.append(b)
}
for round in 0..<7 {
    var baselineMS = 0.0, currentMS = 0.0
    for phase in (round % 2 == 0 ? [0, 1] : [1, 0]) {
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100 {
            if phase == 0 { for t in before { precondition(try t.read().isEmpty) } }
            else { for t in after { precondition(try t.read().isEmpty); precondition(!t.lastOpenedFile) } }
        }
        let ms = (ProcessInfo.processInfo.systemUptime-start)*1000
        if phase == 0 { baselineMS = ms } else { currentMS = ms }
    }
    print("round=\(round+1) polls=8000 baseline_ms=\(baselineMS) optimized_ms=\(currentMS) optimized_opens=0")
}
'''
# Swift's precondition autoclosure cannot throw.
harness = harness.replace('precondition(try a.read() == b.read())',
                          'let first = try a.read(), second = try b.read(); precondition(first == second)')
harness = harness.replace('precondition(try t.read().isEmpty)',
                          'let lines = try t.read(); precondition(lines.isEmpty)')
cache = root / '.build/clang-cache'
cache.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='vibecute-benchmark-') as folder:
    source = Path(folder) / 'benchmark.swift'
    binary = Path(folder) / 'benchmark'
    source.write_text('import Foundation\n' + implementation(before, 'BaselineTail')
                      + implementation(after, 'CurrentTail') + harness)
    subprocess.run(['swiftc', '-O', '-module-cache-path', str(cache), str(source), '-o', str(binary)], check=True)
    print(f'baseline_ref={reference} fixtures=80 polls_per_round=8000 swift=-O order=alternating', flush=True)
    subprocess.run([str(binary)], check=True)
