//! The release evidence table: what the release commit's CI runs did, rendered from the GitHub
//! Actions API's own answers, never typed (docs/releases/automation.md, "The evidence table").
//! Build-host tool, run by the release workflow's `draft` job with `zig run`:
//!
//!   release_evidence --product <owner/repo>@<sha> [--dependency <owner/repo>@<sha>]
//!       --gate <workflow> <workflow.yml> <runs.json> <jobs.json> [--gate ...]
//!       [--current <workflow> <workflow.yml> <run.json> <jobs.json> <job,job...>]
//!       [--allow-skip <job> <reason>]...
//!
//! `workflow.yml` is the workflow file the run ran: for `--gate`, every job it defines must be in
//! the run, by the name the API gives it (its `name:`, or its id, or one name per value of a
//! one-key matrix; `workflow_scan`), and the run must hold no other, so a job that is dropped or
//! renamed refuses rather than leaving one row fewer. A file that sets `continue-on-error`
//! refuses: the API reports a step that failed under it as `success` (recorded live,
//! `release_evidence/continue-on-error-*`), so the table could not tell it from a pass.
//!
//! `runs.json` is `GET /repos/{repo}/actions/workflows/{workflow}.yml/runs?head_sha=&event=push`
//! and `jobs.json` is `GET /repos/{repo}/actions/runs/{id}/jobs?per_page=100` for the newest of
//! those runs; the workflow fetches both with `gh api`, its token in the environment. This file
//! never touches the network, so a test feeds it recorded responses (`release_evidence/`).
//!
//! Every job gets one of three labels, and anything else refuses the table (exit 1, one line):
//!
//! - **passed**: the job succeeded and every one of its steps succeeded.
//! - **expected failure observed**: the job succeeded and the API reports a step of it as failed.
//!   A `continue-on-error` step is not reported so (see above), so the gates refuse that key.
//! - **skipped**: the job was skipped, or it succeeded with a step that did not run. 0.5.3's
//!   demo-m6d was green with its demo step skipped (no Google setup); that is "skipped", never
//!   "passed". A skipped step outranks a failed one: the gate did not run in full. Only a job
//!   given with `--allow-skip <job> <reason>` may be skipped, and its row reads
//!   "skipped (allowed: <reason>)"; any other skip refuses
//!   (docs/decisions/2026-11-18-release-skip-allowlist.md).
//!
//! A run that is not a completed success, a job that failed or was cancelled, a step that was
//! cancelled, a job that succeeded with no step of its own, a job listing that is not the newest
//! run's, or not the product's commit, or that lacks a job the workflow file defines, or (for
//! `--gate`) holds one it does not, refuses.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");

pub const Label = enum {
    passed,
    expected_failure_observed,
    skipped,

    pub fn text(label: Label) []const u8 {
        return switch (label) {
            .passed => "passed",
            .expected_failure_observed => "expected failure observed",
            .skipped => "skipped",
        };
    }
};

pub const Counts = struct {
    passed: u32 = 0,
    expected_failure_observed: u32 = 0,
    skipped: u32 = 0,

    fn add(counts: *Counts, label: Label) void {
        const before = counts.total();
        switch (label) {
            .passed => counts.passed += 1,
            .expected_failure_observed => counts.expected_failure_observed += 1,
            .skipped => counts.skipped += 1,
        }
        assert(counts.total() == before + 1);
    }

    pub fn total(counts: *const Counts) u32 {
        return counts.passed + counts.expected_failure_observed + counts.skipped;
    }
};

/// The one line a refusal prints, after `release-evidence: refused: `.
pub const Diagnostic = struct {
    buffer: [512]u8 = undefined,
    text: []const u8 = "",

    fn set(
        diagnostic: *Diagnostic,
        comptime format: []const u8,
        arguments: anytype,
    ) error{Refused} {
        diagnostic.text = std.fmt.bufPrint(&diagnostic.buffer, format, arguments) catch
            diagnostic.buffer[0..]; // A name too long to fit is cut, not lost: the start is there.
        assert(diagnostic.text.len > 0);
        assert(diagnostic.text.len <= diagnostic.buffer.len);
        return error.Refused;
    }
};

pub const Error = error{ Refused, WriteFailed };

// The API's JSON, reduced to the members this table reads. Unknown members are ignored, so the
// full responses and the trimmed fixtures parse alike.
const Step = struct { name: []const u8, conclusion: ?[]const u8 = null };
const Job = struct {
    name: []const u8,
    status: []const u8,
    conclusion: ?[]const u8 = null,
    html_url: []const u8,
    head_sha: []const u8,
    run_id: u64,
    steps: []const Step = &.{},
};
const Jobs = struct { total_count: u32, jobs: []const Job };
const Run = struct {
    id: u64,
    head_sha: []const u8,
    status: []const u8,
    conclusion: ?[]const u8 = null,
    html_url: []const u8,
    created_at: []const u8,
    run_attempt: u32 = 1,
};
const Runs = struct { total_count: u32, workflow_runs: []const Run };

const json_options: std.json.ParseOptions = .{
    .ignore_unknown_fields = true,
    .max_value_len = constants.release_evidence_input_bytes_max,
};

/// The parsed responses of one gate live here, and are dropped before the next gate's.
var parse_buffer: [constants.release_evidence_parse_bytes_max]u8 = undefined;

pub fn write_header(out: *std.Io.Writer, product: []const u8, dependency: ?[]const u8) Error!void {
    assert(product.len > 0);
    if (dependency) |name| assert(name.len > 0);
    try out.writeAll("## CI evidence\n\n");
    try out.writeAll("Rendered by the release workflow from the GitHub Actions API: the " ++
        "conclusion of every job, and of every step in it, of the release commit's runs. " ++
        "Nothing here is typed (docs/releases/automation.md).\n\n");
    try out.print("- Product: `{s}`\n", .{product});
    try out.print("- Dependency: {s}{s}{s}\n\n", .{
        if (dependency == null) "none" else "`",
        dependency orelse "",
        if (dependency == null) "" else "`",
    });
    try out.writeAll("| Workflow | Job | Result | Steps not run, or failed as expected |\n");
    try out.writeAll("| --- | --- | --- | --- |\n");
}

pub fn write_footer(out: *std.Io.Writer, counts: *const Counts) Error!void {
    assert(counts.total() > 0);
    assert(counts.total() <= constants.release_evidence_gates_max *
        constants.release_evidence_jobs_max);
    try out.print("\n{d} jobs: {d} passed, {d} expected failure observed, {d} skipped.\n", .{
        counts.total(), counts.passed, counts.expected_failure_observed, counts.skipped,
    });
}

/// One gate: the newest run of `workflow` at `product_sha`, and every job of it, as table rows.
pub fn render_gate(
    out: *std.Io.Writer,
    gate: *const Gate,
    counts: *Counts,
    diagnostic: *Diagnostic,
) Error!void {
    assert(gate.workflow.len > 0);
    assert(gate.product_sha.len > 0);
    var fixed: std.heap.FixedBufferAllocator = .init(&parse_buffer);
    const allocator = fixed.allocator();
    const run: Run = if (gate.jobs_named == null) newest: {
        const text = gate.runs_text;
        const runs = std.json.parseFromSliceLeaky(Runs, allocator, text, json_options) catch
            return diagnostic.set("{s}: the runs listing is not the API's JSON", .{gate.workflow});
        break :newest try newest_run(&runs, gate, diagnostic);
    } else std.json.parseFromSliceLeaky(Run, allocator, gate.runs_text, json_options) catch
        return diagnostic.set("{s}: the run is not the API's JSON", .{gate.workflow});
    const jobs = std.json.parseFromSliceLeaky(Jobs, allocator, gate.jobs_text, json_options) catch
        return diagnostic.set("{s}: the job listing is not the API's JSON", .{gate.workflow});
    try check_jobs(&jobs, &run, gate, diagnostic);
    var required: Names = .{};
    if (gate.jobs_named) |names| {
        try workflow_scan(gate.workflow_text, gate.workflow, null, diagnostic);
        try names_split(names, gate.workflow, &required, diagnostic);
    } else {
        try workflow_scan(gate.workflow_text, gate.workflow, &required, diagnostic);
    }
    const whole = gate.jobs_named == null;
    try check_present(&jobs, &run, &required, whole, gate.workflow, diagnostic);
    try write_rows(out, gate, &run, &jobs, counts, diagnostic);
}

/// Job names, each at most once: the jobs a workflow file defines, or the ones `--current` names.
/// A name expanded from a matrix points into `expanded`, so a `Names` is filled in place and never
/// copied.
pub const Names = struct {
    items: [constants.release_evidence_jobs_max][]const u8 = undefined,
    count: u32 = 0,
    expanded: [constants.release_evidence_expanded_bytes_max]u8 = undefined,
    expanded_used: u32 = 0,

    fn slice(names: *const Names) []const []const u8 {
        assert(names.count <= names.items.len);
        assert(names.items.len == constants.release_evidence_jobs_max);
        return names.items[0..names.count];
    }

    fn contains(names: *const Names, name: []const u8) bool {
        assert(name.len > 0);
        assert(names.count <= names.items.len);
        for (names.slice()) |item| {
            if (std.mem.eql(u8, item, name)) return true;
        }
        return false;
    }

    fn append(
        names: *Names,
        name: []const u8,
        workflow: []const u8,
        diagnostic: *Diagnostic,
    ) Error!void {
        assert(name.len > 0);
        if (names.contains(name)) {
            return diagnostic.set("{s}: the job name '{s}' is given twice", .{ workflow, name });
        }
        if (names.count == names.items.len) {
            return diagnostic.set("{s}: more than {d} jobs", .{ workflow, names.items.len });
        }
        names.items[names.count] = name;
        names.count += 1;
        assert(names.count <= names.items.len);
    }

    /// `template` with each `${{ matrix.<key> }}` replaced by `value`, written to `expanded`.
    fn expand(
        names: *Names,
        template: []const u8,
        key: []const u8,
        value: []const u8,
        workflow: []const u8,
        diagnostic: *Diagnostic,
    ) Error![]const u8 {
        assert(key.len > 0);
        assert(value.len > 0);
        assert(names.expanded_used <= names.expanded.len);
        var out: std.Io.Writer = .fixed(names.expanded[names.expanded_used..]);
        var index: usize = 0;
        var replaced: u32 = 0;
        while (index < template.len) {
            if (matrix_reference(template[index..], key)) |length| {
                out.writeAll(value) catch return expand_full(workflow, diagnostic);
                index += length;
                replaced += 1;
            } else {
                out.writeByte(template[index]) catch return expand_full(workflow, diagnostic);
                index += 1;
            }
        }
        assert(replaced > 0); // matrix_names refused a name without a reference.
        const name = out.buffered();
        names.expanded_used += @intCast(name.len);
        assert(names.expanded_used <= names.expanded.len);
        assert(name.len > 0);
        return name;
    }
};

