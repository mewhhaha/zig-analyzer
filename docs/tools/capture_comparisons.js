#!/usr/bin/env node

// Capture LSP responses from zig-analyzer and ZLS for the docs comparison page.
//
// Node:
//   node docs/tools/capture_comparisons.js --repo . --zls /path/to/zls --zig /path/to/zig
//
// Deno:
//   deno run --allow-read --allow-write --allow-run \
//     docs/tools/capture_comparisons.js --repo . --zls /path/to/zls --zig /path/to/zig

const TOKEN =
  /@\w+|"(?:[^"\\]|\\.)*"|\w+|==|!=|<=|>=|=>|\+=|-=|\*=|\|\||&&|[^\sA-Za-z0-9_"]/g;
const REPOSITORY_FILE_URL =
  "https://github.com/mewhhaha/zig-analyzer/blob/main/";

const EXAMPLES = [
  {
    id: "pipeline",
    kind: "Completion",
    label: "inline for",
    title: "A type assembled by inline for",
    summary:
      "The loop wraps Source into Traced(Buffered(Source)); completion answers for the resolved type, not the loop's first binding.",
    fixture: "examples/compiler/comptime_pipeline.zig",
    displayStart: 30,
    displayEnd: 46,
    completion: { line: 45, after: "pipeline." },
    requiredAnalyzerCompletions: ["trace"],
  },
  {
    id: "indirect-field",
    kind: "Completion",
    label: "@field",
    title: "A type selected through @field",
    summary:
      "@field selects Implementations.checked at comptime; the chosen container has one member.",
    fixture: "examples/compiler/indirect_type_lookup.zig",
    displayStart: 0,
    displayEnd: 22,
    completion: { line: 21, after: "ActiveImplementation." },
    requiredAnalyzerCompletions: ["verify"],
  },
  {
    id: "active-branch",
    kind: "Completion",
    label: "comptime if",
    title: "The active comptime branch",
    summary:
      "The feature list contains metrics, so only the first branch exists for this call. ZLS offers both possibilities.",
    fixture: "examples/compiler/conditional_api.zig",
    displayStart: 2,
    displayEnd: 21,
    completion: { line: 20, after: "ActiveApi." },
    requiredAnalyzerCompletions: ["recordMetric"],
  },
  {
    id: "parsed-configuration",
    kind: "Completion",
    label: "parsed spec",
    title: "A type parsed from a string",
    summary:
      'The retry budget is parsed out of "retries:3" at comptime and selects the resilient client.',
    fixture: "examples/compiler/parsed_configuration.zig",
    displayStart: 2,
    displayEnd: 23,
    completion: { line: 18, after: "ResilientClient." },
    requiredAnalyzerCompletions: ["retryBudget"],
  },
  {
    id: "recursive-wrapper",
    kind: "Completion",
    label: "recursion",
    title: "A recursively built wrapper",
    summary:
      "Wrapped(3, Leaf) builds three nested structs; the outermost one answers at the dot.",
    fixture: "examples/compiler/recursive_wrapper.zig",
    displayStart: 0,
    displayEnd: 23,
    completion: { line: 22, after: "wrapped." },
    requiredAnalyzerCompletions: ["unwrap"],
  },
  {
    id: "reflected-strategy",
    kind: "Completion",
    label: "@typeInfo",
    title: "A strategy chosen by reflection",
    summary:
      "Strategy reads Reading's fields through @typeInfo and returns the matching encoder.",
    fixture: "examples/compiler/reflected_strategy.zig",
    displayStart: 2,
    displayEnd: 27,
    completion: { line: 22, after: "ReadingStrategy." },
    requiredAnalyzerCompletions: ["encode"],
  },
  {
    id: "stdlib-completion",
    kind: "Completion",
    label: "std.mem",
    title: "Completing the standard library",
    summary: "Everyday standard-library completion, where both servers agree.",
    fixture: "examples/zls/stdlib_completion.zig",
    displayStart: 0,
    displayEnd: 8,
    completion: { line: 3, after: "std.mem." },
    requiredAnalyzerCompletions: ["eql"],
  },
  {
    id: "keyword-hover",
    kind: "Hover",
    label: "keywords",
    title: "Reference hover on Zig itself",
    summary:
      "Keywords, operators, and literals answer with the language reference.",
    fixture: "examples/zls/language_hover.zig",
    displayStart: 0,
    displayEnd: 4,
  },
  {
    id: "doc-hover",
    kind: "Hover",
    label: "doc comments",
    title: "Hover on ordinary declarations",
    summary: "Doc comments and signatures surface from both servers.",
    fixture: "examples/zls/hover.zig",
    displayStart: 0,
    displayEnd: 17,
  },
  {
    id: "cleanup-warning",
    kind: "Diagnostics",
    label: "late defer",
    title: "Cleanup registered after failure can occur",
    summary:
      "The second allocation can fail before cleanup for the first is registered, so the first can leak.",
    fixture: "examples/diagnostics/memory_management.zig",
    displayStart: 0,
    displayEnd: 24,
    requiredAnalyzerDiagnostics: ["cleanup-after-fallible-operation"],
  },
  {
    id: "lifetimes",
    kind: "Diagnostics",
    label: "lifetimes",
    title: "Views that outlive their storage",
    summary:
      "Slices returned from deinitialized storage and element pointers held across a resize.",
    fixture: "examples/diagnostics/lifetime_mistakes.zig",
    displayStart: 0,
    displayEnd: 27,
    requiredAnalyzerDiagnostics: [
      "returning-deinitialized-view",
      "returning-arena-allocation",
      "invalidated-element-pointer",
    ],
  },
  {
    id: "overlapping-copy",
    kind: "Diagnostics",
    label: "overlap",
    title: "A copy whose slices may overlap",
    summary:
      "Both slices come from the same buffer and are not provably disjoint; @memcpy makes overlap undefined behavior.",
    fixture: "examples/diagnostics/overlapping_copy.zig",
    displayStart: 0,
    displayEnd: 4,
    requiredAnalyzerDiagnostics: ["aliased-memcpy"],
  },
  {
    id: "unsigned-reverse-loop",
    kind: "Diagnostics",
    label: "underflow",
    title: "An unsigned loop that cannot terminate",
    summary:
      "The index is always at least zero, then underflows when the update runs after index zero.",
    fixture: "examples/diagnostics/unsigned_reverse_loop.zig",
    displayStart: 0,
    displayEnd: 6,
    requiredAnalyzerDiagnostics: ["unsigned-reverse-loop"],
  },
  {
    id: "padded-equality",
    kind: "Diagnostics",
    label: "padding",
    title: "Equality that reads undefined padding",
    summary:
      "Byte-wise comparison includes the padding between flag and count, so equal field values can compare unequal.",
    fixture: "examples/diagnostics/padded_equality.zig",
    displayStart: 0,
    displayEnd: 9,
    requiredAnalyzerDiagnostics: ["padded-byte-compare"],
  },
  {
    id: "discarded-error",
    kind: "Diagnostics",
    label: "catch {}",
    title: "An error silently converted to success",
    summary:
      "The empty catch body discards the failure and continues as though the operation succeeded.",
    fixture: "examples/diagnostics/discarded_error.zig",
    displayStart: 0,
    displayEnd: 8,
    requiredAnalyzerDiagnostics: ["discarded-error"],
  },
  {
    id: "compiler-error",
    kind: "Diagnostics",
    label: "compile error",
    title: "A semantic compiler error",
    summary:
      "It parses, but a string literal cannot be returned as u32 — a compiler-backed diagnostic.",
    fixture: "examples/diagnostics/compiler_error.zig",
    displayStart: 0,
    displayEnd: 2,
    requiredAnalyzerDiagnostics: ["compiler-error"],
  },
];

