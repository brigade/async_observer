# async-observer - Rails plugin for asynchronous job execution

# Copyright (C) 2007 Philotic Inc.

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


begin
  require 'mysql'
rescue LoadError
  # Ignore case where we don't have mysql
end
require 'async_observer/queue'
require 'date'

module AsyncObserver; end

class AsyncObserver::Worker

  unless defined?(SLEEP_TIME) # rails loads this file twice
    SLEEP_TIME = 60
    RESERVE_TIMEOUT = 1 # seconds
  end

  class << self
    attr_accessor :finish
    attr_accessor :custom_error_handler
    attr_accessor :before_filter
    attr_accessor :around_filter
    attr_writer :handle

    def handle
      @handle or raise 'no custom handler is defined'
    end

    def error_handler(&block)
      self.custom_error_handler = block
    end

    def before_reserves
      @before_reserves ||= []
    end

    def before_reserve(&block)
      before_reserves << block
    end

    def run_before_reserve
      before_reserves.each {|b| b.call()}
    end
  end

  def initialize(top_binding, opts = {})
    @top_binding = top_binding
    @stop = false
    @opts = opts
  end

  def check_current_symlink
    symlinked_directory = File.realdirpath(@opts[:check_symlink])

    if Dir.pwd != symlinked_directory && File.directory?(symlinked_directory)
      ::Rails.logger.info "Found new app version in #{symlinked_directory}, re-execing: #{$0} #{ARGV.join(' ')}"
      Dir.chdir symlinked_directory
      exec($0, *ARGV)
    end
  end

  def startup()
    appver = AsyncObserver::Queue.app_version
    ::Rails.logger.info "pid is #{$$}"
    ::Rails.logger.info "app version is #{appver}"
    mark_db_socket_close_on_exec()
    if AsyncObserver::Queue.queue.nil?
      ::Rails.logger.info 'no queue has been configured'
      exit(1)
    end
    AsyncObserver::Queue.queue.watch(appver) if appver
    flush_logger
  end

  # This prevents us from leaking fds when we exec. Only works for mysql.
  def mark_db_socket_close_on_exec()
    ActiveRecord::Base.connection_handler.connection_pools.each do |name, pool|
      pool.connection.set_close_on_exec
    end
  rescue NoMethodError
  end

  def shutdown()
    do_all_work()
  end

  def run
    trap('TERM') { @stop = true }
    startup
    main_loop
  rescue => ex
    ::Rails.logger.error "Caught error in run, shutting down: #{ex}"
    ::Rails.logger.error ex.backtrace.join("\n")
  ensure
    shutdown()
  end

  def q_hint()
    @q_hint || AsyncObserver::Queue.queue
  end

  # This heuristic is to help prevent one queue from starving. The idea is that
  # if the connection returns a job right away, it probably has more available.
  # But if it takes time, then it's probably empty. So reuse the same
  # connection as long as it stays fast. Otherwise, have no preference.
  def reserve_and_set_hint()
    t1 = Time.now.utc
    return job = q_hint().reserve(RESERVE_TIMEOUT)
  ensure
    t2 = Time.now.utc
    @q_hint = if brief?(t1, t2) and job then job.conn else nil end
  end

  def brief?(t1, t2)
    ((t2 - t1) * 100).to_i.abs < 10
  end

  def main_loop
    loop do
      job = nil

      begin
        AsyncObserver::Queue.queue.connect()
        self.class.run_before_reserve
        job = reserve_and_set_hint()
      rescue Beanstalk::TimedOut
        # Timeout is expected
      rescue SignalException
        raise
      rescue Beanstalk::DeadlineSoonError
        # Do nothing; immediately try again, giving the user a chance to
        # clean up in the before_reserve hook.
        ::Rails.logger.info 'Job deadline soon; you should clean up.'
      rescue Exception => ex
        @q_hint = nil # in case there's something wrong with this conn
        ::Rails.logger.info(
          "#{ex.class}: #{ex}\n" + ex.backtrace.join("\n"))
        ::Rails.logger.info 'something is wrong. We failed to get a job.'
        ::Rails.logger.info "sleeping for #{SLEEP_TIME}s..."
        sleep(SLEEP_TIME)
      end

      safe_dispatch(job) if job

      break if @stop
      check_current_symlink if @opts[:check_symlink]
    end
  end

  def dispatch(job)
    return run_ao_job(job) if async_observer_job?(job)
    return run_other(job)
  end

  def safe_dispatch(job)
    ::Rails.logger.info "got #{job.inspect}:\n" + job.body
    ::Rails.logger.info job.stats.map { |k, v| "#{k}=#{v}" }.join(' ')
    begin
      start_time = Time.now
      return dispatch(job)
    rescue Interrupt => ex
      begin job.release() rescue :ok end
      raise ex
    rescue Exception => ex
      handle_error(job, ex)
    ensure
      job_duration_milliseconds = ((Time.now - start_time) * 1000).to_i
      ::Rails.logger.info "#!job-duration!#{job_duration_milliseconds}!#{job[:code]}"
      flush_logger
    end
  end

  def flush_logger
    if defined?(::Rails.logger) &&
        ::Rails.logger.respond_to?(:flush)
      ::Rails.logger.flush
    end
  end

  def handle_error(job, ex)
    if self.class.custom_error_handler
      self.class.custom_error_handler.call(job, ex)
    else
      self.class.default_handle_error(job, ex)
    end
  end

  def self.default_around_filter(job)
    yield
  end

  def self.default_handle_error(job, ex)
    ::Rails.logger.info "Job failed: #{job.server}/#{job.id}"
    ::Rails.logger.info("#{ex.class}: #{ex}\n" + ex.backtrace.join("\n"))
    job.decay()
  rescue Beanstalk::UnexpectedResponse
  end

  def run_ao_job(job)
    ::Rails.logger.info 'running as async observer job'
    f = self.class.before_filter
    f.call(job) if f
    job.delete if job.ybody[:delete_first]
    run_code(job)
    job.delete() unless job.ybody[:delete_first]
  rescue ActiveRecord::RecordNotFound => ex
    unless job.ybody[:delete_first]
      if job.age > 60
        job.delete() # it's old; this error is most likely permanent
      else
        job.decay() # it could be replication delay so retry quietly
      end
    end
  end

  def run_code(job)
    f = self.class.around_filter || self.class.method(:default_around_filter)
    f.call(job) do
      eval(job.ybody[:code], @top_binding, "(beanstalk job #{job.id})", 1)
    end
  end

  def async_observer_job?(job)
    begin job.ybody[:type] == :rails rescue false end
  end

  def run_other(job)
    ::Rails.logger.info 'trying custom handler'
    self.class.handle.call(job)
  end

  def do_all_work()
    ::Rails.logger.info 'finishing all running jobs. interrupt again to kill them.'
    f = self.class.finish
    f.call() if f
  end
end

class Mysql
  def set_close_on_exec()
    if @net
      @net.set_close_on_exec()
    else
      # we are in the c mysql binding
      ::Rails.logger.info "Warning: we are using the C mysql binding, can't set close-on-exec"
    end
  end
end

class Mysql::Net
  def set_close_on_exec()
    @sock.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC)
  end
end
