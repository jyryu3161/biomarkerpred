import { create } from "zustand";
import { api } from "@/lib/api";
import { errorText, object, responseError, schemaDefaults } from "@/lib/value";
import type {
  AnalysisConfig,
  DataInfo,
  DockerStatus,
  EngineResponse,
  JsonObject,
  Page,
  RunRecord,
  RuntimeSettings,
} from "@/lib/types";
interface Workspace {
  page: Page;
  schema: JsonObject | null;
  settings: RuntimeSettings | null;
  initialized: boolean;
  initError: string | null;
  doctor: EngineResponse | null;
  dockerStatus: DockerStatus | null;
  downloadingImage: boolean;
  checkingRuntime: boolean;
  runtimeError: string | null;
  config: AnalysisConfig;
  dataInfo: DataInfo | null;
  revision: number;
  validating: boolean;
  validation: EngineResponse | null;
  validatedConfig: AnalysisConfig | null;
  validationError: string | null;
  run: RunRecord | null;
  runLoading: boolean;
  runError: string | null;
}
export const useWorkspace = create<Workspace>(() => ({
  page: "setup",
  schema: null,
  settings: null,
  initialized: false,
  initError: null,
  doctor: null,
  dockerStatus: null,
  downloadingImage: false,
  checkingRuntime: false,
  runtimeError: null,
  config: {},
  dataInfo: null,
  revision: 0,
  validating: false,
  validation: null,
  validatedConfig: null,
  validationError: null,
  run: null,
  runLoading: false,
  runError: null,
}));
export const navigate = (page: Page) => useWorkspace.setState({ page });
let boot: Promise<void> | null = null;
export function initializeWorkspace() {
  boot ??= (async () => {
    const [schema, settings] = await Promise.allSettled([
      api.schema(),
      api.settings(),
    ]);
    const errors: string[] = [];
    if (schema.status === "fulfilled")
      useWorkspace.setState({
        schema: schema.value,
        config: schemaDefaults(schema.value, "binary"),
      });
    else errors.push(errorText(schema.reason));
    if (settings.status === "fulfilled") {
      const config = { ...useWorkspace.getState().config };
      if (settings.value.outputRoot)
        config.output_dir = settings.value.outputRoot;
      useWorkspace.setState({ settings: settings.value, config });
    } else errors.push(errorText(settings.reason));
    useWorkspace.setState({
      initialized: true,
      initError: errors.length ? errors.join("\n") : null,
    });
    if (settings.status === "fulfilled") await checkRuntime();
  })();
  return boot;
}
export function updateConfig(patch: AnalysisConfig) {
  const state = useWorkspace.getState();
  useWorkspace.setState({
    config: { ...state.config, ...patch },
    revision: state.revision + 1,
    validation: null,
    validatedConfig: null,
    validationError: null,
    ...(Object.hasOwn(patch, "data_file") ? { dataInfo: null } : {}),
  });
}
export function changeAnalysisType(type: string) {
  const { schema, config } = useWorkspace.getState();
  if (!schema) return;
  const next = schemaDefaults(schema, type);
  // Keep assay selections and explicit output paths, while replacing endpoint-specific defaults.
  for (const key of [
    "data_file",
    "sample_id",
    "group_column",
    "clinical_columns",
    "features",
    "include",
    "exclude",
    "evidence",
    "output_dir",
  ])
    next[key] = config[key];
  const previousDefaults = schemaDefaults(schema, String(config.analysis_type));
  if (config.output_dir === previousDefaults.output_dir)
    next.output_dir = schemaDefaults(schema, type).output_dir;
  updateConfig(next);
}
export async function inspectData(path: string) {
  const info = await api.header(path);
  if (useWorkspace.getState().config.data_file === path)
    useWorkspace.setState({ dataInfo: info });
  return info;
}
let runtimeSequence = 0;
export async function checkRuntime() {
  const settings = useWorkspace.getState().settings;
  if (!settings || useWorkspace.getState().downloadingImage) return false;
  const sequence = ++runtimeSequence;
  const identity = JSON.stringify(settings);
  const current = () =>
    sequence === runtimeSequence &&
    JSON.stringify(useWorkspace.getState().settings) === identity;
  useWorkspace.setState({
    checkingRuntime: true,
    doctor: null,
    dockerStatus: null,
    runtimeError: null,
  });
  try {
    if (settings.backend === "docker") {
      const status = await api.dockerStatus(settings);
      if (!current()) return false;
      useWorkspace.setState({ dockerStatus: status });
      if (status.state !== "ready") {
        useWorkspace.setState({ runtimeError: status.message });
        return false;
      }
    }
    const response = await api.call({ operation: "doctor", settings });
    if (current()) {
      useWorkspace.setState({
        doctor: response,
        runtimeError: response.success ? null : responseError(response),
      });
      return response.success;
    }
    return false;
  } catch (error) {
    if (current()) useWorkspace.setState({ runtimeError: errorText(error) });
    return false;
  } finally {
    if (current()) useWorkspace.setState({ checkingRuntime: false });
  }
}
async function persistSettings(settings: RuntimeSettings) {
  const saved = await api.saveSettings(settings);
  ++runtimeSequence;
  const state = useWorkspace.getState();
  useWorkspace.setState({
    settings: saved,
    doctor: null,
    dockerStatus: null,
    checkingRuntime: false,
    runtimeError: null,
    validatedConfig: null,
    validation: null,
    revision: state.revision + 1,
  });
  if (
    saved.outputRoot &&
    (!state.config.output_dir ||
      state.config.output_dir === state.settings?.outputRoot ||
      (state.schema &&
        state.config.output_dir ===
          schemaDefaults(state.schema, String(state.config.analysis_type))
            .output_dir))
  )
    updateConfig({ output_dir: saved.outputRoot });
  return saved;
}
export async function saveSettings(settings: RuntimeSettings) {
  if (useWorkspace.getState().downloadingImage)
    throw new Error("Wait for the analysis image download to finish.");
  await persistSettings(settings);
  await checkRuntime();
}
export async function downloadImage(settings: RuntimeSettings) {
  if (useWorkspace.getState().downloadingImage)
    throw new Error("An analysis image download is already in progress. Wait for it to finish.");
  ++runtimeSequence;
  useWorkspace.setState({
    downloadingImage: true,
    checkingRuntime: false,
    doctor: null,
    dockerStatus: null,
    runtimeError: null,
  });
  try {
    const saved = await persistSettings(settings);
    await api.pull(saved);
  } catch (error) {
    // Recheck prerequisites without turning a failed pull into a successful setup.
    const currentSettings = useWorkspace.getState().settings;
    if (currentSettings?.backend === "docker") {
      try {
        const status = await api.dockerStatus(currentSettings);
        useWorkspace.setState({ dockerStatus: status });
      } catch {
        /* The original save/download error remains authoritative. */
      }
    }
    useWorkspace.setState({ runtimeError: errorText(error) });
    throw error;
  } finally {
    useWorkspace.setState({ downloadingImage: false });
  }
  if (!(await checkRuntime())) {
    throw new Error(
      useWorkspace.getState().runtimeError ??
        "The image was downloaded, but runtime verification did not pass. Check runtime diagnostics.",
    );
  }
}
export async function validateConfiguration(file?: string) {
  const state = useWorkspace.getState();
  if (state.validating) return;
  const revision = state.revision;
  useWorkspace.setState({
    validating: true,
    validation: null,
    validatedConfig: null,
    validationError: null,
  });
  try {
    const response = await api.call({
      operation: "validate",
      ...(file
        ? { options: { config: file } }
        : { config: structuredClone(state.config) }),
      ...(state.settings ? { settings: state.settings } : {}),
    });
    if (useWorkspace.getState().revision !== revision) return;
    const normalized = object(response.result.config);
    const valid = response.success && Object.keys(normalized).length > 0;
    useWorkspace.setState({
      validation: response,
      validatedConfig: valid ? structuredClone(normalized) : null,
      validationError: response.success
        ? null
        : `${file && !Object.keys(normalized).length ? "Import failed and was not applied; the form still shows the previous configuration. Fix the imported file or edit the current form.\n" : ""}${responseError(response)}`,
      ...(Object.keys(normalized).length ? { config: normalized } : {}),
    });
    if (
      Object.keys(normalized).length &&
      typeof normalized.data_file === "string"
    ) {
      try {
        await inspectData(normalized.data_file);
      } catch {
        /* QC remains authoritative even when the optional preview fails. */
      }
    }
  } catch (error) {
    if (useWorkspace.getState().revision === revision)
      useWorkspace.setState({ validationError: errorText(error) });
  } finally {
    useWorkspace.setState({ validating: false });
  }
}
let runSequence = 0;
export async function openRun(runDir: string, page?: Page) {
  const sequence = ++runSequence;
  useWorkspace.setState({
    runLoading: true,
    runError: null,
    run: null,
    ...(page ? { page } : {}),
  });
  try {
    const run = await api.run(runDir);
    if (sequence === runSequence) useWorkspace.setState({ run });
  } catch (error) {
    if (sequence === runSequence)
      useWorkspace.setState({ runError: errorText(error) });
  } finally {
    if (sequence === runSequence) useWorkspace.setState({ runLoading: false });
  }
}