class TimeoutError extends Error {}

class LspClient {
  constructor(process, name, rootFileUri) {
    this.process = process;
    this.name = name;
    this.rootFileUri = rootFileUri;
    this.nextId = 0;
    this.diagnostics = new Map();
    this.diagnosticPublications = new Map();
    this.buffer = new Uint8Array();
    this.messages = [];
    this.waiters = [];
    this.readError = null;
    this.pump = this.readOutput().catch((error) => {
      this.readError = error;
      for (const waiter of this.waiters.splice(0)) {
        clearTimeout(waiter.timer);
        waiter.reject(error);
      }
    });
  }

  async send(payload) {
    const body = new TextEncoder().encode(JSON.stringify(payload));
    const header = new TextEncoder().encode(
      `Content-Length: ${body.byteLength}\r\n\r\n`,
    );
    const frame = new Uint8Array(header.byteLength + body.byteLength);
    frame.set(header);
    frame.set(body, header.byteLength);
    await this.process.write(frame);
  }

  async readOutput() {
    while (true) {
      const chunk = await this.process.read();
      if (chunk === null) {
        throw new Error(`${this.name}: server closed its stdout`);
      }
      this.buffer = appendBytes(this.buffer, chunk);
      this.parseMessages();
    }
  }

  parseMessages() {
    while (true) {
      const headerEnd = findHeaderEnd(this.buffer);
      if (headerEnd === -1) return;
      const header = new TextDecoder().decode(
        this.buffer.subarray(0, headerEnd),
      );
      const lengthMatch = /(?:^|\r\n)Content-Length:\s*(\d+)/i.exec(header);
      if (lengthMatch === null) {
        throw new Error(`${this.name}: LSP frame has no Content-Length header`);
      }
      const bodyStart = headerEnd + 4;
      const bodyLength = Number(lengthMatch[1]);
      if (this.buffer.byteLength < bodyStart + bodyLength) return;
      const body = this.buffer.subarray(bodyStart, bodyStart + bodyLength);
      this.buffer = this.buffer.slice(bodyStart + bodyLength);
      this.deliver(JSON.parse(new TextDecoder().decode(body)));
    }
  }

