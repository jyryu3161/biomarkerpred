import { useEffect, useState } from "react";
import {
  Activity,
  Database,
  FlaskConical,
  Network,
  Settings,
  ShieldCheck,
} from "lucide-react";
import { errorText } from "@/lib/value";
import type { Page } from "@/lib/types";
import {
  initializeWorkspace,
  navigate,
  useWorkspace,
} from "@/stores/workspace";
import { recoverJob, useJob } from "@/stores/job";
import { usePrediction } from "@/stores/prediction";
import { Notice } from "@/components/Common";
import { JobPanel } from "@/components/JobPanel";
import { SetupPage } from "@/pages/SetupPage";
import { ResultsPage } from "@/pages/ResultsPage";
import { PredictionPage } from "@/pages/PredictionPage";
import { PathwayPage } from "@/pages/PathwayPage";
import { SettingsPage } from "@/pages/SettingsPage";
const pages = [
  { id: "setup", name: "Analysis setup", icon: FlaskConical },
  { id: "results", name: "Results & history", icon: Database },
  { id: "prediction", name: "Prediction & evaluation", icon: Activity },
  { id: "pathway", name: "Pathways & evidence", icon: Network },
  { id: "settings", name: "Settings", icon: Settings },
] as const;
function App() {
  const { page, doctor, checkingRuntime, initialized, settings, initError } =
    useWorkspace();
  const job = useJob();
  const [jobError, setJobError] = useState("");
  useEffect(() => {
    void initializeWorkspace();
    void recoverJob().catch((error) => setJobError(errorText(error)));
  }, []);
  useEffect(() => {
    if (
      job.phase === "finished" &&
      job.response &&
      (job.operation === "predict" || job.operation === "evaluate")
    )
      usePrediction.setState({ result: job.response });
  }, [job.phase, job.response, job.operation]);
  useEffect(() => {
    const warn = (event: BeforeUnloadEvent) => {
      if (useJob.getState().busy) event.preventDefault();
    };
    window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, []);
  return (
    <div className="app-shell">
      <aside className="sidebar">
        <a
          className="brand"
          href="#"
          onClick={(e) => {
            e.preventDefault();
            navigate("setup");
          }}
        >
          <ShieldCheck size={30} />
          <span>
            BioMarkerPred<small>Research workspace</small>
          </span>
        </a>
        <nav aria-label="Main navigation">
          {pages.map(({ id, name, icon: Icon }) => (
            <button
              key={id}
              aria-current={page === id ? "page" : undefined}
              onClick={() => navigate(id as Page)}
            >
              <Icon size={19} />
              {name}
            </button>
          ))}
        </nav>
        <div className="runtime-summary">
          <span className={`runtime-dot ${doctor?.success ? "ready" : ""}`} />
          {checkingRuntime
            ? "Checking runtime…"
            : doctor?.success
              ? `${settings?.backend === "docker" ? "Docker" : "Local R"} ready`
              : "Runtime needs attention"}
          <small>Shared R engine · schema v1</small>
          <button className="text-button" onClick={() => navigate("settings")}>
            Runtime settings
          </button>
        </div>
      </aside>
      <main>
        <div className="topbar">
          <span>Reproducible biomarker research</span>
          <span>{job.busy ? "Operation active" : "Workspace ready"}</span>
        </div>
        <div className="workspace">
          <div className="page-content">
            {initError && <Notice tone="error">{initError}</Notice>}
            {jobError && (
              <Notice tone="warning">
                Job recovery: {jobError}{" "}
                <button
                  onClick={() =>
                    void recoverJob()
                      .then(() => setJobError(""))
                      .catch((error) => setJobError(errorText(error)))
                  }
                >
                  Retry job recovery
                </button>
              </Notice>
            )}
            {initialized && !doctor?.success && page !== "settings" && (
              <Notice tone="warning">
                {checkingRuntime
                  ? "Checking the selected engine…"
                  : "The selected runtime is not ready. Configure or inspect it in Settings."}
                <button onClick={() => navigate("settings")}>
                  Open settings
                </button>
              </Notice>
            )}
            {page === "setup" && <SetupPage />}
            {page === "results" && <ResultsPage />}
            {page === "prediction" && <PredictionPage />}
            {page === "pathway" && <PathwayPage />}
            {page === "settings" && <SettingsPage />}
          </div>
          <JobPanel />
        </div>
      </main>
    </div>
  );
}
export default App;
