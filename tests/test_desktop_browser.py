#!/usr/bin/env python3
"""Independent browser acceptance with real CLI QC and retained synthetic runs.

Requires a running Vite preview, Playwright/Chromium, and completed synthetic
binary, survival and mapped-network pathway runs. Desktop IPC is injected;
this test does not claim native desktop execution or real process cancellation.
"""
import argparse
import asyncio
import csv
import json
from pathlib import Path
import re
import shutil
import tempfile

from playwright.async_api import async_playwright, expect

from desktop_browser_bridge import DesktopBridge


async def setup_review(page, bridge):
    await expect(page.get_by_role("heading", name="Analysis setup", exact=True)).to_be_visible()
    invalid = json.loads((bridge.development_run / "config.json").read_text())
    invalid["positive_class"] = "invalid-imported-class"
    invalid["positive_label"] = "가져온 반응군"
    invalid_path = bridge.directory / "invalid imported config.json"
    invalid_path.write_text(json.dumps(invalid, ensure_ascii=False), encoding="utf-8")
    bridge.files.append(invalid_path)
    await page.get_by_role("button", name="Import configuration", exact=True).click()
    await expect(page.get_by_label("Positive outcome code", exact=True)).to_have_value("invalid-imported-class", timeout=30000)
    await expect(page.get_by_label("Positive display label", exact=True)).to_have_value("가져온 반응군")
    await expect(page.get_by_role("button", name="Run analysis", exact=True)).to_be_disabled()
    assert await page.get_by_role("alert").count() > 0, "Failed imported QC must stay visible and editable."
    bridge.files.append(bridge.development_run / "config.json")
    await page.get_by_role("button", name="Import configuration", exact=True).click()
    await expect(page.get_by_role("button", name="Run analysis", exact=True)).to_be_enabled(timeout=30000)
    await expect(page.get_by_label("Outer folds", exact=True)).to_have_value("3")
    await expect(page.get_by_label("Patient / group column", exact=True)).to_have_value("patient")

    # An exact comma-containing gene name must survive selection and CLI normalization.
    await page.locator("summary").filter(has_text="Candidate assay columns").click()
    await page.get_by_role("checkbox", name="gene,quoted", exact=True).check()
    await expect(page.get_by_role("button", name="Run analysis", exact=True)).to_be_disabled()
    await page.get_by_label("Positive display label", exact=True).fill("반응군 <browser>")
    await page.get_by_label("Positive outcome code", exact=True).fill("invalid-outcome-code")
    await page.get_by_role("button", name="Run QC", exact=True).click()
    await expect(page.get_by_role("button", name="Run QC", exact=True)).to_be_enabled(timeout=30000)
    await expect(page.get_by_role("button", name="Run analysis", exact=True)).to_be_disabled()
    assert await page.get_by_role("alert").count() > 0, "Invalid QC was discarded"

    await page.get_by_label("Positive outcome code", exact=True).fill("1")
    await page.get_by_role("button", name="Run QC", exact=True).click()
    await expect(page.get_by_role("button", name="Run analysis", exact=True)).to_be_enabled(timeout=30000)
    validations = [args["request"] for command, args in bridge.calls
                   if command == "engine_call" and args["request"]["operation"] == "validate"]
    assert validations[-1]["config"]["positive_label"] == "반응군 <browser>"
    assert "gene,quoted" in validations[-1]["config"]["features"]
    assert validations[-1]["settings"]["backend"] == "local"
    await page.get_by_role("button", name="Run analysis", exact=True).click()
    await page.get_by_role("button", name="Inspect actual run", exact=True).click()
    await expect(page.get_by_role("heading", name=f"Run {bridge.development_run.name}", exact=True)).to_be_visible()
    starts = [args["request"] for command, args in bridge.calls if command == "engine_start"]
    assert starts[-1]["operation"] == "analyze"
    assert starts[-1]["config"]["positive_label"] == "반응군 <browser>"
    assert "gene,quoted" in starts[-1]["config"]["features"]