  deliver(message) {
    const waiter = this.waiters.shift();
    if (waiter !== undefined) {
      clearTimeout(waiter.timer);
      waiter.resolve(message);
      return;
    }
    this.messages.push(message);
  }

  readMessage(timeoutMilliseconds) {
    const queued = this.messages.shift();
    if (queued !== undefined) return Promise.resolve(queued);
    if (this.readError !== null) return Promise.reject(this.readError);
    return new Promise((resolve, reject) => {
      const waiter = { resolve, reject, timer: undefined };
      waiter.timer = setTimeout(() => {
        const index = this.waiters.indexOf(waiter);
        if (index !== -1) this.waiters.splice(index, 1);
        reject(
          new TimeoutError(`${this.name}: no message within the allotted time`),
        );
      }, timeoutMilliseconds);
      this.waiters.push(waiter);
    });
  }

  async request(method, params, timeoutMilliseconds = 60_000) {
    this.nextId += 1;
    const requestId = this.nextId;
    await this.send({ jsonrpc: "2.0", id: requestId, method, params });
    while (true) {
      const message = await this.readMessage(timeoutMilliseconds);
      if (message.id === requestId && !("method" in message)) {
        if ("error" in message) {
          throw new Error(
            `${this.name}: ${method} failed: ${JSON.stringify(message.error)}`,
          );
        }
        return message.result ?? null;
      }
      await this.absorb(message);
    }
  }

  async absorb(message) {
    if (message.method === "textDocument/publishDiagnostics") {
      this.diagnostics.set(message.params.uri, message.params.diagnostics);
      const publications = this.diagnosticPublications.get(message.params.uri) ?? 0;
      this.diagnosticPublications.set(message.params.uri, publications + 1);
      return;
    }
    if ("id" in message && "method" in message) {
      await this.send({ jsonrpc: "2.0", id: message.id, result: null });
    }
  }

