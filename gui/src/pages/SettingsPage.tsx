import { useState } from "react";
import { api } from "@/lib/api";
import { errorText, object, text } from "@/lib/value";
import type { RuntimeSettings } from "@/lib/types";
import { checkRuntime, saveSettings, useWorkspace } from "@/stores/workspace";
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
      <div className="row">
        <button
          className="primary"
          disabled={working || busy}
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
            disabled={working || busy || !draft.dockerImage.trim()}
            onClick={() =>
              void act(
                () => api.pull(draft),
                "Image pull completed. Save settings and check the actual engine before analysis.",
              )
            }
          >
            Pull configured image
          </button>
        )}
      </div>
      {working && <p role="status">Checking or updating runtime…</p>}
      {error && <Notice tone="error">{error}</Notice>}
      {message && <Notice tone="info">{message}</Notice>}
    </Section>
  );
}
export function SettingsPage() {
  const { settings, doctor, checkingRuntime, runtimeError, initError } =
    useWorkspace();
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
        <SettingsForm key={JSON.stringify(settings)} saved={settings} />
      ) : (
        <Notice tone="error">
          Desktop settings could not be loaded. Launch this interface inside the
          desktop application.
        </Notice>
      )}
      <Section title="Runtime diagnostics">
        <button
          disabled={checkingRuntime || !settings}
          onClick={() => void checkRuntime()}
        >
          {checkingRuntime ? "Checking runtime…" : "Check runtime"}
        </button>
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