async def history_review(page, bridge):
    await page.get_by_role("button", name="Results & history", exact=True).click()
    await page.get_by_role("button", name="Refresh run history", exact=True).click()
    for run in [bridge.development_run, bridge.survival_run]:
        await page.get_by_role("checkbox", name=f"Compare {run.name}", exact=True).check()
    await page.get_by_role("button", name="Compare selected runs (2)", exact=True).click()
    await expect(page.get_by_role("heading", name="Recorded comparison", exact=True)).to_be_visible()
    await expect(page.get_by_text(re.compile("Do not rank this run together"))).to_be_visible()
    comparisons = [args["request"] for command, args in bridge.calls
                   if command == "engine_call" and args["request"]["operation"] == "compare"]
    assert len(comparisons[-1]["options"]["run"]) == 2
    await page.get_by_role("button", name="Open HTML report", exact=True).click()
    await page.get_by_role("button", name="Export PDF report", exact=True).click()
    assert bridge.opened[-1] == str(bridge.development_run / "report.html")
    assert bridge.saved[-1] == str(bridge.development_run / "report.pdf")


async def prediction_review(page, bridge):
    await page.get_by_role("button", name="Prediction & evaluation", exact=True).click()
    await page.get_by_role("textbox", name=re.compile(r"^Model file")).fill(str(bridge.development_run / "model.bmpmodel"))
    await page.get_by_role("button", name="Load model", exact=True).click()
    await expect(page.get_by_text(re.compile("Valid null model: no predictor columns"))).to_be_visible()
    input_path = bridge.directory / "identifiers-only.csv"
    with input_path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.writer(stream)
        writer.writerow(["sample", "patient"])
        writer.writerows([["00001", "patient001"], ["9007199254740993123", "patient002"]])
    await page.get_by_role("textbox", name=re.compile(r"^New cohort CSV")).fill(str(input_path))
    await page.get_by_role("textbox", name=re.compile(r"^Prediction \/ evaluation output")).fill(str(bridge.directory / "scores.csv"))
    await page.get_by_role("button", name="Run prediction", exact=True).click()
    await expect(page.get_by_role("cell", name="00001", exact=True)).to_be_visible()
    await expect(page.get_by_role("cell", name="9007199254740993123", exact=True)).to_be_visible()

    await page.get_by_role("combobox", name=re.compile(r"^Scoring operation")).select_option("evaluate")
    await page.get_by_label("Evaluation bootstrap samples", exact=True).fill("0")
    await page.get_by_role("textbox", name=re.compile(r"^Prediction \/ evaluation output")).fill(str(bridge.directory / "external"))
    await page.get_by_role("button", name="Run external evaluation", exact=True).click()
    await expect(page.get_by_text(re.compile(r"Required model\/input columns not found")).first).to_be_visible()
    config = json.loads((bridge.development_run / "config.json").read_text())
    await page.get_by_role("textbox", name=re.compile(r"^New cohort CSV")).fill(config["data_file"])
    await page.get_by_role("button", name="Run external evaluation", exact=True).click()
    await page.get_by_role("button", name="Open evaluation metrics and drift", exact=True).click()
    await expect(page.get_by_role("heading", name="External evaluation performance", exact=True)).to_be_visible()
    await expect(page.get_by_role("heading", name="External distribution and overlap audit", exact=True)).to_be_visible()
    await expect(page.get_by_text(re.compile("byte-identical to the development input")).first).to_be_visible()

    await page.get_by_role("button", name="Prediction & evaluation", exact=True).click()
    await page.get_by_role("textbox", name=re.compile(r"^Model file")).fill(str(bridge.survival_run / "model.bmpmodel"))
    await page.get_by_role("button", name="Load model", exact=True).click()
    await expect(page.get_by_text(re.compile("Valid null model: no predictor columns"))).to_be_visible()
    await page.get_by_role("combobox", name=re.compile(r"^Scoring operation")).select_option("predict")
    await page.get_by_role("textbox", name=re.compile(r"^New cohort CSV")).fill(str(input_path))
    await page.get_by_role("textbox", name=re.compile(r"^Prediction \/ evaluation output")).fill(str(bridge.directory / "survival-scores.csv"))
    await page.get_by_role("combobox", name=re.compile(r"^External data time unit")).select_option("days")
    await page.get_by_role("button", name="Run prediction", exact=True).click()
    await expect(page.get_by_text(re.compile("Time-unit mismatch")).first).to_be_visible()
    await page.get_by_role("combobox", name=re.compile(r"^External data time unit")).select_option("years")
    await page.get_by_role("button", name="Run prediction", exact=True).click()
    await expect(page.get_by_role("cell", name="9007199254740993123", exact=True)).to_be_visible()