fn expand_full(workflow: []const u8, diagnostic: *Diagnostic) error{Refused} {
    assert(workflow.len > 0);
    return diagnostic.set("{s}: the job names its matrices expand to are above {d} bytes " ++
        "(release_evidence_expanded_bytes_max)", .{
        workflow, constants.release_evidence_expanded_bytes_max,
    });
}

fn names_split(
    list: []const u8,
    workflow: []const u8,
    names: *Names,
    diagnostic: *Diagnostic,
) Error!void {
    assert(list.len > 0);
    assert(names.count == 0);
    var iterator = std.mem.splitScalar(u8, list, ',');
    while (iterator.next()) |name| {
        if (name.len == 0) return diagnostic.set("{s}: an empty job name", .{workflow});
        try names.append(name, workflow, diagnostic);
    }
    assert(names.count > 0);
}

/// Every required job is in the run exactly once, so neither a missing job nor one listed twice
/// can pass for another. With `whole` (a gate of every job, `ci`), the run holds no other job:
/// a job the file does not define means the names were predicted wrong (a matrix value GitHub
/// rendered otherwise, a matrix job skipped under its unexpanded name), so it refuses.
fn check_present(
    jobs: *const Jobs,
    run: *const Run,
    required: *const Names,
    whole: bool,
    workflow: []const u8,
    diagnostic: *Diagnostic,
) Error!void {
    assert(required.count > 0);
    assert(jobs.jobs.len <= constants.release_evidence_jobs_max);
    for (required.slice()) |name| {
        var found: u32 = 0;
        for (jobs.jobs) |*job| {
            if (std.mem.eql(u8, job.name, name)) found += 1;
        }
        if (found == 0) {
            return diagnostic.set("{s}: job '{s}' is not in run {d}", .{ workflow, name, run.id });
        }
        if (found > 1) {
            return diagnostic.set("{s}: job '{s}' is in run {d} {d} times", .{
                workflow, name, run.id, found,
            });
        }
    }
    if (!whole) return;
    for (jobs.jobs) |*job| {
        if (!required.contains(job.name)) {
            return diagnostic.set("{s}: job '{s}' of run {d} is not one the workflow file " ++
                "defines", .{ workflow, job.name, run.id });
        }
    }
    // Each required name is in the run once and the run holds no other, so the two are equal.
    assert(jobs.jobs.len == required.count);
}

/// Every job, or with `jobs_named` those jobs alone, by name, so the table reads the same however
/// the API orders them.
fn write_rows(
    out: *std.Io.Writer,
    gate: *const Gate,
    run: *const Run,
    jobs: *const Jobs,
    counts: *Counts,
    diagnostic: *Diagnostic,
) Error!void {
    assert(jobs.jobs.len <= constants.release_evidence_jobs_max);
    var order: [constants.release_evidence_jobs_max]u32 = undefined;
    for (order[0..jobs.jobs.len], 0..) |*slot, index| slot.* = @intCast(index);
    std.mem.sort(u32, order[0..jobs.jobs.len], jobs.jobs, job_before);
    const before = counts.total();
    var written: u32 = 0;
    for (order[0..jobs.jobs.len]) |index| {
        const job = &jobs.jobs[index];
        if (gate.jobs_named) |names| {
            if (!named(names, job.name)) continue;
            if (!std.mem.eql(u8, job.status, "completed")) {
                return diagnostic.set("{s}: job '{s}' is {s}, not completed", .{
                    gate.workflow, job.name, job.status,
                });
            }
        }
        const label = try classify(job, gate.workflow, diagnostic);
        const reason = skip_reason(gate.skips_allowed, job.name);
        if (label == .skipped) {
            if (reason == null) {
                return diagnostic.set("{s}: job '{s}' was skipped, or a step of it, and it is " ++
                    "not allowed to be (--allow-skip)", .{ gate.workflow, job.name });
            }
        }
        counts.add(label);
        try write_row(out, gate.workflow, run, job, label, reason);
        written += 1;
    }
    // check_present found each named job once, and names_split refused a name given twice.
    if (gate.jobs_named) |names| assert(written == std.mem.count(u8, names, ",") + 1);
    assert(counts.total() == before + written);
}

fn named(names: []const u8, name: []const u8) bool {
    assert(names.len > 0);
    var iterator = std.mem.splitScalar(u8, names, ',');
    while (iterator.next()) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

pub const Gate = struct {
    workflow: []const u8,
    /// The workflow file the run ran (`workflow_scan`).
    workflow_text: []const u8,
    product_sha: []const u8,
    runs_text: []const u8,
    jobs_text: []const u8,
    /// Null: the gate is every job of the newest run of `workflow` at the product, which must be
    /// a completed success (`ci`). Otherwise the gate is the release run itself, still running
    /// when the table is drawn: `runs_text` is that one run (`GET .../runs/{id}`), and only these
    /// jobs, by name and comma-separated, each completed, are its evidence (the jobs `draft`
    /// needs). Its commit is the workflow's, so it is not compared with the product's.
    jobs_named: ?[]const u8 = null,
    /// The jobs that may be skipped, by name; any other skipped job or step refuses the table.
    skips_allowed: []const Skip = &.{},
};

/// A job allowed to be skipped, and why (docs/decisions/2026-11-18-release-skip-allowlist.md).
pub const Skip = struct {
    job: []const u8,
    reason: []const u8,
};

/// The reason `job` may be skipped, or null when it may not.
fn skip_reason(skips: []const Skip, job: []const u8) ?[]const u8 {
    assert(skips.len <= constants.release_evidence_skips_allowed_max);
    assert(job.len > 0);
    for (skips) |*skip| {
        if (std.mem.eql(u8, skip.job, job)) return skip.reason;
    }
    return null;
}

/// Reads the workflow file a gate's run ran, line by line, without a YAML parser: it refuses any
/// `continue-on-error` other than `false`, and with `derived` lists the name the API gives each
/// job under `jobs:` (its `name:`, else its id). A shape whose names it cannot predict (a
/// reusable workflow, an expression or a YAML form in the name) refuses, so it fails closed.
///
/// One matrix shape is read (`strategy_line`; the decision is
/// docs/decisions/2026-11-22-release-evidence-matrix.md): a `strategy:` holding `fail-fast:`,
/// `max-parallel:` and a `matrix:` of exactly one key whose value is a one-line list of plain
/// words and numbers (`shard: [1, 2, 3, 4]`), in a job whose `name:` holds
/// `${{ matrix.<key> }}`, spelled so, and no other expression. Such a job is one name per value,
/// the value written as it stands, which is how GitHub renders a word or a decimal number
/// (`fuzz (shard 1 of 4, ...)`, recorded in `release_evidence/0.6.0-*`). Anything else under
/// `strategy:` refuses: `include` or `exclude`, a second key, a block list, a matrix from an
/// expression, a value YAML could read as something else (`1.10`, `010`, `yes`), a matrix job
/// with no `name:` (GitHub's own `id (value)` form).
pub fn workflow_scan(
    text: []const u8,
    workflow: []const u8,
    derived: ?*Names,
    diagnostic: *Diagnostic,
) Error!void {
    assert(workflow.len > 0);
    if (derived) |names| assert(names.count == 0);
    if (text.len == 0) return diagnostic.set("{s}: the workflow file is empty", .{workflow});
    var scan: Scan = .{ .workflow = workflow };
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        scan.line_number += 1;
        const line = std.mem.trimEnd(u8, raw, " \r");
        try check_continue(&scan, line, diagnostic);
        if (derived) |names| try scan_jobs(&scan, line, names, diagnostic);
    }
    if (derived) |names| {
        try job_close(&scan, names, diagnostic);
        if (names.count == 0) {
            return diagnostic.set("{s}: the workflow file defines no job", .{workflow});
        }
    }
    assert(scan.job.id == null);
}

const Scan = struct {
    workflow: []const u8,
    line_number: u32 = 0,
    in_jobs: bool = false,
    job: JobRead = .{},

    /// What the scan has read of the job it is in; `job_close` lists its names and clears it.
    const JobRead = struct {
        id: ?[]const u8 = null,
        name: ?[]const u8 = null,
        /// The line of `name:`, which a refusal of the name, made at the job's end, names.
        name_line: u32 = 0,
        /// The line of `strategy:`, or 0 when the job has none.
        strategy_line: u32 = 0,
        /// The scan is inside the job's `strategy:` block, and inside its `matrix:`.
        in_strategy: bool = false,
        in_matrix: bool = false,
        matrix_line: u32 = 0,
        /// The matrix's one key, and the text between its list's brackets.
        matrix_key: ?[]const u8 = null,
        matrix_values: []const u8 = "",
    };
};

fn indent_of(line: []const u8) usize {
    const content = std.mem.trimStart(u8, line, " ");
    assert(content.len <= line.len);
    if (content.len > 0) assert(content[0] != ' ');
    return line.len - content.len;
}

/// A value with its trailing ` #` comment cut; a quoted value keeps what is inside its quotes.
/// Null: a value this scan does not read (a quote left open, an escape, a YAML form).
fn plain_value(raw: []const u8) ?[]const u8 {
    const value = std.mem.trim(u8, raw, " ");
    assert(value.len <= raw.len);
    if (value.len == 0) return null;
    const quote = value[0];
    if (std.mem.indexOfScalar(u8, "\"'", quote) != null) {
        const close = std.mem.indexOfScalarPos(u8, value, 1, quote) orelse return null;
        const rest = std.mem.trim(u8, value[close + 1 ..], " ");
        if (!std.mem.startsWith(u8, rest, "#")) {
            if (rest.len > 0) return null;
        }
        const inner = value[1..close];
        if (std.mem.indexOfAny(u8, inner, "\\'\"") != null) return null;
        return inner;
    }
    const cut = std.mem.indexOf(u8, value, " #") orelse value.len;
    const plain = std.mem.trimEnd(u8, value[0..cut], " ");
    assert(plain.len <= value.len);
    if (std.mem.indexOfScalar(u8, "|>&*!{[@`%", plain[0]) != null) return null;
    return plain;
}

