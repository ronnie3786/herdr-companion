import { describe, expect, it, vi } from "vitest";
import { NativeGuideAnnotations, drawingPath, resolveTargetLines, sampleCues, type GuideFrame, type GuideTarget } from "./nativeGuideAnnotations";
const target: GuideTarget = {path:"Sources/Catalog.swift",side:"after",startLine:40,endLine:41};
const frame: GuideFrame = {identity:"patch",generation:"audio",sequence:1,time:2.3,cues:[
  {id:"guard",shape:"circle",targets:[target],onset:2,drawSeconds:.6,until:5},
]};
describe("native guide clock", () => {
  it("reconstructs pause, backward seek, replay, expiry, and reduce motion from absolute audio time", () => {
    expect(sampleCues(frame)[0].progress).toBeCloseTo(.5);
    expect(sampleCues(frame)[0].progress).toBeCloseTo(.5);
    expect(sampleCues({...frame,time:1.9})).toEqual([]);
    expect(sampleCues({...frame,time:4})[0].progress).toBe(1);
    expect(sampleCues({...frame,time:5})).toEqual([]);
    expect(sampleCues({...frame,reducedMotion:true})[0].progress).toBe(1);
  });
  it("rejects cross-file arrows and malformed timing", () => {
    expect(sampleCues({...frame,cues:[{...frame.cues[0],shape:"arrow",targets:[target,{...target,path:"other.swift"}]}]})).toEqual([]);
    expect(sampleCues({...frame,cues:[{...frame.cues[0],drawSeconds:NaN}]})).toEqual([]);
    expect(sampleCues({...frame,cues:[{...frame.cues[0],until:2.1}]})).toEqual([]);
  });
  it("requires every exact line on the right side rather than guessing a nearby match", () => {
    const line=(n:number,kind="addition",old?:number) => ({dataset:{line:String(n),lineType:kind,altLine:old ? String(old) : undefined}} as unknown as HTMLElement);
    const lines=[line(40),line(41)];
    expect(resolveTargetLines(target,lines,target.path)).toEqual(lines);
    expect(resolveTargetLines(target,lines.slice(1),target.path)).toEqual([]);
    expect(resolveTargetLines(target,lines,"Sources/Other.swift")).toEqual([]);
    expect(resolveTargetLines({...target,side:"before"},lines,target.path)).toEqual([]);
    const context=[line(50,"context",40),line(51,"context",41)];
    expect(resolveTargetLines({...target,side:"before"},context,target.path)).toEqual(context);
  });
  it("keeps arrow geometry attached to both endpoints", () => {
    const path=drawingPath("arrow",[{x:10,y:20,w:100,h:20},{x:10,y:80,w:80,h:20}]);
    expect(path).toContain("M 118 30");
    expect(path).toContain("98 90");
  });
});


it("does not postpone a pending paint when the audio clock samples faster than WebKit paints", () => {
  const paint = vi.fn();
  let callback: FrameRequestCallback | undefined;
  const request = vi.fn((next: FrameRequestCallback) => { callback=next; return 1; });
  vi.stubGlobal("requestAnimationFrame", request);
  try {
    // Exercise scheduling without a DOM or a running WebView.
    const scheduler = Object.create(NativeGuideAnnotations.prototype);
    scheduler.scheduled = 0;
    scheduler.draw = paint;
    for (let sample=0; sample<30; sample++) scheduler.refresh();
    expect(request).toHaveBeenCalledTimes(1);
    callback!(1000);
    expect(paint).toHaveBeenCalledTimes(1);
    scheduler.refresh();
    expect(request).toHaveBeenCalledTimes(2);
  } finally { vi.unstubAllGlobals(); }
});

it("applies an authoritative media sample even when animation callbacks are suspended", () => {
  const renderer = Object.create(NativeGuideAnnotations.prototype);
  renderer.current = () => ({identity:"patch",path:target.path});
  renderer.generation = "audio";
  renderer.sequence = -1;
  renderer.draw = vi.fn();
  renderer.refresh = vi.fn();
  renderer.update(frame);
  expect(renderer.frame).toEqual(frame);
  expect(renderer.draw).toHaveBeenCalledTimes(1);
  expect(renderer.refresh).not.toHaveBeenCalled();
  renderer.update({...frame,sequence:0});
  expect(renderer.draw).toHaveBeenCalledTimes(1);
});
