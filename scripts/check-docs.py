"""Offline documentation link and anchor checker. No network, org or credentials needed.

Checks every tracked Markdown file for:
  * relative links and images that point at files or directories that do not exist;
  * `#anchors` (same file or another Markdown file) that match no heading, using
    GitHub's heading-slug rules;
  * absolute links into this repository on GitHub (blob/tree/raw) whose path is missing;
  * repository paths named in code blocks and inline code (scripts/, tools/, examples/, ...)
    that do not exist.

External links are not fetched. Use `--external` for a manual check of http(s) URLs.
"""
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPO_URL = re.compile(
    r"https://github\.com/michalTargiel91/scanforce-open/(?:blob|tree|raw)/main/([^\s)#]*)(?:#(\S*))?"
)
LINK = re.compile(r"(?<!\\)!?\[(?:[^\]\\]|\\.)*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
REF_DEF = re.compile(r"^\s{0,3}\[[^\]]+\]:\s*<?(\S+?)>?(?:\s+.*)?$")
HEADING = re.compile(r"^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$")
FENCE = re.compile(r"^\s{0,3}(```|~~~)")
HTML_ID = re.compile(r"""\s(?:id|name)=["']([^"']+)["']""")
REPO_PATH = re.compile(
    r"(?<![\w./-])((?:scripts|tools|examples|docs|provider-config|force-app|config|\.github)/[A-Za-z0-9_./-]*[A-Za-z0-9_])"
)
# Paths that are created or chosen by the reader, or are placeholders.
PATH_EXEMPT = ("provider-config-install", "deployment-settings-install")
# Hosts that answer 403 to scripted clients but work in a browser; checked by hand.
BOT_BLOCKED_HOSTS = ("developer.salesforce.com",)


def tracked_markdown():
    out = subprocess.run(
        ["git", "ls-files", "*.md"], cwd=ROOT, capture_output=True, text=True, check=True
    ).stdout.split()
    return [ROOT / name for name in out if (ROOT / name).is_file()]


def slug(heading, seen):
    """GitHub's anchor for a heading, including the -1, -2 suffix for duplicates."""
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", heading)  # links keep their text
    text = re.sub(r"<[^>]+>", "", text)
    text = text.replace("`", "").replace("*", "").strip().lower()
    base = re.sub(r"[^\w\- ]", "", text, flags=re.UNICODE).replace(" ", "-")
    count = seen.get(base, 0)
    seen[base] = count + 1
    return base if count == 0 else f"{base}-{count}"


def parse(path):
    """Return (anchors, links, code_paths) for a Markdown file, ignoring fenced code for links."""
    anchors, seen = set(), {}
    links, code_paths = [], []
    in_fence = False
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if FENCE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            for match in REPO_PATH.finditer(line):
                code_paths.append((number, match.group(1)))
            continue
        heading = HEADING.match(line)
        if heading:
            anchors.add(slug(heading.group(2), seen))
        anchors.update(HTML_ID.findall(line))
        for match in LINK.finditer(line):
            links.append((number, match.group(1)))
        reference = REF_DEF.match(line)
        if reference:
            links.append((number, reference.group(1)))
        for span in re.findall(r"`([^`\n]+)`", line):
            for match in REPO_PATH.finditer(span):
                code_paths.append((number, match.group(1)))
    return anchors, links, code_paths


def resolve(source, target):
    """Local file a relative link points to, or None when the link is not local."""
    if re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", target) or target.startswith("//"):
        return None
    base = ROOT if target.startswith("/") else source.parent
    return (base / target.lstrip("/")).resolve()


def check(files):
    problems = []
    parsed = {file: parse(file) for file in files}

    def anchors_of(path):
        if path not in parsed and path.suffix == ".md" and path.is_file():
            parsed[path] = parse(path)
        return parsed[path][0] if path in parsed else None

    for file, (anchors, links, code_paths) in list(parsed.items()):
        rel = file.relative_to(ROOT)
        for number, target in links:
            repo = REPO_URL.match(target)
            if repo:
                path = ROOT / repo.group(1)
                if not path.exists():
                    problems.append(f"{rel}:{number}: GitHub link to missing path {repo.group(1)}")
                elif repo.group(2) and path.suffix == ".md" and repo.group(2) not in (anchors_of(path) or set()):
                    problems.append(f"{rel}:{number}: no heading #{repo.group(2)} in {repo.group(1)}")
                continue
            path_part, _, fragment = target.partition("#")
            if not path_part and not fragment:
                continue
            destination = file if not path_part else resolve(file, path_part.split("?")[0])
            if destination is None:
                continue
            if not destination.exists():
                problems.append(f"{rel}:{number}: broken link {target}")
                continue
            if fragment and destination.suffix == ".md":
                known = anchors_of(destination)
                if known is not None and fragment.lower() not in {a.lower() for a in known}:
                    problems.append(f"{rel}:{number}: no heading #{fragment} in {destination.relative_to(ROOT)}")
        for number, path in code_paths:
            if path.startswith(PATH_EXEMPT) or any(c in path for c in "*<>{}"):
                continue
            if not (ROOT / path).exists():
                problems.append(f"{rel}:{number}: code names missing path {path}")
    return problems


def check_external(files):
    urls = {}
    for file in files:
        for number, target in parse(file)[1]:
            if target.startswith(("http://", "https://")) and not REPO_URL.match(target):
                urls.setdefault(target.split("#")[0], f"{file.relative_to(ROOT)}:{number}")
    problems = []
    for url, where in sorted(urls.items()):
        if "example.com" in url or "YOUR-" in url or url.endswith(".example"):
            continue
        if any(f"//{host}/" in url for host in BOT_BLOCKED_HOSTS):
            continue
        status = None
        for method in ("HEAD", "GET"):
            request = urllib.request.Request(url, method=method, headers={"User-Agent": "scanforce-open-docs-check"})
            try:
                with urllib.request.urlopen(request, timeout=20) as reply:
                    status = reply.status
            except urllib.error.HTTPError as failure:
                status = failure.code
            except (urllib.error.URLError, TimeoutError, OSError) as failure:
                status = str(failure)
            if status == 200 or (isinstance(status, int) and status in (301, 302, 303, 307, 308)):
                break
        if not (status == 200 or (isinstance(status, int) and 300 <= status < 400)):
            problems.append(f"{where}: {url} -> {status}")
    return problems


def main(argv):
    files = tracked_markdown()
    problems = check(files)
    if "--external" in argv:
        problems += check_external(files)
    for problem in problems:
        print(problem)
    scope = "including external links" if "--external" in argv else "offline"
    print(f"{len(files)} Markdown files checked ({scope}): {len(problems)} problem(s).")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