/// Refuses `continue-on-error` set to anything but `false`: the API reports a step that failed
/// under it as `success`, so its job would read "passed". Any other line holding the key, outside
/// a comment (a flow mapping, say), refuses as well, so a form this scan does not read cannot
/// slip past.
fn check_continue(scan: *const Scan, line: []const u8, diagnostic: *Diagnostic) Error!void {
    assert(scan.line_number > 0);
    const key = "continue-on-error";
    var content = std.mem.trimStart(u8, line, " ");
    if (std.mem.startsWith(u8, content, "#")) return;
    if (std.mem.indexOf(u8, content, key ++ ":") == null) return;
    if (std.mem.startsWith(u8, content, "- ")) content = std.mem.trimStart(u8, content[2..], " ");
    assert(content.len > 0);
    if (std.mem.startsWith(u8, content, key ++ ":")) {
        const value = plain_value(content[key.len + 1 ..]) orelse "";
        if (std.mem.eql(u8, value, "false")) return;
    }
    return diagnostic.set("{s}: line {d} of the workflow file sets continue-on-error, and the " ++
        "API reports a step that fails under it as a success", .{
        scan.workflow, scan.line_number,
    });
}

fn scan_jobs(scan: *Scan, line: []const u8, names: *Names, diagnostic: *Diagnostic) Error!void {
    assert(scan.line_number > 0);
    const indent = indent_of(line);
    if (indent == line.len) return;
    const content = line[indent..];
    assert(content.len > 0);
    if (content[0] == '#') return;
    if (indent == 0) {
        try job_close(scan, names, diagnostic);
        const key = plain_value(content) orelse "";
        scan.in_jobs = std.mem.eql(u8, key, "jobs:");
        return;
    }
    if (!scan.in_jobs) return;
    if (indent == 2) {
        try job_close(scan, names, diagnostic);
        const id = plain_value(content) orelse "";
        if (id.len < 2) return scan_refuse(scan, "a job id it cannot read", diagnostic);
        if (id[id.len - 1] != ':') return scan_refuse(scan, "a job id it cannot read", diagnostic);
        scan.job.id = id[0 .. id.len - 1];
        return;
    }
    if (indent != 4) {
        // Every line of a `strategy:` block is read, so a form strategy_line does not know
        // refuses rather than passing unread.
        if (scan.job.in_strategy) try strategy_line(scan, indent, content, diagnostic);
        return;
    }
    if (scan.job.id == null) return scan_refuse(scan, "a key outside any job", diagnostic);
    scan.job.in_strategy = false;
    scan.job.in_matrix = false;
    try job_key(scan, content, diagnostic);
}

fn job_key(scan: *Scan, content: []const u8, diagnostic: *Diagnostic) Error!void {
    assert(scan.job.id != null);
    assert(content.len > 0);
    if (std.mem.startsWith(u8, content, "strategy:")) {
        if (scan.job.strategy_line != 0) {
            return scan_refuse(scan, "a second strategy in one job", diagnostic);
        }
        if (!block_opens(content["strategy:".len..])) {
            return scan_refuse(scan, "a strategy it cannot read", diagnostic);
        }
        scan.job.strategy_line = scan.line_number;
        scan.job.in_strategy = true;
        return;
    }
    if (std.mem.startsWith(u8, content, "uses:")) {
        return scan_refuse(scan, "a reusable workflow, whose job names it cannot list", diagnostic);
    }
    if (!std.mem.startsWith(u8, content, "name:")) return;
    const name = plain_value(content["name:".len..]) orelse
        return scan_refuse(scan, "a job name it cannot read", diagnostic);
    scan.job.name = name;
    scan.job.name_line = scan.line_number;
    assert(name.len > 0);
}

/// A key whose value is a block on the lines below: nothing after the colon but a comment.
fn block_opens(rest: []const u8) bool {
    const value = std.mem.trim(u8, rest, " ");
    assert(value.len <= rest.len);
    if (value.len == 0) return true;
    if (value[0] != '#') return false;
    return rest[0] == ' ';
}

/// A line inside a job's `strategy:` block, below its 4-space keys: `fail-fast:`,
/// `max-parallel:` or `matrix:` at 6 spaces, and the matrix's one key at 8.
fn strategy_line(
    scan: *Scan,
    indent: usize,
    content: []const u8,
    diagnostic: *Diagnostic,
) Error!void {
    assert(scan.job.in_strategy);
    assert(indent != 4);
    if (indent == 8) {
        if (scan.job.in_matrix) return matrix_line(scan, content, diagnostic);
        return scan_refuse(scan, "a strategy it cannot read", diagnostic);
    }
    if (indent != 6) return scan_refuse(scan, "a strategy it cannot read", diagnostic);
    scan.job.in_matrix = false;
    if (std.mem.startsWith(u8, content, "fail-fast:")) return;
    if (std.mem.startsWith(u8, content, "max-parallel:")) return;
    if (!std.mem.startsWith(u8, content, "matrix:")) {
        return scan_refuse(scan, "a strategy key it cannot read", diagnostic);
    }
    if (scan.job.matrix_line != 0) {
        return scan_refuse(scan, "a second matrix in one strategy", diagnostic);
    }
    const rest = content["matrix:".len..];
    if (std.mem.indexOf(u8, rest, "${{") != null) {
        const what = "a matrix from an expression, whose job names it cannot list";
        return scan_refuse(scan, what, diagnostic);
    }
    if (!block_opens(rest)) return scan_refuse(scan, "a matrix it cannot read", diagnostic);
    scan.job.matrix_line = scan.line_number;
    scan.job.in_matrix = true;
}

/// The matrix's one key and its values, `key: [a, b, c]`.
fn matrix_line(scan: *Scan, content: []const u8, diagnostic: *Diagnostic) Error!void {
    assert(scan.job.in_matrix);
    assert(scan.job.matrix_line > 0);
    const colon = std.mem.indexOfScalar(u8, content, ':') orelse
        return scan_refuse(scan, "a matrix it cannot read", diagnostic);
    const key = content[0..colon];
    if (std.mem.eql(u8, key, "include")) {
        return scan_refuse(scan, "a matrix include, whose job names it cannot list", diagnostic);
    }
    if (std.mem.eql(u8, key, "exclude")) {
        return scan_refuse(scan, "a matrix exclude, whose job names it cannot list", diagnostic);
    }
    if (scan.job.matrix_key != null) {
        return scan_refuse(scan, "a matrix of more than one key, whose job names it cannot " ++
            "list", diagnostic);
    }
    if (!matrix_word(key)) return scan_refuse(scan, "a matrix key it cannot read", diagnostic);
    const values = flow_list(content[colon + 1 ..]) orelse
        return scan_refuse(scan, "a matrix value that is not a one-line list of plain words " ++
            "and numbers", diagnostic);
    scan.job.matrix_key = key;
    scan.job.matrix_values = values;
    assert(values.len > 0);
}

/// The text between the brackets of a one-line flow list, ` [a, b] # comment`, when every item
/// is a `matrix_value`; null otherwise.
fn flow_list(raw: []const u8) ?[]const u8 {
    const value = std.mem.trim(u8, raw, " ");
    if (raw.len == 0) return null;
    if (raw[0] != ' ') return null;
    if (value.len < 2) return null;
    if (value[0] != '[') return null;
    const close = std.mem.indexOfScalar(u8, value, ']') orelse return null;
    const rest = value[close + 1 ..];
    if (rest.len > 0) {
        if (rest[0] != ' ') return null;
        if (std.mem.trimStart(u8, rest, " ")[0] != '#') return null;
    }
    assert(close > 0);
    const inner = value[1..close];
    var items = std.mem.splitScalar(u8, inner, ',');
    while (items.next()) |item| {
        if (!matrix_value(std.mem.trim(u8, item, " "))) return null;
    }
    assert(inner.len > 0);
    return inner;
}

/// A matrix value GitHub renders exactly as written: a decimal number without a leading zero (at
/// most 9 digits), or a word of letters, digits, `-` and `_` that starts with a letter and that
/// YAML reads as no boolean or null. Anything else (`1.10` is the number 1.1, `010` may be 8 or
/// 10, `yes` may be true) refuses.
fn matrix_value(value: []const u8) bool {
    if (value.len == 0) return false;
    if (std.ascii.isDigit(value[0])) {
        if (value.len > 9) return false;
        if (value[0] == '0') return value.len == 1;
        for (value) |byte| {
            if (!std.ascii.isDigit(byte)) return false;
        }
        return true;
    }
    if (!std.ascii.isAlphabetic(value[0])) return false;
    if (!matrix_word(value)) return false;
    const special = [_][]const u8{ "y", "n", "yes", "no", "on", "off", "true", "false", "null" };
    for (special) |word| {
        if (std.ascii.eqlIgnoreCase(value, word)) return false;
    }
    assert(value.len > 0);
    return true;
}

/// Letters, digits, `-` and `_`, as a matrix key or a word value is written.
fn matrix_word(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        if (byte == '-') continue;
        if (byte == '_') continue;
        return false;
    }
    assert(std.mem.indexOfAny(u8, text, " ${}[],:#'\".") == null);
    return true;
}

/// The length of `${{ matrix.<key> }}` at the start of `text`, spelled with one space inside each
/// brace pair as ci.yml writes it, or null.
fn matrix_reference(text: []const u8, key: []const u8) ?usize {
    assert(key.len > 0);
    const open = "${{ matrix.";
    const close = " }}";
    if (!std.mem.startsWith(u8, text, open)) return null;
    const rest = text[open.len..];
    if (!std.mem.startsWith(u8, rest, key)) return null;
    if (!std.mem.startsWith(u8, rest[key.len..], close)) return null;
    return open.len + key.len + close.len;
}

