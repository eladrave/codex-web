import { createRequire } from "node:module";
import path from "node:path";
import process from "node:process";

const appBundleRequire = createRequire(
  path.resolve("scratch/asar/.vite/build/main-terminal-smoke.js"),
);
const resolvedModule = appBundleRequire.resolve("node-pty");
const bundledModuleDirectory = path.resolve(
  "scratch/asar/node_modules/node-pty",
);

if (resolvedModule.startsWith(bundledModuleDirectory)) {
  throw new Error(
    `terminal resolved the bundled desktop node-pty module: ${resolvedModule}`,
  );
}

const { spawn } = appBundleRequire("node-pty");
const expectedOutput = "codex-web-terminal-pty-ok";
const terminal = spawn("/bin/sh", ["-lc", `printf ${expectedOutput}`], {
  cols: 80,
  rows: 24,
  cwd: "/tmp",
  env: process.env,
});

let output = "";
const timeout = setTimeout(() => {
  terminal.kill();
  throw new Error("terminal PTY smoke test timed out");
}, 5_000);

terminal.onData((data) => {
  output += data;
});

terminal.onExit(({ exitCode, signal }) => {
  clearTimeout(timeout);
  if (exitCode !== 0 || !output.includes(expectedOutput)) {
    throw new Error(
      `terminal PTY smoke test failed: exit=${exitCode} signal=${signal} output=${JSON.stringify(output)}`,
    );
  }
  console.log(`terminal PTY smoke test passed (${resolvedModule})`);
});
