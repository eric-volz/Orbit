"""MkDocs hook for Orbit's documentation site.

The pages in docs/ link to source files and to files in the repository root with
relative paths (../Orbit/Agent/AgentLoop.swift, ../CONTRIBUTING.md), which work
when you read the Markdown on GitHub. GitHub Pages publishes only the built
docs, so this hook rewrites every relative link or image that leaves docs/ into
a link to the file on GitHub (blob for files, tree for folders), keeping any
#anchor. Links inside fenced code blocks and code spans stay as they are. It also
leaves out the "On this page" list, because the site shows its own table of contents.

The repository comes from repo_url in mkdocs.yml; the branch from the
DOCS_SOURCE_BRANCH environment variable (default: main).
"""

import os
import posixpath
import re

BRANCH = os.environ.get("DOCS_SOURCE_BRANCH") or "main"

MARKDOWN_LINK = re.compile(r"(\]\()([^)\s]+)((?:\s+\"[^\"]*\")?\))")
HTML_LINK = re.compile(r"""(\b(?:href|src)=")([^"]+)(")""")
FENCE = re.compile(r"^\s*(```|~~~)")
CODE_SPAN = re.compile(r"(`+)(.+?)\1")
# The "On this page" list at the top of long pages helps on GitHub; the site has
# its own table of contents, so the hook leaves the list out there.
ON_THIS_PAGE = re.compile(
    r"^\*\*On this page\*\*[ \t]*\n(?:[ \t]*\n)*(?:[ \t]*(?:[-*+]|\d+\.)[ \t]+\[[^\n]*\n?)+",
    re.MULTILINE,
)


def on_page_markdown(markdown, page, config, files):
    markdown = ON_THIS_PAGE.sub("", markdown, count=1)
    repo_url = (config.get("repo_url") or "").rstrip("/")
    if not repo_url:
        return markdown
    docs_dir = os.path.abspath(config["docs_dir"])
    repo_root = os.path.dirname(docs_dir)
    page_dir = posixpath.dirname(page.file.src_uri)

    def rewrite(target):
        if re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", target) or target.startswith(("#", "/")):
            return target
        path, sep, fragment = target.partition("#")
        inside_docs = posixpath.normpath(posixpath.join(page_dir, path))
        if not inside_docs.startswith("../"):
            return target
        in_repo = posixpath.normpath(inside_docs[len("../"):])
        kind = "tree" if os.path.isdir(os.path.join(repo_root, in_repo)) else "blob"
        return f"{repo_url}/{kind}/{BRANCH}/{in_repo}{sep}{fragment}"

    def rewrite_line(line):
        # Protect code spans, rewrite the rest.
        spans = []

        def keep(match):
            spans.append(match.group(0))
            return f"\x00{len(spans) - 1}\x00"

        line = CODE_SPAN.sub(keep, line)
        line = MARKDOWN_LINK.sub(lambda m: m.group(1) + rewrite(m.group(2)) + m.group(3), line)
        line = HTML_LINK.sub(lambda m: m.group(1) + rewrite(m.group(2)) + m.group(3), line)
        return re.sub(r"\x00(\d+)\x00", lambda m: spans[int(m.group(1))], line)

    out, fenced = [], False
    for line in markdown.split("\n"):
        if FENCE.match(line):
            fenced = not fenced
            out.append(line)
            continue
        out.append(line if fenced else rewrite_line(line))
    return "\n".join(out)
