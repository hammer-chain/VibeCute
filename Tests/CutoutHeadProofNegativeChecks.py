#!/usr/bin/env python3
"""A wrong ownership mask must fail even if neutral reconstruction is exact."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="cutout-head-negative-") as temp:
    work = Path(temp)
    source = ROOT / "animation/DeepSeek_Cutout/head-proof"
    target = work / source.relative_to(ROOT)
    target.mkdir(parents=True)
    for name in ("ownership.json", "infill-registration.json", "bald-infill-candidate.png",
                 "bald-infill-no-brows.png", "chin-infill-candidate.png", "rear-hair-infill-candidate.png", "tail-infill-candidate.png", "claude-workwear-source.png", "workwear-infill-candidate.png", "bob-back-candidate.png", "maid-torso-infill-candidate.png"):
        shutil.copy2(source / name, target / name)
    reference = Path("docs/animation-reference/deepseek-seated.png")
    (work / reference.parent).mkdir(parents=True)
    shutil.copy2(ROOT / reference, work / reference)
    original_spec = json.loads((target / "ownership.json").read_text())
    spec = json.loads((target / "ownership.json").read_text())
    for layer in spec["layers"]:
        if layer["id"] == "face-visible":
            layer["polygon"] = []
    (target / "ownership.json").write_text(json.dumps(spec))
    binary = work / "head-proof"
    subprocess.run(["swiftc", "-O", str(ROOT / "scripts/prepare_cutout_head_proof.swift"),
                    "-o", str(binary)], check=True, capture_output=True, text=True)
    result = subprocess.run([str(binary)], cwd=work, capture_output=True, text=True)
    checks = json.loads((work / "output/cutout/head-proof/checks.json").read_text())
    assert checks["differentPixels"] == 0, "negative fixture must still reconstruct exactly"
    assert checks["originalFaceChangedPixels"] == 0, "empty face mask must expose the vacuous-check trap"
    assert checks["fixedFeatureProbeChanges"] > 0, "fixed feature probes must catch regenerated identity"
    assert result.returncode != 0, "invalid identity ownership was accepted"
    report = {"passed": True, "case": "empty face ownership still reconstructs but loses identity",
              "reconstructionDifferentPixels": checks["differentPixels"],
              "fixedFeatureProbeChanges": checks["fixedFeatureProbeChanges"],
              "exitCode": result.returncode}
    spec = original_spec
    for layer in spec["layers"]:
        if layer["id"] == "tail":
            layer["polygon"] = []
    (target / "ownership.json").write_text(json.dumps(spec))
    tail_result = subprocess.run([str(binary)], cwd=work, capture_output=True, text=True)
    tail_checks = json.loads((work / "output/cutout/head-proof/checks.json").read_text())
    assert tail_checks["differentPixels"] == 0
    assert tail_checks["tailOwnershipFailures"] == 108
    assert tail_result.returncode != 0, "tail pixels reassigned to hair/body were accepted"
    report["tailOwnershipNegative"] = {"passed": True, "failedProbes": tail_checks["tailOwnershipFailures"],
                                       "neutralDifferentPixels": tail_checks["differentPixels"]}
    (ROOT / "output/cutout/head-proof/negative-checks.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))
