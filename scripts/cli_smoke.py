"""End-to-end CLI checks using deterministic, temporary ZIP fixtures."""

from __future__ import annotations

import json
import subprocess
import tempfile
import zipfile
from pathlib import Path


def write_zip(path: Path, timestamp: tuple[int, int, int, int, int, int]) -> None:
    info = zipfile.ZipInfo("app/config.json", date_time=timestamp)
    info.compress_type = zipfile.ZIP_STORED
    info.external_attr = 0o100644 << 16
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr(info, b'{"mode":"demo"}\n')


def run_cli(first: Path, second: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "moon",
            "run",
            "--target",
            "native",
            "cmd/main",
            "--",
            "compare",
            str(first),
            str(second),
            "--format",
            "json",
        ],
        check=False,
        capture_output=True,
        text=True,
    )


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="zipcause-") as directory:
        root = Path(directory)
        first = root / "first.zip"
        identical = root / "identical.zip"
        changed = root / "changed.zip"
        write_zip(first, (2024, 1, 1, 0, 0, 0))
        write_zip(identical, (2024, 1, 1, 0, 0, 0))
        write_zip(changed, (2024, 1, 3, 0, 0, 0))

        same_result = run_cli(first, identical)
        if same_result.returncode != 0:
            raise SystemExit(f"identical archives returned {same_result.returncode}: {same_result.stdout}{same_result.stderr}")
        same_report = json.loads(same_result.stdout)
        if same_report != {"byte_identical": True, "findings": []}:
            raise SystemExit(f"unexpected identical report: {same_report!r}")

        changed_result = run_cli(first, changed)
        if changed_result.returncode != 1:
            raise SystemExit(f"different archives returned {changed_result.returncode}: {changed_result.stdout}{changed_result.stderr}")
        changed_report = json.loads(changed_result.stdout)
        if not any(finding["kind"] == "timestamp_changed" for finding in changed_report["findings"]):
            raise SystemExit(f"timestamp difference was not classified: {changed_report!r}")

        missing_result = run_cli(root / "missing.zip", identical)
        if missing_result.returncode != 2 or "cannot read" not in missing_result.stdout:
            raise SystemExit(f"missing input did not return the documented error code: {missing_result.returncode}: {missing_result.stdout}{missing_result.stderr}")

    print("CLI smoke checks passed (identical, differing, and invalid ZIP inputs).")


if __name__ == "__main__":
    main()