fn job_close(scan: *Scan, names: *Names, diagnostic: *Diagnostic) Error!void {
    const id = scan.job.id orelse {
        assert(scan.job.name == null);
        assert(scan.job.strategy_line == 0);
        return;
    };
    if (scan.job.strategy_line == 0) {
        if (scan.job.name) |name| {
            if (std.mem.indexOf(u8, name, "${{") != null) {
                const what = "a job name with an expression";
                return scan_refuse_at(scan, scan.job.name_line, what, diagnostic);
            }
        }
        try names.append(scan.job.name orelse id, scan.workflow, diagnostic);
    } else {
        try matrix_names(scan, names, diagnostic);
    }
    scan.job = .{};
    assert(names.count > 0);
}

/// A matrix job's names: its `name:` once for each value, which must each be new.
fn matrix_names(scan: *const Scan, names: *Names, diagnostic: *Diagnostic) Error!void {
    const job = &scan.job;
    assert(job.strategy_line > 0);
    const key = job.matrix_key orelse return scan_refuse_at(scan, job.strategy_line, "a " ++
        "strategy with no one-key matrix, whose job names it cannot list", diagnostic);
    const template = job.name orelse return scan_refuse_at(scan, job.strategy_line, "a " ++
        "matrix job with no name, whose job names it cannot list", diagnostic);
    var references: u32 = 0;
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, template, index, "${{")) |at| {
        if (matrix_reference(template[at..], key) == null) {
            return scan_refuse_at(scan, job.name_line, "a job name with an expression other " ++
                "than its matrix value", diagnostic);
        }
        references += 1;
        index = at + 1;
    }
    if (references == 0) {
        return scan_refuse_at(scan, job.name_line, "a matrix job name that does not hold its " ++
            "matrix value", diagnostic);
    }
    const before = names.count;
    var values = std.mem.splitScalar(u8, job.matrix_values, ',');
    while (values.next()) |item| {
        const value = std.mem.trim(u8, item, " ");
        assert(matrix_value(value)); // flow_list checked every item.
        const name = try names.expand(template, key, value, scan.workflow, diagnostic);
        try names.append(name, scan.workflow, diagnostic);
    }
    assert(names.count > before);
}

fn scan_refuse(scan: *const Scan, what: []const u8, diagnostic: *Diagnostic) Error {
    return scan_refuse_at(scan, scan.line_number, what, diagnostic);
}

fn scan_refuse_at(
    scan: *const Scan,
    line_number: u32,
    what: []const u8,
    diagnostic: *Diagnostic,
) Error {
    assert(what.len > 0);
    assert(line_number > 0);
    assert(line_number <= scan.line_number);
    return diagnostic.set("{s}: line {d} of the workflow file holds {s}", .{
        scan.workflow, line_number, what,
    });
}

fn job_before(jobs: []const Job, left: u32, right: u32) bool {
    assert(left < jobs.len);
    assert(right < jobs.len);
    return std.mem.order(u8, jobs[left].name, jobs[right].name) == .lt;
}

/// The run the release gate reads, as `plan` does: the newest by creation time. It must be the
/// product's commit and a completed success.
fn newest_run(runs: *const Runs, gate: *const Gate, diagnostic: *Diagnostic) Error!Run {
    if (runs.workflow_runs.len == 0) {
        return diagnostic.set("{s}: no run at {s}", .{ gate.workflow, gate.product_sha });
    }
    if (runs.total_count != runs.workflow_runs.len) {
        return diagnostic.set("{s}: the runs listing holds {d} of {d} runs", .{
            gate.workflow, runs.workflow_runs.len, runs.total_count,
        });
    }
    var newest = &runs.workflow_runs[0];
    for (runs.workflow_runs[1..]) |*run| {
        if (std.mem.order(u8, run.created_at, newest.created_at) == .gt) newest = run;
    }
    if (!std.mem.eql(u8, newest.head_sha, gate.product_sha)) {
        return diagnostic.set("{s}: run {d} is of {s}, not the product {s}", .{
            gate.workflow, newest.id, newest.head_sha, gate.product_sha,
        });
    }
    if (!std.mem.eql(u8, newest.status, "completed")) {
        return diagnostic.set("{s}: run {d} is {s}, not completed", .{
            gate.workflow, newest.id, newest.status,
        });
    }
    if (!std.mem.eql(u8, newest.conclusion orelse "none", "success")) {
        return diagnostic.set("{s}: run {d} ended {s}, not success", .{
            gate.workflow, newest.id, newest.conclusion orelse "none",
        });
    }
    assert(newest.id > 0);
    return newest.*;
}

/// The job listing is the whole of the run's, at the run's commit (for `ci`, the product's: the
/// pair of `newest_run`'s check).
fn check_jobs(
    jobs: *const Jobs,
    run: *const Run,
    gate: *const Gate,
    diagnostic: *Diagnostic,
) Error!void {
    assert(run.id > 0);
    if (jobs.jobs.len == 0) {
        return diagnostic.set("{s}: run {d} has no jobs", .{ gate.workflow, run.id });
    }
    if (jobs.jobs.len > constants.release_evidence_jobs_max) {
        return diagnostic.set("{s}: run {d} has {d} jobs, above {d}", .{
            gate.workflow, run.id, jobs.jobs.len, constants.release_evidence_jobs_max,
        });
    }
    if (jobs.total_count != jobs.jobs.len) {
        return diagnostic.set("{s}: the job listing holds {d} of {d} jobs", .{
            gate.workflow, jobs.jobs.len, jobs.total_count,
        });
    }
    for (jobs.jobs) |*job| {
        if (job.run_id != run.id) {
            return diagnostic.set("{s}: job '{s}' is of run {d}, not {d}", .{
                gate.workflow, job.name, job.run_id, run.id,
            });
        }
        if (!std.mem.eql(u8, job.head_sha, run.head_sha)) {
            return diagnostic.set("{s}: job '{s}' is of {s}, not the run's {s}", .{
                gate.workflow, job.name, job.head_sha, run.head_sha,
            });
        }
    }
    assert(jobs.jobs.len <= constants.release_evidence_jobs_max);
}

/// A job's own housekeeping, not a gate: the runner's set-up and tear-down, and the clean-up an
/// action registers, which the runner names `Post ` and the name of an earlier step of the job
/// and skips whenever that step is. A step of the workflow's own named `Post ...` is counted.
fn housekeeping(steps: []const Step, index: usize) bool {
    assert(index < steps.len);
    assert(steps.len <= constants.release_evidence_steps_max);
    const name = steps[index].name;
    if (std.mem.eql(u8, name, "Set up job")) return true;
    if (std.mem.eql(u8, name, "Complete job")) return true;
    const prefix = "Post ";
    if (!std.mem.startsWith(u8, name, prefix)) return false;
    for (steps[0..index]) |*earlier| {
        if (std.mem.eql(u8, earlier.name, name[prefix.len..])) return true;
    }
    return false;
}

pub fn classify(job: *const Job, workflow: []const u8, diagnostic: *Diagnostic) Error!Label {
    assert(workflow.len > 0);
    const conclusion = job.conclusion orelse "none";
    if (std.mem.eql(u8, conclusion, "skipped")) return .skipped;
    if (!std.mem.eql(u8, conclusion, "success")) {
        return diagnostic.set("{s}: job '{s}' ended {s}", .{ workflow, job.name, conclusion });
    }
    if (job.steps.len > constants.release_evidence_steps_max) {
        return diagnostic.set("{s}: job '{s}' has {d} steps, above {d}", .{
            workflow, job.name, job.steps.len, constants.release_evidence_steps_max,
        });
    }
    var skipped: u32 = 0;
    var failed: u32 = 0;
    var counted: u32 = 0;
    for (job.steps, 0..) |*step, index| {
        if (housekeeping(job.steps, index)) continue;
        counted += 1;
        const outcome = step.conclusion orelse "none";
        if (std.mem.eql(u8, outcome, "success")) continue;
        if (std.mem.eql(u8, outcome, "skipped")) {
            skipped += 1;
        } else if (std.mem.eql(u8, outcome, "failure")) {
            failed += 1;
        } else {
            return diagnostic.set("{s}: job '{s}', step '{s}' ended {s}", .{
                workflow, job.name, step.name, outcome,
            });
        }
    }
    assert(skipped + failed <= counted);
    assert(counted <= job.steps.len);
    if (counted == 0) {
        return diagnostic.set("{s}: job '{s}' succeeded with no step of its own", .{
            workflow, job.name,
        });
    }
    if (skipped > 0) return .skipped;
    if (failed > 0) return .expected_failure_observed;
    return .passed;
}

fn write_row(
    out: *std.Io.Writer,
    workflow: []const u8,
    run: *const Run,
    job: *const Job,
    label: Label,
    reason: ?[]const u8,
) Error!void {
    assert(workflow.len > 0);
    assert(job.html_url.len > 0);
    try out.writeAll("| [");
    try write_cell(out, workflow);
    try out.print("]({s}) attempt {d} | [", .{ run.html_url, run.run_attempt });
    try write_cell(out, job.name);
    try out.print("]({s}) | {s}", .{ job.html_url, label.text() });
    if (label == .skipped) {
        try out.writeAll(" (allowed: ");
        try write_cell(out, reason.?); // write_rows refused a skip with no reason.
        try out.writeAll(")");
    }
    try out.writeAll(" | ");
    var listed: u32 = 0;
    for (job.steps, 0..) |*step, index| {
        if (housekeeping(job.steps, index)) continue;
        const outcome = step.conclusion orelse "none";
        if (std.mem.eql(u8, outcome, "success")) continue;
        if (listed > 0) try out.writeAll("; ");
        try write_cell(out, step.name);
        try out.print(" ({s})", .{outcome});
        listed += 1;
    }
    if (label == .passed) assert(listed == 0);
    try out.writeAll(" |\n");
}

/// A table cell holds no line break and no unescaped `|`.
fn write_cell(out: *std.Io.Writer, cell: []const u8) Error!void {
    for (cell) |byte| {
        switch (byte) {
            '|' => try out.writeAll("\\|"),
            '\n', '\r' => try out.writeByte(' '),
            else => try out.writeByte(byte),
        }
    }
}

// The command line.

const Arguments = struct {
    product: []const u8 = "",
    dependency: ?[]const u8 = null,
    gates: [constants.release_evidence_gates_max]GatePaths = undefined,
    gates_count: u32 = 0,
    skips: [constants.release_evidence_skips_allowed_max]Skip = undefined,
    skips_count: u32 = 0,
};

