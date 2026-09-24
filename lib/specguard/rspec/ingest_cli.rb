# frozen_string_literal: true

require "json"
require "optparse"

require_relative "../rspec"
require_relative "ingest_reporter"
require_relative "transport"

# `specguard-ingest`'s command line — the other end of `log/test_results.jsonl`.
#
# == Why this file is not on `require "specguard/rspec"`'s chain
#
# `specguard-lint` runs on machines that never make a network call, and putting
# this file on the umbrella's chain would put `net/http`, `uri` and `zlib` on
# the linter's load path to serve a command it never invokes. So it is loaded by
# its own path, exactly as the formatter is and for the same reason —
# `require "specguard/rspec/ingest_cli"`, which `bin/specguard-ingest` does.
module SpecGuard
  module RSpec
    # Replays a saved run: reads a `log/test_results.jsonl` back and re-delivers
    # each line through the {Transport} this gem already ships.
    #
    # == The file is not a new wire format, and that is the whole design
    #
    # `SpecGuard::RSpecFormatter#deliver` hands the *same* Hash to
    # `Transport#deliver` and to its own `append`, and each of them calls
    # `JSON.generate` on it once. A line in the sink is therefore byte-for-byte
    # the body the endpoint refused, so replaying it needs no parser, no
    # migration and no versioning — only something that reads a line back and
    # POSTs it. That is all this class is.
    #
    # == The exit contract, which is {CLI}'s reasoning transferred verbatim
    #
    #   0  every line was accepted
    #   1  at least one line was refused by the endpoint
    #   2  this tool could not do its job
    #
    # Ruby exits **1** for an uncaught exception and for an uncaught
    # `OptionParser::InvalidOption`, and 1 is already spent here on "the
    # endpoint said no". Left alone, `specguard-ingest --dry-runn` and an
    # unreadable file would both report that the platform refused a run it was
    # never offered — a tool failure wearing the costume of a content failure,
    # which is the defect {CLI} exists to keep out of the linter. So {#run}
    # rescues and *returns* rather than exits, and {EXIT_REFUSED} is produced in
    # exactly one place — {#exit_code}, over a `:refused` {LineResult} — so it
    # means that and nothing else.
    #
    # `Interrupt`, `SignalException` and `SystemExit` are deliberately not
    # caught. Ctrl-C halfway through a 40-line file must stay Ctrl-C.
    #
    # `Errno::EPIPE` joins them, and for the shell's side of the same reason
    # (SPGD-1288). A truncated report — `--list` into `head`, a CI log
    # tailer that stopped reading — is not this tool failing:
    # the deliveries all happened and the per-line verdicts are in hand, and
    # the reader simply stopped listening. Left to the backstop it is a
    # fabricated 2 with an `internal error:` line — on `--list`, a 0 → 2
    # flip on a clean listing. So the rescue below catches it ahead of the
    # bands and yields the code the run had already computed: {#exit_code}
    # over the results when they exist, {EXIT_OK} when the pipe closed
    # before any verdict did — the `--list` path builds none, and a run that
    # reported nothing has no verdict for an exit code to carry. On the
    # delivery path a truncated report that exits 2 is exiting with its
    # legitimate `:undelivered` code, not the backstop's.
    #
    # == Where the line between 1 and 2 actually falls
    #
    # Not where {Transport::Result} draws it. That struct answers `:rejected`
    # for *any* non-2xx, and "a non-2xx came back" is not the same claim as
    # "the endpoint read this payload and judged it" — so this class redraws
    # the line rather than inheriting it.
    #
    # The platform emits exactly one verdict about a payload:
    # `Api::V1::IngestsController#create` reaches
    # `render_bad_request(payload.errors)`, a **400**. Every other non-2xx is
    # the endpoint declining to look at the run — a 401 is answered by
    # `authenticate_api_key!`'s `before_action` before the action runs at all,
    # so `Ingest::Payload` is never even constructed — or the endpoint not
    # being there (404), or the platform failing (429, 5xx). **Nothing was
    # stored in any of them**, and none of them is a statement about anyone's
    # suite. They are `:undelivered`, and they are a 2.
    #
    # `:failed` — connection refused, DNS, TLS, a read timeout — is a 2 for the
    # same reason arrived at from further away: nothing was delivered and no
    # verdict exists. A socket error reported as a 1 would be this tool telling
    # an operator their run is bad on the strength of a broken pipe; a 404
    # reported as a 1 would be it telling them the same thing on the strength
    # of a typo in `SPECGUARD_ENDPOINT`, while its own advice line says to go
    # fix that variable.
    #
    # That last case is the one that fixes the rule in place: an **unset**
    # `SPECGUARD_ENDPOINT` is a 2 from {#build_transport}, so an endpoint set
    # to the *wrong URL* must be a 2 as well. Same operator mistake, same fix,
    # and the case where this tool knows more must not report worse.
    #
    # 2 also dominates: a file where line 3 was refused and line 7 never
    # arrived exits 2, because the second fact is the one that leaves work
    # undone. Both are printed either way — the exit code chooses what to
    # shout, never what to say.
    #
    # == It re-delivers EVERY line, and will not guess which ones were failures
    #
    # The sink is not a failure log. `#deliver` writes to it when a delivery
    # failed *and* when no API key was set at all (`return append(data) if
    # blank?(configuration.api_key)`), and the two are indistinguishable on the
    # line — there is no field to tell them apart. A developer's local file is
    # therefore a file of ordinary laptop runs, and pointing this command at it
    # sends all of them.
    #
    # A heuristic here would be worse than the gap: it would be this tool
    # guessing at somebody's intent from data that does not carry it, and being
    # confidently wrong about which runs reach the platform. So the tool is
    # explicit and user-initiated instead, `--help` says so in as many words,
    # and no line is filtered.
    #
    # `--from-line` and `--lines` are the two things that narrow the set, and
    # both narrow it by numbers the user typed after reading the report — which
    # is the opposite of a guess. They exist because {LineResult}'s numbering is
    # only half of criterion 3: a report that says line 7 was refused is worth
    # little if acting on it means re-sending lines 1 through 6, and re-sending
    # a line that carries no `ci_run_id` is not free — `RunRecorder` has no
    # identity to fold it onto, so it becomes a second row.
    #
    # == Why a suffix was not enough, and why `--lines` is not a heuristic
    #
    # `--from-line N` can express only a *suffix*, and the set a report points
    # at is a suffix at most once. The sink is append-only and mixes both
    # sources, so ordinary keyless laptop runs keep landing *after* the CI
    # failures somebody wants to replay. Worse, {CONTENT_REFUSAL_CODES} is a
    # content verdict — a 400 will be refused every time it is offered — so a
    # 400 sitting at line 3 of a 40-line file is a line no suffix can step over,
    # and the file can never be replayed to completion.
    #
    # `--lines 3,7,12-15` is the same category of thing as `--from-line`: a set
    # the user typed, over the file's own numbering, after reading `--list`.
    # Nothing about the line's *content* is consulted, which is the line the
    # paragraph above draws and this flag stays on the explicit side of.
    #
    # The two are refused *together* — {UsageError}, a 2. They answer the same
    # question, and an intersection would silently drop a number the user typed
    # (`--from-line 5 --lines 3,7` delivers only 7, and the 3 vanishes without a
    # word). Quietly narrowing what it was asked for is the failure this whole
    # file is arranged against, so the combination is refused rather than
    # resolved. Carving the file up with `sed` is not the alternative either: a
    # carved temp file renumbers, and the whole value of resuming from a report
    # is that line 12 is still line 12.
    #
    # A *repeated* selector is the other half of that question and gets the
    # opposite answer deliberately, not by omission: `--lines 1,2 --lines 4`
    # delivers line 4, and `--from-line 2 --from-line 5` starts at 5, both by
    # last-wins. The reason the cross-flag case is refused does not reach this
    # one. Refusing `--from-line` with `--lines` is about two *different* flags
    # answering one question, where combining them yields a set smaller than
    # either one names and the user cannot see which of their numbers went. A
    # repeat is one flag answering its own question twice, and the later answer
    # *replaces* the earlier rather than intersecting it — the delivered set is
    # exactly the last one typed, which is the one thing on the command line
    # that is unambiguously current. It is also what makes a selector
    # overridable at all: a wrapper script or shell alias that bakes in
    # `--lines` is corrected by appending a new one, and refusing the repeat
    # would take that away for no gain in clarity. Last-wins is `OptionParser`'s
    # convention and the shell's; this file adopts it on purpose and pins it in
    # the spec, so it is a decision rather than a default nobody looked at.
    #
    # == `--drain`, the follow-through, and why it removes only what it saw
    #
    # A successful replay used to leave the queue byte-identical: this file had
    # no write, rename or truncate path, so the next incident's failures
    # appended behind runs that had already landed, and the README's retry
    # gesture — re-running the command — re-sent every one of them. A line with
    # a `ci_run_id` folds onto the run it already made, so re-sending it is
    # harmless; a line without one has nothing to fold onto and becomes a
    # second row on the platform. `--drain` is the opt-in answer: after the
    # deliveries, exactly the lines answered 202 **in this invocation** are
    # removed from the file.
    #
    # Only those. The removal is keyed to what was *observed*, never to what
    # was inferred — the same line this file draws against guessing which lines
    # were failures. A refused line is refused every time it is offered, an
    # undelivered one never arrived, an unparseable one was never a run, a
    # blank one was never anything, and a line a selector held back was never
    # sent — so all of them stay, byte for byte, in the file's order. The queue
    # is failure-only by construction, which is what makes removing accepted
    # lines coherent here in a way it would not be on the mixed local record:
    # draining a file of ordinary laptop runs would delete runs that were
    # never failures. That is the second guard — the drain refuses any path
    # that is not the configured replay queue, compared exactly as
    # {#no_such_file_message} compares, and it refuses `--list` too, since a
    # listing delivers nothing for it to drain.
    #
    # The rewrite is atomic: a temporary file in the same directory, renamed
    # over the original, so a failure mid-drain leaves the file as it was —
    # and the file is not touched at all unless something was accepted. Bytes
    # appended while the deliveries ran (the formatter appends to the queue
    # with no lock) are carried into the rewrite; the window that remains
    # between the final read and the rename is disclosed at {#drain_source},
    # not claimed closed. A drain that cannot complete is stated, never
    # silent: the deliveries are still reported in full, the warning names the
    # file, and the run exits 2, because a 0 would read as "drained" about a
    # queue that was not.
    #
    # == `--list`, which is what makes "check the file first" an instruction
    #
    # Having refused to guess *for* the user, this command owes them what they
    # need to decide. {#list} prints one row per line off the fields the
    # envelope already carries — `branch`, `commit_sha`, `ci_run_id` or its
    # absence, how many examples, how long — and delivers nothing. Reading the
    # file by hand is not the alternative: one line is one whole run, and at
    # this project's design point that is megabytes of JSON on a single
    # physical line.
    #
    # It short-circuits **ahead of {#build_transport}**, deliberately, and that
    # ordering is the load-bearing part. `build_transport` raises for a blank
    # `SPECGUARD_ENDPOINT` or `SPECGUARD_API_KEY`, and the file that most needs
    # checking is the one written *because no API key was set*
    # (`Formatter` — `return append(data) if blank?(configuration.api_key)`).
    # Requiring a key to look at the file would withdraw the instrument in
    # exactly the situation that produces the hazard.
    #
    # Listing delivers nothing, so it can never be a content verdict: it
    # answers 0 or 2 and never routes through {#exit_code}, which stays the one
    # place {EXIT_REFUSED} is produced.
    #
    # == What it will not claim
    #
    # The natural question about a replay is whether a line *folded onto* an
    # existing run or *created* a new one, and the platform does not answer it:
    # `Ingest::RunRecorder#record` find-or-creates by `ci_run_id` and the 202
    # body carries no created-versus-updated flag. So this class reports what it
    # can see — the `test_run_id` that came back, and whether the line carried a
    # `ci_run_id` at all — and states folding only where two lines *observed*
    # it: same `ci_run_id` in, same `test_run_id` out is one row, not an
    # inference about one. See {#folded_runs}.
    #
    # == `--json`, and the one thing the human report cannot say
    #
    # A 400 is the only *permanent* verdict here ({CONTENT_REFUSAL_CODES}), so
    # the only way to land a refused line is to learn which specs the platform
    # objected to and fix the payload. It names every one of them — one error per
    # bad spec — and {Transport::Result#reason} renders three, truncated to 300
    # characters, because it exists for the one stderr line an in-run CI warning
    # is allowed. On a systemic client bug over a 20,000-example suite, the
    # command whose entire job is to fix and re-send a refused run was showing
    # three of twenty thousand reasons.
    #
    # `--json` is the second channel that cap's own grounds hand over, and it is
    # a RENDERER: stdout carries one document instead of the human report, in
    # both modes, over the same {LineResult}s, the same counts, the same
    # groupings and the same {#exit_code}. Nothing about what this command
    # *decides* moves — the cap, `#reason` and the formatter's warning are
    # untouched, and the default output is byte-identical (pinned in
    # `spec/specguard/rspec/regression_targets_spec.rb`). See {IngestReporter}
    # for the document, and for which runs emit one.
    class IngestCLI
      BANNER = "Usage: specguard-ingest [options] <file>"

      # Shown by `--help`. The second paragraph is the one that has to be there:
      # the local record — and any replay-queue file from before the sink split
      # — mixes failed deliveries with ordinary keyless local runs and nothing
      # on the line tells them apart, so a developer must not be able to
      # discover only afterwards that they pushed their laptop's history.
      DESCRIPTION = <<~TEXT.freeze
        Re-delivers a saved run to SpecGuard's ingest endpoint. <file> is a file
        the RSpec formatter wrote — one whole run per line, byte-for-byte the
        body the endpoint was offered. The formatter writes failed deliveries
        to the replay queue, log/test_results.jsonl, and — when no API key is
        configured — ordinary local runs to the local development record,
        log/test_results.local.jsonl.

        EVERY line in <file> is delivered — or, when you narrow it, every line
        --from-line or --lines names. The two files were split precisely so a
        log/test_results.jsonl written entirely by this version or later could
        hold only genuine failed deliveries — by construction. But the local
        record, and any file written before the split, carries no marker: a
        laptop's file is a file of ordinary local runs mixed with genuine
        failures, indistinguishable on the line, and all of them will be sent.
        Nothing is filtered and nothing is guessed at.

        So check the file first: --list prints one row per line — branch, commit,
        ci_run_id or its absence, how many examples, how long — and delivers
        nothing at all. It needs no SPECGUARD_ENDPOINT and no SPECGUARD_API_KEY,
        because the file most worth checking is the one written when no API key
        was set. It composes with --from-line and --lines, so you can list the
        exact set you are about to send.

        Each line is delivered once, with no retry, and reported by its line
        number in <file>. Use --from-line to resume a file that was only partly
        accepted, or --lines to send an arbitrary set of them — 3,7,12-15 — over
        that same numbering, instead of re-sending all of it. Both narrow the
        same file, so give one or the other and never both.

        --drain is the follow-through, and it is opt-in: after the deliveries,
        the lines this invocation got a 202 for are removed from <file>, so the
        next incident's failures do not land behind runs that already landed.
        Everything else stays byte for byte and in order — refused, undelivered,
        unparseable and blank lines, and every line --from-line or --lines held
        back. Removing lines renumbers what is left: the report's line numbers
        describe <file> as it was read, not as the next run finds it, so resume
        by re-running --list (or --drain) rather than reusing those numbers.
        The rewrite is atomic: a temporary file in the same directory,
        renamed over the original, so a failure mid-drain leaves the file as it
        was, and bytes appended while the deliveries ran are carried into the
        rewrite. Only the replay queue is drained — another path is refused,
        because the local record is a development record, not a queue — and
        --drain with --list is refused too, since a listing delivers nothing
        for it to drain.

        Reads SPECGUARD_ENDPOINT, SPECGUARD_API_KEY and SPECGUARD_TIMEOUT.

        --json replaces the human report with one JSON document on stdout, in
        both modes. It carries every line's status, the endpoint's HTTP code and
        the FULL list of reasons a refusal named — the human line has room for
        three of them — plus the same summary counts and folding observations.
        Warnings stay on stderr, and a run that never got as far as reading
        <file> writes no document at all.

        Exit codes:
          0  every line was accepted — or, with --list, the file was listed
          1  at least one line was refused by the endpoint — it read the payload
             and said no (HTTP 400). Unreachable with --list, which delivers
             nothing and so can never carry a verdict about a run
          2  this tool could not do its job — bad flags, no endpoint or API key,
             an unreadable file, an unparseable line, a delivery that never
             reached the endpoint, or one the endpoint answered without ever
             reading it (401, 404, 429, 5xx — nothing was stored, so none of
             them is a verdict about your run). With --drain, a rewrite that
             could not complete is a 2 as well — the file is left as it was.
             With --list the only reachable 2s are a bad flag and a file that
             cannot be read: listing needs no credentials, and an unparseable
             line becomes a row in the listing rather than an exit code
      TEXT

      # Every line in the file was accepted by the endpoint — including the
      # vacuous case of a file with no lines in it, which is loud on stderr for
      # exactly the reason `specguard-lint`'s empty selection is: the contract
      # has no code for "there was nothing to do", so the warning carries it.
      EXIT_OK = 0
      # At least one line was refused. The only code that says something about
      # the *content* of a run, and the only path to it is a non-2xx whose
      # status is in {CONTENT_REFUSAL_CODES}.
      EXIT_REFUSED = 1
      # This tool could not do its job: bad flags, no endpoint or API key
      # configured, a file it could not read, a line it could not parse, a
      # delivery that never reached the endpoint at all, or one the endpoint
      # answered without ever reading — a 401, 404, 429 or 5xx.
      EXIT_MISUSE = 2

      # The status codes that carry a verdict about the payload — which on this
      # platform is exactly one.
      #
      # `Api::V1::IngestsController#create` reaches
      # `render_bad_request(payload.errors)` and nothing else. A 401 comes from
      # `authenticate_api_key!`'s `before_action` before the action runs, so
      # `Ingest::Payload` is never constructed and no verdict about the run
      # exists to report; a 403, 404, 429 or 5xx never gets as far as a body
      # either. See the class comment for what that costs an operator when it
      # is got wrong.
      #
      # A list of one rather than `code == 400`, so a platform that grows a
      # second verdict is a one-line change here — and deliberately *not*
      # pre-seeded with a 422 the platform does not send. An unlisted refusal
      # is reported as `:undelivered`, which under-claims, and under-claiming
      # is the safe direction: it sends an operator to look at their setup
      # rather than at a suite that was never judged.
      CONTENT_REFUSAL_CODES = [400].freeze

      # What happened to one line of the file. `number` is its 1-based position
      # in the file *as given*, counting the blank lines that were skipped, so
      # the report addresses the same lines an editor does and a partially
      # accepted file can be resumed from rather than blindly re-sent.
      #
      # `detail` is the flattened one-line rendering the text report prints, and
      # `code` and `reasons` are the two structured facts flattening it destroys
      # — the numeric HTTP status, and the **whole** array off
      # {Transport::Result} rather than the three {Transport::Result#reason} has
      # room for. They are carried rather than derived because a document cannot
      # be reconstructed from prose: `and 19997 more` is not the 19,997.
      #
      # `reasons` is whatever there is to say about why this line did not land,
      # as it arrived: the platform's own strings on a refusal (verbatim,
      # including a `nil` where the body said nothing readable), the parse
      # problem where the line was never a run, the exception's rendering where
      # nothing reached the endpoint, and `[]` on an acceptance. Normalising it
      # to a list of strings is {IngestReporter}'s job, because that guarantee
      # is the document's rather than this struct's.
      LineResult = Struct.new(:number, :status, :detail, :code, :reasons, :test_run_id, :ci_run_id,
                              keyword_init: true)

      # The envelope facts a *listing* states about one line — the same five
      # {#list_row} prints, extracted once so both renderers read one set of
      # facts rather than each deciding for itself what a non-scalar `branch` or
      # a non-Array `specs` means. `problem` names why the line is not a run,
      # and is `nil` for every line that is one.
      #
      # Every other member is `nil` exactly where the row says `no branch`,
      # `no specs` or `no duration_seconds`: the line does not carry that fact.
      ListedLine = Struct.new(:number, :problem, :branch, :commit_sha, :ci_run_id, :examples,
                              :duration_seconds, keyword_init: true)

      # Two or more accepted lines that went out with one `ci_run_id` and came
      # back with one `test_run_id` — folding, observed rather than inferred.
      # Grouped once ({#folded_runs}) and rendered twice, as a sentence by
      # {#folding_observation} and as data by {IngestReporter}.
      Folding = Struct.new(:ci_run_id, :test_run_id, :numbers, keyword_init: true)

      # The file, as this tool reads it: the numbered lines that carry a
      # payload, a count of the blank ones that do not, and a count of the ones
      # the selector held back — with `selector` naming which flag did it, so
      # the summary can say. The blanks and the skips are counted rather than
      # dropped because a summary that quietly narrows what it is summarising is
      # the failure this project keeps finding.
      #
      # `absent` is the same discipline applied one layer later, to the lines
      # that were *typed* rather than to the lines that were read. A `--lines`
      # entry can name a line past the end of the file, and such a number is not
      # held back — there was nothing there to hold — so `skipped` cannot carry
      # it and the file's own counts cannot state it. It is derived from the
      # file's length in {#read_source} and rendered in the shorthand it was
      # typed in, because the user acts on what they typed. Empty when the
      # selector was fully satisfied, and empty under `--from-line`, whose
      # past-the-end case is already a suffix that selected nothing.
      #
      # `raw` and `read_bytes` are the drain's inputs, captured by
      # {#read_source} and by nothing else: the file's exact bytes as of the
      # read, and that read's length in bytes. The rebuild keeps `raw`'s lines
      # minus the accepted numbers — which is what makes "byte for byte" a
      # property of the rewrite rather than a hope — and `read_bytes` is where
      # the tail starts: anything appended past it while the deliveries ran is
      # carried into the rewrite verbatim. They are members of {Source} rather
      # than a second read inside {#drain_source} because the length that
      # matters is the one the numbered lines were counted against; a fresh
      # read at drain time would answer a different read.
      #
      # @return [Array<String>] `absent`, each entry a number or an `N-M` range
      Source = Struct.new(:path, :lines, :blank, :skipped, :absent, :selector,
                          :raw, :read_bytes, keyword_init: true)

      # What `--drain` did, decided once in {#drain_source} and rendered by
      # both renderers — the same one-fact-two-renderings discipline the status
      # counts and the folding groups are held to. `removed` is the count of
      # lines taken out of the file (0 when nothing was accepted, so no rewrite
      # happened at all), `remaining` is the count of lines the rewrite LEFT in
      # the file — `kept + appended`, counted as lines (blank lines and the
      # carried tail included), so a renderer can tell a queue that still holds
      # work from one the drain emptied. `remaining` is meaningful only where a
      # rewrite actually happened: on the no-accept and failed paths the file
      # did not move, so it stays `nil`. `failed` is a rewrite that could not
      # complete: the file was left as it was, the warning is already on
      # stderr, and the exit code is a 2, because a 0 would read as "drained"
      # about a queue that was not. `nil` — no {Drain} at all — is the flag's
      # absence, and both renderers render nothing for it.
      Drain = Struct.new(:removed, :remaining, :failed, keyword_init: true)

      # What the command line asked for. A struct rather than a bare path,
      # because `--from-line` is the second half of the same question — which
      # lines of which file — and threading it as an ivar would put a value
      # {#run} depends on somewhere {#run} does not name. `line_set` is that
      # same half asked the other way, as an explicit set rather than a
      # starting point, and the two are mutually exclusive (see the class
      # comment). `list` is the third half: whether those lines are to be
      # *shown* or *sent*. `json` is orthogonal to all three — it chooses the
      # renderer, never the set and never the verdict. `drain` is the one
      # member about what happens *after* the sending: whether the lines this
      # invocation got a 202 for are to be removed from <file> once the
      # deliveries are done.
      #
      # `line_set` is an Array of Ranges rather than an expanded Array of
      # Integers, so `--lines 1-90000000` costs nothing to hold. `nil` means the
      # flag was not given and `from_line` is the selector.
      Options = Struct.new(:path, :from_line, :list, :line_set, :json, :drain, keyword_init: true)

      # One entry of a `--lines` spec: `12` or `12-15`, and nothing else. No
      # sign, no open end, no whitespace inside — {#parse_line_set} strips each
      # entry before matching, so `3, 7` is fine, but `12-` and `5 - 7` are not
      # near-misses to be repaired, they are typos to be reported. This is the
      # `Integer`-coercion rationale on `--from-line` applied to a richer
      # grammar: a spec that half-parses would silently deliver the wrong set,
      # and delivering the wrong set is the one outcome a selector exists to
      # prevent.
      LINE_SPEC_ENTRY = /\A(\d+)(?:-(\d+))?\z/

      STATUS_LABELS = {
        accepted: "accepted",
        refused: "refused",
        undelivered: "not delivered",
        unparseable: "unparseable"
      }.freeze

      def initialize(stdout: $stdout, stderr: $stderr, env: ENV)
        @stdout = stdout
        @stderr = stderr
        @env = env
      end

      # @param argv [Array<String>]
      # @return [Integer] 0, 1 or 2 — never anything else, and never by letting
      #   an exception reach the shell
      def run(argv)
        options = parse_options(argv)
        return EXIT_OK if options.nil? # --help / --version already printed

        # Ahead of `build_transport`, and that is the whole point of the branch
        # being here rather than after it. Listing sends nothing, so it needs no
        # endpoint and no key — and the file that most wants looking at is the
        # one the formatter wrote *because* no key was set. A listing that
        # demanded credentials would be unavailable in exactly the case it
        # exists for.
        return list(options) if options.list

        # Before the file is opened, deliberately. "There is nowhere to send
        # this" is the earlier question — which lines to send does not matter
        # when nothing is going to accept them — and asking it first means an
        # unconfigured run reads its one real problem instead of a complaint
        # about a path that was never the point.
        transport = build_transport

        source = read_source(options)
        results = source.lines.map { |number, text| deliver_line(number, text, transport) }
        # After the deliveries, before the report — the only position where the
        # summary can state what the drain removed. `drained` is nil without
        # the flag, and both renderers render nothing for it, which is the
        # whole of the flag being opt-in.
        drained = options.drain ? drain_source(source, results) : nil

        report(source, results, json: options.json, drained: drained)
        exit_code(results, drained: drained)
      rescue Errno::EPIPE
        # The report's reader stopped listening — `| head`, a quitting pager,
        # a CI log tailer. The deliveries happened and the per-line verdicts
        # are in hand, so the code is the run's own, recomputed from
        # `results`, not the backstop's "the tool is broken". `results` is
        # nil on the `--list` path, which builds none, and when the pipe
        # closed before any delivery was made; then {EXIT_OK} stands. See
        # the class comment.
        results ? exit_code(results, drained: drained) : EXIT_OK
      rescue UsageError => e
        @stderr.puts "specguard-ingest: error: #{e.message}"
        EXIT_MISUSE
      rescue ScriptError, StandardError => e
        # The backstop that makes exit 1 mean one thing. Anything reaching here
        # is a bug in this tool, not a verdict from the endpoint about anyone's
        # run, so it is a 2 and it says so in those words.
        @stderr.puts "specguard-ingest: internal error: #{e.class}: #{e.message}"
        EXIT_MISUSE
      end

      private

      # One expression, over the whole file. The `:undelivered` and
      # `:unparseable` clause is first because 2 dominates: a line that never
      # reached the endpoint leaves the job unfinished, and reporting that as
      # "your content was refused" is the exact confusion the contract exists to
      # prevent.
      #
      # `drained` joins the dominance list ahead of the content verdicts, on
      # the same grounds: a drain that could not complete left the queue
      # holding everything it held before, accepted lines included, and
      # reporting that as "your content was refused" (or as a clean 0) would
      # both be the wrong shout.
      def exit_code(results, drained: nil)
        return EXIT_MISUSE if drained&.failed
        return EXIT_MISUSE if results.any? { |result| %i[undelivered unparseable].include?(result.status) }
        return EXIT_REFUSED if results.any? { |result| result.status == :refused }

        EXIT_OK
      end

      # `--list`: read the file, print what is in it, deliver nothing.
      #
      # Note what this does *not* do — it does not call {#exit_code}. Listing
      # makes no request, so no endpoint has read anything and no verdict about
      # anyone's run exists; routing it through the shared code would put a
      # second producer behind {EXIT_REFUSED} and cost exit 1 the single meaning
      # the class comment is built around. The two codes reachable from here are
      # 0 (listed) and, via the {UsageError} {#read_source} raises, 2.
      #
      # It reuses {#read_source} rather than reading the file itself, which is
      # what makes the numbers here the same numbers `--from-line` and `--lines`
      # take, what makes a listing under either flag preview exactly the set a
      # delivery would send, and what makes an invalid-UTF-8 line arrive as a
      # line to be named rather than an exception.
      #
      # Under `--json` the rows become one document and the warning stays where
      # it is. An empty listing still writes the document — the file was read,
      # and `"lines": []` over a summary of zeroes is a true statement about it —
      # whereas a file that could not be read raises out of {#read_source}
      # before there is anything to be a document about.
      def list(options)
        source = read_source(options)
        lines = source.lines.map { |number, text| listed_line(number, text) }

        if lines.empty?
          @stderr.puts "specguard-ingest: warning: #{source.path} holds no runs to list#{empty_detail(source)}"
          return EXIT_OK unless options.json
        end

        if options.json
          @stdout.puts IngestReporter.render_listing(source: source, lines: lines, counts: listed_counts(lines))
          return EXIT_OK
        end

        lines.each { |line| @stdout.puts list_row(line) }
        @stdout.puts list_summary(source)
        EXIT_OK
      end

      # One line of the file, as facts rather than as a judgement. An
      # unparseable line is listed *as unparseable* — the same discipline
      # {#deliver_line} applies, for the same reason: a line silently dropped
      # from a preview is a preview that under-reports what the delivery would
      # do.
      #
      # The envelope is free-form, so every field goes through {#scalar} for the
      # reason {#deliver_line} reports `ci_run_id` that way: rendering
      # `{"a"=>1}` as a branch would be this tool inventing structure the line
      # does not have. `0 examples` and `no specs` are likewise different facts —
      # an empty list is a run that carried none, a missing or non-Array `specs`
      # is a line that does not say — so the count is `nil` rather than 0 for the
      # second, and both renderers inherit that distinction rather than each
      # making it.
      def listed_line(number, text)
        payload, problem = parse_payload(text)
        return ListedLine.new(number: number, problem: problem) if payload.nil?

        specs = payload["specs"]
        duration = payload["duration_seconds"]

        ListedLine.new(number: number,
                       branch: scalar(payload["branch"]),
                       commit_sha: scalar(payload["commit_sha"]),
                       ci_run_id: scalar(payload["ci_run_id"]),
                       examples: specs.is_a?(Array) ? specs.length : nil,
                       duration_seconds: duration.is_a?(Numeric) ? duration : nil)
      end

      # The row, off the facts above and nothing else — which is what makes the
      # document and the listing two renderings of one reading of the line.
      def list_row(line)
        return "line #{line.number}: #{STATUS_LABELS.fetch(:unparseable)} — #{line.problem}" if line.problem

        "line #{line.number}: #{listed_fields(line).join(', ')}"
      end

      # `ci_run_id` is the decision-relevant one — a line without it has nothing
      # for `RunRecorder` to fold onto and becomes a second run — so its absence
      # is stated rather than left as a gap in the row.
      def listed_fields(line)
        [named("branch", line.branch),
         named("commit_sha", line.commit_sha),
         named("ci_run_id", line.ci_run_id),
         line.examples ? "#{line.examples} example#{'s' unless line.examples == 1}" : "no specs",
         line.duration_seconds ? "#{line.duration_seconds}s" : "no duration_seconds"]
      end

      def named(name, value)
        value ? "#{name} #{value}" : "no #{name}"
      end

      # Says what was listed and, last and unconditionally, that nothing left
      # the machine — the one thing a reader of a preview must not have to infer
      # from the absence of a delivery report.
      def list_summary(source)
        parts = ["specguard-ingest: listed #{source.lines.length} line#{'s' unless source.lines.length == 1} " \
                 "from #{source.path}"]

        parts << blank_clause(source) if source.blank.positive?
        parts << skipped_clause(source) if source.skipped.positive?
        parts << absent_clause(source) if source.absent.any?
        parts << "nothing was delivered"

        parts.join("; ")
      end

      # One line, one attempt, one result — and no retry loop.
      #
      # The gem's no-retry decision is about in-run cost to CI wall clock, and
      # this tool runs out of band where that argument does not apply. It still
      # does not retry: the line is on disk and re-running the command is the
      # retry, made by someone who can see why the first attempt failed rather
      # than by a loop that cannot.
      def deliver_line(number, text, transport)
        payload, problem = parse_payload(text)
        if payload.nil?
          return LineResult.new(number: number, status: :unparseable, detail: problem, reasons: [problem])
        end

        ci_run_id = scalar(payload["ci_run_id"])
        result = transport.deliver(payload)

        case result.outcome
        when :success
          LineResult.new(number: number, status: :accepted, detail: "HTTP #{result.code}", code: result.code,
                         reasons: [], test_run_id: result.test_run_id, ci_run_id: ci_run_id)
        when :rejected
          # A non-2xx is not automatically a verdict. {CONTENT_REFUSAL_CODES}
          # names the ones the platform actually forms an opinion in; the rest
          # arrived, stored nothing, and said nothing about this run.
          status = CONTENT_REFUSAL_CODES.include?(result.code) ? :refused : :undelivered
          # `result.reasons` verbatim — the whole array, not the three
          # `result.reason` flattens it to. A body that said nothing readable
          # leaves it nil, which {IngestReporter} renders as `[]`.
          LineResult.new(number: number, status: status, detail: result.reason, code: result.code,
                         reasons: result.reasons, ci_run_id: ci_run_id)
        else
          # No code, because no answer: the exception's rendering is the whole of
          # what there is to say, and it is the only thing `reasons` can carry.
          LineResult.new(number: number, status: :undelivered, detail: result.reason,
                         reasons: [result.reason], ci_run_id: ci_run_id)
        end
      end

      # `[payload, nil]`, or `[nil, problem]` naming why the line is not a run.
      # A pair rather than one value of two types, because `JSON.parse` answers
      # a bare `"text"` line with a String and a sentinel String would then be
      # indistinguishable from a payload — and rather than an exception, because
      # an unparseable line is a per-line result like any other: one corrupt
      # line (a sink truncated by a killed process, most likely) must not stop
      # the other thirty-nine from being delivered.
      def parse_payload(text)
        # Before `JSON.parse`, which raises an encoding error rather than a
        # `JSON::ParserError` for these — and whose message would carry the
        # offending bytes into a `String#strip` that raises in turn.
        return [nil, "the line is not valid UTF-8, so it cannot be a run"] unless text.valid_encoding?

        parsed = JSON.parse(text)
        return [parsed, nil] if parsed.is_a?(Hash)

        [nil, "the line is #{parsed.class} JSON, and a run is an object"]
      rescue JSON::ParserError => e
        [nil, "could not parse the line as JSON: #{e.message.lines.first.to_s.strip}"]
      end

      def build_transport
        configuration = Configuration.new(env: @env)

        # Both named, and named separately. They fail for different reasons and
        # are fixed in different places, and "delivery is not configured" would
        # leave an operator who set one of the two guessing which.
        raise UsageError, "no endpoint is configured (set SPECGUARD_ENDPOINT)" if blank?(configuration.endpoint)
        raise UsageError, "no API key is configured (set SPECGUARD_API_KEY)" if blank?(configuration.api_key)

        transport = Transport.new(endpoint: configuration.endpoint, api_key: configuration.api_key,
                                  timeout: configuration.timeout)
        # Asked once, here, so a malformed `SPECGUARD_ENDPOINT` is one exit 2
        # rather than N identical `:failed` lines. `Transport#deliver` would
        # otherwise swallow the same `ArgumentError` once per line and report a
        # delivery problem for what is a configuration problem.
        validate_endpoint(transport)

        transport
      end

      def validate_endpoint(transport)
        transport.uri
      rescue ArgumentError => e
        raise UsageError, e.message
      end

      # @param options [Options] which lines of which file. Whichever selector
      #   was given, everything it does not name is counted and held back, never
      #   renumbered — the whole value of resuming from a report is that line 12
      #   is still line 12.
      # @raise [UsageError] for every way a file can refuse to be read. All of
      #   them are exit 2 — the tool was pointed at something it cannot work
      #   from, which is not a verdict about anybody's run.
      def read_source(options)
        path = options.path
        raise UsageError, no_such_file_message(path) unless File.exist?(path)
        raise UsageError, "not a file: #{path}" unless File.file?(path)

        lines = []
        blank = 0
        skipped = 0
        # The file's length, counted rather than inferred: `with_index` is
        # already running and discards its last `number`, and a counter that
        # starts at 0 says "no lines" about an empty file where a nil would say
        # "not known". It is what {#absent_entries} measures the typed numbers
        # against.
        length = 0

        # Numbered from the file, not from the payloads: a blank line still
        # advances the count, so line 12 in this report is line 12 in an editor.
        #
        # The selector is asked FIRST, in the one branch position the suffix
        # test used to hold, so both narrowings inherit the numbering, the blank
        # counting and the invalid-UTF-8 handling below unchanged.
        #
        # `strip` RAISES on a line that is not valid UTF-8 — pointing this
        # command at a binary file by mistake is the obvious way to get one —
        # and such a line is not blank, it is a line that cannot be a run. It is
        # kept, so {#parse_payload} says exactly that about it and the rest of
        # the file still delivers. Swallowing it here would lose a line silently
        # and letting it raise would report a bug in this tool.
        File.foreach(path).with_index(1) do |text, number|
          length = number

          if held_back?(number, options)
            skipped += 1
          elsif text.valid_encoding? && text.strip.empty?
            blank += 1
          else
            lines << [number, text]
          end
        end

        # The drain's capture, taken AFTER the line walk and for that reason:
        # read first, length second means `read_bytes` covers everything the
        # numbered lines were counted against, even where an append landed
        # between the two reads — such bytes are in `raw` (as extra tail lines
        # numbered past the delivered set, kept by any rewrite) and past
        # `read_bytes` is genuinely only what arrived after this method
        # returned. Reading the bytes first would invert that: a line appended
        # in the gap could then be delivered AND carried back by the tail.
        #
        # Binary on purpose — this is the file's bytes, not its characters.
        # The default path never looks at either member; the whole capture is
        # the drain's, and its cost on the default path is one read.
        raw = File.binread(path)

        Source.new(path: path, lines: lines, blank: blank, skipped: skipped,
                   absent: absent_entries(options, length),
                   selector: options.line_set ? :line_set : :from_line,
                   raw: raw, read_bytes: raw.bytesize)
      rescue SystemCallError, IOError => e
        raise UsageError, "could not read #{path}: #{e.message}"
      end

      # The `no such file` refusal, with one conditional clause: when the
      # missing path IS the configured replay queue and the configured local
      # record exists, name the record. A keyless developer is pointed at
      # `log/test_results.jsonl` by the help while their run wrote the other
      # file, and this is the one moment the tool can say so. The guard is the
      # conjunction — equality, not "the path looks like a queue", and an
      # existence check, not "the record is merely configured" — so an ordinary
      # typo keeps the plain message byte-for-byte, and the clause cannot fire
      # on a relative default that happens to resolve against the working
      # directory.
      def no_such_file_message(path)
        configuration = Configuration.new(env: @env)
        local = configuration.local_output_path
        if path == configuration.output_path && File.exist?(local)
          "no such file: #{path} — the replay queue was never written, but the " \
            "local record #{local} does exist (what the formatter writes when " \
            "no API key is configured)"
        else
          "no such file: #{path}"
        end
      end

      # The whole of the selection, and the only place it is decided. `--lines`
      # is an explicit set, so a line it does not name is held back wherever in
      # the file it sits; `--from-line` is a suffix, so only the lines before it
      # are. The two never both apply — {#parse_options} refuses the pair.
      def held_back?(number, options)
        return !options.line_set.any? { |range| range.cover?(number) } if options.line_set

        number < options.from_line
      end

      # The typed numbers the file does not have, in the shorthand they were
      # typed in.
      #
      # Computed over line NUMBERS rather than over entries, which is what makes
      # a half-satisfied range the same fact as a wholly unsatisfied one: a
      # range running past the end of the file has named lines that were typed
      # and delivered nothing, exactly as a lone out-of-range number has. Each
      # entry contributes only the portion above the file's length, so the
      # clause names the unanswered part rather than the entry that was half
      # honoured, and a range stays a range rather than becoming a list of
      # numbers the user would have to read back into what they wrote.
      #
      # `--from-line` contributes nothing: it is a suffix, and a suffix past the
      # end of the file already says so through the lines it held back.
      #
      # A line the file HAS and that is blank is not here and must never be —
      # `blank` already says "you named a line that exists and holds nothing",
      # and stating both would be one line reported under two causes. The
      # comparison is against the file's length alone, which is what keeps that
      # true rather than merely usually true.
      #
      # @return [Array<String>]
      def absent_entries(options, length)
        return [] unless options.line_set

        options.line_set.filter_map do |range|
          first = [range.first, length + 1].max
          next if first > range.last

          first == range.last ? first.to_s : "#{first}-#{range.last}"
        end.uniq
      end

      # The per-line report on stdout — it is the product — with the diagnostics
      # about this tool's own situation on stderr, which is the split
      # `specguard-lint` already makes. `--json` moves the product and leaves the
      # diagnostics: a run that delivered nothing is still loud on stderr, in
      # both renderers, because the warning is a statement about this tool's
      # situation and not a result.
      #
      # == Two renderers, one set of facts
      #
      # The counts and the folding groups are computed ONCE here and handed to
      # whichever renderer runs. Both the text summary line and the document's
      # `summary` are statements about the same numbers, and a command whose two
      # renderers can disagree about how much of a file it delivered is worse
      # than one that only prints prose: the disagreement is unfalsifiable from
      # outside the process.
      def report(source, results, json:, drained: nil)
        if results.empty?
          @stderr.puts "specguard-ingest: warning: #{source.path} holds no runs to deliver#{empty_detail(source)}"
          return unless json
        end

        counts = status_counts(results)
        foldings = folded_runs(results)

        if json
          @stdout.puts IngestReporter.render_delivery(source: source, results: results, counts: counts,
                                                      foldings: foldings, drained: drained)
          return
        end

        results.each { |result| @stdout.puts line_report(result) }
        @stdout.puts summary_line(source, results, counts, drained)
        foldings.each { |folding| @stdout.puts folding_observation(folding) }
      end

      def status_counts(results)
        results.group_by(&:status).transform_values(&:length)
      end

      # The listing's counterpart to {#status_counts}. A preview delivers
      # nothing, so `unparseable` is the only status a listed line can hold —
      # but it is counted *here*, next to the delivery path's counts, rather
      # than inside the renderer: {IngestReporter} states that its counts are
      # handed in, and a count computed in the one place that promises not to
      # compute them is the invariant holding by luck instead of by structure.
      def listed_counts(lines)
        { unparseable: lines.count(&:problem) }
      end

      # Why there was nothing to do, when there is a reason other than "the file
      # is empty". A `--from-line` past the end of the file, a `--lines` that
      # names only lines the file does not have, and a genuinely empty file are
      # the same silence otherwise, and only two of them are the user's mistake.
      # The third clause is what tells the second of those from the first: a
      # held-back count alone is the file's own length read back, which a reader
      # can mistake for a selector that did something.
      def empty_detail(source)
        parts = []
        parts << "#{source.blank} blank line#{'s' unless source.blank == 1}" if source.blank.positive?
        parts << skipped_clause(source) if source.skipped.positive?
        parts << absent_clause(source) if source.absent.any?

        parts.empty? ? "" : " (#{parts.join('; ')})"
      end

      # Named for the flag that actually held them back, and worded for what
      # that flag does. `--from-line` holds back a prefix, so those lines are
      # "earlier"; `--lines` holds back whatever it did not name, which can sit
      # anywhere in the file, so calling them earlier would be a lie in the
      # common case.
      def skipped_clause(source)
        count = source.skipped
        return "#{count} line#{'s' unless count == 1} not selected by --lines" if source.selector == :line_set

        "#{count} earlier line#{'s' unless count == 1} skipped by --from-line"
      end

      # The typed numbers the file does not have, named rather than counted.
      # {#skipped_clause}'s counterpart for the other direction: that one says
      # how much of the FILE the selector held back, and this one says how much
      # of the SELECTOR the file could not answer. A count would be the wrong
      # shape here — the reader's next action is editing the numbers they typed,
      # so the clause hands those numbers back in the form they wrote them.
      def absent_clause(source)
        "--lines named #{source.absent.join(', ')}, which the file does not have"
      end

      def blank_clause(source)
        "#{source.blank} blank line#{'s' unless source.blank == 1} skipped"
      end

      def line_report(result)
        detail = [result.detail, identity(result)].compact.join(", ")
        line = "line #{result.number}: #{STATUS_LABELS.fetch(result.status)}"
        detail.empty? ? line : "#{line} — #{detail}"
      end

      # The two facts criterion 4 can be stated from: what the endpoint said the
      # run's id is, and whether the line carried a run identity of its own.
      #
      # A line with no `ci_run_id` is reported as having none and nothing more.
      # The platform records such a run as its own row, but that happens inside
      # `RunRecorder` where this tool cannot see it, and a claim it cannot
      # observe is a claim it does not make.
      def identity(result)
        return nil unless result.status == :accepted

        ["test_run_id #{result.test_run_id || '(not reported)'}",
         result.ci_run_id ? "ci_run_id #{result.ci_run_id}" : "no ci_run_id"].join(", ")
      end

      # States how much of the file reached the endpoint, always, and in a form
      # that cannot read as "all clean" when it was "nothing sent": the
      # accepted count is over the total rather than on its own, and every other
      # outcome gets a clause of its own instead of being folded into a
      # remainder the reader has to compute.
      def summary_line(source, results, counts, drained)
        parts = ["specguard-ingest: delivered #{counts.fetch(:accepted, 0)} of " \
                 "#{results.length} run#{'s' unless results.length == 1} from #{source.path}"]

        parts << "#{counts[:refused]} refused" if counts[:refused]
        parts << "#{counts[:undelivered]} could not be delivered" if counts[:undelivered]
        parts << "#{counts[:unparseable]} could not be parsed" if counts[:unparseable]
        parts << blank_clause(source) if source.blank.positive?
        parts << skipped_clause(source) if source.skipped.positive?
        parts << absent_clause(source) if source.absent.any?
        parts << drain_clause(source, drained) if drained&.removed&.positive?

        parts.join("; ")
      end

      # The drain's clause, present exactly when lines were removed and never
      # otherwise — the summary's established shape, where a clause names a
      # fact that is positive rather than padding the line with zeroes. The
      # `removed: 0` of a rewrite that did not happen (nothing was accepted)
      # needs no clause: the accepted count in the first clause already says
      # so. The `removed: 0` of a rewrite that FAILED is carried by the stderr
      # warning and by the exit code, both louder than a clause would be.
      #
      # The clause's second half states the consequence the removal has for
      # the numbers this very report just printed: a rewrite that leaves any
      # line in the file renumbers them, because the survivors are packed up
      # from the top — so the numbers above describe the file as it was READ,
      # not as the next invocation will find it, and must not be reused to
      # address it. A drain that emptied the file says nothing extra: there is
      # no number left for the sentence to be about.
      def drain_clause(source, drained)
        clause = +"#{drained.removed} accepted line#{'s' unless drained.removed == 1} removed from #{source.path}"
        return clause unless drained.remaining&.positive?

        left = drained.remaining
        clause << " — the #{left} line#{'s' unless left == 1} left " \
                  "#{left == 1 ? 'is' : 'are'} now numbered from 1, so the numbers above " \
                  "no longer address #{left == 1 ? 'it' : 'them'}"
      end

      # Folding, stated only where it was *seen*.
      #
      # The proposal for this tool asked it to say whether a replayed line
      # folded into an existing run or created a new one, and the 202 body does
      # not carry that flag. What it does carry is the run's id, and two lines
      # that went out with the same `ci_run_id` and came back with the same
      # `test_run_id` are two deliveries onto one row — which is not an
      # inference about folding, it is folding, observed. Anything short of two
      # such lines gets no {Folding} at all rather than a hedged one.
      #
      # Grouped here and rendered by {#folding_observation} or by
      # {IngestReporter}, rather than grouped by each of them: one observation
      # rendered twice cannot disagree with itself.
      #
      # @return [Array<Folding>]
      def folded_runs(results)
        results
          .select { |result| result.status == :accepted && result.ci_run_id && result.test_run_id }
          .group_by { |result| [result.ci_run_id, result.test_run_id] }
          .filter_map do |(ci_run_id, test_run_id), group|
            next if group.length < 2

            Folding.new(ci_run_id: ci_run_id, test_run_id: test_run_id, numbers: group.map(&:number))
          end
      end

      def folding_observation(folding)
        "specguard-ingest: lines #{folding.numbers.join(', ')} carried ci_run_id #{folding.ci_run_id} and each " \
          "came back with test_run_id #{folding.test_run_id} — the endpoint folded them onto one run"
      end

      # --drain: remove from <file> exactly the lines this invocation got a 202
      # for, atomically, carrying anything appended while the deliveries ran.
      #
      # == What is removed, and what is not
      #
      # Only `:accepted` results, by their own file-line numbers — the removal
      # is keyed to what the endpoint answered this run, never to a guess about
      # which lines were failures. Everything else {Source#raw} holds is kept:
      # refused, undelivered and unparseable lines, the blank ones, and every
      # line a selector held back — each byte for byte, in the file's order.
      #
      # == The tail, carried
      #
      # The formatter appends to the queue with no lock, so bytes can land
      # after {#read_source} and before this rewrite. Those bytes are the
      # tail: everything in the file NOW past the length read then, carried
      # into the rewrite verbatim. They were never delivered, so the accepted
      # set can never name them — carrying them is what keeps a concurrent
      # append from being destroyed by the very run that emptied the queue.
      #
      # == The residual race, disclosed rather than closed
      #
      # The tail read below is as late as the design can put it, which narrows
      # the race to read → rename: bytes a formatter appends AFTER that read
      # but BEFORE {File.rename} lands go to the old inode and are lost when
      # the rename swaps the directory entry. The window is two syscalls wide
      # and is NOT closed — closing it would take a lock in the formatter, and
      # that is deliberately out of scope here. What this code claims is
      # narrower: everything appended before the final read survives, and a
      # failure at any point before the rename leaves the original
      # byte-identical.
      #
      # Nothing is written unless something was accepted: a drain over a file
      # whose every line was refused, or whose selector held everything back,
      # leaves the file — and its mtime — exactly as it was.
      #
      # @return [Drain] what was removed; `failed`, with the warning already
      #   on stderr, when the rewrite could not complete
      def drain_source(source, results)
        accepted = results.select { |result| result.status == :accepted }.map(&:number)
        return Drain.new(removed: 0, failed: false) if accepted.empty?

        # Binary throughout: `raw` is the file's bytes, and the rebuild is a
        # byte operation, not a character one. `each_line` splits on the same
        # `"\n"` the numbering was counted with, so `number` here is the
        # number the reports printed.
        kept = String.new(encoding: Encoding::BINARY)
        source.raw.each_line.with_index(1) do |text, number|
          kept << text unless accepted.include?(number)
        end

        current = File.binread(source.path)
        appended =
          if current.bytesize > source.read_bytes
            current.byteslice(source.read_bytes, current.bytesize - source.read_bytes)
          else
            String.new(encoding: Encoding::BINARY)
          end

        rewritten = kept + appended
        drain_write(source.path, rewritten)
        # Counted as LINES, on `each_line`'s terms — the same split the
        # numbering itself was built on — never as bytes: a blank line counts,
        # and a queue the drain emptied reads 0 rather than 1.
        Drain.new(removed: accepted.length, remaining: rewritten.each_line.count, failed: false)
      rescue SystemCallError, IOError => e
        # Stated, never silent — and reported without costing the delivery
        # report: stdout below is still the full per-line report, this warning
        # names the file, and {#exit_code} turns the run into a 2, because a
        # 0 would read as "drained" about a queue that was not.
        @stderr.puts "specguard-ingest: warning: could not remove the accepted lines from #{source.path}: " \
                     "#{e.message} — the file is left as it was"
        Drain.new(removed: 0, failed: true)
      end

      # The atomic swap: a temporary file in the SAME directory — `rename` is
      # only atomic within one filesystem — renamed over the original. A
      # failure at any point before the rename leaves the original untouched,
      # and the `ensure` takes the temporary with it.
      def drain_write(path, content)
        tmp = File.join(File.dirname(path),
                        ".#{File.basename(path)}.drain-#{Process.pid}-#{rand(1 << 32).to_s(36)}.tmp")
        begin
          File.binwrite(tmp, content)
          File.rename(tmp, path)
        ensure
          File.unlink(tmp) if File.exist?(tmp)
        end
      end

      # @return [Options, nil] `nil` when `--help` or `--version` has already
      #   said everything the invocation was asking for.
      def parse_options(argv)
        from_line = nil
        line_set = nil
        list = false
        json = false
        drain = false

        parser = OptionParser.new do |o|
          o.banner = BANNER
          o.separator ""
          o.separator DESCRIPTION
          o.separator ""
          o.separator "Options:"
          # Deliberately alongside the selectors rather than instead of them:
          # they compose, so the set you list is the set you are about to send.
          o.on("--list", "List the runs in <file> without delivering any of them") do
            list = true
          end
          # `Integer` rather than a String and a `to_i`: `--from-line twelve`
          # would otherwise become 0 and silently deliver the whole file, which
          # is the one outcome a resume flag exists to prevent. OptionParser
          # raises `InvalidArgument` instead, and that is a 2 like every other
          # misuse.
          o.on("--from-line N", Integer, "Start at line N of <file>, skipping the lines before it") do |value|
            raise UsageError, "--from-line must be 1 or greater, got #{value}" if value < 1

            from_line = value
          end
          # No coercion to lean on for this one — and deliberately not
          # OptionParser's `String`, whose acceptor rejects an empty argument
          # with a message about the flag rather than about the spec. So the
          # raw value comes through and {#parse_line_set} does the same job by
          # hand and to the same standard: every way of mistyping a spec is a
          # UsageError that names what was wrong with it, and none of them falls
          # back to the whole file.
          o.on("--lines SPEC",
               "Deliver only the lines SPEC names — numbers and ranges over <file>'s",
               "own numbering, e.g. 3,7,12-15. Not combinable with --from-line") do |value|
            line_set = parse_line_set(value)
          end
          # Composes with everything above it: it chooses the renderer, never
          # the set that is listed or sent and never the code that is returned.
          o.on("--json", "Emit one JSON document on stdout instead of the human report") do
            json = true
          end
          # Delivery-shaped and opt-in: it changes nothing about what is sent,
          # only what happens to <file> afterwards, and the guards below hold
          # it to the queue and refuse it a listing.
          o.on("--drain", "After delivering, remove from <file> exactly the lines this run accepted —",
               "atomically, keeping every other line byte for byte") do
            drain = true
          end
          o.on("-v", "--version", "Print the version and exit") do
            @stdout.puts "specguard-ruby #{VERSION}"
            return nil
          end
          o.on("-h", "--help", "Print this help and exit") do
            @stdout.puts o
            return nil
          end
        end

        files = parser.parse(argv)
        raise UsageError, "no file given — #{BANNER}" if files.empty?
        raise UsageError, "one file at a time, got #{files.length}: #{files.join(', ')}" if files.length > 1

        # Refused rather than intersected. Both answer "which lines", and an
        # intersection would drop a number the user typed without saying so —
        # see the class comment.
        if from_line && line_set
          raise UsageError, "--from-line and --lines both choose which lines to send; give one or the other"
        end

        # `--drain` follows the delivery; `--list` is the refusal to deliver.
        # They are not an intersection to resolve but two answers to "does this
        # run send anything", and a listing that also drained would either
        # drain nothing silently or drain without the deliveries the removal
        # is keyed to — both are the quiet-failure shape this file refuses.
        if drain && list
          raise UsageError, "--drain delivers and removes the lines that were accepted; " \
                            "--list delivers nothing, so there is nothing for it to drain"
        end

        # The drain may empty the replay queue and nothing else. A path that
        # is not {Configuration#output_path} is either the local record — a
        # development record of ordinary keyless runs, not a queue, where
        # removing accepted lines would delete runs that were never failures —
        # or a file this invocation was pointed at by mistake. The comparison
        # is exact string equality, the one {#no_such_file_message} makes: a
        # path spelled differently from the configuration is refused rather
        # than resolved, and SPECGUARD_OUTPUT_PATH relocates the drain with
        # the queue.
        if drain
          queue = Configuration.new(env: @env).output_path
          if files.first != queue
            raise UsageError, "--drain empties the replay queue, and #{files.first} is not it " \
                              "(configured as #{queue}) — the local record is a development record, not a queue"
          end
        end

        Options.new(path: files.first, from_line: from_line || 1, list: list, line_set: line_set, json: json,
                    drain: drain)
      rescue OptionParser::ParseError => e
        # Uncaught, this is the likeliest way a user sees a false "the endpoint
        # refused your run": OptionParser raises and Ruby exits 1. Retyping it
        # is what makes a typo'd flag a 2.
        raise UsageError, e.message
      end

      # `3,7,12-15` → `[3..3, 7..7, 12..15]`, or {UsageError} — never a set that
      # is "close to" what was typed. A selector that half-understood its
      # argument would deliver the wrong runs, which is worse than not running
      # at all, so every entry must match {LINE_SPEC_ENTRY} whole.
      #
      # Ranges are kept as Ranges rather than expanded: membership is
      # `Range#cover?` over a handful of entries, so a fat-fingered
      # `--lines 1-90000000` is refused by the file's length rather than by
      # running the machine out of memory first.
      #
      # @return [Array<Range>] in the order typed, which does not matter —
      #   delivery order is the file's, always.
      def parse_line_set(spec)
        entries = spec.split(",", -1).map(&:strip)
        raise UsageError, "--lines needs at least one line number, got #{spec.inspect}" if entries.empty?

        entries.map { |entry| parse_line_spec_entry(entry, spec) }
      end

      def parse_line_spec_entry(entry, spec)
        raise UsageError, "--lines has an empty entry in #{spec.inspect}" if entry.empty?

        match = LINE_SPEC_ENTRY.match(entry)
        raise UsageError, "--lines: #{entry.inspect} is not a line number or a N-M range" if match.nil?

        first = Integer(match[1], 10)
        last = match[2] ? Integer(match[2], 10) : first
        raise UsageError, "--lines: line numbers start at 1, got #{entry.inspect}" if first < 1
        raise UsageError, "--lines: #{entry.inspect} ends before it starts" if last < first

        first..last
      end

      def blank?(value)
        value.nil? || value.to_s.strip.empty?
      end

      # A run identity is whatever the CI provider exported, passed through by
      # `Configuration` as a free-form string. Anything that is not a scalar is
      # not one, and reporting `{"a"=>1}` as a `ci_run_id` would be this tool
      # inventing structure the envelope does not have.
      def scalar(value)
        value.is_a?(String) || value.is_a?(Numeric) ? value.to_s : nil
      end
    end
  end
end
