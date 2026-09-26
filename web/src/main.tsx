import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "@fontsource/barlow-semi-condensed/600.css";
import "@fontsource/barlow-semi-condensed/700.css";
import "@fontsource-variable/public-sans";
import "@fontsource/ibm-plex-mono/400.css";
import { App } from "./App.tsx";
import "./styles.css";

const rootElement = document.getElementById("root");
if (rootElement === null) {
  throw new Error('index.html is missing the <div id="root"> mount point');
}

createRoot(rootElement).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
