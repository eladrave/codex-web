import fs from "node:fs/promises";
import { createRequire } from "node:module";
import path from "node:path";
import process from "node:process";

const packageRequire = createRequire(path.resolve("package.json"));
const nodePtyRoot = path.dirname(
  packageRequire.resolve("node-pty/package.json"),
);
const helperCandidates = [
  path.join(nodePtyRoot, "build/Release/spawn-helper"),
  path.join(
    nodePtyRoot,
    `prebuilds/${process.platform}-${process.arch}/spawn-helper`,
  ),
];

for (const helperPath of helperCandidates) {
  try {
    await fs.chmod(helperPath, 0o755);
  } catch (error) {
    if (error?.code !== "ENOENT") {
      throw error;
    }
  }
}
