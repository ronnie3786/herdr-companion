import type { Socket } from "node:net";

/** Ordered, bounded writes without turning transient backpressure into EOF. */
export class SocketWriter {
	private pending: Buffer[] = [];
	private pendingBytes = 0;
	private blocked = false;
	private finishing = false;
	private closed = false;
	private deadline?: ReturnType<typeof setTimeout>;

	constructor(
		private readonly socket: Socket,
		private readonly maxBytes = 4 * 1024 * 1024,
		private readonly maxRecords = 2048,
		private readonly stallMilliseconds = 30_000,
	) {
		socket.on("drain", this.drain);
		socket.once("close", this.dispose);
		// A peer disappearing during a write must never terminate Pi's TUI.
		socket.on("error", this.fail);
	}

	write(bytes: Buffer): void {
		if (this.closed || this.finishing || this.socket.destroyed || !this.socket.writable) return;
		if (this.pendingBytes + this.socket.writableLength + bytes.length > this.maxBytes) {
			this.fail();
			return;
		}
		if (this.blocked) {
			if (this.pending.length >= this.maxRecords) {
				this.fail();
				return;
			}
			this.pending.push(bytes);
			this.pendingBytes += bytes.length;
			return;
		}
		this.send(bytes);
	}

	/** Shutdown preserves already accepted terminal events before sending EOF. */
	finish(): void {
		this.finishing = true;
		if (!this.closed && !this.blocked) this.socket.end();
	}

	private send(bytes: Buffer): void {
		try {
			if (!this.socket.write(bytes)) {
				// false means accepted, but wait for drain before writing again.
				this.blocked = true;
				this.deadline = setTimeout(this.fail, this.stallMilliseconds);
				this.deadline.unref();
			}
		} catch {
			this.fail();
		}
	}

	private drain = (): void => {
		if (this.closed) return;
		clearTimeout(this.deadline);
		this.deadline = undefined;
		this.blocked = false;
		while (!this.closed && !this.blocked && this.pending.length > 0) {
			const bytes = this.pending.shift()!;
			this.pendingBytes -= bytes.length;
			this.send(bytes);
		}
		if (!this.closed && !this.blocked && this.finishing) this.socket.end();
	};

	private fail = (): void => {
		this.dispose();
		this.socket.destroy();
	};

	private dispose = (): void => {
		this.closed = true;
		clearTimeout(this.deadline);
		this.deadline = undefined;
		this.pending = [];
		this.pendingBytes = 0;
		this.socket.off("drain", this.drain);
	};
}
