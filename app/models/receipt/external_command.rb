# frozen_string_literal: true

require "open3"

# Runs a command-line reader (zbarimg, pdftoppm) on a receipt file. The child gets
# a minimal environment, so API keys and database URLs never reach it, and is
# killed with its process group when it runs past the time limit.
module Receipt::ExternalCommand
  Error = Class.new(StandardError)
  TimeoutError = Class.new(Error)

  ENV_VARS = { "PATH" => "/usr/local/bin:/usr/bin:/bin", "LC_ALL" => "C.UTF-8" }.freeze
  MAX_OUTPUT = 1.megabyte

  module_function

  def available?(program)
    ENV_VARS["PATH"].split(":").any? { |dir| File.executable?(File.join(dir, program)) }
  end

  # Returns [stdout, exit status]. Output beyond MAX_OUTPUT is cut off.
  def run(*command, timeout:, chdir:)
    Open3.popen3(ENV_VARS, *command, unsetenv_others: true, pgroup: true, chdir: chdir) do |stdin, stdout, stderr, wait|
      stdin.close
      output = Thread.new { read_capped(stdout) }
      Thread.new { read_capped(stderr) }

      unless wait.join(timeout)
        kill(wait.pid)
        wait.join
        raise TimeoutError, "#{command.first} timed out"
      end

      [ output.value, wait.value.exitstatus ]
    end
  rescue Errno::ENOENT
    raise Error, "#{command.first} is not installed"
  end

  def read_capped(io)
    data = io.read(MAX_OUTPUT).to_s
    io.read(64.kilobytes) until io.eof? # drain so the child never blocks on a full pipe
    data
  rescue IOError
    data.to_s
  end

  def kill(pid)
    Process.kill("KILL", -pid)
  rescue Errno::ESRCH, Errno::EPERM
    nil
  end
end
