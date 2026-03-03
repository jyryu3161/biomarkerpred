import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent, waitFor } from "@testing-library/react";
import { AnalysisTypeSelector } from "@/components/setup/AnalysisTypeSelector";
import { Sidebar } from "@/components/layout/Sidebar";

describe("AnalysisTypeSelector", () => {
  it("renders drug response prediction option", () => {
    const onChange = vi.fn();
    render(<AnalysisTypeSelector value="binary" onChange={onChange} />);

    expect(screen.getByText("Drug Response Prediction")).toBeDefined();
  });

  it("shows description for the analysis type", () => {
    const onChange = vi.fn();
    render(<AnalysisTypeSelector value="binary" onChange={onChange} />);

    expect(screen.getByText(/Logistic regression/)).toBeDefined();
  });

  it("auto-sets to binary when given non-binary value", () => {
    const onChange = vi.fn();
    render(<AnalysisTypeSelector value={"survival" as any} onChange={onChange} />);

    expect(onChange).toHaveBeenCalledWith("binary");
  });
});

describe("Sidebar", () => {
  it("renders all navigation items", () => {
    const onPageChange = vi.fn();
    render(<Sidebar currentPage="setup" onPageChange={onPageChange} analysisRunning={false} />);

    expect(screen.getByText("Setup")).toBeDefined();
    expect(screen.getByText("Results")).toBeDefined();
    expect(screen.getByText("Settings")).toBeDefined();
  });

  it("calls onPageChange when clicking a nav item", () => {
    const onPageChange = vi.fn();
    render(<Sidebar currentPage="setup" onPageChange={onPageChange} analysisRunning={false} />);

    fireEvent.click(screen.getByText("Settings"));
    expect(onPageChange).toHaveBeenCalledWith("settings");
  });

  it("shows app title and version", async () => {
    const onPageChange = vi.fn();
    render(<Sidebar currentPage="setup" onPageChange={onPageChange} analysisRunning={false} />);

    expect(screen.getByText("RESPRED")).toBeDefined();
    await waitFor(() => {
      expect(screen.getByText("v0.3.0")).toBeDefined();
    });
  });

  it("shows running indicator when analysis is active", () => {
    const onPageChange = vi.fn();
    const { container } = render(
      <Sidebar currentPage="setup" onPageChange={onPageChange} analysisRunning={true} />,
    );

    const greenDot = container.querySelector(".bg-green-500");
    expect(greenDot).toBeTruthy();
  });
});