async def cancellation_review(page, bridge):
    await page.get_by_role("button", name="Results & history", exact=True).click()
    bridge.mutation_mode = "unverified"
    await page.get_by_role("button", name="Regenerate reports", exact=True).click()
    first_id = bridge.active
    assert first_id
    await page.get_by_role("button", name="Cancel operation", exact=True).click()
    await expect(page.get_by_role("button", name="Retry cancellation", exact=True)).to_be_visible()
    await expect(page.get_by_text(re.compile("Synthetic test diagnostic")).first).to_be_visible()
    await expect(page.get_by_text("Operation active", exact=True)).to_be_visible()
    await page.get_by_role("button", name="Prediction & evaluation", exact=True).click()
    await expect(page.get_by_role("button", name="Run prediction", exact=True)).to_be_disabled()
    bridge.mutation_mode = "delayed"
    await page.get_by_role("button", name="Retry cancellation", exact=True).click()
    await expect(page.get_by_text("Workspace ready", exact=True)).to_be_visible()
    await page.get_by_role("button", name="Results & history", exact=True).click()
    await page.get_by_role("button", name="Regenerate reports", exact=True).click()
    assert bridge.active and bridge.active != first_id
    await bridge.emit(first_id, "report", "complete", bridge.snapshots[first_id]["response"])
    await expect(page.get_by_text("Operation active", exact=True)).to_be_visible()
    await page.get_by_role("button", name="Cancel operation", exact=True).click()
    await expect(page.get_by_text("Workspace ready", exact=True)).to_be_visible()
    bridge.mutation_mode = "immediate"


async def pathway_review(page, bridge):
    await page.get_by_role("button", name="Pathways & evidence", exact=True).click()
    await page.locator("summary").filter(has_text="Open a saved pathway directory").click()
    await page.get_by_role("textbox", name=re.compile(r"^Saved pathway run directory")).fill(str(bridge.pathway_run))
    await page.get_by_role("button", name="Open saved pathway run", exact=True).click()
    await expect(page.get_by_role("heading", name="Gene evidence explorer", exact=True)).to_be_visible()
    graph = json.loads((bridge.pathway_run / "graph.json").read_text())
    svg = page.get_by_role("img", name="Functional association network", exact=True)
    await svg.scroll_into_view_if_needed()
    assert await svg.locator("line").count() == len(graph["edges"])
    slider = page.get_by_role("slider", name="Minimum displayed confidence", exact=True)
    await slider.press("End")
    assert await svg.locator("line").count() == sum(edge["score"] >= 1 for edge in graph["edges"])
    await slider.press("Home")
    circle = svg.locator("circle").first
    await circle.scroll_into_view_if_needed()
    before = await circle.bounding_box()
    x, y = before["x"] + before["width"] / 2, before["y"] + before["height"] / 2
    await page.mouse.move(x, y)
    await page.mouse.down()
    await page.mouse.move(x + 30, y + 20, steps=3)
    await page.mouse.up()
    after = await circle.bounding_box()
    assert abs(after["x"] - before["x"] - 30) < 2, (before, after)
    assert abs(after["y"] - before["y"] - 20) < 2, (before, after)
    sources = {}
    for mapping in graph["assay_mapping"]:
        sources.setdefault(mapping["node_id"], []).append(mapping["source_id"])
    shared = [(node_id, genes) for node_id, genes in sources.items() if len(genes) > 1]
    assert shared, "Use a synthetic pathway fixture with a shared mapped node"
    for node_id, genes in shared:
        for gene in genes:
            await page.get_by_label("Search network genes", exact=True).fill(gene)
            node = None
            for candidate in await svg.locator("[data-node-id]").all():
                if await candidate.get_attribute("data-node-id") == node_id:
                    node = candidate
                    break
            assert node is not None, (node_id, gene)
            await node.press("Enter")
            await expect(page.locator(".gene-detail").get_by_role("heading", name=gene, exact=True)).to_be_visible()
    await page.get_by_label("Search network genes", exact=True).fill("not_a_real_gene_832933")
    assert await svg.locator("circle").count() == 0
    await page.get_by_label("Search network genes", exact=True).fill("")


