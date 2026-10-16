#!/usr/bin/env python3
"""Optional browser acceptance of a retained, synthetic pathway report.

Requires Playwright and Chromium; pass a completed report with network edges.
"""
import argparse
import json
from pathlib import Path

from playwright.sync_api import sync_playwright


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("report", type=Path)
    parser.add_argument("--chromium", type=Path)
    args = parser.parse_args()
    graph = json.loads((args.report.parent / "graph.json").read_text())
    assert graph["edges"], "Use a retained synthetic report with network edges."
    with sync_playwright() as playwright:
        options = {"headless": True, "args": ["--no-sandbox"]}
        if args.chromium:
            options["executable_path"] = str(args.chromium)
        browser = playwright.chromium.launch(**options)
        page = browser.new_page(viewport={"width": 1440, "height": 1000})
        errors = []
        page.on("pageerror", lambda error: errors.append(str(error)))
        page.goto(args.report.resolve().as_uri())
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        svg = page.locator("#network")
        svg.scroll_into_view_if_needed()
        original_edges = svg.locator("line").count()
        assert original_edges == len(graph["edges"])
        for threshold in (1, 0):
            page.locator("#confidence").evaluate(
                "(element, value) => {element.value=value; element.dispatchEvent(new Event('input'))}",
                threshold,
            )
            assert svg.locator("line").count() == sum(
                edge["score"] >= threshold for edge in graph["edges"]
            )

        # A wide SVG has letterboxing; screen-space dragging must still track the pointer.
        circle = svg.locator("circle").first
        before = circle.bounding_box()
        x, y = before["x"] + before["width"] / 2, before["y"] + before["height"] / 2
        page.mouse.move(x, y)
        page.mouse.down()
        page.mouse.move(x + 30, y + 20, steps=3)
        page.mouse.up()
        after = circle.bounding_box()
        assert abs(after["x"] - before["x"] - 30) < 2, (before, after)
        assert abs(after["y"] - before["y"] - 20) < 2, (before, after)

        # Every mapped source of a shared STRING node remains searchable.
        groups = {}
        for row in graph.get("assay_mapping", []):
            groups.setdefault(row["node_id"], []).append(row["source_id"])
        for sources in groups.values():
            if len(sources) < 2:
                continue
            for gene in sources:
                page.locator("#search").fill(gene)
                assert svg.locator("circle").count() > 0, gene
                page.get_by_role("button", name=gene, exact=True).click()
                assert json.loads(page.locator("#details").inner_text())["gene"] == gene
        page.locator("#search").fill("no_matching_gene_824593")
        assert svg.locator("circle").count() == 0
        assert page.locator("#genes tr").count() == 0
        assert not errors, errors
        browser.close()
    print("Pathway browser review passed: confidence filtering, screen-space drag, mapped-source search and details.")


if __name__ == "__main__":
    main()
