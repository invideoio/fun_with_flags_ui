// Builds priv/static/icons/hugeicons.svg from the @hugeicons/core-free-icons 4.3.5
// tarball (MIT). Run: node dev/icons/build_sprite.js <extracted>/package/dist/esm priv/static/icons/hugeicons.svg
// Build priv/static/icons/hugeicons.svg from @hugeicons/core-free-icons 4.3.5
// (MIT), read from the extracted tarball. Only the icons the UI uses.
const fs = require("fs");
const DIR = process.argv[2];
const OUT = process.argv[3];
const ICONS = {
  "search": "Search01", "add": "Add01", "copy": "Copy01", "star": "Star", "delete": "Delete02",
  "arrow-left": "ArrowLeft02", "arrow-right": "ArrowRight02", "arrow-up": "ArrowUp02", "arrow-down": "ArrowDown02",
  "chevron-down": "ArrowDown01", "keyboard": "Keyboard",
  "sun": "Sun03", "moon": "Moon02", "computer": "Computer", "filter": "FilterHorizontal",
  "tick": "Tick02", "cancel": "Cancel01", "flag": "Flag02", "user": "UserCircle"
};
const camel = (k) => k.replace(/[A-Z]/g, (m) => "-" + m.toLowerCase());
let out = '<svg xmlns="http://www.w3.org/2000/svg" style="display:none">\n';
out += "<!-- Hugeicons stroke-rounded, from @hugeicons/core-free-icons 4.3.5 (MIT, see LICENSE-hugeicons.md) -->\n";
for (const [id, name] of Object.entries(ICONS)) {
  const src = fs.readFileSync(`${DIR}/${name}Icon.js`, "utf8");
  const body = src.slice(src.indexOf("["), src.lastIndexOf("];") + 1);
  const elements = Function('"use strict"; return (' + body + ");")();
  const inner = elements.map(([tag, attrs]) => {
    const a = Object.entries(attrs).filter(([k]) => k !== "key")
      .map(([k, v]) => `${camel(k)}="${String(v).replace(/"/g, "&quot;")}"`).join(" ");
    return `<${tag} ${a}/>`;
  }).join("");
  out += `<symbol id="hi-${id}" viewBox="0 0 24 24">${inner}</symbol>\n`;
}
out += "</svg>\n";
fs.writeFileSync(OUT, out);
console.log(Object.keys(ICONS).length, "icons,", out.length, "bytes");