const GatePaths = struct {
    workflow: []const u8,
    workflow_path: []const u8,
    runs_path: []const u8,
    jobs_path: []const u8,
    jobs_named: ?[]const u8 = null,
};

var workflow_buffer: [constants.release_evidence_input_bytes_max]u8 = undefined;
var runs_buffer: [constants.release_evidence_input_bytes_max]u8 = undefined;
var jobs_buffer: [constants.release_evidence_input_bytes_max]u8 = undefined;
var output_buffer: [constants.release_evidence_output_bytes_max]u8 = undefined;

pub fn main(init: std.process.Init) !u8 {
    var error_buffer: [1024]u8 = undefined;
    var error_writer: std.Io.File.Writer = .init(.stderr(), init.io, &error_buffer);
    const errors = &error_writer.interface;
    var arguments: Arguments = .{};
    parse_arguments(init, &arguments) catch {
        try errors.writeAll("usage: release_evidence --product <repo>@<sha> " ++
            "[--dependency <repo>@<sha>] " ++
            "--gate <workflow> <workflow.yml> <runs.json> <jobs.json>... " ++
            "[--current <workflow> <workflow.yml> <run.json> <jobs.json> <job,job...>] " ++
            "[--allow-skip <job> <reason>]...\n");
        try errors.flush();
        return constants.tool_exit_usage;
    };
    assert(arguments.gates_count > 0);
    var out: std.Io.Writer = .fixed(&output_buffer);
    var diagnostic: Diagnostic = .{};
    render_all(init.io, &out, &arguments, &diagnostic) catch |err| switch (err) {
        error.Refused => {
            try errors.print("release-evidence: refused: {s}\n", .{diagnostic.text});
            try errors.flush();
            return constants.tool_exit_failed;
        },
        error.WriteFailed => {
            try errors.writeAll("release-evidence: refused: the table is larger than its " ++
                "buffer (release_evidence_output_bytes_max)\n");
            try errors.flush();
            return constants.tool_exit_failed;
        },
    };
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &.{});
    try stdout_writer.interface.writeAll(out.buffered());
    try stdout_writer.interface.flush();
    return constants.tool_exit_ok;
}

fn render_all(
    io: std.Io,
    out: *std.Io.Writer,
    arguments: *const Arguments,
    diagnostic: *Diagnostic,
) Error!void {
    assert(arguments.gates_count > 0);
    const product_sha = commit_of(arguments.product);
    try write_header(out, arguments.product, arguments.dependency);
    var counts: Counts = .{};
    for (arguments.gates[0..arguments.gates_count]) |*paths| {
        const workflow_text = read(io, paths.workflow_path, &workflow_buffer, diagnostic) catch
            return error.Refused;
        const runs_text = read(io, paths.runs_path, &runs_buffer, diagnostic) catch
            return error.Refused;
        const jobs_text = read(io, paths.jobs_path, &jobs_buffer, diagnostic) catch
            return error.Refused;
        const gate: Gate = .{
            .workflow = paths.workflow,
            .workflow_text = workflow_text,
            .product_sha = product_sha,
            .runs_text = runs_text,
            .jobs_text = jobs_text,
            .jobs_named = paths.jobs_named,
            .skips_allowed = arguments.skips[0..arguments.skips_count],
        };
        try render_gate(out, &gate, &counts, diagnostic);
    }
    try write_footer(out, &counts);
    assert(counts.total() > 0);
}

/// `owner/repo@sha` names a commit; the runs are checked against the part after the `@`.
fn commit_of(name: []const u8) []const u8 {
    const at = std.mem.lastIndexOfScalar(u8, name, '@').?; // parse_arguments checked it is there.
    assert(at + 1 < name.len);
    return name[at + 1 ..];
}

fn read(io: std.Io, path: []const u8, buffer: []u8, diagnostic: *Diagnostic) error{Refused}![]u8 {
    assert(path.len > 0);
    const text = std.Io.Dir.cwd().readFile(io, path, buffer) catch |err|
        return diagnostic.set("cannot read {s} ({s})", .{ path, @errorName(err) });
    if (text.len == buffer.len) {
        return diagnostic.set("{s} is larger than {d} bytes", .{ path, buffer.len });
    }
    return text;
}

fn parse_arguments(init: std.process.Init, arguments: *Arguments) error{Usage}!void {
    var iterator = init.minimal.args.iterate();
    _ = iterator.next();
    while (iterator.next()) |argument| {
        if (std.mem.eql(u8, argument, "--product")) {
            arguments.product = try commit_name(iterator.next());
        } else if (std.mem.eql(u8, argument, "--dependency")) {
            arguments.dependency = try commit_name(iterator.next());
        } else if (std.mem.eql(u8, argument, "--gate")) {
            if (arguments.gates_count == arguments.gates.len) return error.Usage;
            arguments.gates[arguments.gates_count] = .{
                .workflow = iterator.next() orelse return error.Usage,
                .workflow_path = iterator.next() orelse return error.Usage,
                .runs_path = iterator.next() orelse return error.Usage,
                .jobs_path = iterator.next() orelse return error.Usage,
            };
            arguments.gates_count += 1;
        } else if (std.mem.eql(u8, argument, "--current")) {
            if (arguments.gates_count == arguments.gates.len) return error.Usage;
            arguments.gates[arguments.gates_count] = .{
                .workflow = iterator.next() orelse return error.Usage,
                .workflow_path = iterator.next() orelse return error.Usage,
                .runs_path = iterator.next() orelse return error.Usage,
                .jobs_path = iterator.next() orelse return error.Usage,
                .jobs_named = iterator.next() orelse return error.Usage,
            };
            if (arguments.gates[arguments.gates_count].jobs_named.?.len == 0) return error.Usage;
            arguments.gates_count += 1;
        } else if (std.mem.eql(u8, argument, "--allow-skip")) {
            try skip_argument(&iterator, arguments);
        } else {
            return error.Usage;
        }
    }
    if (arguments.product.len == 0) return error.Usage;
    if (arguments.gates_count == 0) return error.Usage;
    assert(arguments.gates_count <= arguments.gates.len);
}

fn skip_argument(iterator: *std.process.Args.Iterator, arguments: *Arguments) error{Usage}!void {
    assert(arguments.skips_count <= arguments.skips.len);
    if (arguments.skips_count == arguments.skips.len) return error.Usage;
    const skip: Skip = .{
        .job = iterator.next() orelse return error.Usage,
        .reason = iterator.next() orelse return error.Usage,
    };
    if (skip.job.len == 0) return error.Usage;
    if (skip.reason.len == 0) return error.Usage;
    if (skip_reason(arguments.skips[0..arguments.skips_count], skip.job) != null) {
        return error.Usage;
    }
    arguments.skips[arguments.skips_count] = skip;
    arguments.skips_count += 1;
    assert(arguments.skips_count <= arguments.skips.len);
}

fn commit_name(argument: ?[]const u8) error{Usage}![]const u8 {
    const name = argument orelse return error.Usage;
    const at = std.mem.lastIndexOfScalar(u8, name, '@') orelse return error.Usage;
    if (at == 0) return error.Usage;
    if (at + 1 == name.len) return error.Usage;
    assert(name.len > 2);
    return name;
}

// Tests.

const testing = std.testing;
const fixture_ci_workflow = @embedFile("release_evidence/0.5.3-ci.yml");
const fixture_release_workflow = @embedFile("release_evidence/0.5.3-release.yml");
const fixture_probe_workflow = @embedFile("release_evidence/continue-on-error.yml");
const fixture_probe_jobs = @embedFile("release_evidence/continue-on-error-jobs.json");
const fixture_ci_runs = @embedFile("release_evidence/0.5.3-ci-runs.json");
const fixture_ci_jobs = @embedFile("release_evidence/0.5.3-ci-jobs.json");
const fixture_release_run = @embedFile("release_evidence/0.5.3-release-run.json");
const fixture_release_jobs = @embedFile("release_evidence/0.5.3-release-jobs.json");
const release_jobs_named = "plan the release,macOS gates (hosted)," ++
    "the tap and the site are reachable";
const fixture_table = @embedFile("release_evidence/0.5.3-table.md");
const sha_0_5_3 = "87498d04ea854cfbe7114699556a43866a0fcbc4";
const fixture_0_6_0_ci_workflow = @embedFile("release_evidence/0.6.0-ci.yml");
const fixture_0_6_0_ci_runs = @embedFile("release_evidence/0.6.0-ci-runs.json");
const fixture_0_6_0_ci_jobs = @embedFile("release_evidence/0.6.0-ci-jobs.json");
const fixture_0_6_0_release_workflow = @embedFile("release_evidence/0.6.0-release.yml");
const fixture_0_6_0_release_run = @embedFile("release_evidence/0.6.0-release-run.json");
const fixture_0_6_0_release_jobs = @embedFile("release_evidence/0.6.0-release-jobs.json");
const fixture_0_6_0_table = @embedFile("release_evidence/0.6.0-table.md");
const sha_0_6_0 = "82981d00c300de2806abfef2bdaee2caf84f670c";
const m6d_name = "demo-m6d (Ubuntu 24.04 VM, KVM, Artifact Registry and gcr.io through WIF)";
/// As release.yml passes it (docs/decisions/2026-11-18-release-skip-allowlist.md).
const skips_0_5_3 = [_]Skip{.{ .job = m6d_name, .reason = "Google WIF is not set up yet" }};

fn render_test(out: *std.Io.Writer, gates: []const Gate, diagnostic: *Diagnostic) Error!void {
    const sha = gates[0].product_sha;
    const product_0_6_0 = "ZigboxOrg/zigbox@" ++ sha_0_6_0;
    const product_0_5_3 = "Zigbox/zigbox@" ++ sha_0_5_3;
    const product = if (std.mem.eql(u8, sha, sha_0_6_0)) product_0_6_0 else product_0_5_3;
    try write_header(out, product, null);
    var counts: Counts = .{};
    for (gates) |*gate| try render_gate(out, gate, &counts, diagnostic);
    try write_footer(out, &counts);
}

