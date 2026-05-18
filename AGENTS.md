# RemoteCode macOS Rules

- Browser parity is mandatory: every macOS browser URL change must emit host state so iOS mirrors the same target.
- External URLs, localhost/dev-server URLs, and macOS file URLs must stay synchronized between macOS and iOS.
- Browser target changes on either side must propagate to the paired side, or the control must stay host-driven/read-only.
- Do not add browser behavior that only works on one side without updating the other side in the same change.
- User workflow state must survive closing and reopening RemoteCode. Persist the user's active workspace, panes, selected tabs, browser URLs/titles, surface metadata, agent thread state, and other explicit user choices unless the user intentionally closes/deletes them.