  async drain(milliseconds) {
    const deadline = Date.now() + milliseconds;
    while (Date.now() < deadline) {
      try {
        await this.absorb(
          await this.readMessage(Math.max(deadline - Date.now(), 1)),
        );
      } catch (error) {
        if (error instanceof TimeoutError) return;
        throw error;
      }
    }
  }

  async initialize(initializationOptions) {
    await this.request(
      "initialize",
      {
        processId: null,
        rootUri: this.rootFileUri,
        initializationOptions: initializationOptions ?? null,
        capabilities: {
          textDocument: {
            hover: { contentFormat: ["markdown", "plaintext"] },
            completion: {},
            publishDiagnostics: {},
          },
        },
      },
      120_000,
    );
    await this.send({ jsonrpc: "2.0", method: "initialized", params: {} });
  }

  async saveFile(uri) {
    await this.send({
      jsonrpc: "2.0",
      method: "textDocument/didSave",
      params: { textDocument: { uri } },
    });
  }

  async openFile(uri, text) {
    await this.send({
      jsonrpc: "2.0",
      method: "textDocument/didOpen",
      params: {
        textDocument: { uri, languageId: "zig", version: 1, text },
      },
    });
  }

  async changeFile(uri, version, text) {
    await this.send({
      jsonrpc: "2.0",
      method: "textDocument/didChange",
      params: {
        textDocument: { uri, version },
        contentChanges: [{ text }],
      },
    });
  }

  async closeFile(uri) {
    await this.send({
      jsonrpc: "2.0",
      method: "textDocument/didClose",
      params: { textDocument: { uri } },
    });
  }

  async shutdown() {
    try {
      await this.request("shutdown", null, 10_000);
      await this.send({ jsonrpc: "2.0", method: "exit", params: null });
      await withTimeout(
        this.process.wait(),
        10_000,
        `${this.name}: server did not exit`,
      );
    } catch {
      this.process.kill();
      await withTimeout(
        this.process.wait(),
        2_000,
        `${this.name}: killed server did not exit`,
      ).catch(() => {});
    }
  }
}

function appendBytes(left, right) {
  if (left.byteLength === 0) return right.slice();
  const combined = new Uint8Array(left.byteLength + right.byteLength);
  combined.set(left);
  combined.set(right, left.byteLength);
  return combined;
}

function findHeaderEnd(bytes) {
  for (let index = 0; index + 3 < bytes.byteLength; index += 1) {
    if (
      bytes[index] === 13 && bytes[index + 1] === 10 &&
      bytes[index + 2] === 13 && bytes[index + 3] === 10
    ) {
      return index;
    }
  }
  return -1;
}

function withTimeout(promise, milliseconds, message) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new TimeoutError(message)),
      milliseconds,
    );
    promise.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error) => {
        clearTimeout(timer);
        reject(error);
      },
    );
  });
}

function sanitizeLinks(text, repositoryFileUri) {
  return text
    .replaceAll(repositoryFileUri, REPOSITORY_FILE_URL)
    .replace(/\[([^\]]+)\]\(file:\/\/[^)]*\)/g, "$1");
}

function hoverText(result, repositoryFileUri) {
  if (result === null || result === undefined) return null;
  const { contents } = result;
  if (
    contents !== null && typeof contents === "object" &&
    !Array.isArray(contents)
  ) {
    return sanitizeLinks(contents.value.trim(), repositoryFileUri);
  }
  if (Array.isArray(contents)) {
    const parts = contents.map((entry) =>
      typeof entry === "string" ? entry : entry.value
    );
    return sanitizeLinks(
      parts.map((part) => part.trim()).join("\n\n"),
      repositoryFileUri,
    );
  }
  return sanitizeLinks(String(contents).trim(), repositoryFileUri);
}

function completionLabels(result) {
  if (result === null || result === undefined) return [];
  const entries = Array.isArray(result) ? result : result.items;
  return [...new Set(entries.map((entry) => entry.label))].sort();
}

