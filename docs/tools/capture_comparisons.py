#!/usr/bin/env python3
"""Capture LSP responses from zig-analyzer and ZLS for the docs comparison page.

Runs both servers over the example fixtures, records hover for every token in
the displayed region, completion at each example's cursor, and published
diagnostics, then writes docs/comparison-data.js. Re-run when either server or
a fixture changes:

    python docs/tools/capture_comparisons.py --repo . --zls /path/to/zls
"""

import argparse
import json
import os
import re
import select
import subprocess
import sys
import time
from pathlib import Path

TOKEN = re.compile(
    r'@\w+|"(?:[^"\\]|\\.)*"|\w+|==|!=|<=|>=|=>|\+=|-=|\*=|\|\||&&|[^\sA-Za-z0-9_"]'
)

EXAMPLES = [
    {
        "id": "pipeline",
        "kind": "Completion",
        "title": "A type assembled by inline for",
        "summary": "The final container is Traced(Buffered(Source)). Completion at the dot asks for members of that resolved type, not the loop's initial type.",
        "fixture": "examples/compiler/comptime_pipeline.zig",
        "displayStart": 30,
        "displayEnd": 46,
        "completion": {"line": 45, "after": "pipeline."},
        "observation": "zig-analyzer asks the compiler for ActivePipeline's final shape. ZLS follows the mutable comptime binding only as far as Source and offers a member that does not exist on the final outer container.",
    },
    {
        "id": "indirect-field",
        "kind": "Completion",
        "title": "A type selected through @field",
        "summary": "The string argument selects Implementations.checked at comptime, so the selected container has one member: verify.",
        "fixture": "examples/compiler/indirect_type_lookup.zig",
        "displayStart": 0,
        "displayEnd": 22,
        "completion": {"line": 21, "after": "ActiveImplementation."},
        "observation": "The source contains no direct syntax edge from ActiveImplementation to the checked declaration. Compiler resolution supplies that edge to zig-analyzer.",
    },
    {
        "id": "active-branch",
        "kind": "Completion",
        "title": "The active comptime branch",
        "summary": "The feature list contains metrics, so only the first anonymous struct is the result of Api for this call.",
        "fixture": "examples/compiler/conditional_api.zig",
        "displayStart": 2,
        "displayEnd": 21,
        "completion": {"line": 20, "after": "ActiveApi."},
        "observation": "ZLS 0.16 improved branching-type analysis and exposes both possibilities. zig-analyzer reports the branch the compiler actually selected for this instantiation.",
    },
    {
        "id": "keyword-hover",
        "kind": "Hover",
        "title": "Reference hover on Zig itself",
        "summary": "Declaration hover is useful after a symbol exists. Language-token hover also explains the syntax used to create that symbol.",
        "fixture": "examples/zls/language_hover.zig",
        "displayStart": 0,
        "displayEnd": 4,
        "observation": "ZLS does provide hover for declarations, @ builtins, enum and field access, and labels. The difference here is explanatory language-reference coverage for Zig syntax itself: keywords, operators, literals, and punctuation.",
    },
    {
        "id": "cleanup-warning",
        "kind": "Diagnostics",
        "title": "Cleanup registered after failure can occur",
        "summary": "Every function here compiles. In the last one, the second allocation can fail before cleanup for the first is registered, so the first allocation can leak.",
        "fixture": "examples/diagnostics/memory_management.zig",
        "displayStart": 0,
        "displayEnd": 24,
        "observation": "zig-analyzer's warning is conservative and local: a resource acquisition, a later fallible operation, and cleanup registered too late. Its quick fix moves the defer directly after the acquisition. The other functions stay clean under this repository's configuration.",
    },
    {
        "id": "compiler-error",
        "kind": "Diagnostics",
        "title": "A semantic compiler error",
        "summary": "The source parses, but a string literal cannot be returned as u32. This separates parser diagnostics from compiler-backed semantic diagnostics.",
        "fixture": "examples/diagnostics/compiler_error.zig",
        "displayStart": 0,
        "displayEnd": 2,
        "observation": "This is an architectural difference, not a claim that ZLS can never show compiler errors. zig-analyzer's compiler session is part of normal analysis; ZLS exposes compiler output through its optional build-on-save workflow.",
    },
]


