import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { EmbeddedGitTargetError } from "./App";

describe("embedded Git route errors", () => {
  it("renders an explicit target error instead of the unrelated Herdr shell", () => {
    const html = renderToStaticMarkup(
      <EmbeddedGitTargetError message="Choose exactly one pane or First Mate Git target." />,
    );
    expect(html).toContain('role="alert"');
    expect(html).toContain("Git target unavailable");
    expect(html).toContain("Choose exactly one pane or First Mate Git target.");
    expect(html).not.toContain("herdr-sidebar");
  });
});