test "0.5.3's recorded runs render the checked-in table, demo-m6d skipped" {
    // Goal: the API's recorded answers for 0.5.3's release commit (ci, and the release run's own
    // jobs `draft` needs; fetched once with `gh api` and trimmed) render exactly the checked-in
    // table, and demo-m6d, green with its demo step skipped, reads "skipped", not "passed".
    // Method: render and compare bytes.
    var buffer: [64 * 1024]u8 = undefined;
    @memset(&buffer, 0xaa);
    var out: std.Io.Writer = .fixed(&buffer);
    var diagnostic: Diagnostic = .{};
    try render_test(&out, &.{
        gate_of("ci", sha_0_5_3, fixture_ci_runs, fixture_ci_jobs),
        release_gate(release_jobs_named),
    }, &diagnostic);
    try testing.expectEqualStrings(fixture_table, out.buffered());
    const m6d_row = "| [ci](https://github.com/Zigbox/zigbox/actions/runs/44198012387) " ++
        "attempt 2 | " ++
        "[" ++ m6d_name ++ "]" ++
        "(https://github.com/Zigbox/zigbox/actions/runs/44198012387/job/134468367728) | " ++
        "skipped (allowed: Google WIF is not set up yet) |";
    try testing.expect(std.mem.indexOf(u8, out.buffered(), m6d_row) != null);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "| demo-m6d") == null);
}

