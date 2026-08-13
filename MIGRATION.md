# Migrating to the split report shape

> Türkçe sürüm: [`MIGRATION.tr.md`](MIGRATION.tr.md).

For anyone writing reports into the Collie Firestore **without** the Collie SDK — a host app
with its own reporter that produces the same documents. If you use the SDK, updating it is
the whole migration and this file is only background.

The change: **the raw log stream moves out of the report document into its own document.**

Two things are covered here. The split is the required one — do it and the panel's list gets
fast again. [Session context](#optional-session-context-the-panels-collapsible-history) at
the end is optional and independent: it is what lets the panel fold a report's inherited
history instead of making an analyst scroll past it.

---

## Why

The analyst panel's list screen shows four things per report — status, the tester's
sentence, the device, the date. To paint that it reads `collie_reports`.

Firestore's web SDK cannot fetch a subset of a document's fields. There is no `select()`; a
document arrives whole or not at all. So every field inside the report document was
downloaded to render those four columns — including `entries`, the complete captured log
stream with every request and response body in it.

That alone would be wasteful. What made it a real problem is how testers work: they never
close the app. The log stream is tied to the process, so the tenth report from a device
that has been running for three days carries the previous nine reports' traffic as well as
its own. Report documents therefore **grow over time**, and the list got measurably slower
with every report filed — the complaint was "it keeps getting slower", and this was why.

The screenshot had already been split out for exactly this reason (`collie_report_screenshots`).
The stream now follows the same pattern, and for the same reason.

Two things fall out of it:

- The panel's list query moves small documents, so it can page instead of loading everything.
- A report whose stream is close to Firestore's 1 MiB document cap no longer risks being
  rejected for the size of its logs, because the two halves are bounded separately.

---

## What changes on the wire

Before — one document:

```
collie_reports/{reportId}
  appKey, status, hasScreenshot, clientReportId, createdAt,
  app, device, report, telemetry,
  entries: [ … the whole stream … ]     ← the problem
```

After — two documents, same id:

```
collie_reports/{reportId}
  appKey, status, hasScreenshot, clientReportId, createdAt,
  app, device, report, telemetry        ← no entries

collie_report_entries/{reportId}
  appKey                                ← repeated, see below
  entries: [ … the whole stream … ]
  createdAt
```

`appKey` is repeated on the entries document on purpose: the security rules scope that
collection on its own. A rule that had to read the parent report would cost an extra read
per write **and** fail on the very first write, when the parent does not exist yet.

Everything else is unchanged — same collection names, same report id as document id, same
field names inside `app` / `device` / `report` / `telemetry`, same screenshot document.

---

## How to migrate

### 1. Write the stream first, then the report

Order matters. The report document is what the panel discovers; it must never point at a
stream that has not been written yet. This is the same ordering the screenshot already has.

```
1. write collie_report_screenshots/{reportId}   (if there is one)
2. write collie_report_entries/{reportId}       ← new
3. write collie_reports/{reportId}              (without `entries`)
```

If step 2 fails **transiently** (offline, timeout, unavailable), retry the whole report
later — do not write the report document. If it fails **permanently** (permission denied,
because the rules have not been deployed yet), fall back to the old shape: put `entries`
back inside the report document and write it. A large document is a performance problem; a
report whose stream was silently dropped is a lost bug.

### 2. Remove the field, do not blank it

The `entries` field must be **absent** from the report document — not `entries: []`.

The panel decides where to read the stream from with "does the report document have an
`entries` field?", because an empty array is a legitimate answer: a report with no captured
logs. Writing `[]` makes the panel believe that is the whole stream, and the report shows up
with no logs at all.

If you write with a merge/patch operation and the document may already exist from an earlier
attempt (a retry after your app updated), delete the field explicitly — `FieldValue.delete()`
in the Firebase SDKs — or the old inline copy survives the merge.

### 3. Keep the ids identical

`collie_report_entries/{reportId}` uses the **same document id** as the report. That is what
makes a retry overwrite rather than duplicate, and it is how the panel finds the stream: it
does not query, it reads that one document id.

### 4. Deploy the security rules first

The rules ship with Collie: `Integration/firestore.rules`. Two things in them matter here.

- `collie_report_entries` needs its own block — without it every write to the new collection
  is denied and your reporter falls back to inline forever (correct, but you gain nothing).
- The report shape check no longer **requires** `entries`. If you deploy a reporter that
  omits the field while the old rules are live, every report is rejected.

So: rules first, then the client. In the other order you get a window where nothing can be
filed at all.

### 5. Leave old reports alone

No backfill is needed. The panel reads both shapes — inline first when the field is present,
the separate document otherwise — so reports already in Firestore keep opening exactly as
they did. They are also short-lived: a report is deleted once it has been pushed to Jira and
its retention window passes.

---

## Checklist

- [ ] `Integration/firestore.rules` deployed, including the `collie_report_entries` block
- [ ] Reporter writes `collie_report_entries/{reportId}` with `appKey` + `entries` (+ `createdAt`)
- [ ] Report document no longer contains `entries` — the field is **absent**, not empty
- [ ] Entries document is written **before** the report document
- [ ] Transient failure → retry the whole report; permanent failure → fall back to inline
- [ ] Retries reuse the same report id for all three documents
- [ ] Filed a test report and confirmed in the panel: it opens, the log stream is there, the
      network and navigation lists are populated

The last one is the one that catches mistakes the others miss — an empty log list on a
report that clearly captured traffic means the panel found an `entries: []` where it
expected either a real stream or an absent field.

---

## Optional: session context (the panel's collapsible history)

Not part of the split — a separate, older addition (SDK 1.14.0 / android-0.3.0) that your
reporter probably does not send yet. Skip it and reports still work; send it and the panel
stops burying the part of the report that is actually new.

### The problem it solves

Testers do not kill the app. The log stream lives as long as the process, so the tenth
report from a device carries the previous nine reports' navigation and traffic as well as
its own — and the handful of lines the bug is actually about sit at the bottom of hundreds
that are not. This is the same fact that made report documents grow; here it is about
*reading* one report rather than listing many.

The fix is presentational and lossless: the panel collapses everything older than a
boundary into a block that opens with one click, and leaves the newer part open. Nothing is
dropped — the `appConfig` or `login` call fired once at session start is inside the
collapsed block, not gone.

### The fields

Five **optional** fields inside the `report` block:

| Field | Type | Meaning |
|---|---|---|
| `previousReportAt` | ISO-8601 | `capturedAt` of this device's previous report. Absent on the first one. |
| `sessionStartedAt` | ISO-8601 | Start of the current logical session. |
| `processStartedAt` | ISO-8601 | When the process started — i.e. how long the app has been alive. |
| `sessionOrdinal` | int, 1-based | Which logical session this is. |
| `sequence` | int, 1-based | Which report this is from this device. |

The panel takes the fold boundary from **`previousReportAt`, falling back to
`sessionStartedAt`** for a device's first report. Send neither and there is no boundary, so
the report renders exactly as it does today — which is why these must stay optional: reports
already in Firestore carry none of them.

`processStartedAt`, `sessionOrdinal` and `sequence` do not move the fold. They are what the
panel prints above the lists ("3. rapor · 2. oturum · 3 gündür açık") — the context that
explains *why* a report opens folded.

### Three rules that make or break it

1. **Every timestamp needs a UTC offset.** The boundary is found by comparing
   `previousReportAt` against entry timestamps. A stamp without an offset is read in the
   analyst's browser timezone and slides the fold by hours — silently, and in a way that
   looks like a data problem rather than a formatting one.

2. **`sequence`, `sessionOrdinal` and `previousReportAt` must survive a process kill.**
   Persist them (`UserDefaults` / `SharedPreferences` / equivalent) and update
   `previousReportAt` to the report's own `capturedAt` after a successful submission.
   `processStartedAt` is the one field that deliberately resets with the process.

3. **A logical session restarts after a long background, not on every resume.** Collie uses
   a **30-minute** background threshold, identical on both platforms — it is what tells "the
   tester came back after lunch" apart from "the tester switched apps for ten seconds". Pick
   the same value; a threshold that differs makes the same tester behaviour fold at
   different points, and nothing on screen can tell that apart from a real difference.

### Session markers (recommended)

Collie also injects synthetic entries into the stream, at their chronological positions,
all with `category: "collie"` — the panel renders those as a labelled rule rather than a log
row, so an analyst can see the session boundaries on the timeline:

| Timestamp | `message` |
|---|---|
| `processStartedAt` | `Session started — <formatted date>` |
| `previousReportAt` | `Previous report submitted` |
| each resume | `Session resumed after <n> min background` |

The middle one matters most and needs its timestamp to be **exactly** `previousReportAt`:
the panel keeps an entry equal to the boundary on the *new* side of the fold, so the marker
lands directly under the collapsed block as the line that shows where the previous report
ended.

Markers are inserted **without reordering, dropping or rewriting a single host entry** —
each one goes after every entry at or before its own timestamp. The stream stays lossless.

### What it looks like downstream

In the panel the older half is one collapsed line. In the Jira issue it cannot be: Jira Data
Center's wiki renderer has no collapsible macro at all (`{expand}` is a *Confluence* macro,
and the request to add one to Jira was closed "Won't Fix"). So the panel puts that half
under an "Önceki bağlam" heading **below** this report's own rows instead — same content,
positioned so it cannot bury the requests the ticket is about.

---

## Firestore indexes (panel side)

Not part of the client change, but the same migration: the panel's paged list needs two
composite indexes on `collie_reports`.

| Fields | Used by |
|---|---|
| `appKey` ASC, `createdAt` DESC | The list query for a non-admin analyst |
| `appKey` ASC, `bridgedAt` ASC | The retention sweep |

Note also that the list is now ordered by `createdAt`. Firestore omits documents that lack
the ordering field from a query entirely — so **every report must carry `createdAt`**, or it
will not appear in the panel at all.
