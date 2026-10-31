import copy
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
VALIDATOR = ROOT / "script/validate_legacy_manifest.py"
WORKFLOW = ROOT / ".github/workflows/release.yml"
ASSET_URL = "https://github.com/robinebers/openusage/releases/download/v0.6.28/OpenUsage.app.tar.gz"


class LegacyManifestTests(unittest.TestCase):
    def manifest(self):
        return {
            "version": "0.6.28",
            "platforms": {
                "darwin-aarch64": {"url": ASSET_URL, "signature": "synthetic-signature"}
            },
        }

    def run_validator(self, data):
        self.assertTrue(VALIDATOR.is_file(), "Legacy manifest validator is missing")
        with tempfile.TemporaryDirectory(prefix="openusage-manifest-test-") as directory:
            path = Path(directory) / "latest.json"
            path.write_bytes(data)
            result = subprocess.run(
                [sys.executable, "-B", str(VALIDATOR), str(path)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(path.read_bytes(), data)
            return result

    def test_accepts_minimal_legacy_manifest_without_optional_metadata(self):
        result = self.run_validator(json.dumps(self.manifest()).encode())
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_accepts_four_platforms_and_preserves_original_bytes(self):
        manifest = self.manifest()
        manifest.update(notes="Synthetic release notes", pub_date="2026-01-02T03:04:05Z")
        manifest["platforms"] = {
            platform: {"url": ASSET_URL, "signature": f"synthetic-{platform}"}
            for platform in (
                "darwin-x86_64", "darwin-x86_64-app", "darwin-aarch64", "darwin-aarch64-app"
            )
        }
        data = (" \n" + json.dumps(manifest, indent=3) + "\n\n").encode()
        result = self.run_validator(data)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_malformed_json_and_invalid_root_shapes(self):
        for data in (b"{", b"null", b"[]", b'"manifest"', b"false"):
            with self.subTest(data=data):
                result = self.run_validator(data)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(result.stderr.strip())

    def test_rejects_wrong_or_missing_version(self):
        for version in (None, "0.6.27", "0.8.0", 0.628, "v0.6.28"):
            with self.subTest(version=version):
                manifest = self.manifest()
                if version is None:
                    del manifest["version"]
                else:
                    manifest["version"] = version
                self.assertNotEqual(self.run_validator(json.dumps(manifest).encode()).returncode, 0)

    def test_rejects_missing_empty_or_invalid_platforms(self):
        for platforms in (None, {}, [], "darwin-aarch64", False):
            with self.subTest(platforms=platforms):
                manifest = self.manifest()
                if platforms is None:
                    del manifest["platforms"]
                else:
                    manifest["platforms"] = platforms
                self.assertNotEqual(self.run_validator(json.dumps(manifest).encode()).returncode, 0)

    def test_rejects_any_unusable_platform_entry(self):
        entries = [None, [], "entry", {}, {"signature": "synthetic"}, {"url": ASSET_URL}]
        for field in ("url", "signature"):
            for value in (None, "", "  ", 42, []):
                entry = copy.deepcopy(self.manifest()["platforms"]["darwin-aarch64"])
                entry[field] = value
                entries.append(entry)
        for entry in entries:
            with self.subTest(entry=entry):
                manifest = self.manifest()
                manifest["platforms"]["darwin-x86_64"] = entry
                self.assertNotEqual(self.run_validator(json.dumps(manifest).encode()).returncode, 0)

    def test_rejects_blank_platform_names(self):
        for name in ("", "  "):
            with self.subTest(name=name):
                manifest = self.manifest()
                manifest["platforms"] = {name: manifest["platforms"]["darwin-aarch64"]}
                self.assertNotEqual(self.run_validator(json.dumps(manifest).encode()).returncode, 0)

    def test_rejects_non_https_or_unusable_urls(self):
        for url in (
            ASSET_URL.replace("https:", "http:"), "file:///archive.app.tar.gz",
            "archive.app.tar.gz", "https://", "https://[invalid",
        ):
            with self.subTest(url=url):
                manifest = self.manifest()
                manifest["platforms"]["darwin-aarch64"]["url"] = url
                self.assertNotEqual(self.run_validator(json.dumps(manifest).encode()).returncode, 0)


class ReleaseWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.workflow = WORKFLOW.read_text()
        self.steps = re.split(r"(?=^      - )", self.workflow, flags=re.MULTILINE)[1:]

    def step_containing(self, text):
        matches = [step for step in self.steps if text in step]
        self.assertEqual(len(matches), 1, text)
        return matches[0]

    def test_all_preflight_checks_precede_first_release_write(self):
        publications = list(re.finditer(
            r"uses:\s*softprops/action-gh-release@|^\s+gh release (?:create|upload|edit)\b",
            self.workflow,
            flags=re.MULTILINE,
        ))
        self.assertTrue(publications)
        first_publication = publications[0].start()
        for check in (
            "gh release download", "python3 -B script/validate_legacy_manifest.py",
            'cat "$SPARKLE_PRIVATE_KEY_FILE" | "$GA"', 'grep -Eq "$DMG',
            '[ "$after" -ge "$before" ]',
        ):
            with self.subTest(check=check):
                self.assertIn(check, self.workflow)
                self.assertLess(self.workflow.index(check), first_publication)

    def test_stable_manifest_uses_canonical_source_and_stays_outside_feed(self):
        preparation = self.step_containing("gh release download")
        self.assertIn("if: steps.meta.outputs.channel == 'stable'", preparation)
        self.assertIn("id: legacy", preparation)
        self.assertRegex(preparation, r"gh release download v0\.6\.28\s+--repo robinebers/openusage")
        self.assertIn("--pattern latest.json", preparation)
        self.assertIn('$RUNNER_TEMP/legacy-updater', preparation)
        self.assertIn('python3 -B script/validate_legacy_manifest.py "$legacy_dir/latest.json"', preparation)
        self.assertIn('echo "path=$legacy_dir/latest.json" >> "$GITHUB_OUTPUT"', preparation)
        self.assertNotIn("feed/", preparation)
        self.assertLess(preparation.index("validate_legacy_manifest.py"), preparation.index('echo "path='))

    def test_publication_reuses_prepared_optional_manifest_without_later_upload(self):
        publication = self.step_containing("uses: softprops/action-gh-release@")
        self.assertIn("dist/OpenUsage-${{ steps.meta.outputs.version }}.dmg", publication)
        self.assertIn("${{ steps.legacy.outputs.path }}", publication)
        self.assertIn("fail_on_unmatched_files: true", publication)
        self.assertNotIn("if:", publication)
        self.assertNotRegex(self.workflow, r"gh release (?:upload|create|edit)\b")
        self.assertNotIn("--clobber", self.workflow)

    def test_existing_appcast_security_and_channel_guards_remain(self):
        generation = self.step_containing('cat "$SPARKLE_PRIVATE_KEY_FILE" | "$GA"')
        for guard in (
            "https://github.com/${{ github.repository }}/releases/download/${{ steps.meta.outputs.tag }}/",
            "--ed-key-file -", "--maximum-versions 0", "channel_arg=(--channel beta)",
            "sparkle:edSignature", '[ "$after" -ge "$before" ]',
        ):
            with self.subTest(guard=guard):
                self.assertIn(guard, generation)
        self.assertIn("keep_files: true", self.workflow)
        self.assertIn("group: release-appcast", self.workflow)
        self.assertIn("cancel-in-progress: false", self.workflow)


if __name__ == "__main__":
    unittest.main()
