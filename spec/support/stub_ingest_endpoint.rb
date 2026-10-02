# frozen_string_literal: true

require "json"
require "socket"
require "zlib"

# A real HTTP server on a real socket, in ten lines of protocol.
#
# == Why not a stubbed `Net::HTTP`
#
# The thing under test *is* the HTTP call. A `Net::HTTP` double proves that
# {SpecGuard::Client::Transport} calls the methods the test author expected it to
# call, which is exactly the claim that is worth nothing here: it would stay
# green through a missing `use_ssl`, a body that never got written, a path
# assembled with one slash too many, and a `Bearer` header the platform's
# `/\ABearer\s+(?<token>.+)\z/i` would not match. Every one of those is a
# production 401 or 404 that a double cannot see, because the wire is the only
# place they exist.
#
# So this speaks the protocol instead, and records what actually arrived. It is
# ~40 lines because HTTP/1.1 with `Connection: close` and a `Content-Length`
# body genuinely is that small, and stdlib has shipped no HTTP *server* since
# WEBrick left the standard library.
#
# == The three shapes it can take
#
#   status:   what to answer with — 202 for the happy path, 400/401/500 for the
#             non-exception failures the formatter's `rescue` is blind to.
#   responses: a different answer per request, in order, for a client that makes
#             more than one — the replayer sends a whole file through one
#             endpoint, so "line 2 refused, line 3 accepted" needs this.
#   hang:     accept the connection and never answer, so a client's read timeout
#             is the only thing that can end the request.
#   requests: everything that arrived, so an example can assert on the exact
#             headers and body rather than on a call.
class StubIngestEndpoint
  Request = Struct.new(:verb, :path, :headers, :body, keyword_init: true) do
    # The body as the *platform* would see it, standing in for the
    # `GzipRequestBody` middleware: a `Content-Encoding: gzip` request is
    # inflated, anything else is passed through. This is what lets an example
    # assert that a compressed payload round-trips key-for-key rather than
    # merely that a header was set — the header alone would stay green through
    # a body that inflates to something other than what was serialized.
    #
    # `body` is deliberately left as the raw bytes that arrived, so an example
    # can still measure the compressed size and see the two are different.
    def decoded_body
      headers["content-encoding"] == "gzip" ? Zlib.gunzip(body) : body
    end

    def json = JSON.parse(decoded_body)
  end

  REASONS = {
    200 => "OK", 202 => "Accepted", 400 => "Bad Request", 401 => "Unauthorized",
    403 => "Forbidden", 404 => "Not Found", 429 => "Too Many Requests",
    500 => "Internal Server Error", 503 => "Service Unavailable"
  }.freeze

  # Runs the server for the duration of the block and always shuts it down,
  # including when an example fails — a leaked accept thread would otherwise
  # outlive the suite and hold the port.
  def self.run(**options)
    server = new(**options)
    yield server
  ensure
    server&.stop
  end

  def initialize(status: 202, body: '{"test_run_id":"9f8e7d6","embedding_status":"pending"}', hang: false,
                 responses: nil)
    @status = status
    @body = body
    @hang = hang
    # A different answer per request, in order, for a client that makes more
    # than one. `specguard-ingest` replays a whole file through one endpoint,
    # so "line 2 was refused and line 3 was accepted" is only expressible if
    # the server can change its mind between requests.
    #
    # `nil` keeps the single-answer behaviour every other caller relies on, and
    # a list shorter than the number of requests repeats its last entry — so
    # `[{status: 400}]` refuses everything, exactly as `status: 400` does.
    # Each entry may set `status`, `body`, or both; whatever it omits falls
    # back to the constructor's.
    @responses = responses
    @requests = []
    @mutex = Mutex.new
    # Port 0: the kernel picks a free one, so parallel examples cannot collide
    # on a hard-coded number.
    @server = TCPServer.new("127.0.0.1", 0)
    @thread = Thread.new { serve }
  end

  def port = @server.addr[1]

  def endpoint = "http://127.0.0.1:#{port}"

  def requests = @mutex.synchronize { @requests.dup }

  def stop
    @thread&.kill
    @server.close unless @server.closed?
  end

  private

  def serve
    loop do
      socket = @server.accept
      handle(socket)
    end
  rescue IOError, Errno::EBADF, Errno::EINVAL
    # `stop` closed the listening socket out from under `accept`. Expected.
    nil
  end

  def handle(socket)
    request = read_request(socket)
    index = 0
    @mutex.synchronize { index = @requests.push(request).length - 1 } if request

    # Held, not closed: closing would hand the client an EOF, which
    # `Net::HTTP` reports as `EOFError` rather than the read timeout this is
    # here to provoke. The thread is killed in `stop`.
    return sleep if @hang

    socket.write(response(index))
    socket.close
  rescue Errno::EPIPE, Errno::ECONNRESET, IOError
    nil
  end

  def read_request(socket)
    line = socket.gets
    return nil if line.nil?

    verb, path, = line.split(" ")
    headers = read_headers(socket)
    length = headers["content-length"].to_i

    Request.new(verb: verb, path: path, headers: headers,
                body: length.positive? ? socket.read(length) : "")
  end

  def read_headers(socket)
    headers = {}

    while (line = socket.gets) && line != "\r\n"
      key, value = line.split(":", 2)
      headers[key.to_s.strip.downcase] = value.to_s.strip
    end

    headers
  end

  def response(index = 0)
    answer = @responses ? (@responses[index] || @responses.last) : {}
    status = answer.fetch(:status, @status)
    body = answer.fetch(:body, @body)

    <<~HTTP.gsub("\n", "\r\n") + body
      HTTP/1.1 #{status} #{REASONS.fetch(status, 'Unknown')}
      Content-Type: application/json
      Content-Length: #{body.bytesize}
      Connection: close

    HTTP
  end
end
