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
        "label": "inline for",
        "title": "A type assembled by inline for",
        "summary": "The loop wraps Source into Traced(Buffered(Source)); completion answers for the resolved type, not the loop's first binding.",
        "fixture": "examples/compiler/comptime_pipeline.zig",
        "displayStart": 30,
        "displayEnd": 46,
        "completion": {"line": 45, "after": "pipeline."},
    },
    {
        "id": "indirect-field",
        "kind": "Completion",
        "label": "@field",
        "title": "A type selected through @field",
        "summary": "@field selects Implementations.checked at comptime; the chosen container has one member.",
        "fixture": "examples/compiler/indirect_type_lookup.zig",
        "displayStart": 0,
        "displayEnd": 22,
        "completion": {"line": 21, "after": "ActiveImplementation."},
    },
    {
        "id": "active-branch",
        "kind": "Completion",
        "label": "comptime if",
        "title": "The active comptime branch",
        "summary": "The feature list contains metrics, so only the first branch exists for this call. ZLS offers both possibilities.",
        "fixture": "examples/compiler/conditional_api.zig",
        "displayStart": 2,
        "displayEnd": 21,
        "completion": {"line": 20, "after": "ActiveApi."},
    },
    {
        "id": "parsed-configuration",
        "kind": "Completion",
        "label": "parsed spec",
        "title": "A type parsed from a string",
        "summary": "The retry budget is parsed out of \"retries:3\" at comptime and selects the resilient client.",
        "fixture": "examples/compiler/parsed_configuration.zig",
        "displayStart": 2,
        "displayEnd": 23,
        "completion": {"line": 18, "after": "ResilientClient."},
    },
    {
        "id": "recursive-wrapper",
        "kind": "Completion",
        "label": "recursion",
        "title": "A recursively built wrapper",
        "summary": "Wrapped(3, Leaf) builds three nested structs; the outermost one answers at the dot.",
        "fixture": "examples/compiler/recursive_wrapper.zig",
        "displayStart": 0,
        "displayEnd": 23,
        "completion": {"line": 22, "after": "wrapped."},
    },
    {
        "id": "reflected-strategy",
        "kind": "Completion",
        "label": "@typeInfo",
        "title": "A strategy chosen by reflection",
        "summary": "Strategy reads Reading's fields through @typeInfo and returns the matching encoder.",
        "fixture": "examples/compiler/reflected_strategy.zig",
        "displayStart": 2,
        "displayEnd": 27,
        "completion": {"line": 22, "after": "ReadingStrategy."},
    },
    {
        "id": "stdlib-completion",
        "kind": "Completion",
        "label": "std.mem",
        "title": "Completing the standard library",
        "summary": "Everyday standard-library completion, where both servers agree.",
        "fixture": "examples/zls/stdlib_completion.zig",
        "displayStart": 0,
        "displayEnd": 8,
        "completion": {"line": 3, "after": "std.mem."},
    },
    {
        "id": "keyword-hover",
        "kind": "Hover",
        "label": "keywords",
        "title": "Reference hover on Zig itself",
        "summary": "Keywords, operators, and literals answer with the language reference.",
        "fixture": "examples/zls/language_hover.zig",
        "displayStart": 0,
        "displayEnd": 4,
    },
    {
        "id": "doc-hover",
        "kind": "Hover",
        "label": "doc comments",
        "title": "Hover on ordinary declarations",
        "summary": "Doc comments and signatures surface from both servers.",
        "fixture": "examples/zls/hover.zig",
        "displayStart": 0,
        "displayEnd": 17,
    },
    {
        "id": "cleanup-warning",
        "kind": "Diagnostics",
        "label": "late defer",
        "title": "Cleanup registered after failure can occur",
        "summary": "The second allocation can fail before cleanup for the first is registered, so the first can leak.",
        "fixture": "examples/diagnostics/memory_management.zig",
        "displayStart": 0,
        "displayEnd": 24,
    },
    {
        "id": "lifetimes",
        "kind": "Diagnostics",
        "label": "lifetimes",
        "title": "Views that outlive their storage",
        "summary": "Slices returned from deinitialized storage and element pointers held across a resize.",
        "fixture": "examples/diagnostics/lifetime_mistakes.zig",
        "displayStart": 0,
        "displayEnd": 27,
    },
    {
        "id": "compiler-error",
        "kind": "Diagnostics",
        "label": "compile error",
        "title": "A semantic compiler error",
        "summary": "It parses, but a string literal cannot be returned as u32 — a compiler-backed diagnostic.",
        "fixture": "examples/diagnostics/compiler_error.zig",
        "displayStart": 0,
        "displayEnd": 2,
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
        "label": example["label"],
        "title": example["title"],
        "summary": example["summary"],
        "fixture": example["fixture"],
        "displayStart": example["displayStart"],
        "lines": display,
        "tokens": tokens,
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
