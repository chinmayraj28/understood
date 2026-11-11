// The address says which page is open; older links keep working.
import { describe, expect, it } from "vitest";
import { href, parseRoute } from "../../src/router";

describe("routes", () => {
  it("opens the landing page by default and on its sections", () => {
    expect(parseRoute("")).toEqual({ page: "landing" });
    expect(parseRoute("#/")).toEqual({ page: "landing" });
    expect(parseRoute("#/how")).toEqual({ page: "landing", section: "how" });
    expect(parseRoute("#/results")).toEqual({ page: "landing", section: "results" });
    expect(parseRoute("#/nonsense")).toEqual({ page: "landing" });
  });

  it("opens the pipeline and recordings pages", () => {
    expect(parseRoute(href.pipeline)).toEqual({ page: "pipeline" });
    expect(parseRoute(href.recordings)).toEqual({ page: "recordings" });
  });

  it("hears a clip from a link, new or old", () => {
    expect(parseRoute(href.hear("F03-S3-0012"))).toEqual({ page: "pipeline", hearClip: "F03-S3-0012" });
    expect(parseRoute("#hear=F03-S3-0012")).toEqual({ page: "pipeline", hearClip: "F03-S3-0012" });
  });

  it("opens the pipeline without a clip when a hear link is badly encoded, instead of a blank page", () => {
    expect(() => parseRoute("#hear=%E0")).not.toThrow();
    expect(parseRoute("#hear=%E0")).toEqual({ page: "pipeline" });
    expect(parseRoute("#/pipeline?hear=%E0").page).toBe("pipeline");
  });

  it("opens the privacy section", () => {
    expect(parseRoute("#/privacy")).toEqual({ page: "landing", section: "privacy" });
  });

  it("keeps the old recordings address", () => {
    expect(parseRoute("#dataset")).toEqual({ page: "recordings" });
    expect(parseRoute("#dataset-title")).toEqual({ page: "recordings" });
  });
});
