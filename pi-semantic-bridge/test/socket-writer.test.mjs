import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import test from "node:test";
import { setTimeout as delay } from "node:timers/promises";
import { createJiti } from "jiti";

const { SocketWriter } = await createJiti(import.meta.url).import("../lib/socket-writer.ts");

class TestSocket extends EventEmitter {
	writable = true;
	writableLength = 0;
	destroyed = false;
	accepted = [];
	results = [];
	endCount = 0;
	write(bytes) {
		const result = this.results.shift() ?? true;
		if (result instanceof Error) throw result;
		this.accepted.push(bytes.toString());
		if (!result) this.writableLength += bytes.length;
		return result;
	}
	drain() {
		this.writableLength = 0;
		this.emit("drain");
	}
	destroy() {
		if (this.destroyed) return;
		this.destroyed = true;
		this.writable = false;
		this.emit("close");
	}
	end() {
		this.endCount += 1;
		this.writable = false;
	}
}

test("large checkpoint followed by live deltas survives repeated backpressure in order", () => {
	const socket = new TestSocket();
	const writer = new SocketWriter(socket);
	socket.results = [false, false, true];
	const checkpoint = "x".repeat(390 * 1024);
	writer.write(Buffer.from(checkpoint));
	writer.write(Buffer.from("first delta"));
	writer.write(Buffer.from("second delta"));
	assert.equal(socket.destroyed, false);
	assert.deepEqual(socket.accepted, [checkpoint]);
	socket.drain();
	assert.deepEqual(socket.accepted, [checkpoint, "first delta"]);
	socket.drain();
	assert.deepEqual(socket.accepted, [checkpoint, "first delta", "second delta"]);
	assert.equal(socket.destroyed, false);
	socket.destroy();
});

test("byte bound includes both the socket buffer and pending application writes", () => {
	const socket = new TestSocket();
	const writer = new SocketWriter(socket, 8);
	socket.results = [false];
	writer.write(Buffer.from("1234"));
	writer.write(Buffer.from("5678"));
	assert.equal(socket.destroyed, false);
	writer.write(Buffer.from("9"));
	assert.equal(socket.destroyed, true);
	socket.drain();
	assert.deepEqual(socket.accepted, ["1234"]);
});

test("record bound also protects against many tiny queued updates", () => {
	const socket = new TestSocket();
	const writer = new SocketWriter(socket, 1024, 2);
	socket.results = [false];
	for (const value of ["a", "b", "c"]) writer.write(Buffer.from(value));
	assert.equal(socket.destroyed, false);
	writer.write(Buffer.from("d"));
	assert.equal(socket.destroyed, true);
	assert.deepEqual(socket.accepted, ["a"]);
});

test("one oversized write is rejected before being handed to the socket", () => {
	const socket = new TestSocket();
	new SocketWriter(socket, 8).write(Buffer.alloc(9));
	assert.equal(socket.destroyed, true);
	assert.deepEqual(socket.accepted, []);
});

test("shutdown drains accepted final events before EOF and ignores later writes", () => {
	const socket = new TestSocket();
	const writer = new SocketWriter(socket);
	socket.results = [false, false, true];
	for (const value of ["delta", "session_shutdown", "checkpoint"]) writer.write(Buffer.from(value));
	writer.finish();
	writer.write(Buffer.from("too late"));
	assert.equal(socket.endCount, 0);
	socket.drain();
	assert.equal(socket.endCount, 0);
	socket.drain();
	assert.deepEqual(socket.accepted, ["delta", "session_shutdown", "checkpoint"]);
	assert.equal(socket.endCount, 1);
	socket.destroy();
});

test("close and write failures discard pending data without escaping into Pi", () => {
	for (const failure of ["close", "error", "throw"]) {
		const socket = new TestSocket();
		const writer = new SocketWriter(socket);
		socket.results = [false, new Error("synthetic write failure")];
		writer.write(Buffer.from("first"));
		writer.write(Buffer.from("queued"));
		if (failure === "close") socket.destroy();
		else if (failure === "error") socket.emit("error", new Error("synthetic peer failure"));
		else socket.drain();
		assert.equal(socket.destroyed, true);
		socket.drain();
		writer.write(Buffer.from("late"));
		assert.deepEqual(socket.accepted, ["first"]);
	}
});

test("a permanently stalled reader is released without requiring another update", async () => {
	const socket = new TestSocket();
	const writer = new SocketWriter(socket, 1024, 10, 10);
	socket.results = [false];
	writer.write(Buffer.from("waiting"));
	await delay(30);
	assert.equal(socket.destroyed, true);
});

test("a recovered writer cancels its stall deadline", async () => {
	const socket = new TestSocket();
	const writer = new SocketWriter(socket, 1024, 10, 10);
	socket.results = [false];
	writer.write(Buffer.from("waiting"));
	socket.drain();
	await delay(30);
	assert.equal(socket.destroyed, false);
	writer.write(Buffer.from("later"));
	assert.deepEqual(socket.accepted, ["waiting", "later"]);
	socket.destroy();
});
