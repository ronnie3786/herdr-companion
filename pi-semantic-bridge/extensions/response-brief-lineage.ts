import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { registerSessionLineage } from "../lib/session-lineage.ts";

/** Persist only Herdr parent/child lineage for isolated response-brief runs. */
export default function responseBriefLineage(pi: ExtensionAPI): void {
	registerSessionLineage(pi);
}
