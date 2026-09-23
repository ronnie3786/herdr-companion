import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { fileURLToPath } from "node:url";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";

export default defineConfig({
  plugins: [react(), {
    name: "bundled-diff-licenses",
    generateBundle() {
      const packages = new Map<string, string>();
      for (const id of this.getModuleIds()) {
        if (!id.includes("/node_modules/") || id.startsWith("\0")) continue;
        let directory = dirname(id.split("?")[0]);
        while (directory.includes("node_modules")) {
          const manifest = join(directory, "package.json");
          if (existsSync(manifest)) {
            const pkg = JSON.parse(readFileSync(manifest, "utf8"));
            if (pkg.name && pkg.version) {
              const key = `${pkg.name} ${pkg.version}`;
              if (!packages.has(key)) {
                let notices = readdirSync(directory, { withFileTypes: true })
                  .filter((entry) => entry.isFile() && /^(licen[cs]e|copying|notice)([.-]|$)/i.test(entry.name))
                  .map((entry) => entry.name).sort()
                  .map((name) => readFileSync(join(directory, name), "utf8")).join("\n\n");
                // lru_map's npm tarball puts its full MIT notice in README.
                if (!notices && pkg.name === "lru_map") {
                  notices = readFileSync(join(directory, "README.md"), "utf8").split("# MIT license\n")[1] ?? "";
                }
                if (!notices) throw new Error(`Missing bundled license for ${key}`);
                packages.set(key, `## ${key}\n\n${notices}`);
              }
              break;
            }
          }
          directory = dirname(directory);
        }
      }
      this.emitFile({ type: "asset", fileName: "PRReviewDiffRenderer-LICENSES.txt",
        source: "Herdr shared diff renderer — third-party notices\n\n" + [...packages].sort(([a], [b]) => a.localeCompare(b, "en")).map(([, text]) => text).join("\n\n") });
    },
  }],
  base: "./",
  publicDir: false,
  build: {
    outDir: "../../herdr-harness-mac/herdr-harness-mac/Resources",
    emptyOutDir: false,
    cssCodeSplit: false,
    assetsInlineLimit: Number.MAX_SAFE_INTEGER,
    rollupOptions: {
      input: fileURLToPath(new URL("PRReviewDiffRenderer.html", import.meta.url)),
      output: {
        inlineDynamicImports: true,
        entryFileNames: "PRReviewDiffRenderer.js",
        assetFileNames: "PRReviewDiffRenderer.[ext]",
      },
    },
  },
});
