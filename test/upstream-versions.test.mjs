import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repositoryRoot = fileURLToPath(new URL("..", import.meta.url));
const updater = path.join(
  repositoryRoot,
  "scripts",
  "update_upstream_versions.py",
);

test("updates pinned desktop and CLI versions from verified metadata shapes", async () => {
  const root = await fs.mkdtemp(
    path.join(os.tmpdir(), "codex-web-update-test-"),
  );
  const dockerfile = path.join(root, "Dockerfile");
  const appcast = path.join(root, "appcast.xml");
  const npmMetadata = path.join(root, "npm.json");
  const githubOutput = path.join(root, "github-output");

  try {
    await fs.writeFile(
      dockerfile,
      ["ARG CODEX_APP_VERSION=26.1.100", "ARG CODEX_VERSION=0.1.0", ""].join(
        "\n",
      ),
    );
    await fs.writeFile(
      appcast,
      `<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item>
      <sparkle:version>41</sparkle:version>
      <sparkle:shortVersionString>26.2.200</sparkle:shortVersionString>
    </item>
    <item>
      <sparkle:version>42</sparkle:version>
      <sparkle:shortVersionString>26.2.201</sparkle:shortVersionString>
    </item>
  </channel>
</rss>
`,
    );
    await fs.writeFile(npmMetadata, '{"version":"0.2.0"}\n');

    const result = spawnSync(
      "python3",
      [
        updater,
        "--dockerfile",
        dockerfile,
        "--appcast-file",
        appcast,
        "--npm-metadata-file",
        npmMetadata,
        "--github-output",
        githubOutput,
        "--write",
      ],
      { encoding: "utf8" },
    );
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(JSON.parse(result.stdout), {
      app_changed: true,
      app_version: "26.2.201",
      changed: true,
      cli_changed: true,
      cli_version: "0.2.0",
      current_app_version: "26.1.100",
      current_cli_version: "0.1.0",
    });
    assert.equal(
      await fs.readFile(dockerfile, "utf8"),
      ["ARG CODEX_APP_VERSION=26.2.201", "ARG CODEX_VERSION=0.2.0", ""].join(
        "\n",
      ),
    );
    assert.match(await fs.readFile(githubOutput, "utf8"), /changed=true/);

    const unchanged = spawnSync(
      "python3",
      [
        updater,
        "--dockerfile",
        dockerfile,
        "--appcast-file",
        appcast,
        "--npm-metadata-file",
        npmMetadata,
      ],
      { encoding: "utf8" },
    );
    assert.equal(unchanged.status, 0, unchanged.stderr);
    assert.equal(JSON.parse(unchanged.stdout).changed, false);
  } finally {
    await fs.rm(root, { force: true, recursive: true });
  }
});