async function captureExample(
  example,
  repository,
  analyzer,
  zls,
  strings,
  stringIndexes,
  runtime,
) {
  function intern(text) {
    if (text === null) return -1;
    const existing = stringIndexes.get(text);
    if (existing !== undefined) return existing;
    const index = strings.length;
    stringIndexes.set(text, index);
    strings.push(text);
    return index;
  }

  const fixturePath = runtime.path.join(repository, example.fixture);
  const text = await runtime.readText(fixturePath);
  const uri = runtime.toFileUrl(fixturePath);
  const lines = text.split("\n");
  const display = lines.slice(example.displayStart, example.displayEnd + 1);

  await Promise.all([analyzer.openFile(uri, text), zls.openFile(uri, text)]);
  if (example.kind === "Diagnostics") {
    // Build-on-save diagnostics only fire on a save event, so report one to
    // both servers and give ZLS's build run time to publish.
    await Promise.all([analyzer.drain(500), zls.drain(500)]);
    const zlsPublicationsBeforeSave = [...zls.diagnosticPublications.values()]
      .reduce((total, publications) => total + publications, 0);
    await Promise.all([analyzer.saveFile(uri), zls.saveFile(uri)]);
    const deadline = Date.now() + 60_000;
    let documentVersion = 2;
    while (
      Date.now() < deadline &&
      (analyzer.diagnostics.get(uri) ?? []).length === 0
    ) {
      await analyzer.drain(2_000);
      if ((analyzer.diagnostics.get(uri) ?? []).length === 0) {
        await analyzer.changeFile(uri, documentVersion, text);
        documentVersion += 1;
      }
    }
    if ((analyzer.diagnostics.get(uri) ?? []).length === 0) {
      throw new Error(
        `${example.fixture}: zig-analyzer published no diagnostics within 60 seconds`,
      );
    }
    await analyzer.drain(3_000);
    const zlsDeadline = Date.now() + 60_000;
    while (
      Date.now() < zlsDeadline &&
      [...zls.diagnosticPublications.values()]
        .reduce((total, publications) => total + publications, 0) ===
        zlsPublicationsBeforeSave
    ) {
      await zls.drain(2_000);
    }
    await zls.drain(3_000);
  } else {
    await analyzer.drain(1_000);
    await zls.drain(500);
  }

  let completion = null;
  if (example.completion !== undefined) {
    const { line, after } = example.completion;
    const afterStart = lines[line].indexOf(after);
    if (afterStart === -1) {
      throw new Error(
        `${example.fixture}:${
          line + 1
        }: completion marker '${after}' was not found`,
      );
    }
    const character = afterStart + after.length;
    const position = { line, character };
    const required = example.requiredAnalyzerCompletions ?? [];
    const deadline = Date.now() + 60_000;
    let analyzerLabels = [];
    while (Date.now() < deadline) {
      const result = await analyzer.request("textDocument/completion", {
        textDocument: { uri },
        position,
      });
      analyzerLabels = completionLabels(result);
      if (required.every((label) => analyzerLabels.includes(label))) break;
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
    for (const label of required) {
      if (!analyzerLabels.includes(label)) {
        throw new Error(
          `${example.fixture}:${line + 1}: zig-analyzer completion omitted '${label}'`,
        );
      }
    }
    const zlsResult = await zls.request("textDocument/completion", {
      textDocument: { uri },
      position,
    });
    completion = {
      line,
      character,
      analyzer: analyzerLabels,
      zls: completionLabels(zlsResult),
    };
  }

  const tokens = [];
  for (const [offset, line] of display.entries()) {
    const fileLine = example.displayStart + offset;
    const row = [];
    for (const match of line.matchAll(TOKEN)) {
      const position = { line: fileLine, character: match.index };
      const responses = [];
      for (const client of [analyzer, zls]) {
        const result = await client.request("textDocument/hover", {
          textDocument: { uri },
          position,
        });
        responses.push(intern(hoverText(result, runtime.repositoryFileUri)));
      }
      row.push([match.index, match[0].length, ...responses]);
    }
    tokens.push(row);
  }

  const captured = {
    id: example.id,
    kind: example.kind,
    label: example.label,
    title: example.title,
    summary: example.summary,
    fixture: example.fixture,
    displayStart: example.displayStart,
    lines: display,
    tokens,
  };

  if (completion !== null) captured.completion = completion;

  if (example.kind === "Diagnostics") {
    captured.diagnostics = {};
    for (const [client, key] of [[analyzer, "analyzer"], [zls, "zls"]]) {
      captured.diagnostics[key] = (client.diagnostics.get(uri) ?? []).map((
        entry,
      ) => ({
        startLine: entry.range.start.line,
        startChar: entry.range.start.character,
        endLine: entry.range.end.line,
        endChar: entry.range.end.character,
        code: String(entry.code ?? ""),
        message: entry.message,
        severity: { 1: "error", 2: "warning", 3: "info", 4: "hint" }[entry.severity] ?? "info",
      }));
    }
    const analyzerCodes = captured.diagnostics.analyzer.map((entry) => entry.code);
    for (const required of example.requiredAnalyzerDiagnostics ?? []) {
      if (!analyzerCodes.includes(required)) {
        throw new Error(
          `${example.fixture}: zig-analyzer diagnostics omitted '${required}'`,
        );
      }
    }
  }

  await Promise.all([analyzer.closeFile(uri), zls.closeFile(uri)]);
  return captured;
}

function parseArguments(args) {
  const parsed = { repository: null, zls: null, zig: null, out: null, help: false };
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    if (argument === "--help" || argument === "-h") {
      parsed.help = true;
      continue;
    }
    if (
      argument !== "--repo" && argument !== "--zls" && argument !== "--zig" &&
      argument !== "--out"
    ) {
      throw new Error(`unknown argument '${argument}'`);
    }
    if (index + 1 === args.length) {
      throw new Error(`${argument} requires a path`);
    }
    const value = args[index + 1];
    index += 1;
    if (argument === "--repo") parsed.repository = value;
    if (argument === "--zls") parsed.zls = value;
    if (argument === "--zig") parsed.zig = value;
    if (argument === "--out") parsed.out = value;
  }
  return parsed;
}

