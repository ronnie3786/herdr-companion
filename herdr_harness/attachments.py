"""Bounded uploads and private, Herdr-owned attachment storage."""

from __future__ import annotations


MAX_ATTACHMENT_BYTES = 20 * 1024 * 1024
# A 20 MB payload expands to roughly 26.7 MB as base64. This limit includes
# the small surrounding JSON object while the rest of the API retains 1 MB.
MAX_ATTACHMENT_JSON_BYTES = 29 * 1024 * 1024


class AttachmentError(ValueError):
    def __init__(
        self,
        message: str,
        *,
        code: str = "invalid_attachment",
        status: int = 400,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.status = status


def store_attachment(*, workspace_id: str, filename: str, content_type: str, data: bytes, environ=None) -> dict:
    """Persist a bounded upload in Herdr-owned storage with private permissions.

    Workspace identifiers are opaque. Hash them into directory names instead of
    accepting them as paths; original filenames only appear in response metadata.
    """
    import hashlib
    import os
    import re
    import uuid
    from datetime import datetime, timezone
    from pathlib import Path

    if not isinstance(workspace_id, str) or not workspace_id or len(workspace_id) > 256 or any(ord(c) < 32 for c in workspace_id):
        raise AttachmentError("workspace is invalid")
    if not isinstance(data, bytes) or not data:
        raise AttachmentError("file is empty")
    if len(data) > MAX_ATTACHMENT_BYTES:
        raise AttachmentError("file exceeds 20 MB limit", code="attachment_too_large", status=413)
    if not isinstance(filename, str) or not filename or len(filename) > 512 or any(ord(c) < 32 for c in filename):
        raise AttachmentError("filename is invalid")
    if not isinstance(content_type, str) or len(content_type) > 255 or any(ord(c) < 32 for c in content_type):
        raise AttachmentError("content_type is invalid")
    content_type = content_type.strip() or "application/octet-stream"
    env = os.environ if environ is None else environ
    home = Path(env.get("HOME") or Path.home()).expanduser()
    root = Path(env.get("HERDR_HARNESS_ATTACHMENTS_DIR") or home / ".local" / "share" / "herdr-harness" / "attachments").expanduser()
    workspace_key = hashlib.sha256(workspace_id.encode()).hexdigest()
    attachment_id = uuid.uuid4().hex
    safe_name = re.sub(r"[^A-Za-z0-9._-]", "_", Path(filename.replace("\\", "/")).name)[:120].strip(".") or "attachment"
    stored_name = f"{attachment_id}-{safe_name}"
    descriptor = None
    root_descriptor = None
    workspace_descriptor = None
    try:
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
        # Directory descriptors and O_NOFOLLOW prevent a swapped workspace
        # symlink from redirecting an upload outside Herdr's storage directory.
        root_descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.mkdir(workspace_key, mode=0o700, dir_fd=root_descriptor)
        except FileExistsError:
            pass
        workspace_descriptor = os.open(workspace_key, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root_descriptor)
        descriptor = os.open(stored_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=workspace_descriptor)
        with os.fdopen(descriptor, "wb") as stream:
            descriptor = None
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        stored_path = str(root.resolve() / workspace_key / stored_name)
    except OSError as exc:
        raise AttachmentError("Could not store the attachment", code="attachment_storage_failed", status=503) from exc
    finally:
        for handle in (descriptor, workspace_descriptor, root_descriptor):
            if handle is not None:
                os.close(handle)
    return {
        "id": attachment_id, "filename": stored_name, "original_filename": filename,
        "content_type": content_type, "size": len(data), "path": stored_path,
        "workspace_id": workspace_id, "created_at": datetime.now(timezone.utc).isoformat(),
    }
