import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import "./styles/fonts.css";
import "./styles/base.css";
import "./styles/pipeline.css";
import "./styles/stations.css";
import "./styles/panels.css";
import "./styles/sections.css";
import "./styles/dataset.css";
import "./styles/hear.css";
import "./styles/motion.css";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