test "a run of another commit, a failed run and a short job listing refuse" {
    // Goal: the table is refused, never rendered, when the evidence is not the product's or not
    // whole. Method: the recorded 0.5.3 responses against another commit, and edited copies.
    var buffer: [64 * 1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var diagnostic: Diagnostic = .{};
    const other = "f8209996e8c96121fa1f9b91d94ed4d6344a3dea";
    var counts: Counts = .{};
    const wrong_commit = gate_of("ci", other, fixture_ci_runs, fixture_ci_jobs);
    try testing.expectError(error.Refused, render_gate(&out, &wrong_commit, &counts, &diagnostic));
    try testing.expect(std.mem.indexOf(u8, diagnostic.text, "not the product") != null);

    const failed_runs = try replace_once(fixture_ci_runs, "\"success\"", "\"failure\"");
    defer testing.allocator.free(failed_runs);
    const failed_run = gate_of("ci", sha_0_5_3, failed_runs, fixture_ci_jobs);
    try testing.expectError(error.Refused, render_gate(&out, &failed_run, &counts, &diagnostic));
    const failed_text = "ci: run 44198012387 ended failure, not success";
    try testing.expectEqualStrings(failed_text, diagnostic.text);

    const count_27 = "\"total_count\": 27";
    const short_jobs = try replace_once(fixture_ci_jobs, "\"total_count\": 26", count_27);
    defer testing.allocator.free(short_jobs);
    const short = gate_of("ci", sha_0_5_3, fixture_ci_runs, short_jobs);
    try testing.expectError(error.Refused, render_gate(&out, &short, &counts, &diagnostic));
    try testing.expectEqualStrings("ci: the job listing holds 26 of 27 jobs", diagnostic.text);
    try testing.expectEqual(@as(u32, 0), counts.total());
}

fn replace_once(text: []const u8, old: []const u8, new: []const u8) ![]u8 {
    const at = std.mem.indexOf(u8, text, old).?; // The fixture holds it; a test that misses fails.
    return std.mem.concat(testing.allocator, u8, &.{ text[0..at], new, text[at + old.len ..] });
}

fn release_gate(names: []const u8) Gate {
    var gate = gate_of("release", sha_0_5_3, fixture_release_run, fixture_release_jobs);
    gate.workflow_text = fixture_release_workflow;
    gate.jobs_named = names;
    return gate;
}

test "the release run's named jobs: each must be there once and completed" {
    // Goal: a named job missing from the release run, a name given twice (which once hid a
    // missing one), or a job still running refuses. Method: the recorded release run with a name
    // it lacks, a name repeated, and a named job edited to in_progress.
    var buffer: [16 * 1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var diagnostic: Diagnostic = .{};
    var counts: Counts = .{};
    const missing = release_gate("plan the release,no such job");
    try testing.expectError(error.Refused, render_gate(&out, &missing, &counts, &diagnostic));
    try testing.expectEqualStrings(
        "release: job 'no such job' is not in run 44205899240",
        diagnostic.text,
    );
    const twice = release_gate("plan the release,plan the release");
    try testing.expectError(error.Refused, render_gate(&out, &twice, &counts, &diagnostic));
    try testing.expectEqualStrings(
        "release: the job name 'plan the release' is given twice",
        diagnostic.text,
    );
    const running_jobs = try replace_once(
        fixture_release_jobs,
        "\"status\": \"completed\"",
        "\"status\": \"in_progress\"",
    );
    defer testing.allocator.free(running_jobs);
    var running = release_gate("plan the release");
    running.jobs_text = running_jobs;
    try testing.expectError(error.Refused, render_gate(&out, &running, &counts, &diagnostic));
    const running_text = "release: job 'plan the release' is in_progress, not completed";
    try testing.expectEqualStrings(running_text, diagnostic.text);
}

fn gate_of(workflow: []const u8, sha: []const u8, runs: []const u8, jobs: []const u8) Gate {
    return .{
        .workflow = workflow,
        .workflow_text = fixture_ci_workflow,
        .product_sha = sha,
        .runs_text = runs,
        .jobs_text = jobs,
        .skips_allowed = &skips_0_5_3,
    };
}

test "each label at its boundary, and the outcomes that refuse" {
    // Goal: the three labels and the refusals, one case each, including a skipped step beating a
    // failed one, `Post X` not counting only after a step X, and a success with no step of its
    // own refusing. Method: classify hand-built jobs; these are synthetic (a failed step in a
    // successful job was never recorded: see the continue-on-error test), and say so.
    var diagnostic: Diagnostic = .{};
    const ok: Step = .{ .name = "Run the demo", .conclusion = "success" };
    const skip: Step = .{ .name = "Run the demo", .conclusion = "skipped" };
    const fail: Step = .{ .name = "Probe", .conclusion = "failure" };
    const cache: Step = .{ .name = "Cache the VM base image", .conclusion = "skipped" };
    const cache_ok: Step = .{ .name = "Cache the VM base image", .conclusion = "success" };
    const post_skipped: Step = .{ .name = "Post Cache the VM base image", .conclusion = "skipped" };
    const post_own: Step = .{ .name = "Post the result", .conclusion = "skipped" };
    const set_up: Step = .{ .name = "Set up job", .conclusion = "success" };
    const cancelled: Step = .{ .name = "Run the demo", .conclusion = "cancelled" };
    const base: Job = .{
        .name = "j",
        .status = "completed",
        .conclusion = "success",
        .html_url = "u",
        .head_sha = "s",
        .run_id = 1,
    };
    const cases = [_]struct { steps: []const Step, conclusion: []const u8, label: ?Label }{
        .{ .steps = &.{ cache_ok, ok, post_skipped }, .conclusion = "success", .label = .passed },
        .{ .steps = &.{ ok, post_skipped }, .conclusion = "success", .label = .skipped },
        .{ .steps = &.{ cache, post_skipped }, .conclusion = "success", .label = .skipped },
        .{ .steps = &.{ ok, post_own }, .conclusion = "success", .label = .skipped },
        .{ .steps = &.{set_up}, .conclusion = "success", .label = null },
        .{ .steps = &.{}, .conclusion = "success", .label = null },
        .{ .steps = &.{ ok, fail }, .conclusion = "success", .label = .expected_failure_observed },
        .{ .steps = &.{ fail, skip }, .conclusion = "success", .label = .skipped },
        .{ .steps = &.{}, .conclusion = "skipped", .label = .skipped },
        .{ .steps = &.{ ok, fail }, .conclusion = "failure", .label = null },
        .{ .steps = &.{ok}, .conclusion = "cancelled", .label = null },
        .{ .steps = &.{ ok, cancelled }, .conclusion = "success", .label = null },
    };
    for (cases) |case| {
        var job = base;
        job.steps = case.steps;
        job.conclusion = case.conclusion;
        if (case.label) |label| {
            try testing.expectEqual(label, try classify(&job, "ci", &diagnostic));
        } else {
            try testing.expectError(error.Refused, classify(&job, "ci", &diagnostic));
        }
    }
}

test "a cell escapes the table's separator" {
    // Goal: a job name with `|` or a newline cannot break the row. Method: render one cell.
    var buffer: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try write_cell(&out, "a|b\nc");
    try testing.expectEqualStrings("a\\|b c", out.buffered());
}

test "jobs and steps at their bounds pass, one past refuses" {
    // Goal: `release_evidence_jobs_max` jobs and `release_evidence_steps_max` steps are read, one
    // more of either refuses. Method: synthetic listings of each length.
    var diagnostic: Diagnostic = .{};
    const run: Run = .{
        .id = 1,
        .head_sha = "s",
        .status = "completed",
        .html_url = "u",
        .created_at = "t",
    };
    const gate = gate_of("ci", "s", "", "");
    const step: Step = .{ .name = "Run the demo", .conclusion = "success" };
    var steps: [constants.release_evidence_steps_max + 1]Step = @splat(step);
    const job: Job = .{
        .name = "j",
        .status = "completed",
        .conclusion = "success",
        .html_url = "u",
        .head_sha = "s",
        .run_id = 1,
        .steps = steps[0..constants.release_evidence_steps_max],
    };
    var all: [constants.release_evidence_jobs_max + 1]Job = @splat(job);
    const at_max: Jobs = .{ .total_count = all.len - 1, .jobs = all[0 .. all.len - 1] };
    try check_jobs(&at_max, &run, &gate, &diagnostic);
    const past_max: Jobs = .{ .total_count = all.len, .jobs = &all };
    try testing.expectError(error.Refused, check_jobs(&past_max, &run, &gate, &diagnostic));
    try testing.expectEqualStrings("ci: run 1 has 101 jobs, above 100", diagnostic.text);

    try testing.expectEqual(Label.passed, try classify(&job, "ci", &diagnostic));
    var long = job;
    long.steps = &steps;
    try testing.expectError(error.Refused, classify(&long, "ci", &diagnostic));
    try testing.expectEqualStrings("ci: job 'j' has 129 steps, above 128", diagnostic.text);
}

test "every job ci.yml defines must be in the run exactly once" {
    // Goal: the ci gate lists its jobs from the workflow file, so a job dropped from the run, or
    // a second job under a name, refuses instead of leaving one row fewer. Method: 0.5.3's ci.yml
    // (26 jobs, as the recorded run) against the recorded jobs with one name edited.
    var names: Names = .{};
    var diagnostic: Diagnostic = .{};
    try workflow_scan(fixture_ci_workflow, "ci", &names, &diagnostic);
    try testing.expectEqual(@as(u32, 26), names.count);
    try testing.expectEqualStrings("what changed", names.items[0]);
    try testing.expect(names.contains("demo-m6d (Ubuntu 24.04 VM, KVM, Artifact Registry " ++
        "and gcr.io through WIF)"));
    var buffer: [64 * 1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var counts: Counts = .{};
    const renamed = try replace_once(fixture_ci_jobs, "\"name\": \"tidy\"", "\"name\": \"tidy2\"");
    defer testing.allocator.free(renamed);
    const missing = gate_of("ci", sha_0_5_3, fixture_ci_runs, renamed);
    try testing.expectError(error.Refused, render_gate(&out, &missing, &counts, &diagnostic));
    try testing.expectEqualStrings("ci: job 'tidy' is not in run 44198012387", diagnostic.text);
    const doubled = try replace_once(fixture_ci_jobs, "\"name\": \"test\"", "\"name\": \"tidy\"");
    defer testing.allocator.free(doubled);
    const twice = gate_of("ci", sha_0_5_3, fixture_ci_runs, doubled);
    try testing.expectError(error.Refused, render_gate(&out, &twice, &counts, &diagnostic));
    try testing.expectEqualStrings("ci: job 'tidy' is in run 44198012387 2 times", diagnostic.text);
    try testing.expectEqual(@as(u32, 0), counts.total());
}

test "a continue-on-error failure reads as a success, so the workflow file refuses it" {
    // Goal: the reason the scan refuses continue-on-error, kept as evidence: the API reported
    // the probe's failed continue-on-error step as `success`, so its job never reads "expected
    // failure observed". Method: the recorded probe (run 44380683397, scratch branch, never
    // merged; the GitHub MCP server's serialization, a subset of the API's fields), classified,
    // then its workflow file scanned.
    var parse_memory: [64 * 1024]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&parse_memory);
    const allocator = fixed.allocator();
    const parsed = std.json.parseFromSliceLeaky(Jobs, allocator, fixture_probe_jobs, json_options);
    const jobs = try parsed;
    const probe = &jobs.jobs[0];
    try testing.expectEqualStrings("continue-on-error probe", probe.name);
    try testing.expectEqualStrings("Fails, continue-on-error", probe.steps[1].name);
    try testing.expectEqualStrings("success", probe.steps[1].conclusion.?);
    var diagnostic: Diagnostic = .{};
    try testing.expectEqual(Label.skipped, try classify(probe, "coe-probe", &diagnostic));
    var without_skipped = probe.*;
    const kept = [_]Step{ probe.steps[0], probe.steps[1], probe.steps[2], probe.steps[4] };
    without_skipped.steps = &kept;
    try testing.expectEqual(Label.passed, try classify(&without_skipped, "coe-probe", &diagnostic));
    var names: Names = .{};
    const scanned = workflow_scan(fixture_probe_workflow, "coe-probe", &names, &diagnostic);
    try testing.expectError(error.Refused, scanned);
    const refused = "coe-probe: line 16 of the workflow file sets continue-on-error, and the " ++
        "API reports a step that fails under it as a success";
    try testing.expectEqualStrings(refused, diagnostic.text);
}

test "the workflow scan reads names and refuses what it cannot predict" {
    // Goal: each shape the scan reads or refuses, one case each. Method: small synthetic files.
    const cases = [_]struct { text: []const u8, names: ?[]const u8 }{
        .{ .text = "on: push\njobs:\n  a:\n    runs-on: x\n  b:\n    name: 'B one' # c\n" ++
            "    continue-on-error: false\nenv:\n  c:\n", .names = "a,B one" },
        .{ .text = "jobs:\n  a:\n    strategy:\n      matrix: {}\n", .names = null },
        .{ .text = "jobs:\n  a:\n    uses: ./.github/workflows/x.yml\n", .names = null },
        .{ .text = "jobs:\n  a:\n    name: x ${{ matrix.y }}\n", .names = null },
        .{ .text = "jobs:\n  a:\n    name: >\n      folded\n", .names = null },
        .{ .text = "jobs:\n  a:\n    continue-on-error: ${{ true }}\n", .names = null },
        .{ .text = "jobs:\n  a:\n    steps:\n      - continue-on-error: true\n", .names = null },
        .{ .text = "jobs:\n  a:\n    name: b\n  b:\n", .names = null },
        .{ .text = "jobs:\n# none\n", .names = null },
        .{ .text = "", .names = null },
    };
    var diagnostic: Diagnostic = .{};
    for (cases) |case| {
        var names: Names = .{};
        const scanned = workflow_scan(case.text, "w", &names, &diagnostic);
        const expected = case.names orelse {
            try testing.expectError(error.Refused, scanned);
            continue;
        };
        try scanned;
        var want: Names = .{};
        try names_split(expected, "w", &want, &diagnostic);
        try testing.expectEqual(want.count, names.count);
        for (want.slice(), names.slice()) |left, right| try testing.expectEqualStrings(left, right);
    }
}

test "a workflow file at the job bound passes, one past refuses" {
    // Goal: `release_evidence_jobs_max` jobs are listed, one more refuses. Method: generated files.
    var text: [constants.release_evidence_jobs_max + 1][16]u8 = undefined;
    var buffer: [(constants.release_evidence_jobs_max + 1) * 16 + 8]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try out.writeAll("jobs:\n");
    for (&text, 0..) |*line, index| {
        const job = try std.fmt.bufPrint(line, "  j{d}:\n", .{index});
        if (index == constants.release_evidence_jobs_max) {
            var names: Names = .{};
            var diagnostic: Diagnostic = .{};
            try workflow_scan(out.buffered(), "w", &names, &diagnostic);
            try testing.expectEqual(constants.release_evidence_jobs_max, names.count);
        }
        try out.writeAll(job);
    }
    var names: Names = .{};
    var diagnostic: Diagnostic = .{};
    try testing.expectError(error.Refused, workflow_scan(out.buffered(), "w", &names, &diagnostic));
    try testing.expectEqualStrings("w: more than 100 jobs", diagnostic.text);
}

test "a skip refuses unless its job is allowed, and an allowed one names its reason" {
    // Goal: a skipped job or step refuses the table unless the job is on the allow-list, and an
    // allowed one reads "skipped (allowed: <reason>)", never "passed". Method: 0.5.3's recorded
    // ci run, whose demo-m6d skipped its demo steps, without and with the list.
    var buffer: [64 * 1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var diagnostic: Diagnostic = .{};
    var counts: Counts = .{};
    var unlisted = gate_of("ci", sha_0_5_3, fixture_ci_runs, fixture_ci_jobs);
    unlisted.skips_allowed = &.{.{ .job = "tidy", .reason = "r" }};
    try testing.expectError(error.Refused, render_gate(&out, &unlisted, &counts, &diagnostic));
    try testing.expectEqualStrings("ci: job '" ++ m6d_name ++ "' was skipped, or a step of " ++
        "it, and it is not allowed to be (--allow-skip)", diagnostic.text);
    out = .fixed(&buffer);
    counts = .{};
    var listed = gate_of("ci", sha_0_5_3, fixture_ci_runs, fixture_ci_jobs);
    listed.skips_allowed = &.{.{ .job = m6d_name, .reason = "a | b" }};
    try render_gate(&out, &listed, &counts, &diagnostic);
    const row_end = "| skipped (allowed: a \\| b) |";
    try testing.expect(std.mem.indexOf(u8, out.buffered(), row_end) != null);
    try testing.expectEqual(@as(u32, 1), counts.skipped);
    try testing.expectEqual(@as(u32, 25), counts.passed);
}

fn gate_0_6_0(jobs: []const u8) Gate {
    var gate = gate_of("ci", sha_0_6_0, fixture_0_6_0_ci_runs, jobs);
    gate.workflow_text = fixture_0_6_0_ci_workflow;
    return gate;
}

inline fn fuzz_name(comptime shard: []const u8) []const u8 {
    return "fuzz (shard " ++ shard ++ " of 4, every fuzzer, fresh seeds)";
}

test "0.6.0's recorded runs render the checked-in table, the fuzz matrix as four jobs" {
    // Goal: the release that found the gap. ci.yml at 0.6.0's release commit has one matrix job,
    // `fuzz`, whose name holds `${{ matrix.shard }}` (release run 45050090867 refused it); its
    // four shards are four predicted names, each in the recorded run once. Method: scan the
    // recorded ci.yml, then render the recorded API answers (ci run 45039162888 and the release
    // run's named jobs, trimmed as 0.5.3's) and compare with the table the tool printed for them.
    var names: Names = .{};
    var diagnostic: Diagnostic = .{};
    try workflow_scan(fixture_0_6_0_ci_workflow, "ci", &names, &diagnostic);
    try testing.expectEqual(@as(u32, 29), names.count);
    inline for (.{ "1", "2", "3", "4" }) |shard| {
        try testing.expect(names.contains(fuzz_name(shard)));
    }
    try testing.expect(!names.contains(fuzz_name("${{ matrix.shard }}")));
    var buffer: [64 * 1024]u8 = undefined;
    @memset(&buffer, 0xaa);
    var out: std.Io.Writer = .fixed(&buffer);
    var release = gate_of("release", sha_0_6_0, fixture_0_6_0_release_run, "");
    release.workflow_text = fixture_0_6_0_release_workflow;
    release.jobs_text = fixture_0_6_0_release_jobs;
    release.jobs_named = release_jobs_named;
    try render_test(&out, &.{ gate_0_6_0(fixture_0_6_0_ci_jobs), release }, &diagnostic);
    try testing.expectEqualStrings(fixture_0_6_0_table, out.buffered());
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, out.buffered(), "| [fuzz (shard "));
}

test "a matrix job's names must each be in the run once, and the run holds no other job" {
    // Goal: a shard missing from the run, or a job beside the four that the file does not
    // define, refuses. Method: 0.6.0's recorded jobs with shard 3 renamed to a fifth shard, and
    // with a fifth shard's job added (total_count raised to match).
    var buffer: [64 * 1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var diagnostic: Diagnostic = .{};
    var counts: Counts = .{};
    const shard_3 = "\"name\": \"" ++ fuzz_name("3");
    const renamed = try replace_once(fixture_0_6_0_ci_jobs, shard_3, "\"name\": \"" ++
        fuzz_name("5"));
    defer testing.allocator.free(renamed);
    const missing = gate_0_6_0(renamed);
    try testing.expectError(error.Refused, render_gate(&out, &missing, &counts, &diagnostic));
    try testing.expectEqualStrings("ci: job '" ++ fuzz_name("3") ++ "' is not in run " ++
        "45039162888", diagnostic.text);
    const fifth = "{\"name\": \"" ++ fuzz_name("5") ++ "\", \"status\": \"completed\", " ++
        "\"conclusion\": \"success\", \"html_url\": \"u\", \"head_sha\": \"" ++ sha_0_6_0 ++
        "\", \"run_id\": 45039162888, \"steps\": [{\"name\": \"Fuzz\", \"conclusion\": " ++
        "\"success\"}]},";
    const count_30 = "\"total_count\": 30";
    const counted = try replace_once(fixture_0_6_0_ci_jobs, "\"total_count\": 29", count_30);
    defer testing.allocator.free(counted);
    const added = try replace_once(counted, "\"jobs\": [", "\"jobs\": [" ++ fifth);
    defer testing.allocator.free(added);
    const extra = gate_0_6_0(added);
    try testing.expectError(error.Refused, render_gate(&out, &extra, &counts, &diagnostic));
    try testing.expectEqualStrings("ci: job '" ++ fuzz_name("5") ++ "' of run 45039162888 " ++
        "is not one the workflow file defines", diagnostic.text);
    try testing.expectEqual(@as(u32, 0), counts.total());
}

const matrix_head = "jobs:\n  f:\n    name: f ${{ matrix.s }}\n    strategy:\n";

test "the workflow scan reads the one matrix shape" {
    // Goal: the matrix shape the scan reads, in each order and form it allows, gives one name
    // per value, written as it stands. Method: small synthetic files and their expected names.
    const cases = [_]struct { text: []const u8, names: []const u8 }{
        .{ .text = matrix_head ++ "      fail-fast: false\n      max-parallel: 2\n" ++
            "      matrix: # c\n        s: [1, 2, 0, 10, a-b, Linux_x] # c\n" ++
            "    steps:\n      - run: x ${{ matrix.s }}\n  g:\n", .names = "f 1,f 2,f 0,f 10," ++
            "f a-b,f Linux_x,g" },
        .{ .text = "jobs:\n  f:\n    strategy:\n      matrix:\n        os: [linux,mac]\n" ++
            "    name: ${{ matrix.os }}/${{ matrix.os }}\n", .names = "linux/linux,mac/mac" },
        .{
            .text = matrix_head ++ "      matrix:\n        s: [999999999]\n",
            .names = "f 999999999",
        },
    };
    var diagnostic: Diagnostic = .{};
    for (cases) |case| {
        var names: Names = .{};
        try workflow_scan(case.text, "w", &names, &diagnostic);
        var want: Names = .{};
        try names_split(case.names, "w", &want, &diagnostic);
        try testing.expectEqual(want.count, names.count);
        for (want.slice(), names.slice()) |left, right| try testing.expectEqualStrings(left, right);
    }
}

test "the workflow scan refuses every other matrix shape" {
    // Goal: each matrix form outside the one read refuses, with the line and what it holds.
    // Method: small synthetic files, each with the refusal it must print.
    const in_matrix = matrix_head ++ "      matrix:\n";
    const cases = [_]struct { text: []const u8, refusal: []const u8 }{
        .{ .text = in_matrix ++ "        include: [a]\n", .refusal = "6 of the workflow file " ++
            "holds a matrix include, whose job names it cannot list" },
        .{ .text = in_matrix ++ "        s: [1]\n        exclude: [a]\n", .refusal = "7 of the " ++
            "workflow file holds a matrix exclude, whose job names it cannot list" },
        .{ .text = in_matrix ++ "        s: [1]\n        t: [2]\n", .refusal = "7 of the " ++
            "workflow file holds a matrix of more than one key, whose job names it cannot list" },
        .{ .text = in_matrix ++ "        s:\n          - 1\n", .refusal = "6 of the workflow " ++
            "file holds a matrix value that is not a one-line list of plain words and numbers" },
        .{ .text = in_matrix ++ "        s:\n        - 1\n", .refusal = "6 of the workflow " ++
            "file holds a matrix value that is not" },
        .{
            .text = matrix_head ++ "      matrix: ${{ fromJSON(needs.a.outputs.m) }}\n",
            .refusal = "5 of the workflow file holds a matrix from an expression",
        },
        .{ .text = matrix_head ++ "      matrix: {s: [1]}\n", .refusal = "5 of the workflow " ++
            "file holds a matrix it cannot read" },
        .{ .text = "jobs:\n  f:\n    name: f ${{ matrix.s }} ${{ github.ref }}\n    strategy:\n" ++
            "      matrix:\n        s: [1]\n", .refusal = "3 of the workflow file holds a job " ++
            "name with an expression other than its matrix value" },
        .{ .text = "jobs:\n  f:\n    name: f ${{ matrix.t }}\n    strategy:\n" ++
            "      matrix:\n        s: [1]\n", .refusal = "other than its matrix value" },
        .{ .text = "jobs:\n  f:\n    name: f ${{matrix.s}}\n    strategy:\n" ++
            "      matrix:\n        s: [1]\n", .refusal = "other than its matrix value" },
        .{
            .text = "jobs:\n  f:\n    strategy:\n      matrix:\n        s: [1]\n",
            .refusal = "3 of the workflow file holds a matrix job with no name",
        },
        .{
            .text = "jobs:\n  f:\n    name: f\n    strategy:\n      matrix:\n        s: [1]\n",
            .refusal = "3 of the workflow file holds a matrix job name that does not hold",
        },
        .{ .text = matrix_head ++ "      fail-fast: false\n", .refusal = "4 of the workflow " ++
            "file holds a strategy with no one-key matrix" },
        .{ .text = matrix_head ++ "      foo: 1\n", .refusal = "a strategy key it cannot read" },
        .{ .text = matrix_head ++ "       matrix:\n", .refusal = "a strategy it cannot read" },
        .{ .text = matrix_head ++ "        s: [1]\n", .refusal = "a strategy it cannot read" },
        .{ .text = in_matrix ++ "        s: [1]\n          t: 2\n", .refusal = "7 of the " ++
            "workflow file holds a strategy it cannot read" },
        .{ .text = in_matrix ++ "        s: [1]\n      matrix:\n", .refusal = "a second matrix" },
        .{ .text = in_matrix ++ "        s: [1]\n    strategy:\n", .refusal = "a second strategy" },
        .{ .text = "jobs:\n  f:\n    strategy: {matrix: {s: [1]}}\n", .refusal = "a strategy " ++
            "it cannot read" },
        .{ .text = in_matrix ++ "        s: [1]\n    uses: ./x.yml\n", .refusal = "a reusable" },
    };
    var diagnostic: Diagnostic = .{};
    for (cases) |case| {
        var names: Names = .{};
        const scanned = workflow_scan(case.text, "w", &names, &diagnostic);
        try testing.expectError(error.Refused, scanned);
        if (std.mem.indexOf(u8, diagnostic.text, case.refusal) == null) {
            std.debug.print("{s}\n  printed: {s}\n", .{ case.text, diagnostic.text });
            return error.TestUnexpectedResult;
        }
    }
}

test "the workflow scan refuses a matrix value YAML could read otherwise" {
    // Goal: only a value GitHub renders exactly as written is read: no float, leading zero,
    // sign, quote, boolean or null word, empty item or repeated value; a list left open refuses.
    // Method: one file per value list.
    const lists = [_][]const u8{
        "[1.10]", "[010]", "[-1]",     "['a']",  "[yes]", "[True]", "[null]",
        "[off]",  "[]",    "[1, , 2]", "[1, 2",  "[a b]", "[1e3]",  "[1234567890]",
        "[[1]]",  "[1]x",  "[1]#c",    "[1, 1]", "[~]",   "[a.b]",  "[${{ x }}]",
    };
    var diagnostic: Diagnostic = .{};
    for (lists) |list| {
        var text: [256]u8 = undefined;
        const file = try std.fmt.bufPrint(&text, "{s}      matrix:\n        s: {s}\n", .{
            matrix_head, list,
        });
        var names: Names = .{};
        const scanned = workflow_scan(file, "w", &names, &diagnostic);
        testing.expectError(error.Refused, scanned) catch |err| {
            std.debug.print("accepted: {s}\n", .{list});
            return err;
        };
    }
}

test "matrix names at the expanded byte bound pass, one byte past refuses" {
    // Goal: names expanded from matrices fill `release_evidence_expanded_bytes_max` exactly, and
    // one byte more refuses. Method: a job of 8 values whose names are each an eighth of the bound
    // long, then the same with a name one byte longer.
    const per_name = constants.release_evidence_expanded_bytes_max / 8;
    comptime assert(per_name * 8 == constants.release_evidence_expanded_bytes_max);
    var diagnostic: Diagnostic = .{};
    for ([_]usize{ 0, 1 }) |extra| {
        var file: std.Io.Writer.Allocating = .init(testing.allocator);
        defer file.deinit();
        try file.writer.writeAll("jobs:\n  f:\n    name: ");
        try file.writer.splatByteAll('a', per_name - 1 + extra);
        try file.writer.writeAll("${{ matrix.s }}\n    strategy:\n      matrix:\n" ++
            "        s: [1, 2, 3, 4, 5, 6, 7, 8]\n");
        var names: Names = .{};
        const scanned = workflow_scan(file.written(), "w", &names, &diagnostic);
        if (extra == 0) {
            try scanned;
            try testing.expectEqual(@as(u32, 8), names.count);
            const bound = constants.release_evidence_expanded_bytes_max;
            try testing.expectEqual(bound, names.expanded_used);
        } else {
            try testing.expectError(error.Refused, scanned);
            try testing.expectEqualStrings("w: the job names its matrices expand to are above " ++
                "32768 bytes (release_evidence_expanded_bytes_max)", diagnostic.text);
        }
    }
}
