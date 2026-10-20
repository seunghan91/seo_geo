# frozen_string_literal: true

require "socket"

# Minimal loopback HTTP server; no external network is used by remote audit tests.
class AuditHttpServer
  attr_reader :origin, :requests

  def initialize(&handler)
    @server = TCPServer.new("127.0.0.1", 0)
    @origin = "http://127.0.0.1:#{@server.addr[1]}"
    @requests = []
    @thread = Thread.new do
      loop do
        socket = @server.accept
        begin
          line = socket.gets
          next unless line

          _method, path, = line.split
          headers = {}
          while (line = socket.gets) && line != "\r\n"
            name, value = line.split(":", 2)
            headers[name.downcase] = value.strip
          end
          @requests << { path: path, headers: headers, time: Process.clock_gettime(Process::CLOCK_MONOTONIC) }
          status, response_headers, body = handler.call(path, headers, @origin)
          body ||= ""
          socket.write("HTTP/1.1 #{status} Response\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n")
          response_headers.each { |name, value| socket.write("#{name}: #{value}\r\n") }
          socket.write("\r\n#{body}")
        ensure
          socket.close
        end
      end
    rescue IOError, Errno::EBADF
      # Listener closed by #close.
    end
  end

  def close
    @server.close
    @thread.join(2) || @thread.kill.join
  end
end
