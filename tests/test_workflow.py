"""Checks for the ARM64 build workflow.

Run with ``python3 -m unittest discover -s tests -v`` (requires Bash and yq v4).
"""

import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest


WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/test-build.yml"
REPO_INPUT = "${{ github.event.inputs.test_repo_url }}"
DEFAULT_REPO = "https://github.com/deepanjanxyz/notepad.git"
CLONE_MOCK = """\
git() {
  printf '%s\\n' "$@" > "$GIT_ARGS_FILE"
  if [[ "${GIT_EXIT_CODE:-0}" != 0 ]]; then return "$GIT_EXIT_CODE"; fi
  mkdir "$3"
  cat > "$3/gradlew" <<'GRADLE'
#!/usr/bin/env bash
printf '%s\\n' "$@" > "$GRADLE_ARGS_FILE"
exit "${GRADLE_EXIT_CODE:-0}"
GRADLE
}
"""


class BuildWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        parsed = subprocess.run(
            ["yq", "-o=json", ".", str(WORKFLOW)],
            check=True,
            capture_output=True,
            text=True,
        )
        cls.workflow = json.loads(parsed.stdout)
        cls.job = cls.workflow["jobs"]["test-setup-and-build"]
        cls.steps = cls.job["steps"]

    def run_shell(self, script, directory, **variables):
        return subprocess.run(
            ["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", script],
            cwd=directory,
            env={**os.environ, **variables},
            capture_output=True,
            text=True,
        )

    def run_build(self, directory, url=DEFAULT_REPO, **variables):
        script = self.steps[3]["run"]
        self.assertIn(REPO_INPUT, script)
        script = script.replace(REPO_INPUT, url)
        git_args = Path(directory) / "git-args"
        gradle_args = Path(directory) / "gradle-args"
        result = self.run_shell(
            CLONE_MOCK + script,
            directory,
            GIT_ARGS_FILE=str(git_args),
            GRADLE_ARGS_FILE=str(gradle_args),
            **variables,
        )
        return result, git_args, gradle_args

    def test_manual_dispatch_has_optional_default_repository(self):
        self.assertEqual(list(self.workflow["on"]), ["workflow_dispatch"])
        repo_input = self.workflow["on"]["workflow_dispatch"]["inputs"]["test_repo_url"]
        self.assertFalse(repo_input["required"])
        self.assertEqual(repo_input["default"], DEFAULT_REPO)

    def test_native_arm_runner_prepares_before_building_and_uploading(self):
        self.assertEqual(self.job["runs-on"], "ubuntu-24.04-arm")
        self.assertEqual(len(self.steps), 5)
        self.assertRegex(self.steps[0]["uses"], r"^actions/checkout@")
        self.assertIn("./Install.sh", self.steps[1]["run"])
        self.assertIn("uname -m", self.steps[2]["run"])
        self.assertIn("java -version", self.steps[2]["run"])
        self.assertIn("./gradlew assembleDebug --stacktrace", self.steps[3]["run"])
        self.assertRegex(self.steps[4]["uses"], r"^actions/upload-artifact@")

    def test_setup_makes_installer_executable_and_runs_it(self):
        with tempfile.TemporaryDirectory() as directory:
            installer = Path(directory) / "Install.sh"
            installer.write_text('#!/usr/bin/env bash\nprintf "ready\\n" > setup-ran\n')
            result = self.run_shell(self.steps[1]["run"], directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(installer.stat().st_mode & stat.S_IXUSR)
            self.assertEqual((Path(directory) / "setup-ran").read_text(), "ready\n")

    def test_build_uses_the_dispatched_repository_and_debug_task(self):
        with tempfile.TemporaryDirectory() as directory:
            url = "https://github.com/example/another-app.git"
            result, git_args, gradle_args = self.run_build(directory, url)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(git_args.read_text().splitlines(), ["clone", url, "test-project"])
            self.assertEqual(gradle_args.read_text().splitlines(), ["assembleDebug", "--stacktrace"])

    def test_clone_failure_does_not_attempt_a_build(self):
        with tempfile.TemporaryDirectory() as directory:
            result, git_args, gradle_args = self.run_build(directory, GIT_EXIT_CODE="23")
            self.assertEqual(result.returncode, 23)
            self.assertEqual(git_args.read_text().splitlines(), ["clone", DEFAULT_REPO, "test-project"])
            self.assertFalse(gradle_args.exists())

    def test_gradle_failure_is_not_hidden(self):
        with tempfile.TemporaryDirectory() as directory:
            result, _, gradle_args = self.run_build(directory, GRADLE_EXIT_CODE="17")
            self.assertEqual(result.returncode, 17)
            self.assertEqual(gradle_args.read_text().splitlines(), ["assembleDebug", "--stacktrace"])

    def test_uploaded_artifact_is_the_debug_apk_from_the_cloned_project(self):
        artifact = self.steps[4]["with"]
        self.assertEqual(artifact["name"], "built-apk")
        self.assertEqual(artifact["path"], "test-project/app/build/outputs/apk/debug/*.apk")


if __name__ == "__main__":
    unittest.main()
