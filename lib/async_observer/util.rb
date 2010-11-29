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


require 'open3'

module AsyncObserver; end
module AsyncObserver::Util
  def log_bracketed(name, log_elapsed_time=false)
    begin
      start_time = Time.now.utc
      RAILS_DEFAULT_LOGGER.info "#!#{name}!begin!#{start_time.xmlschema(6)}"
      yield()
    ensure
      end_time = Time.now.utc
      if log_elapsed_time
        elapsed = end_time - start_time
        RAILS_DEFAULT_LOGGER.info "#!#{name}!elapsed!#{"%0.6f-seconds" % elapsed}"
      end
      RAILS_DEFAULT_LOGGER.info "#!#{name}!end!#{end_time.xmlschema(6)}"
    end
  end
end
