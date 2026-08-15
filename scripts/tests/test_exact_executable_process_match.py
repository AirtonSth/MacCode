import subprocess
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
PROCESS_FILTER = REPOSITORY_ROOT / "scripts" / "exact-executable-pids.awk"


class ExactExecutableProcessMatchTests(unittest.TestCase):
    def test_remote_code_match_does_not_capture_distill_service_prefix(self):
        executable = "/worktree/dist/RemoteCode.app/Contents/MacOS/RemoteCode"
        processes = "\n".join(
            [
                f"101 {executable}",
                f"102 {executable}DistillService mcp",
                f"103 {executable}RunAsUserHelper",
                f"104 {executable} --scheduled-task-agent-unregister",
                "105 /other/worktree/dist/RemoteCode.app/Contents/MacOS/RemoteCode",
            ]
        )

        result = subprocess.run(
            [
                "/usr/bin/awk",
                "-v",
                f"executable={executable}",
                "-f",
                str(PROCESS_FILTER),
            ],
            input=processes + "\n",
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["101", "104"])

    def test_launch_and_package_scripts_share_the_exact_match_filter(self):
        for relative_path in ("scripts/run-app.sh", "scripts/package-app.sh"):
            source = (REPOSITORY_ROOT / relative_path).read_text()
            self.assertIn("scripts/exact-executable-pids.awk", source, relative_path)


if __name__ == "__main__":
    unittest.main()