async def main(args):
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="bmp-desktop-browser-") as temporary:
        bridge = DesktopBridge(root, args.rscript, temporary, args.development_run,
                               args.survival_run, args.pathway_run)
        history = bridge.directory / "history"
        for run in [bridge.development_run, bridge.survival_run]:
            shutil.copytree(run, history / "runs" / run.name)
        bridge.settings["outputRoot"] = str(history)
        async with async_playwright() as playwright:
            options = {"headless": True, "args": ["--no-sandbox"]}
            if args.chromium:
                options["executable_path"] = str(args.chromium)
            browser = await playwright.chromium.launch(**options)
            page = await browser.new_page(viewport={"width": 1280, "height": 900})
            page.set_default_timeout(30000)
            errors = []
            page.on("pageerror", lambda error: errors.append(str(error)))
            await bridge.attach(page)
            try:
                await page.goto(args.url)
                await setup_review(page, bridge)
                await history_review(page, bridge)
                await prediction_review(page, bridge)
                await cancellation_review(page, bridge)
                await pathway_review(page, bridge)
                assert await page.evaluate("document.documentElement.scrollWidth <= innerWidth"), "Page overflow"
                if args.screenshot:
                    await page.screenshot(path=str(args.screenshot), full_page=True)
                    await page.get_by_role("img", name="Functional association network", exact=True).scroll_into_view_if_needed()
                    await page.screenshot(path=str(args.screenshot.with_name(args.screenshot.stem + "-network.png")))
                await page.set_viewport_size({"width": 720, "height": 900})
                assert await page.evaluate("document.documentElement.scrollWidth <= innerWidth"), "Narrow page overflow"
                assert not errors, errors
            except BaseException:
                if args.screenshot:
                    await page.screenshot(path=str(args.screenshot.with_suffix(".failure.png")), full_page=True)
                    args.screenshot.with_suffix(".failure.txt").write_text(await page.locator("body").inner_text(), encoding="utf-8")
                raise
            finally:
                if args.log:
                    args.log.write_text(json.dumps(bridge.calls, ensure_ascii=False, indent=2), encoding="utf-8")
                await browser.close()
    print("Desktop browser review passed: real CLI QC/prediction/evaluation, IDs, history/comparison, job races and mapped network interaction.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:5178")
    parser.add_argument("--rscript", type=Path, required=True)
    parser.add_argument("--development-run", type=Path, required=True)
    parser.add_argument("--survival-run", type=Path, required=True)
    parser.add_argument("--pathway-run", type=Path, required=True)
    parser.add_argument("--chromium", type=Path)
    parser.add_argument("--screenshot", type=Path)
    parser.add_argument("--log", type=Path)
    asyncio.run(main(parser.parse_args()))
