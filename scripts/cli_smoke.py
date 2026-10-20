"""End-to-end CLI checks using deterministic, temporary ZIP fixtures."""

from __future__ import annotations

import io
import json
import subprocess
import tempfile
import zipfile
from pathlib import Path


def write_zip(
    path: Path,
    timestamp: tuple[int, int, int, int, int, int],
    compression: int = zipfile.ZIP_STORED,
    name: str = "app/config.json",
) -> None:
    info = zipfile.ZipInfo(name, date_time=timestamp)
    info.compress_type = compression
    info.external_attr = 0o100644 << 16
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr(info, b'{"mode":"demo"}\n')


class NonSeekableBuffer(io.BytesIO):
    def seekable(self) -> bool:
        return False

    def seek(self, offset: int, whence: int = 0) -> int:
        raise io.UnsupportedOperation("stream does not support seeking")


def write_streamed_zip(path: Path) -> None:
    buffer = NonSeekableBuffer()
    info = zipfile.ZipInfo("app/config.json", date_time=(2024, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_DEFLATED
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr(info, b'{"mode":"demo"}\n')
    path.write_bytes(buffer.getvalue())


def run_cli(*arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "moon",
            "run",
            "--target",
            "native",
            "cmd/main",
            "--",
            *arguments,
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
        deflated = root / "deflated.zip"
        streamed = root / "streamed.zip"
        special_first = root / "special-first.zip"
        special_changed = root / "special-changed.zip"
        special_name = 'app/line\n"quoted".json'
        write_zip(first, (2024, 1, 1, 0, 0, 0))
        write_zip(identical, (2024, 1, 1, 0, 0, 0))
        write_zip(changed, (2024, 1, 3, 0, 0, 0))
        write_zip(
            deflated,
            (2024, 1, 1, 0, 0, 0),
            compression=zipfile.ZIP_DEFLATED,
        )
        write_streamed_zip(streamed)
        write_zip(special_first, (2024, 1, 1, 0, 0, 0), name=special_name)
        write_zip(special_changed, (2024, 1, 3, 0, 0, 0), name=special_name)

        with zipfile.ZipFile(deflated) as archive:
            if archive.testzip() is not None:
                raise SystemExit("Python generated an invalid DEFLATE fixture")
        with zipfile.ZipFile(streamed) as archive:
            info = archive.getinfo("app/config.json")
            if archive.testzip() is not None or not info.flag_bits & 0x0008:
                raise SystemExit("streamed fixture must use a valid data descriptor")

        same_result = run_cli(
            "compare", str(first), str(identical), "--format", "json"
        )
        if same_result.returncode != 0:
            raise SystemExit(f"identical archives returned {same_result.returncode}: {same_result.stdout}{same_result.stderr}")
        same_report = json.loads(same_result.stdout)
        if same_report != {"byte_identical": True, "findings": []}:
            raise SystemExit(f"unexpected identical report: {same_report!r}")

        deflated_result = run_cli(
            "compare", str(deflated), str(deflated), "--format", "json"
        )
        if deflated_result.returncode != 0:
            raise SystemExit(
                "Python DEFLATE archive was rejected: "
                f"{deflated_result.returncode}: "
                f"{deflated_result.stdout}{deflated_result.stderr}"
            )
        deflated_report = json.loads(deflated_result.stdout)
        if deflated_report != {"byte_identical": True, "findings": []}:
            raise SystemExit(f"unexpected DEFLATE report: {deflated_report!r}")

        streamed_result = run_cli(
            "compare", str(streamed), str(streamed), "--format", "json"
        )
        if streamed_result.returncode != 0:
            raise SystemExit(
                "streamed ZIP with a data descriptor was rejected: "
                f"{streamed_result.returncode}: "
                f"{streamed_result.stdout}{streamed_result.stderr}"
            )
        streamed_report = json.loads(streamed_result.stdout)
        if streamed_report != {"byte_identical": True, "findings": []}:
            raise SystemExit(f"unexpected streamed ZIP report: {streamed_report!r}")

        descriptor_diff = run_cli(
            "compare", str(deflated), str(streamed), "--format", "json"
        )
        if descriptor_diff.returncode != 1:
            raise SystemExit(
                "normal and streamed DEFLATE archives should differ: "
                f"{descriptor_diff.returncode}: "
                f"{descriptor_diff.stdout}{descriptor_diff.stderr}"
            )
        descriptor_report = json.loads(descriptor_diff.stdout)
        if not any(
            finding["kind"] == "flags_changed"
            for finding in descriptor_report["findings"]
        ):
            raise SystemExit(
                f"data descriptor difference was not classified: {descriptor_report!r}"
            )

        version_result = run_cli("--version")
        if version_result.returncode != 0 or version_result.stdout.strip() != "zipcause 0.1.0":
            raise SystemExit(
                f"unexpected version output: {version_result.returncode}: "
                f"{version_result.stdout}{version_result.stderr}"
            )

        changed_result = run_cli(
            "compare", str(first), str(changed), "--format", "json"
        )
        if changed_result.returncode != 1:
            raise SystemExit(f"different archives returned {changed_result.returncode}: {changed_result.stdout}{changed_result.stderr}")
        changed_report = json.loads(changed_result.stdout)
        if not any(finding["kind"] == "timestamp_changed" for finding in changed_report["findings"]):
            raise SystemExit(f"timestamp difference was not classified: {changed_report!r}")

        text_result = run_cli("compare", str(first), str(changed))
        expected_timestamp = (
            'timestamp_changed: "app/config.json" — DOS timestamp changed from '
            "2024-01-01 00:00:00 to 2024-01-03 00:00:00"
        )
        if text_result.returncode != 1 or expected_timestamp not in text_result.stdout:
            raise SystemExit(
                "text output must explain the observed timestamp values: "
                f"{text_result.returncode}: "
                f"{text_result.stdout}{text_result.stderr}"
            )

        special_json_result = run_cli(
            "compare",
            str(special_first),
            str(special_changed),
            "--format",
            "json",
        )
        if special_json_result.returncode != 1:
            raise SystemExit(
                "special ZIP filename comparison failed: "
                f"{special_json_result.returncode}: "
                f"{special_json_result.stdout}{special_json_result.stderr}"
            )
        special_report = json.loads(special_json_result.stdout)
        if not any(
            finding["kind"] == "timestamp_changed"
            and finding["path"] == special_name
            for finding in special_report["findings"]
        ):
            raise SystemExit(
                f"JSON did not preserve the exact special filename: {special_report!r}"
            )

        special_text_result = run_cli(
            "compare", str(special_first), str(special_changed)
        )
        marker = "timestamp_changed: "
        marker_index = special_text_result.stdout.find(marker)
        decoded_path = None
        if marker_index >= 0:
            path_text = special_text_result.stdout[marker_index + len(marker) :]
            try:
                decoded_path, _ = json.JSONDecoder().raw_decode(path_text)
            except json.JSONDecodeError:
                pass
        if special_text_result.returncode != 1 or decoded_path != special_name:
            raise SystemExit(
                "text output must safely quote newlines and quotes in filenames: "
                f"{special_text_result.returncode}: "
                f"{special_text_result.stdout}{special_text_result.stderr}"
            )

        missing_result = run_cli(
            "compare",
            str(root / "missing.zip"),
            str(identical),
            "--format",
            "json",
        )
        if (
            missing_result.returncode != 2
            or "cannot read" not in missing_result.stderr
            or missing_result.stdout
        ):
            raise SystemExit(
                "missing input must return code 2, keep JSON stdout empty, "
                f"and write diagnostics to stderr: {missing_result.returncode}: "
                f"{missing_result.stdout}{missing_result.stderr}"
            )

        usage_result = run_cli("invalid-command")
        if (
            usage_result.returncode != 2
            or "Usage: zipcause compare" not in usage_result.stderr
            or usage_result.stdout
        ):
            raise SystemExit(
                "invalid command must return code 2 and write usage to stderr: "
                f"{usage_result.returncode}: {usage_result.stdout}{usage_result.stderr}"
            )

    print("CLI smoke checks passed (identical, differing, and invalid ZIP inputs).")


if __name__ == "__main__":
    main()