// ZLS reads its configuration from `initializationOptions`. The comparison
// hands it every setting that could strengthen its answers: an explicit zig
// executable (instead of PATH luck), build-on-save diagnostics (they only
// publish when the client reports saves), and its opt-in style warnings.
function zlsInitializationOptions(zigPath) {
  return {
    zig_exe_path: zigPath,
    enable_build_on_save: true,
    warn_style: true,
  };
}

function usage() {
  return [
    "Capture zig-analyzer and ZLS responses for the documentation.",
    "",
    "Usage:",
    "  node docs/tools/capture_comparisons.js --repo . --zls /path/to/zls [--zig /path/to/zig] [--out path]",
    "  deno run --allow-read --allow-write --allow-run docs/tools/capture_comparisons.js --repo . --zls /path/to/zls [--zig /path/to/zig] [--out path]",
  ].join("\n");
}

async function createRuntime(repository) {
  const path = await import("node:path");
  const { pathToFileURL } = await import("node:url");
  const repositoryFileUri = pathToFileURL(`${repository}${path.sep}`).href;
  if (typeof globalThis.Deno !== "undefined") {
    return {
      path,
      repositoryFileUri,
      readText: (filePath) => Deno.readTextFile(filePath),
      writeText: (filePath, text) => Deno.writeTextFile(filePath, text),
      toFileUrl: (filePath) => pathToFileURL(filePath).href,
      spawn: spawnDenoProcess,
    };
  }

  const fileSystem = await import("node:fs/promises");
  return {
    path,
    repositoryFileUri,
    readText: (filePath) => fileSystem.readFile(filePath, "utf8"),
    writeText: (filePath, text) => fileSystem.writeFile(filePath, text, "utf8"),
    toFileUrl: (filePath) => pathToFileURL(filePath).href,
    spawn: spawnNodeProcess,
  };
}

