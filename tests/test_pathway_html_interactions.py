#!/usr/bin/env python3
"""Targeted standalone HTML regression: SVG transforms and exact source IDs.

Pass a completed synthetic report containing a node mapped to multiple source
genes. Requires optional Playwright/Chromium; does not mutate saved run artifacts.
"""
import argparse
import json
from pathlib import Path
import tempfile

from playwright.sync_api import sync_playwright


def box_center(locator):
    box = locator.bounding_box()
    return box, box["x"] + box["width"] / 2, box["y"] + box["height"] / 2


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("report", type=Path)
    parser.add_argument("--chromium", type=Path)
    args = parser.parse_args()
    source = args.report.read_text()
    marker = "<script type='application/json' id='payload'>"
    prefix, remainder = source.split(marker, 1)
    serialized, suffix = remainder.split("</script>", 1)
    payload = json.loads(serialized)
    groups = {}
    for relation in payload["graph"]["assay_mapping"]:
        groups.setdefault(relation["node_id"], []).append(relation["source_id"])
    node_id, genes = next((node, genes) for node, genes in groups.items() if len(genes) > 1)
    unusual = "source;with;semicolons_9157"
    for relation in payload["graph"]["assay_mapping"]:
        if relation["source_id"] == genes[0]:
            relation["source_id"] = unusual
    for row in payload["evidence"]:
        if row["gene"] == genes[0]:
            row["gene"] = unusual
    # query_genes deliberately retains the old semicolon display string:
    # interaction must use the exact structured node/source relation instead.
    encoded = json.dumps(payload).replace("<", "\\u003c").replace(">", "\\u003e")
    fixture = prefix + marker + encoded + "</script>" + suffix

    with tempfile.TemporaryDirectory(prefix="bmp-html-interactions-") as directory:
        path = Path(directory) / "report.html"
        path.write_text(fixture)
        with sync_playwright() as playwright:
            launch = {"headless": True, "args": ["--no-sandbox"]}
            if args.chromium:
                launch["executable_path"] = str(args.chromium)
            browser = playwright.chromium.launch(**launch)
            page = browser.new_page(viewport={"width": 1440, "height": 1000})
            errors = []
            page.on("pageerror", lambda error: errors.append(str(error)))
            page.goto(path.as_uri())
            svg = page.locator("#network")
            for gene in (unusual, genes[1]):
                page.locator("#search").fill(gene)
                node = page.locator(f'#network [data-node-id="{node_id}"]')
                assert node.count() == 1, gene
                node.locator("circle").click()
                assert json.loads(page.locator("#details").inner_text())["gene"] == gene
            page.locator("#search").fill("")
            page.locator(f'#network [data-node-id="{node_id}"] circle').click()
            details = json.loads(page.locator("#details").inner_text())
            assert {row["gene"] for row in details["source_gene_evidence"]} == {unusual, genes[1]}

            for width in (1440, 860):
                page.set_viewport_size({"width": width, "height": 1000})
                svg.scroll_into_view_if_needed()
                circle = svg.locator("circle").first
                before, x, y = box_center(circle)
                page.mouse.move(x + 2, y + 2)
                page.mouse.down()
                page.mouse.move(x + 32, y + 22, steps=3)
                page.mouse.up()
                after = circle.bounding_box()
                assert abs(after["x"] - before["x"] - 30) < 1, (before, after)
                assert abs(after["y"] - before["y"] - 20) < 1, (before, after)

                # A cancelled pointer and lost capture must both terminate drag.
                for cancellation in ("pointercancel", "lostpointercapture"):
                    before, x, y = box_center(circle)
                    page.mouse.move(x, y)
                    page.mouse.down()
                    svg.evaluate(
                        "(svg, eventType) => svg.dispatchEvent(new PointerEvent(eventType, "
                        "{pointerId:1, pointerType:'mouse', bubbles:true}))",
                        cancellation,
                    )
                    page.mouse.move(x + 25, y + 15, steps=2)
                    page.mouse.up()
                    after = circle.bounding_box()
                    assert abs(after["x"] - before["x"]) < 0.1, (cancellation, before, after)
                    assert abs(after["y"] - before["y"]) < 0.1, (cancellation, before, after)
            assert not errors, errors
            browser.close()
    print("Pathway HTML interaction tests passed: wide/narrow SVG drag, cancellation, exact semicolon IDs and shared-node evidence.")


if __name__ == "__main__":
    main()
