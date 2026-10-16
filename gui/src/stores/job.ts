import { create } from "zustand";
import { api } from "@/lib/api";
import { errorText, object, responseError, text } from "@/lib/value";
import type {
  EngineEvent,
  EngineRequest,
  EngineResponse,
  JobSnapshot,
  Operation,
} from "@/lib/types";
interface JobState {
  jobId: string | null;
  operation: Operation | null;
  phase: string;
  busy: boolean;
  logs: string[];
  progress: Record<string, unknown>;
  response: EngineResponse | null;
  error: string | null;
}
const initial: JobState = {
  jobId: null,
  operation: null,
  phase: "idle",
  busy: false,
  logs: [],
  progress: {},
  response: null,
  error: null,
};
export const useJob = create<JobState>(() => ({ ...initial }));
let subscription: Promise<() => void> | null = null;
export function receiveEvent(event: EngineEvent) {
  const state = useJob.getState();
  if (state.jobId !== event.jobId || state.phase === "finished") return;
  if (event.type === "complete") {
    useJob.setState({
      phase: "finished",
      busy: false,
      response: event.payload as EngineResponse,
      error: null,
    });
    return;
  }
  const payload = object(event.payload);
  const unverifiedResponse =
    event.type === "cancellation_unverified" &&
    typeof payload.success === "boolean" &&
    payload.result
      ? (event.payload as EngineResponse)
      : null;
  const message = unverifiedResponse
    ? responseError(unverifiedResponse)
    : typeof event.payload === "string"
      ? event.payload
      : text(payload.message, "");
  const logs = message ? [...state.logs, message].slice(-300) : state.logs;
  const phase =
    event.type === "cancellation_unverified"
      ? event.type
      : state.phase === "cancelling" ||
          state.phase === "cancellation_unverified"
        ? state.phase
        : event.type === "accepted"
          ? "accepted"
          : "running";
  useJob.setState({
    logs,
    phase,
    ...(unverifiedResponse ? { response: unverifiedResponse } : {}),
    progress: event.type === "progress" ? payload : state.progress,
    error:
      event.type === "cancellation_unverified"
        ? message || "Termination could not be confirmed. Retry cancellation."
        : state.error,
  });
}
export function applySnapshot(snapshot: JobSnapshot | null) {
  if (
    !snapshot ||
    useJob.getState().jobId !== snapshot.jobId ||
    useJob.getState().phase === "finished"
  )
    return;
  if (snapshot.phase === "finished")
    useJob.setState({
      response: snapshot.response,
      phase: "finished",
      busy: false,
      error: null,
    });
  else {
    useJob.setState({
      phase: snapshot.phase,
      busy: true,
      response: snapshot.response,
      ...(snapshot.phase === "cancellation_unverified" && snapshot.response
        ? { error: responseError(snapshot.response) }
        : {}),
    });
    if (snapshot.lastEvent)
      receiveEvent({
        ...snapshot.lastEvent,
        jobId: snapshot.jobId,
        operation: snapshot.operation,
      });
  }
}
async function listenOnce() {
  subscription ??= api.listen(receiveEvent).catch((error) => {
    subscription = null;
    throw error;
  });
  return subscription;
}
export async function recoverJob() {
  await listenOnce();
  const snapshot = await api.status();
  if (snapshot && !useJob.getState().busy) {
    useJob.setState({
      ...initial,
      jobId: snapshot.jobId,
      operation: snapshot.operation,
      busy: true,
      phase: snapshot.phase,
    });
    applySnapshot(snapshot);
  }
}
export async function startJob(request: EngineRequest): Promise<string> {
  if (useJob.getState().busy)
    throw new Error(
      "Another operation is still active. Wait for confirmed completion.",
    );
  const jobId = crypto.randomUUID();
  // Reserve synchronously, before listener setup or invoke can yield to another page.
  useJob.setState({
    ...initial,
    jobId,
    operation: request.operation,
    busy: true,
    phase: "accepted",
  });
  try {
    await listenOnce();
    await api.start(structuredClone(request), jobId);
    applySnapshot(await api.status(jobId));
  } catch (error) {
    // Registration can fail before a job exists, or another client can own the registry.
    try {
      let snapshot: JobSnapshot | null;
      try {
        snapshot = await api.status(jobId);
      } catch {
        snapshot = await api.status(null);
      }
      if (snapshot) {
        if (snapshot.jobId !== jobId)
          useJob.setState({
            ...initial,
            jobId: snapshot.jobId,
            operation: snapshot.operation,
            phase: snapshot.phase,
            busy: true,
          });
        applySnapshot(snapshot);
        useJob.setState({ error: errorText(error) });
        return snapshot.jobId;
      }
      useJob.setState({
        phase: "finished",
        busy: false,
        error: errorText(error),
      });
    } catch {
      useJob.setState({
        phase: "cancellation_unverified",
        busy: true,
        error: `Cannot confirm job registration or termination: ${errorText(error)}. Retry cancellation or reconnect to inspect status.`,
      });
    }
    throw error;
  }
  return jobId;
}
export async function cancelJob() {
  const { jobId, busy } = useJob.getState();
  if (!jobId || !busy) return;
  useJob.setState({ phase: "cancelling", error: null });
  try {
    applySnapshot(await api.cancel(jobId));
  } catch (error) {
    if (useJob.getState().busy)
      useJob.setState({
        phase: "cancellation_unverified",
        error: errorText(error),
      });
  }
}
export async function refreshJob() {
  const id = useJob.getState().jobId;
  if (id) applySnapshot(await api.status(id));
}
// Test-only lifecycle reset also supports hot-reloaded development without duplicate listeners.
export async function resetJobController() {
  if (subscription) (await subscription)();
  subscription = null;
  useJob.setState({ ...initial });
}
