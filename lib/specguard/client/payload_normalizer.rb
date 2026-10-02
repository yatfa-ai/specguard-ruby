# frozen_string_literal: true

require "json"

module SpecGuard
  module Client
    # Relaxes PROTOCOL.md §1's permissive annotation syntax into strict JSON.
    #
    # §1 promises "the linter normalizes before validating" and lists three
    # equivalent forms. This converts all of them:
    #
    #   * unquoted keys         `{entity:"Order"}`   -> `{"entity":"Order"}`
    #   * single-quoted strings `{'entity':'Order'}` -> `{"entity":"Order"}`
    #   * arbitrary whitespace  (`JSON.parse` already tolerates it)
    #
    # plus a trailing comma before `}`/`]` as a courtesy.
    #
    # == Why this is a character scanner, not a `gsub`
    #
    # It is a character-scanner rather than a regex substitution **so quoted
    # content is never rewritten** — a `behavior` sentence containing `it's` or
    # `{` is passed through untouched. Any `gsub`-then-`JSON.parse` port
    # corrupts exactly those values; the examples under "quoted content is
    # never rewritten" in `payload_normalizer_spec.rb` pin them.
    #
    # The payload is *never* `eval`'d. It is attacker-controllable text taken
    # from a comment in someone's spec file, so it only ever reaches
    # `JSON.parse`, which cannot execute anything.
    #
    # == The bare-word rule
    #
    # A bare word is quoted **only in key position**. A bare word used as a
    # value (`{layer: request}`) is left alone so it still fails downstream —
    # the protocol relaxes keys and quote style, never value quoting.
    #
    # Ported from open-test-intent's `bin/validate-intent`
    # (`normalize_payload` / `_requote`).
    module PayloadNormalizer
      # Anchored at the scan position (`\G`), so it matches AT i rather than
      # searching from it. Explicit ASCII ranges, per PROTOCOL.md §1 — a Unicode
      # word class would make the accepted surface syntax depend on the regex
      # engine, which is what one specification exists to prevent.
      BARE_WORD = /\G[A-Za-z_$][A-Za-z0-9_$]*/.freeze

      module_function

      # @param raw [String] the object literal as written in the source
      # @return [String] strict JSON, ready for `JSON.parse`
      # @raise [ScanError] on an unterminated string literal
      def normalize(raw)
        out = +""
        i = 0
        length = raw.length

        while i < length
          char = raw[i]

          # Already-strict double-quoted string: copy verbatim, contents and all.
          if char == '"'
            finish = AnnotationScanner.scan_string(raw, i, '"')
            out << raw[i...finish]
            i = finish
            next
          end

          # Single-quoted string: re-emit its body as a JSON string.
          if char == "'"
            finish = AnnotationScanner.scan_string(raw, i, "'")
            out << requote(raw[(i + 1)...(finish - 1)])
            i = finish
            next
          end

          if (match = BARE_WORD.match(raw, i))
            word = match[0]
            after = match.end(0)
            out << (key_position?(raw, after) ? JSON.generate(word) : word)
            i = after
            next
          end

          # Trailing comma before a closing bracket: drop it.
          if char == "," && closes_after?(raw, i + 1)
            i += 1
            next
          end

          out << char
          i += 1
        end

        out
      end

      # Re-emits the body of a single-quoted string as a double-quoted JSON
      # string, preserving every escape that JSON understands.
      #
      # @param body [String] the string's contents, without its surrounding quotes
      # @return [String] a complete JSON string literal, quotes included
      def requote(body)
        out = +""
        i = 0
        length = body.length

        while i < length
          char = body[i]

          if char == "\\"
            nxt = i + 1 < length ? body[i + 1] : ""
            # `\'` is meaningless in JSON — unescape it; keep every other escape.
            out << (nxt == "'" ? "'" : char + nxt)
            i += 2
            next
          end

          out << (char == '"' ? '\"' : char)
          i += 1
        end

        %("#{out}")
      end

      # True when the next non-space character after `pos` is a `:`, i.e. the
      # bare word just scanned is a key rather than a value.
      def key_position?(raw, pos)
        probe = skip_space(raw, pos)
        probe < raw.length && raw[probe] == ":"
      end

      # True when the next non-space character at or after `pos` closes a
      # bracket, i.e. the comma just scanned was a trailing comma.
      def closes_after?(raw, pos)
        probe = skip_space(raw, pos)
        probe < raw.length && (raw[probe] == "}" || raw[probe] == "]")
      end

      def skip_space(raw, pos)
        pos += 1 while pos < raw.length && raw[pos].match?(/\s/)
        pos
      end
    end
  end
end