function spawnDenoProcess(command, cwd) {
  const child = new Deno.Command(command[0], {
    args: command.slice(1),
    cwd,
    stdin: "piped",
    stdout: "piped",
    stderr: "null",
  }).spawn();
  const input = child.stdin.getWriter();
  const output = child.stdout.getReader();
  const status = child.status;
  return {
    write: (bytes) => input.write(bytes),
    async read() {
      const result = await output.read();
      return result.done ? null : result.value;
    },
    wait: () => status,
    kill: () => {
      try {
        child.kill("SIGKILL");
      } catch {
        // The process has already exited.
      }
    },
  };
}

async function spawnNodeProcess(command, cwd) {
  const { spawn } = await import("node:child_process");
  const child = spawn(command[0], command.slice(1), {
    cwd,
    stdio: ["pipe", "pipe", "ignore"],
  });
  const output = child.stdout[Symbol.asyncIterator]();
  const status = new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("exit", (code, signal) => resolve({ code, signal }));
  });
  return {
    write: (bytes) =>
      new Promise((resolve, reject) => {
        child.stdin.write(bytes, (error) =>
          error === undefined || error === null ? resolve() : reject(error));
      }),
    async read() {
      const result = await output.next();
      return result.done ? null : new Uint8Array(result.value);
    },
    wait: () => status,
    kill: () => child.kill("SIGKILL"),
  };
}

async function main() {
  const preliminaryArgs = typeof globalThis.Deno !== "undefined"
    ? Deno.args
    : process.argv.slice(2);
  const arguments_ = parseArguments(preliminaryArgs);
  if (arguments_.help) {
    console.log(usage());
    return;
  }
  if (arguments_.repository === null || arguments_.zls === null) {
    throw new Error(`--repo and --zls are required\n\n${usage()}`);
  }

  const path = await import("node:path");
  const repository = path.resolve(arguments_.repository);
  const runtime = await createRuntime(repository);
  const zlsPath = path.resolve(arguments_.zls);
  const outputPath = arguments_.out === null
    ? path.join(repository, "docs", "comparison-data.js")
    : path.resolve(arguments_.out);
  const strings = [];
  const stringIndexes = new Map();
  const captured = [];

  // Fresh servers per example: zig-analyzer 0.16 returns empty completions
  // for the second file opened within one LSP session.
  for (const example of EXAMPLES) {
    console.error(`capturing ${example.id}`);
    const analyzerProcess = await runtime.spawn([
      path.join(repository, "zig-out", "bin", "zig-analyzer"),
      "lsp",
    ], repository);
    const zlsProcess = await runtime.spawn([zlsPath], repository);
    const analyzer = new LspClient(
      analyzerProcess,
      "zig-analyzer",
      runtime.toFileUrl(repository),
    );
    const zls = new LspClient(zlsProcess, "zls", runtime.toFileUrl(repository));
    try {
      await Promise.all([
        analyzer.initialize(),
        zls.initialize(zlsInitializationOptions(arguments_.zig)),
      ]);
      captured.push(
        await captureExample(
          example,
          repository,
          analyzer,
          zls,
          strings,
          stringIndexes,
          runtime,
        ),
      );
    } finally {
      await Promise.allSettled([analyzer.shutdown(), zls.shutdown()]);
    }
  }

  const payload = { strings, examples: captured };
  await runtime.writeText(
    outputPath,
    `const comparisonData = ${JSON.stringify(payload)};\n`,
  );
  console.error(`wrote ${outputPath}`);
}

main().catch((error) => {
  console.error(`capture_comparisons: ${error.message}`);
  if (typeof globalThis.Deno !== "undefined") {
    Deno.exit(1);
  } else {
    process.exitCode = 1;
  }
});
