/** Media-time ink. Geometry follows the rendered code, including while paused. */
export interface GuideTarget { path: string; side: "before" | "after"; startLine: number; endLine: number }
export interface TimedCue {
  id: string; shape: "circle" | "underline" | "arrow" | "highlight";
  targets: GuideTarget[]; onset: number; drawSeconds: number; until?: number;
}
export interface GuideFrame {
  identity: string; generation: string; sequence: number; time: number;
  cues: TimedCue[]; reducedMotion?: boolean;
}
export interface GuidePreparation { identity: string; generation: string; targets: GuideTarget[] }
interface Rect { x: number; y: number; w: number; h: number }
const clamp = (n: number) => Math.max(0, Math.min(1, n));
export function validTarget(t: GuideTarget) {
  return t && typeof t.path === "string" && t.path.length > 0 && ["before", "after"].includes(t.side)
    && Number.isInteger(t.startLine) && Number.isInteger(t.endLine) && t.startLine > 0
    && t.endLine >= t.startLine && t.endLine - t.startLine < 200;
}
export function sampleCues(frame: GuideFrame) {
  if (!Number.isFinite(frame.time) || frame.time < 0 || !Array.isArray(frame.cues)) return [];
  return frame.cues.filter(c => typeof c.id === "string" && ["circle", "underline", "arrow", "highlight"].includes(c.shape)
    && Number.isFinite(c.onset) && c.onset >= 0 && Number.isFinite(c.drawSeconds) && c.drawSeconds > 0
    && Array.isArray(c.targets) && c.targets.length === (c.shape === "arrow" ? 2 : 1) && c.targets.every(validTarget)
    && c.targets.every(t => t.path === c.targets[0].path)
    && (c.until == null || (Number.isFinite(c.until) && c.until >= c.onset + c.drawSeconds))
    && frame.time >= c.onset && (c.until == null || frame.time < c.until))
    .map(cue => ({cue, progress: frame.reducedMotion ? 1 : clamp((frame.time - cue.onset) / cue.drawSeconds)}));
}
/** Same media-clock path vocabulary as the working NarratedGuide prototype. */
export function drawingPath(shape: TimedCue["shape"], rects: Rect[]) {
  const {x,y,w,h} = rects[0];
  if (shape === "circle") return `M ${x+w*.12} ${y+1} C ${x+w*.4} ${y-5},${x+w} ${y-2},${x+w+4} ${y+h*.38} C ${x+w+12} ${y+h+8},${x+w*.2} ${y+h+7},${x-2} ${y+h*.7} C ${x-12} ${y+h*.3},${x+w*.05} ${y-1},${x+w*.34} ${y-2}`;
  if (shape === "underline") return `M ${x} ${y+h} Q ${x+w*.4} ${y+h+5} ${x+w} ${y+h-1} M ${x+5} ${y+h+4} Q ${x+w*.6} ${y+h+7} ${x+w-12} ${y+h+3}`;
  if (shape === "highlight") return `M ${x} ${y} h ${w} v ${h} h ${-w} Z`;
  const b=rects[1], start=x+w+8, end=b.x+b.w+8, right=Math.max(start,end)+27, by=b.y+b.h/2;
  return `M ${start} ${y+h/2} C ${right} ${y+h/2},${right} ${by},${end} ${by} M ${end+6} ${by-5} l -6 5 6 5`;
}
export function targetLineNumber(line: HTMLElement, side: GuideTarget["side"]) {
  const deletion = ["deletion", "change-deletion"].includes(line.dataset.lineType ?? "");
  return side === "before" ? Number(deletion ? line.dataset.line : line.dataset.altLine)
    : deletion ? NaN : Number(line.dataset.line);
}
export function resolveTargetLines(target: GuideTarget, lines: HTMLElement[], path: string): HTMLElement[] {
  if (!validTarget(target) || target.path !== path) return [];
  const resolved: HTMLElement[] = [];
  for (let n=target.startLine; n<=target.endLine; n++) {
    const line = lines.find(el => targetLineNumber(el, target.side) === n);
    if (!line) return []; // A missing line is never mapped to its neighbor.
    resolved.push(line);
  }
  return resolved;
}
export class NativeGuideAnnotations {
  private frame: GuideFrame | null = null;
  private enabled = true;
  private generation = "";
  private sequence = -1;
  private svg: SVGSVGElement | null = null;
  private scheduled = 0;
  private resize: ResizeObserver;
  private observed: Element | null = null;
  constructor(private current: () => {identity:string;path:string}|null, private lines: () => HTMLElement[]) {
    this.resize = new ResizeObserver(() => this.refresh());
    window.addEventListener("scroll", () => this.refresh(), {passive:true,capture:true});
    window.addEventListener("resize", () => this.refresh(), {passive:true});
    window.matchMedia("(prefers-reduced-motion: reduce)").addEventListener("change", () => this.refresh());
  }
  setEnabled(enabled: boolean) { this.enabled=enabled; this.refresh(); }
  reset() {  this.frame=null; this.generation=""; this.sequence=-1; this.svg?.replaceChildren(); }
  prepare(request: GuidePreparation) {
    if (request.identity !== this.current()?.identity || !Array.isArray(request.targets)) return false;
    this.generation=request.generation; this.sequence=-1; this.frame=null; this.svg?.replaceChildren();
    const groups=request.targets.map(t => resolveTargetLines(t,this.lines(),this.current()!.path));
    const ready=groups.every(g => g.length>0);
    if (ready) groups[0]?.[0]?.scrollIntoView({block:"center",inline:"nearest",behavior:"instant"});
    return ready;
  }
  update(frame: GuideFrame) {
    if (frame.identity !== this.current()?.identity || frame.generation !== this.generation
      || !Number.isInteger(frame.sequence) || frame.sequence <= this.sequence) return;
    this.sequence=frame.sequence; this.frame=frame;
    // Native samples are already bounded to 30 Hz. Apply them immediately;
    // background WebKit pages can throttle animation callbacks independently.
    this.draw();
  }
  refresh() {
    // Coalesce into the pending paint. Rescheduling every audio sample can
    // starve a throttled WebKit surface whose paint rate is below 30 Hz.
    if (this.scheduled) return;
    this.scheduled=requestAnimationFrame(() => { this.scheduled=0; this.draw(); });
  }
  private draw() {
    const host=document.querySelector("diffs-container");
    if (host !== this.observed) { this.resize.disconnect(); if(host) this.resize.observe(host); this.observed=host; }
    if (!this.svg) {
      this.svg=document.createElementNS("http://www.w3.org/2000/svg","svg");
      this.svg.setAttribute("class","native-guide-ink"); this.svg.setAttribute("aria-hidden","true");
      document.body.append(this.svg);
    }
    this.svg.setAttribute("viewBox",`0 0 ${window.innerWidth} ${window.innerHeight}`);
    this.svg.replaceChildren();
    const current=this.current(), frame=this.frame;
    if (!this.enabled || !current || !frame || current.identity!==frame.identity) return;
    const entries=sampleCues({...frame,reducedMotion:frame.reducedMotion || window.matchMedia("(prefers-reduced-motion: reduce)").matches});
    const lines=this.lines();
    for (const {cue,progress} of entries) {
      const groups=cue.targets.map(t => resolveTargetLines(t,lines,current.path));
      if(groups.some(g => g.length===0)) continue;
      const rects=groups.map(group => {
        // Measure code spans when available, avoiding the full-width line box.
        const bounds=group.map(el => {
          const range=document.createRange(); range.selectNodeContents(el); return range.getBoundingClientRect();
        }).filter(r=>r.width>0 && r.height>0);
        if (!bounds.length) return null;
        const left=Math.min(...bounds.map(r=>r.left)), top=Math.min(...bounds.map(r=>r.top));
        return {x:left-5,y:top-3,w:Math.max(...bounds.map(r=>r.right))-left+10,h:Math.max(...bounds.map(r=>r.bottom))-top+6};
      });
      if(rects.some(r=>r===null)) continue;
      const path=document.createElementNS("http://www.w3.org/2000/svg","path");
      path.setAttribute("d",drawingPath(cue.shape,rects as Rect[]));
      path.setAttribute("data-cue-id",cue.id); path.setAttribute("data-progress",progress.toFixed(4));
      path.setAttribute("vector-effect","non-scaling-stroke"); path.setAttribute("pathLength","1");
      if(cue.shape==="highlight") { path.style.fill="currentColor";path.style.fillOpacity=String(.18*progress);path.style.strokeOpacity=String(progress); }
      else {path.style.strokeDasharray="1 1";path.style.strokeDashoffset=String(1-progress);}
      this.svg.append(path);
    }
  }
}