class LspClient:
    def __init__(self, command, cwd, name):
        self.name = name
        self.next_id = 0
        self.diagnostics = {}
        self.buffer = b""
        self.process = subprocess.Popen(
            command,
            cwd=cwd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )

    def send(self, payload):
        body = json.dumps(payload).encode()
        self.process.stdin.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
        self.process.stdin.flush()

    def fill_buffer(self, deadline):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"{self.name}: no message within the allotted time")
        descriptor = self.process.stdout.fileno()
        readable, _, _ = select.select([descriptor], [], [], remaining)
        if not readable:
            raise TimeoutError(f"{self.name}: no message within the allotted time")
        chunk = os.read(descriptor, 65536)
        if not chunk:
            raise RuntimeError(f"{self.name}: server closed its stdout")
        self.buffer += chunk

    def read_message(self, timeout):
        deadline = time.monotonic() + timeout
        while b"\r\n\r\n" not in self.buffer:
            self.fill_buffer(deadline)
        headers, _, rest = self.buffer.partition(b"\r\n\r\n")
        length = int(re.search(rb"Content-Length: (\d+)", headers).group(1))
        while len(rest) < length:
            self.buffer = rest
            self.fill_buffer(deadline)
            rest = self.buffer
        self.buffer = rest[length:]
        return json.loads(rest[:length])

    def request(self, method, params, timeout=60):
        self.next_id += 1
        request_id = self.next_id
        self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        while True:
            message = self.read_message(timeout)
            if message.get("id") == request_id and "method" not in message:
                if "error" in message:
                    raise RuntimeError(f"{self.name}: {method} failed: {message['error']}")
                return message.get("result")
            self.absorb(message)

    def absorb(self, message):
        if message.get("method") == "textDocument/publishDiagnostics":
            params = message["params"]
            self.diagnostics[params["uri"]] = params["diagnostics"]
        elif "id" in message and "method" in message:
            self.send({"jsonrpc": "2.0", "id": message["id"], "result": None})

    def drain(self, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            remaining = deadline - time.monotonic()
            try:
                self.absorb(self.read_message(max(remaining, 0.1)))
            except TimeoutError:
                return

    def initialize(self, root):
        self.request(
            "initialize",
            {
                "processId": None,
                "rootUri": f"file://{root}",
                "capabilities": {
                    "textDocument": {
                        "hover": {"contentFormat": ["markdown", "plaintext"]},
                        "completion": {},
                        "publishDiagnostics": {},
                    }
                },
            },
            timeout=120,
        )
        self.send({"jsonrpc": "2.0", "method": "initialized", "params": {}})

    def open_file(self, uri, text):
        self.send(
            {
                "jsonrpc": "2.0",
                "method": "textDocument/didOpen",
                "params": {
                    "textDocument": {
                        "uri": uri,
                        "languageId": "zig",
                        "version": 1,
                        "text": text,
                    }
                },
            }
        )

    def close_file(self, uri):
        self.send(
            {
                "jsonrpc": "2.0",
                "method": "textDocument/didClose",
                "params": {"textDocument": {"uri": uri}},
            }
        )

    def shutdown(self):
        try:
            self.request("shutdown", None, timeout=10)
            self.send({"jsonrpc": "2.0", "method": "exit", "params": None})
            self.process.wait(timeout=10)
        except Exception:
            self.process.kill()


REPOSITORY_FILE_URL = "https://github.com/mewhhaha/zig-analyzer/blob/main/"


def sanitize_links(text, repo):
    # Hover markdown may link to local files. Repository files map to GitHub;
    # anything else (e.g. the installed Zig stdlib) keeps only its label so no
    # machine-local path reaches the published page.
    text = text.replace(f"file://{repo}/", REPOSITORY_FILE_URL)
    return re.sub(r"\[([^\]]+)\]\(file://[^)]*\)", r"\1", text)


def hover_text(result, repo):
    if not result:
        return None
    contents = result["contents"]
    if isinstance(contents, dict):
        return sanitize_links(contents["value"].strip(), repo)
    if isinstance(contents, list):
        parts = [entry if isinstance(entry, str) else entry["value"] for entry in contents]
        return sanitize_links("\n\n".join(part.strip() for part in parts), repo)
    return sanitize_links(str(contents).strip(), repo)


def completion_labels(result):
    if not result:
        return []
    items = result["items"] if isinstance(result, dict) else result
    return sorted({item["label"] for item in items})


def capture_example(example, repo, analyzer, zls, strings, string_index):
    def intern(text):
        if text is None:
            return -1
        if text not in string_index:
            string_index[text] = len(strings)
            strings.append(text)
        return string_index[text]

    path = repo / example["fixture"]
    text = path.read_text()
    uri = f"file://{path}"
    lines = text.split("\n")
    display = lines[example["displayStart"] : example["displayEnd"] + 1]

    for client in (analyzer, zls):
        client.open_file(uri, text)
    if example["kind"] == "Diagnostics":
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline and uri not in analyzer.diagnostics:
            analyzer.drain(1)
        analyzer.drain(3)
        zls.drain(3)
    else:
        analyzer.drain(1)
        zls.drain(0.5)

    tokens = []
    for offset, line in enumerate(display):
        file_line = example["displayStart"] + offset
        row = []
        for match in TOKEN.finditer(line):
            position = {"line": file_line, "character": match.start()}
            responses = []
            for client in (analyzer, zls):
                result = client.request(
                    "textDocument/hover",
                    {"textDocument": {"uri": uri}, "position": position},
                )
                responses.append(intern(hover_text(result, repo)))
            row.append([match.start(), len(match.group()), *responses])
        tokens.append(row)

    captured = {
        "id": example["id"],
        "kind": example["kind"],
        "title": example["title"],
        "summary": example["summary"],
        "fixture": example["fixture"],
        "displayStart": example["displayStart"],
        "lines": display,
        "tokens": tokens,
        "observation": example["observation"],
    }

    if "completion" in example:
        line = example["completion"]["line"]
        character = lines[line].index(example["completion"]["after"]) + len(
            example["completion"]["after"]
        )
        labels = {}
        for client, key in ((analyzer, "analyzer"), (zls, "zls")):
            result = client.request(
                "textDocument/completion",
                {"textDocument": {"uri": uri}, "position": {"line": line, "character": character}},
            )
            labels[key] = completion_labels(result)
        captured["completion"] = {"line": line, "character": character, **labels}

    if example["kind"] == "Diagnostics":
        captured["diagnostics"] = {
            key: [
                {
                    "startLine": entry["range"]["start"]["line"],
                    "startChar": entry["range"]["start"]["character"],
                    "endLine": entry["range"]["end"]["line"],
                    "endChar": entry["range"]["end"]["character"],
                    "code": str(entry.get("code", "")),
                    "message": entry["message"],
                }
                for entry in client.diagnostics.get(uri, [])
            ]
            for client, key in ((analyzer, "analyzer"), (zls, "zls"))
        }

    for client in (analyzer, zls):
        client.close_file(uri)
    return captured


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--zls", required=True, type=Path)
    parser.add_argument("--out", type=Path)
    arguments = parser.parse_args()

    repo = arguments.repo.resolve()
    out = arguments.out or repo / "docs" / "comparison-data.js"

    strings = []
    string_index = {}
    captured = []
    # Fresh servers per example: zig-analyzer 0.16 returns empty completions
    # for the second file opened within one LSP session.
    for example in EXAMPLES:
        print(f"capturing {example['id']}", file=sys.stderr)
        analyzer = LspClient([str(repo / "zig-out/bin/zig-analyzer"), "lsp"], repo, "zig-analyzer")
        zls = LspClient([str(arguments.zls.resolve())], repo, "zls")
        for client in (analyzer, zls):
            client.initialize(repo)
        captured.append(capture_example(example, repo, analyzer, zls, strings, string_index))
        for client in (analyzer, zls):
            client.shutdown()

    payload = {"strings": strings, "examples": captured}
    out.write_text("const comparisonData = " + json.dumps(payload) + ";\n")
    print(f"wrote {out}", file=sys.stderr)


if __name__ == "__main__":
    main()
