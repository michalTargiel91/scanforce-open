"""The reference provider image runs as a non-root user whatever the host file modes are."""

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class MockProviderDockerfileTest(unittest.TestCase):
    def test_server_is_made_readable_before_dropping_privileges(self):
        # COPY keeps the host mode: a checkout under umask 077 gave "Permission denied" at start-up.
        text = (ROOT / "examples/mock-provider/Dockerfile").read_text()
        self.assertIn("COPY server.py", text)
        self.assertLess(text.index("chmod 0644 server.py"), text.index("USER app"))

    def test_runs_as_non_root_and_binds_the_platform_port(self):
        text = (ROOT / "examples/mock-provider/Dockerfile").read_text()
        self.assertIn("USER app", text)
        self.assertIn("HOST=0.0.0.0", text)


if __name__ == "__main__":
    unittest.main()
