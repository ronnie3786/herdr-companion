import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { SharedDiffRenderer } from "./SharedDiffRenderer";

const patch = `diff --git a/Garden.swift b/Garden.swift
--- a/Garden.swift
+++ b/Garden.swift
@@ -1,2 +1,2 @@
-let seed = 1
+let seed = 2
 return seed
`;

describe("shared inline annotation slots", () => {
  it.each(["unified", "split"] as const)("preserves side-specific annotation slots in %s view", (diffStyle) => {
    const html = renderToStaticMarkup(
      <SharedDiffRenderer file="Garden.swift" patch={patch} diffStyle={diffStyle}
        lineAnnotations={[
          { side: "deletions", lineNumber: 1, metadata: "Human: old seed" },
          { side: "additions", lineNumber: 1, metadata: "Agent: <script>unsafe()</script>" },
        ]}
        renderAnnotation={({ metadata }) => <article>{metadata}</article>} />,
    );
    expect(html).toContain('slot="annotation-deletions-1"');
    expect(html).toContain('slot="annotation-additions-1"');
    expect(html).toContain("Human: old seed");
    expect(html).toContain("Agent: &lt;script&gt;unsafe()&lt;/script&gt;");
    expect(html).not.toContain("<script>");
  });

  it("keeps annotation-free consumers unchanged", () => {
    const html = renderToStaticMarkup(<SharedDiffRenderer file="Garden.swift" patch={patch} />);
    expect(html).toContain("diffs-container");
    expect(html).not.toContain("annotation-");
  });
});
