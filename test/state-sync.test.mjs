import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import Database from "better-sqlite3";

import {
  createStateSnapshot,
  restoreStateSnapshot,
} from "../docker/state-sync.mjs";

test("snapshots and restores Electron and Codex settings safely", async () => {
  const root = await fs.mkdtemp(
    path.join(os.tmpdir(), "codex-web-state-test-"),
  );
  const electronDataDir = path.join(root, "electron");
  const codexHome = path.join(root, "codex");
  const backupFile = path.join(root, "persistent", "state.tar");

  try {
    await fs.mkdir(electronDataDir, { recursive: true });
    await fs.mkdir(codexHome, { recursive: true });
    await fs.writeFile(
      path.join(electronDataDir, "preferences.json"),
      '{"memoryEnabled":true}\n',
    );
    await fs.writeFile(
      path.join(codexHome, "config.toml"),
      'model = "gpt-5.6"\n',
    );
    await fs.mkdir(path.join(codexHome, "cli", "gh"), { recursive: true });
    await fs.mkdir(path.join(codexHome, "cli", "gcloud"), {
      recursive: true,
    });
    await fs.writeFile(
      path.join(codexHome, "cli", "gh", "hosts.yml"),
      "github.com:\n  user: eladrave\n",
    );
    await fs.writeFile(
      path.join(codexHome, "cli", "gitconfig"),
      "[credential]\n\thelper = gh auth git-credential\n",
    );
    await fs.writeFile(path.join(codexHome, "auth.json"), '{"secret":true}\n');

    const databasePath = path.join(electronDataDir, "app-state.sqlite");
    const database = new Database(databasePath);
    database.exec(
      "CREATE TABLE settings (name TEXT PRIMARY KEY, value TEXT NOT NULL)",
    );
    database
      .prepare("INSERT INTO settings (name, value) VALUES (?, ?)")
      .run("customInstructions", "Use concise answers");
    const gcloudCredentialsPath = path.join(
      codexHome,
      "cli",
      "gcloud",
      "credentials.db",
    );
    const gcloudCredentials = new Database(gcloudCredentialsPath);
    gcloudCredentials.exec(
      "CREATE TABLE credentials (account TEXT PRIMARY KEY, token TEXT NOT NULL)",
    );
    gcloudCredentials
      .prepare("INSERT INTO credentials (account, token) VALUES (?, ?)")
      .run("eladrave@gmail.com", "refresh-token-placeholder");
    await createStateSnapshot({ backupFile, codexHome, electronDataDir });
    database.close();
    gcloudCredentials.close();

    await fs.rm(electronDataDir, { force: true, recursive: true });
    await fs.rm(codexHome, { force: true, recursive: true });
    assert.equal(
      await restoreStateSnapshot({ backupFile, codexHome, electronDataDir }),
      true,
    );

    assert.equal(
      await fs.readFile(path.join(electronDataDir, "preferences.json"), "utf8"),
      '{"memoryEnabled":true}\n',
    );
    assert.equal(
      await fs.readFile(path.join(codexHome, "config.toml"), "utf8"),
      'model = "gpt-5.6"\n',
    );
    assert.equal(
      await fs.readFile(path.join(codexHome, "cli", "gh", "hosts.yml"), "utf8"),
      "github.com:\n  user: eladrave\n",
    );
    assert.equal(
      await fs.readFile(path.join(codexHome, "cli", "gitconfig"), "utf8"),
      "[credential]\n\thelper = gh auth git-credential\n",
    );
    await assert.rejects(
      fs.access(path.join(codexHome, "auth.json")),
      /ENOENT/,
    );

    const restoredDatabase = new Database(databasePath, {
      fileMustExist: true,
      readonly: true,
    });
    assert.equal(
      restoredDatabase
        .prepare("SELECT value FROM settings WHERE name = ?")
        .pluck()
        .get("customInstructions"),
      "Use concise answers",
    );
    restoredDatabase.close();

    const restoredGcloudCredentials = new Database(gcloudCredentialsPath, {
      fileMustExist: true,
      readonly: true,
    });
    assert.equal(
      restoredGcloudCredentials
        .prepare("SELECT token FROM credentials WHERE account = ?")
        .pluck()
        .get("eladrave@gmail.com"),
      "refresh-token-placeholder",
    );
    restoredGcloudCredentials.close();
  } finally {
    await fs.rm(root, { force: true, recursive: true });
  }
});

test("restore is a no-op before the first state snapshot", async () => {
  const root = await fs.mkdtemp(
    path.join(os.tmpdir(), "codex-web-state-test-"),
  );
  try {
    assert.equal(
      await restoreStateSnapshot({
        backupFile: path.join(root, "missing.tar"),
        codexHome: path.join(root, "codex"),
        electronDataDir: path.join(root, "electron"),
      }),
      false,
    );
  } finally {
    await fs.rm(root, { force: true, recursive: true });
  }
});

test("keeps immutable snapshots and falls back from a corrupt newest snapshot", async () => {
  const root = await fs.mkdtemp(
    path.join(os.tmpdir(), "codex-web-state-test-"),
  );
  const electronDataDir = path.join(root, "electron");
  const codexHome = path.join(root, "codex");
  const backupFile = path.join(root, "persistent", "state.tar");
  const snapshotDirectory = `${backupFile}.snapshots`;

  try {
    await fs.mkdir(electronDataDir, { recursive: true });
    await fs.mkdir(codexHome, { recursive: true });
    for (let index = 0; index < 6; index += 1) {
      await fs.writeFile(
        path.join(electronDataDir, "preferences.json"),
        `${index}\n`,
      );
      await createStateSnapshot({ backupFile, codexHome, electronDataDir });
      await new Promise((resolve) => setTimeout(resolve, 2));
    }

    const snapshots = await Promise.all(
      (await fs.readdir(snapshotDirectory)).map(async (name) => ({
        name,
        stats: await fs.stat(path.join(snapshotDirectory, name)),
      })),
    );
    snapshots.sort((left, right) => right.stats.mtimeMs - left.stats.mtimeMs);
    assert.equal(snapshots.length, 4);
    await fs.writeFile(
      path.join(snapshotDirectory, snapshots[0].name),
      "not a tar archive\n",
    );

    await fs.rm(electronDataDir, { force: true, recursive: true });
    await fs.rm(codexHome, { force: true, recursive: true });
    assert.equal(
      await restoreStateSnapshot({ backupFile, codexHome, electronDataDir }),
      true,
    );
    assert.equal(
      await fs.readFile(path.join(electronDataDir, "preferences.json"), "utf8"),
      "4\n",
    );
  } finally {
    await fs.rm(root, { force: true, recursive: true });
  }
});
