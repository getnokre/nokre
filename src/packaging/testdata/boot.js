import { mount } from "./live.js";
await mount({ wasm: "./app.wasm", into: document.getElementById("app") });
