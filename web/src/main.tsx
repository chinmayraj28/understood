import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { AccessGate } from "./components/AccessGate";
import "./styles/fonts.css";
import "./styles/base.css";
import "./styles/pipeline.css";
import "./styles/stations.css";
import "./styles/panels.css";
import "./styles/sections.css";
import "./styles/dataset.css";
import "./styles/hear.css";
import "./styles/site.css";
import "./styles/workspace.css";
import "./styles/motion.css";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <AccessGate>
      <App />
    </AccessGate>
  </StrictMode>,
);
