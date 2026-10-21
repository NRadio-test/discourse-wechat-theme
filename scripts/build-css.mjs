#!/usr/bin/env node
import fs from "node:fs/promises";

const args = process.argv.slice(2);
if (args.some((arg) => arg !== "--check")) {
  console.error("Usage: node scripts/build-css.mjs [--check]");
  process.exitCode = 2;
} else {
  const parts = ["shell", "chat", "inline-chat", "message-actions", "topic-groups", "profile-card"];
  const directory = new URL("../common/", import.meta.url);
  const target = new URL("common.scss", directory);
  try {
    const sources = await Promise.all(parts.map((name) => fs.readFile(new URL(`${name}.scss`, directory), "utf8")));
    const expected = sources.map((source) => source.replace(/\r\n/g, "\n").trimEnd()).join("\n\n") + "\n";
    if (args.includes("--check")) {
      const actual = await fs.readFile(target, "utf8").catch((error) => {
        if (error.code === "ENOENT") return null;
        throw error;
      });
      if (actual !== expected) {
        console.error("common/common.scss is missing or stale. Run: node scripts/build-css.mjs");
        process.exitCode = 1;
      } else {
        console.log("CSS check passed: common/common.scss matches all source files.");
      }
    } else {
      await fs.writeFile(target, expected, "utf8");
      console.log(`Generated common/common.scss: ${parts.join(" → ")}.`);
    }
  } catch (error) {
    console.error(`CSS build failed: ${error.message}`);
    process.exitCode = 1;
  }
}
