# async-observer - Rails plugin for asynchronous job execution
# Copyright (C) 2009 Todd A. Fisher.

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
module AsyncObserver; end

class AsyncObserver::Daemonize
  def self.detach(pidfile='log/worker.pid',&block)
    read_pipe, write_pipe = IO.pipe

    # See: http://stackoverflow.com/q/881388
    # First fork starts a throwaway process...
    fork do
      read_pipe.close

      # ...which starts a new session (as the session leader)...
      fail 'failed to detach from controlling term' unless Process.setsid

      # ...and then fork again to let the session leader die.
      fork do
        daemon_pid = Process.pid
        write_pipe.write(daemon_pid)
        write_pipe.close

        # Delete pidfile when this process exits (but not child processes)
        at_exit { File.unlink(pidfile) if Process.pid == daemon_pid }

        File.umask 0000
        STDIN.reopen "/dev/null"
        STDOUT.reopen "/dev/null", "a"
        STDERR.reopen STDOUT
        block.call
      end
    end

    write_pipe.close

    # Wait until grandchild process has started
    File.open(pidfile, 'wb') {|f| f.write(read_pipe.read) }
    read_pipe.close
  end
end
