# frozen_string_literal: true

# Socket-free Net::HTTP test double; exercises HttpFetcher request construction and response handling.
class AuditHttpStub
  Response = Struct.new(:code, :body, :headers) do
    def to_hash
      headers.to_h { |key, value| [key.downcase, Array(value)] }
    end
  end

  class Connection
    attr_accessor :use_ssl, :open_timeout, :read_timeout, :write_timeout, :max_retries

    def initialize(server)
      @server = server
    end

    def start
      yield self
    end

    def request(request)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = @server.request(request)
      raise Net::ReadTimeout if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > read_timeout

      response
    end
  end

  attr_reader :origin, :requests, :connections

  def initialize(origin: "http://127.0.0.1:18080", &handler)
    @origin = origin
    @handler = handler
    @requests = []
    @connections = []
  end

  def connection(host, port, proxy)
    raise "unexpected destination #{host}:#{port}" unless "http://#{host}:#{port}" == origin
    raise "unexpected proxy" unless proxy.nil?

    Connection.new(self).tap { |connection| @connections << connection }
  end

  def request(request)
    headers = request.to_hash.transform_values(&:first)
    @requests << { path: request.path, headers: headers, time: Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    status, response_headers, body = @handler.call(request.path, headers, origin)
    Response.new(status.to_s, body, response_headers)
  end

  def close; end
end
