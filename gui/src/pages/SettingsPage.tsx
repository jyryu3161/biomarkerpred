import { useState } from "react";
import { api } from "@/lib/api";
import { errorText, object, text } from "@/lib/value";
import type { DockerStatus, RuntimeSettings } from "@/lib/types";
import {
  checkRuntime,
  downloadImage,
  saveSettings,
  useWorkspace,
} from "@/stores/workspace";
import { useJob } from "@/stores/job";
import {
  Facts,
  Field,
  JsonDetails,
  Notice,
  PathField,
  Section,
} from "@/components/Common";
function SettingsForm({ saved }: { saved: RuntimeSettings }) {
  const [draft, setDraft] = useState(saved);
  const [working, setWorking] = useState(false);
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");
  const busy = useJob((s) => s.busy);
  const downloading = useWorkspace((s) => s.downloadingImage);
  const checking = useWorkspace((s) => s.checkingRuntime);
  const disabled = working || busy || downloading || checking;
  const act = async (fn: () => Promise<unknown>, message: string) => {
    setWorking(true);
    setError("");
    setMessage("");
    try {
      await fn();
      setMessage(message);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setWorking(false);
    }
  };
  return (
    <Section title="Execution settings">
      <fieldset disabled={disabled} style={{ border: 0, padding: 0, margin: 0 }}>
        <div className="form-grid">
          <Field label="Runtime backend">
            <select
              value={draft.backend}
              onChange={(e) =>
                setDraft({
                  ...draft,
                  backend: e.target.value as RuntimeSettings["backend"],
                })
              }
            >
              <option value="local">Local R</option>
              <option value="docker">Docker engine</option>
            </select>
          </Field>
          {draft.backend === "local" ? (
            <PathField
              label="Rscript executable"
              value={draft.rPath ?? ""}
              onChange={(rPath) => setDraft({ ...draft, rPath: rPath || null })}
              hint="Leave empty for the configured environment / PATH. Local execution does not require Docker."
            />
          ) : (
            <>
              <PathField
                label="Docker executable"
                value={draft.dockerPath ?? ""}
                onChange={(dockerPath) =>
                  setDraft({ ...draft, dockerPath: dockerPath || null })
                }
                hint="Leave empty to find Docker on PATH."
              />
              <Field label="Docker image">
                <input
                  value={draft.dockerImage}
                  onChange={(e) =>
                    setDraft({ ...draft, dockerImage: e.target.value })
                  }
                />
              </Field>
            </>
          )}
        </div>
        <PathField
          label="Default output / history root"
          value={draft.outputRoot ?? ""}
          onChange={(outputRoot) =>
            setDraft({ ...draft, outputRoot: outputRoot || null })
          }
          directory
          hint="Stored on this computer. Analyses create unique child run directories."
        />
      </fieldset>
      {draft.backend === "docker" && (
        <p>
          Install Docker Desktop if needed. <button
            disabled={disabled}
            onClick={() => void act(api.openDockerDownload, "Opening the official Docker Desktop download page in your browser.")}
          >Open Docker Desktop download page</button>{" "}
          Start Docker Desktop and wait for its Linux engine to be running, then
          download the analysis image below. If it is already running, check the
          selected executable, Docker context and permissions. Checking runtime
          never installs an image or starts Docker.
        </p>
      )}
      <div className="row">
        <button
          className="primary"
          disabled={disabled}
          onClick={() =>
            void act(
              () => saveSettings(draft),
              "Settings saved; runtime diagnostics refreshed.",
            )
          }
        >
          Save settings and check
        </button>
        {draft.backend === "docker" && (
          <button
            disabled={disabled || !draft.dockerImage.trim()}
            onClick={() =>
              void act(
                () => downloadImage(draft),
                "Analysis image downloaded; settings saved and the actual engine passed doctor.",
              )
            }
          >
            {downloading ? "Downloading analysis image…" : "Download analysis image"}
          </button>
        )}
      </div>
      {(working || downloading || checking) && (
        <p role="status">
          {downloading
            ? "Downloading the analysis image. This may take several minutes (up to 30 minutes); runtime verification follows automatically."
            : "Checking runtime…"}
        </p>
      )}
      {error && <Notice tone="error">{error}</Notice>}
      {message && <Notice tone="info">{message}</Notice>}
    </Section>
  );
}
function dockerFacts(status: DockerStatus | null) {
  const engine = {
    cli_missing: "Docker CLI not found",
    engine_unreachable: "Cannot connect",
    wrong_container_mode: "Windows containers (Linux required)",
    image_missing: "Running (Linux containers)",
    image_check_failed: "Running (Linux containers)",
    ready: "Running (Linux containers)",
  };
  const image = {
    cli_missing: "Not checked (Docker Engine required)",
    engine_unreachable: "Not checked (Docker Engine required)",
    wrong_container_mode: "Not checked (Docker Engine required)",
    image_missing: "Not downloaded",
    image_check_failed: "Inspection failed",
    ready: `Available: ${status?.image}`,
  };
  return {
    "Docker Engine": status ? engine[status.state] : "Not checked",
    "Analysis Image": status ? image[status.state] : "Not checked",
  };
}
export function SettingsPage() {
  const {
    settings, doctor, dockerStatus, downloadingImage,
    checkingRuntime, runtimeError, initError,
  } = useWorkspace();
  const result = object(doctor?.result);
  return (
    <div className="stack">
      <header>
        <p className="eyebrow">RUNTIME</p>
        <h1>Settings</h1>
        <p>
          The desktop and CLI execute the same installed R engine and
          configuration schema.
        </p>
      </header>
      {initError && <Notice tone="error">{initError}</Notice>}
      {settings ? (
        <SettingsForm saved={settings} />
      ) : (
        <Notice tone="error">
          Desktop settings could not be loaded. Launch this interface inside the
          desktop application.
        </Notice>
      )}
      <Section title="Runtime diagnostics">
        <button
          disabled={checkingRuntime || downloadingImage || !settings}
          onClick={() => void checkRuntime()}
        >
          {checkingRuntime ? "Checking runtime…" : "Check runtime"}
        </button>
        {settings?.backend === "docker" && (
          <>
            <Facts value={dockerFacts(dockerStatus)} />
            {dockerStatus && (
              <JsonDetails value={dockerStatus.diagnostics} title="Docker command diagnostics" />
            )}
          </>
        )}
        {runtimeError && <Notice tone="error">{runtimeError}</Notice>}
        {doctor && (
          <>
            <Notice tone={doctor.success ? "success" : "error"}>
              {doctor.success
                ? `Ready: ${settings?.backend} engine passed doctor.`
                : "Runtime is not ready."}
            </Notice>
            <Facts
              value={Object.fromEntries(
                [
                  "application",
                  "engine_version",
                  "interface_version",
                  "config_version",
                  "model_version",
                  "r_version",
                  "platform",
                  "engine_root",
                ].map((key) => [key, result[key]]),
              )}
            />
            <h3>Required packages and graphics</h3>
            <Facts value={result.packages} />
            <Facts value={result.graphics} />
            <h3>Optional pathway capabilities</h3>
            <Facts value={result.pathway_capabilities} />
            <JsonDetails value={doctor} title="Complete doctor response" />
          </>
        )}
        <p className="muted">
          Readiness requires the actual versioned CLI, core packages and
          Cairo/PNG/TIFF graphics. Optional annotation packages are diagnosed
          separately. {text(object(result.pathway_capabilities).note, "")}
        </p>
      </Section>
    </div>
  );
}
