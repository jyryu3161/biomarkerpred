import { beforeEach, describe, expect, it, vi } from "vitest";
import { api } from "@/lib/api";
import type { EngineEvent, EngineResponse, JobSnapshot } from "@/lib/types";
import {
  applySnapshot,
  cancelJob,
  recoverJob,
  resetJobController,
  startJob,
  useJob,
} from "@/stores/job";
const response: EngineResponse = {
  success: true,
  cancelled: false,
  exitCode: 0,
  result: { ok: true, run_dir: "/actual/runs/unique", status: "completed" },
  verificationError: null,
  stderrTail: [],
};
let listener: (event: EngineEvent) => void;
function snapshot(
  jobId: string,
  phase = "running",
  result: EngineResponse | null = null,
): JobSnapshot {
  return {
    jobId,
    operation: "analyze",
    phase,
    lastEvent: null,
    response: result,
  };
}
beforeEach(async () => {
  await resetJobController();
  vi.spyOn(api, "listen").mockImplementation(async (callback) => {
    listener = callback;
    return () => undefined;
  });
  vi.spyOn(api, "start").mockResolvedValue(undefined);
  vi.spyOn(api, "status").mockImplementation(async (jobId) =>
    jobId ? snapshot(jobId) : null,
  );
});
describe("one process-owning job across desktop pages", () => {
  it("subscribes before invoke, recovers immediate completion, and uses the actual output directory", async () => {
    vi.mocked(api.start).mockImplementation(async (_request, jobId) => {
      expect(api.listen).toHaveBeenCalledOnce();
      listener({
        jobId,
        operation: "analyze",
        type: "complete",
        payload: response,
      });
    });
    const jobId = await startJob({
      operation: "analyze",
      config: { output_dir: "/configured-root" },
    });
    expect(useJob.getState()).toMatchObject({
      jobId,
      phase: "finished",
      busy: false,
      response,
    });
    expect(useJob.getState().response?.result.run_dir).toBe(
      "/actual/runs/unique",
    );
  });
  it("reserves synchronously and blocks a second mutation while listener startup is pending", async () => {
    let resolve!: (value: () => void) => void;
    vi.mocked(api.listen).mockReturnValue(
      new Promise((value) => {
        resolve = value;
      }),
    );
    const first = startJob({ operation: "analyze" });
    await expect(startJob({ operation: "ora" })).rejects.toThrow(
      "Another operation",
    );
    expect(api.start).not.toHaveBeenCalled();
    resolve(() => undefined);
    await first;
    expect(api.start).toHaveBeenCalledOnce();
  });
  it("ignores delayed previous-job events and bounds current logs", async () => {
    const first = await startJob({ operation: "analyze" });
    listener({
      jobId: first,
      operation: "analyze",
      type: "complete",
      payload: response,
    });
    const second = await startJob({ operation: "evaluate" });
    listener({
      jobId: first,
      operation: "analyze",
      type: "complete",
      payload: response,
    });
    expect(useJob.getState()).toMatchObject({
      jobId: second,
      busy: true,
      response: null,
    });
    for (let i = 0; i < 400; i++)
      listener({
        jobId: second,
        operation: "evaluate",
        type: "log",
        payload: { message: String(i) },
      });
    expect(useJob.getState().logs).toHaveLength(300);
    expect(useJob.getState().logs[0]).toBe("100");
  });
  it("preserves an unverified EngineResponse event diagnostic including its named container", async () => {
    const id = await startJob({ operation: "analyze" });
    const diagnostic = {
      ...response,
      success: false,
      result: { error: "Cannot verify named container bmp-xyz termination" },
    };
    listener({
      jobId: id,
      operation: "analyze",
      type: "cancellation_unverified",
      payload: diagnostic,
    });
    expect(useJob.getState()).toMatchObject({
      busy: true,
      phase: "cancellation_unverified",
      error: "Cannot verify named container bmp-xyz termination",
      response: diagnostic,
    });
  });
  it("recovers a missed complete event from the post-start snapshot", async () => {
    vi.mocked(api.status).mockImplementation(async (jobId) =>
      snapshot(jobId!, "finished", response),
    );
    await startJob({ operation: "predict" });
    expect(useJob.getState()).toMatchObject({
      phase: "finished",
      busy: false,
      response,
    });
  });
  it("retains registry ownership when an unverified snapshot includes a failure response, and permits cancellation retry", async () => {
    const id = await startJob({ operation: "analyze" });
    const failed = {
      ...response,
      success: false,
      cancelled: false,
      verificationError: "container bmp-123 could not be stopped",
    };
    vi.spyOn(api, "cancel")
      .mockResolvedValueOnce({
        ...snapshot(id, "cancellation_unverified", failed),
        lastEvent: {
          type: "cancellation_unverified",
          payload: { message: "container bmp-123 remains active" },
        },
      })
      .mockResolvedValueOnce(
        snapshot(id, "finished", {
          ...response,
          success: false,
          cancelled: true,
        }),
      );
    await cancelJob();
    expect(useJob.getState()).toMatchObject({
      busy: true,
      phase: "cancellation_unverified",
      error: "container bmp-123 remains active",
      response: failed,
    });
    await expect(startJob({ operation: "predict" })).rejects.toThrow(
      "Another operation",
    );
    await cancelJob();
    expect(api.cancel).toHaveBeenCalledTimes(2);
    expect(useJob.getState()).toMatchObject({
      busy: false,
      phase: "finished",
      response: { cancelled: true },
    });
  });
  it("adds snapshot identity to lastEvent during recovery", async () => {
    vi.mocked(api.status).mockResolvedValue({
      ...snapshot("owned-process"),
      lastEvent: {
        type: "progress",
        payload: { message: "Fold 2 / 5", current: 2, total: 5 },
      },
    });
    await recoverJob();
    expect(useJob.getState()).toMatchObject({
      jobId: "owned-process",
      busy: true,
      progress: { current: 2 },
      logs: ["Fold 2 / 5"],
    });
  });
  it("clears a rejected request when its ID is unknown and no active registry owner exists", async () => {
    vi.mocked(api.start).mockRejectedValue(
      new Error("Invalid operation argument"),
    );
    vi.mocked(api.status).mockImplementation(async (jobId) => {
      if (jobId) throw new Error("Unknown jobId");
      return null;
    });
    await expect(startJob({ operation: "analyze" })).rejects.toThrow(
      "Invalid operation",
    );
    expect(useJob.getState()).toMatchObject({
      phase: "finished",
      busy: false,
      error: "Invalid operation argument",
    });
  });
  it("adopts another actual registry owner after start rejection instead of enabling mutations", async () => {
    vi.mocked(api.start).mockRejectedValue(
      new Error("Active job already exists"),
    );
    vi.mocked(api.status).mockImplementation(async (jobId) => {
      if (jobId) throw new Error("Unknown jobId");
      return snapshot("other-window");
    });
    await startJob({ operation: "analyze" });
    expect(useJob.getState()).toMatchObject({
      jobId: "other-window",
      busy: true,
      phase: "running",
    });
  });
  it("keeps an uncertain registration busy when both status queries fail", async () => {
    vi.mocked(api.start).mockRejectedValue(new Error("IPC disconnected"));
    vi.mocked(api.status).mockRejectedValue(new Error("IPC disconnected"));
    await expect(startJob({ operation: "analyze" })).rejects.toThrow(
      "IPC disconnected",
    );
    expect(useJob.getState()).toMatchObject({
      busy: true,
      phase: "cancellation_unverified",
    });
  });
  it("does not overwrite completion with an older running snapshot", async () => {
    const id = await startJob({ operation: "analyze" });
    listener({
      jobId: id,
      operation: "analyze",
      type: "complete",
      payload: { ...response, cancelled: true, success: false },
    });
    applySnapshot(snapshot(id));
    expect(useJob.getState()).toMatchObject({
      busy: false,
      phase: "finished",
      response: { cancelled: true, result: { status: "completed" } },
    });
  });
});
