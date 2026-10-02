// Export the approved Original drawings from an operator-supplied prototype.
// Usage: node export-avatars.cjs /path/to/watchers-prototype /path/to/WatcherAvatars
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const [source, output] = process.argv.slice(2);
if (!source || !output) throw new Error("Supply the prototype directory and output asset catalog directory.");
const context = {window: {}, localStorage: {getItem: () => null, setItem() {}}, setInterval: () => 0};
vm.createContext(context);
for (const file of ["v2-core.js", "v2-avatar-styles.js"]) {
  vm.runInContext(fs.readFileSync(path.join(source, file), "utf8"), context, {filename: file, timeout: 5000});
}
const library = context.window.V2;
fs.mkdirSync(output, {recursive: true});
function save(name, drawing) {
  const directory = path.join(output, `${name}.imageset`);
  fs.mkdirSync(directory, {recursive: true});
  const svg = drawing.replace("<svg ", '<svg xmlns="http://www.w3.org/2000/svg" ')
    .replace(/\sclass="[^"]*"/g, "")
    .replace(/(fill|stroke)="#([0-9a-f]{6})([0-9a-f]{2})"/gi,
      (_, attribute, color, alpha) => `${attribute}="#${color}" ${attribute}-opacity="${Number.parseInt(alpha, 16) / 255}"`);
  fs.writeFileSync(path.join(directory, `${name}.svg`), svg);
  fs.writeFileSync(path.join(directory, "Contents.json"), JSON.stringify({images: [{filename: `${name}.svg`, idiom: "universal"}], info: {author: "xcode", version: 1}, properties: {"preserves-vector-representation": true}}, null, 2));
}
for (const avatar of [...library.CHARACTERS, ...library.INSTRUMENTS]) {
  for (const state of ["idle", "resting"]) save(`Watcher-${avatar.id}-${state}`, library.avatarSVG(avatar.id, state, "original"));
}
save("Watcher-slack", library.SLACK);
save("Watcher-github", library.GITHUB);
