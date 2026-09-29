# First Mate document visibility

First Mate full-feature snapshots retain every document returned by the companion. A managed session handoff creates both a durable handoff record and a checkpoint document; the handoff record's `document_id` is the canonical provenance link between them.

Native Mac, iPhone, and iPad document lists omit documents whose exact IDs are referenced by snapshot handoff records. Counts, workflow document menus, search, and empty states use the same presentation policy. Titles and content are never used to classify a handoff, so a user document called “Session handoff” remains visible unless a handoff record references its ID.

This is presentation-only. The raw document and handoff arrays remain in native state, and the companion continues to retain and return both. Recovery/checkpoint tracking and direct document lookup therefore keep access to the exact handoff artifact. A legacy snapshot with no `handoffs` field presents every document rather than guessing from its title.
