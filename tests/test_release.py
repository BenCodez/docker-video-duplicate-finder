"""Exercise the exact workflow preparation script, including untrusted inputs."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class ReleaseTests(unittest.TestCase):
    def prepare(self, event="pull_request", ref="refs/pull/17/merge", **inputs):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "output"
            env = dict(os.environ,
                       GITHUB_EVENT_NAME=event, GITHUB_REF=ref,
                       GITHUB_SHA="b" * 40, GITHUB_OUTPUT=str(output),
                       GITHUB_REPOSITORY="BenCodez/docker-video-duplicate-finder",
                       REQUESTED_COMMIT="", REQUESTED_TAG="", REQUESTED_PUBLISH="", REQUESTED_LATEST="")
            env.update(inputs)
            result = subprocess.run(["bash", str(REPO / ".github/scripts/prepare-release.sh")], cwd=REPO, env=env, text=True, capture_output=True)
            values = dict(line.split("=", 1) for line in output.read_text().splitlines()) if output.exists() else {}
            return result, values

    def test_prs_branches_and_default_manual_runs_do_not_publish(self):
        for event, ref in (("pull_request", "refs/pull/17/merge"), ("push", "refs/heads/main"), ("workflow_dispatch", "refs/heads/main")):
            result, values = self.prepare(event, ref)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(values["publish"], "false")
            self.assertEqual(values["promote_latest"], "false")

    def test_version_tags_publish_without_touching_latest(self):
        for tag in ("v26.10.1", "v26.10.1-pre.1"):
            result, values = self.prepare("push", f"refs/tags/{tag}")
            self.assertEqual(result.returncode, 0)
            self.assertEqual(values["image_tag"], tag)
            self.assertEqual(values["publish"], "true")
            self.assertEqual(values["promote_latest"], "false")

    def test_latest_requires_explicit_stable_manual_release(self):
        result, values = self.prepare("workflow_dispatch", "refs/heads/main", REQUESTED_TAG="v26.10.1", REQUESTED_PUBLISH="true", REQUESTED_LATEST="true")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(values["publish"], "true")
        self.assertEqual(values["promote_latest"], "true")
        for tag, publish in (("test", "true"), ("v26.10.1-pre.1", "true"), ("v26.10.1", "false"), ("latest", "true")):
            result, _ = self.prepare("workflow_dispatch", "refs/heads/main", REQUESTED_TAG=tag, REQUESTED_PUBLISH=publish, REQUESTED_LATEST="true")
            self.assertNotEqual(result.returncode, 0)

    def test_invalid_refs_and_unsafe_source_pins_fail_before_publication(self):
        for tag in ("vgarbage", "v26.10", "v26.10.1/unsafe"):
            result, _ = self.prepare("push", "refs/tags/" + tag)
            self.assertNotEqual(result.returncode, 0)
        for commit in ("main", "v4.1.1", "a" * 39, "a" * 40 + "\npublish=true"):
            result, _ = self.prepare(REQUESTED_COMMIT=commit)
            self.assertNotEqual(result.returncode, 0)
        for tag in ("$(touch /tmp/vdf-unsafe)", "test\npublish=true", "latest", "../test"):
            result, _ = self.prepare("workflow_dispatch", "refs/heads/main", REQUESTED_TAG=tag, REQUESTED_PUBLISH="true")
            self.assertNotEqual(result.returncode, 0)

    def test_other_repositories_cannot_publish_to_the_bencodez_package(self):
        result, values = self.prepare("push", "refs/tags/v26.10.1", GITHUB_REPOSITORY="example/docker-video-duplicate-finder")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(values["publish"], "false")

    def test_explicit_source_revision_is_in_the_commit_tag(self):
        result, values = self.prepare("workflow_dispatch", "refs/heads/main", REQUESTED_COMMIT="c" * 40, REQUESTED_TAG="candidate", REQUESTED_PUBLISH="true")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(values["application_commit"], "c" * 40)
        self.assertEqual(values["commit_tag"], "sha-" + "b" * 12 + "-" + "c" * 12)


if __name__ == "__main__":
    unittest.main()
