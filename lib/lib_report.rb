module LibReport

  # Very simple base class used to store some common properties and
  # methods for objects which deal with worked hours.

  class ReportElementaryCalculator

    # Committed, not committed hours (floats)

    attr_accessor :committed, :not_committed

    def initialize
      reset!()
    end

    # Returns total worked hours (committed plus not committed).

    def total
      return ( @committed + @not_committed )
    end

    # Returns 'true' if the object records > 0 total hours, else 'false'.

    def has_hours?
      return ( total() > 0.0 )
    end

    # Add the given calculator's committed and not committed hours to this
    # calculator's hours.

    def add!( calculator )
      @committed     += calculator.committed
      @not_committed += calculator.not_committed
    end

    # Reset the object's hour counts.

    def reset!
      @committed     = 0.0
      @not_committed = 0.0
    end
  end

  #############################################################################
  # CALCULATION SUPPORT - MAIN REPORT OBJECT
  #############################################################################

  # Class which manages a report.

  class Report < ReportElementaryCalculator

    include LibSections

    # Configure the handlers and human-readable labels for the ways in
    # which reports get broken up, in terms of frequency. View code which
    # presents a choice of report frequency should obtain the labels for
    # the list with the 'label' method. Use the 'column_title' method for
    # a column "title", shown alongside or above column headings. Use the
    # 'column_heading' method for per-column headings.

    FREQUENCY = [
      { :label => 'Totals only',      :title => '',                  :column => :heading_total,             :generator => :totals_report                                          },
      { :label => 'UK tax year',      :title => 'UK tax year:',      :column => :heading_tax_year,          :generator => :periodic_report, :generator_arg => :end_of_uk_tax_year },
      { :label => 'Calendar year',    :title => 'Year:',             :column => :heading_calendar_year,     :generator => :periodic_report, :generator_arg => :end_of_year        },
      { :label => 'Calendar quarter', :title => 'Quarter starting:', :column => :heading_quarter_and_month, :generator => :periodic_report, :generator_arg => :end_of_quarter     },
      { :label => 'Monthly',          :title => 'Month:',            :column => :heading_quarter_and_month, :generator => :periodic_report, :generator_arg => :end_of_month       },
      { :label => 'Weekly',           :title => 'Week starting:',    :column => :heading_weekly,            :generator => :periodic_report, :generator_arg => :end_of_week        },

      # Daily reports are harmful since they can cause EXTREMELY large reports
      # to be generated and this can take longer than the web browser will wait
      # before timing out. In the mean time, Rails keeps building the report...
      #
      # { :label => 'Daily',            :title => 'Date:',              :column => :heading_daily,            :generator => :daily_report                                           },
    ]

    # Complete date range for the whole report; array of user IDs used for
    # per-user breakdowns; array of task IDs the report will represent.
    attr_accessor :range
    attr_reader   :user_ids, :task_ids # Bespoke "task_ids=" and "user_ids=" methods are defined later

    # Range data for the 'new' view form.
    attr_accessor :range_start, :range_end
    attr_accessor :range_week_start, :range_week_end
    attr_accessor :range_month_start, :range_month_end

    # A row from the FREQUENCY constant and the current index into that array,
    # as a stringify_keys.
    attr_reader :frequency_data, :frequency

    # Read-only array of actual user and task objects based on the IDs; call
    # "build_task_and_user_arrays" to build it. Not all users or tasks may be
    # included, depending on security settings.
    attr_reader :users, :tasks

    # Array of ReportRows making up the report. The row objects contain
    # arrays of cells, corresponding to columns of the report.
    attr_reader :rows

    # Array of ReportSection objects describing per-section totals of various
    # kinds. See the ReportSection class and LibSections module for
    # details.
    attr_reader :sections

    # Number of columns after all calculations are complete; this is the same
    # as the size of the 'column_ranges' or 'column_totals' arrays below, but
    # using this explicit property is likely to make code more legible.
    attr_reader :column_count

    # Array of ranges, one per column, giving the range for each of
    # the columns held within the rows. The indices into this array match
    # indices into the rows' cell arrays.
    attr_reader :column_ranges

    # Array of ReportColumnTotal objects, one per column, giving the total
    # hours for that column. The indices into this array match indices into
    # the rows' cell arrays.
    attr_reader :column_totals

    # Total duration of all tasks in all rows; number of hours remaining (may
    # be negative for overrun) after all hours worked in tasks with non-zero
    # duration. If 'nil', *all* tasks had zero duration. The 'actual' value
    # only accounts for committed hours, while the 'potential' value includes
    # both committed and not-committed hours (thus, subject to change).
    attr_reader :total_duration, :total_actual_remaining, :total_potential_remaining

    # Array of ReportUserColumnTotal objects, each index corresponding to a
    # user the "users" array at the same index. These give the total work done
    # by that user across all rows.
    attr_reader :user_column_totals

    # Create a new Report. In the first parameter, pass the current Lib
    # user. In the next parameter pass nothing to use default values for a 'new
    # report' view form, or pass "params[ :report ]" (or similar) to create
    # using a params hash from a 'new report' form submission.

    def initialize( current_user, params = nil )
      @current_user = current_user

      # These settings are closely related to the report 'edit' view, since
      # ReportsController will set params onto an instance of a Report object
      # in order to begin its form processing work.

      @range_start       = nil
      @range_end         = nil
      @range_week_start  = nil
      @range_week_end    = nil
      @range_month_start = nil
      @range_month_end   = nil
      @task_ids          = []
      @user_ids          = []
      @tasks             = []
      @users             = []
      @frequency         = 0

      unless ( params.nil? )

        # Adapted from ActiveRecord::Base "attributes=", Rails 2.1.0
        # on 29-Jun-2008.

        attributes = params.dup
        attributes.stringify_keys!
        attributes.each do | key, value |
          if ( key.include?( '(' ) )
            raise( "Multi-parameter attributes are not supported." )
          else
            send( key + "=", value )
          end
        end
      end
    end

    # Build the 'task' array if 'task_ids' is updated externally.

    def task_ids=( ids )
      ids ||= []
      ids = ids.values if ( ids.class == Hash or ids.class == HashWithIndifferentAccess )
      ids.map! { | str | str.to_i }

      @task_ids = ids
      @tasks    = []

      @task_ids.each_index do | index |
        @tasks[ index ] = Task.find( @task_ids[ index ] )
      end

      # Security - discard tasks the user should not be able to see.

      if ( @current_user.restricted? )
        @tasks.select do | task |
          task.is_permitted_for?( @current_user )
        end
      end

      # Now the fiddly bit! Sort the task objects by augmented title, then
      # retrospectively rebuild the task IDs array using the reordered list.

      Task.sort_by_augmented_title( @tasks )
      @task_ids = @tasks.map { | task | task.id }
    end

    # Build the 'user' array if 'user_ids' is updated externally.

    def user_ids=( ids )
      ids ||= []
      ids = ids.values if ( ids.class == Hash or ids.class == HashWithIndifferentAccess )
      @user_ids = ids.map { | str | str.to_i }

      # Security - if the current user is restricted they might try and hack
      # the form to view other user details.

      if ( @current_user.restricted? )
        @user_ids = [ @current_user.id ] unless( @user_ids.empty? )
      end

      # Turn the list of (now numeric) user IDs into user objects.

      @users = User.find_active(
        :all,
        :conditions => { :id => @user_ids },
        :order      => 'name ASC'
      )
    end

    # Set the 'frequency_data' field when 'frequency' is updated externally.

    def frequency=( freq )
      @frequency      = freq.to_i
      @frequency_data = FREQUENCY[ @frequency ]
    end

    # Compile the report.

    def compile
      rationalise_dates()

      return if ( @tasks.nil? or @tasks.empty? )

      add_rows()
      add_columns()
      calculate!()
    end

    # Helper method which returns a user-displayable label describing this
    # report type. There's a class method equivalent below.

    def label
      return @frequency_data[ :label ]
    end

    # Helper method which returns a user-displayable range describing the
    # total date range for this report.

    def display_range
      return heading_total( @range )
    end

    # Class method equivalent of "label" above. Returns the label for the
    # given frequency, which must be a valid index into Report::FREQUENCY.
    # See also "labels" below.

    def self.label( frequency )
      return Report::FREQUENCY[ frequency ][ :label ]
    end

    # Class method which returns an array of labels for various report
    # frequencies. The index into the array indicates the frequency index.

    def self.labels
      return Report::FREQUENCY.map { | f | f[ :label ] }
    end

    # Helper method which returns a user-displayable column title to be shown
    # once, next to or near per-column headings (see "column_heading"),
    # appropriate for the report type.

    def column_title
      return @frequency_data[ :title ]
    end

    # Helper method which returns a user-displayable column heading appropriate
    # for the report type. Pass the column index.

    def column_heading( col_index )
      col_range = @column_ranges[ col_index ]
      return send( @frequency_data[ :column ], col_range )
    end

    # Does the column at the given index only contain partial results, because
    # it is the first or last column in the overall range and that range starts
    # or ends somewhere in the middle? Returns 'true' if so, else 'false'.

    def partial_column?( col_index )

#TODO: Doesn't work, because col_range accurately reflects the column range
#      rather than the quantised range. Getting at the latter is tricky, so
#      leaving this for later. At present the method is only used for display
#      purposes in the column headings.

      col_range = @column_ranges[ col_index ]
      return ( col_range.first < @range.first or col_range.last > @range.last )
    end

  private

    # Unpack a string of the form "number_number[_number...]" and return the
    # numbers as an array of integers (e.g. "12_2008" becomes [12, 2008]).

    def unpack_string( rstr )
      return rstr.split( '_' ).collect() { | str | str.to_i() }
    end

    # Turn the start and end times into a Date range; if there are
    # any errors, use defaults instead.

    def rationalise_dates
      default_range = date_range()

      begin
        if ( not @range_month_start.blank? )
          year, month = unpack_string( @range_month_start )
          range_start = Date.new( year, month )
        elsif ( not @range_week_start.blank? )
          year, week = unpack_string( @range_week_start )
          range_start = Timesheet.date_for( year, week, TimesheetRow::FIRST_DAY, true )
        else
          range_start = Date.parse( @range_start )
        end
      rescue
        range_start = default_range.first
      end

      begin
        if ( not @range_month_end.blank? )
          year, month = unpack_string( @range_month_end )
          range_end = Date.new( year, month ).at_end_of_month()
        elsif ( not @range_week_end.blank? )
          year, week = unpack_string( @range_week_end )
          range_end = Timesheet.date_for( year, week, TimesheetRow::LAST_DAY, true )
        else
          range_end = Date.parse( @range_end )
        end
      rescue
        range_end = default_range.last
      end

      if ( range_end < range_start )
        @range = range_end..range_start
      else
        @range = range_start..range_end
      end
    end

    # Return the default date range for a report - from the 1st January
    # on the first year that Timesheet.time_range() reports as valid, to
    # "today", if no work packets exist; else the date of the earliest and
    # latest work packets over all selected tasks (@task_ids array must be
    # populated with permitted task IDs, or "nil" for 'all tasks').

    def date_range
      earliest = WorkPacket.find_earliest_by_tasks( @task_ids )
      latest   = WorkPacket.find_latest_by_tasks( @task_ids )

      end_of_range   = earliest.nil? ? Date.current                                   : earliest.date.to_date
      start_of_range = latest.nil?   ? Date.new( Timesheet.time_range().first, 1, 1 ) : latest.date.to_date

      return ( start_of_range..end_of_range )
    end

    # Create row objects for the report as a first stage of report compilation.

    def add_rows
      @rows = []
      @tasks.each do | task |
        row = ReportRow.new( task )
        @rows.push( row )
      end
    end

    # Once all rows are added with add_rows, they need populating with columns.
    # Call here to do this. The Report's user information, task information
    # etc. will all be used to populate the rows with cells describing the
    # worked hours condition for that row and column.
    #
    # Each cell added onto a row's array of cells has its date range stored at
    # the same index in the @column_ranges array and a ReportColumnTotal object
    # stored at the same index in the @column_totals array.

    def add_columns
      @column_ranges = []
      @column_totals = []

      # Earlier versions of the report generator asked the database for very
      # specific groups of work packets for date ranges across individual
      # columns. Separate queries were made for per-user breakdowns. This got
      # very, very slow far too easily. There's a big RAM penalty for reading
      # in all work packets in one go, but doing this and iterating over the
      # required items on each column within Ruby is much faster overall.

      @committed_work_packets     = []
      @not_committed_work_packets = []
      user_ids                    = @user_ids.empty? ? nil : @user_ids

      @task_ids.each_index do | index |
        task_id = @tasks[ index ]

        @committed_work_packets[ index ] = WorkPacket.find_committed_by_task_user_and_range(
            @range,
            task_id,
            user_ids
        )

        @not_committed_work_packets[ index ] = WorkPacket.find_not_committed_by_task_user_and_range(
            @range,
            task_id,
            user_ids
        )
      end

      # Generate the report by calling the generator in the FREQUENCY constant.
      # Generators iterate over the report's date range, calling add_column
      # (note singular name) for each iteration.

      send( @frequency_data[ :generator ], @frequency_data[ :generator_arg ] )

      # Finish off by filling in the column count property.

      @column_count = @column_totals.size()
    end

    # Add columns to the report, with each column spanning one day of the total
    # report date range.

    def daily_report( report, ignored = nil )
      @range.each do | day |
        add_column( day..day )
      end
    end

    # Add columns to the report, with each column spanning one period the total
    # report date range. The period is determined by the second parameter. This
    # must be a method name that, when invoked on a Date object, returns the end
    # of a period given a date within that period. For example, method names
    # ":end_of_week" or ":end_of_quarter" would result in one column per week or
    # one column per quarter, respectively.
    #
    # If the report's total date range starts or ends part way through a column,
    # then that column will contain only data from the report range. That is, the
    # range is *not* quantised to a column boundary.

    def periodic_report( end_of_period_method )
      period_start_day = @range.first
      report_end_day   = @range.last

      begin
        column_end_day = period_start_day.send( end_of_period_method )
        period_end_day = [ column_end_day, report_end_day ].min

        add_column( period_start_day..period_end_day )
        period_start_day = period_end_day + 1
      end while ( @range.include?( period_start_day ) )
    end

    # Add a single column to the given report spanning the total report date
    # range.

    def totals_report( ignored = nil )
      add_column( @range )
    end

    # Add a column containing data for the given range of Date objects.

    def add_column( range )
      col_total = ReportColumnTotal.new

      @tasks.each_index do | task_index |
        task      = @tasks[ task_index ]
        row       = @rows[ task_index ]
        cell_data = ReportCell.new

        # Work out the total for this cell, which will take care of per-user
        # totals in passing.

        committed     = 
        not_committed = 

        cell_data.calculate!(
          range,
          @committed_work_packets[ task_index ],
          @not_committed_work_packets[ task_index ],
          @user_ids
        )

        # Include the cell in this row and the running column total.

        row.add_cell( cell_data )
        col_total.add_cell( cell_data )
      end

      @column_ranges.push( range )
      @column_totals.push( col_total )
    end

    # Compute row, column and overall totals for the report. You must have
    # run 'add_columns' beforehand.

    def calculate!

      # Calculate total task duration.

      @total_duration = 0.0

      @tasks.each do | task |
        @total_duration += task.duration
      end

      # Reset the task summary totals.

      @total_actual_remaining = @total_potential_remaining = nil

      # Calculate the grand total across all rows.

      reset!()

      @rows.each_index do | row_index |
        row  = @rows[ row_index ]
        task = @tasks[ row_index ]

        add!( row )

        if ( task.duration > 0 )
          @total_actual_remaining    ||= @total_duration
          @total_potential_remaining ||= @total_duration

          @total_actual_remaining    -= row.committed
          @total_potential_remaining -= row.total
        end
      end

      # Work out the row totals for individual users.

      @users.each_index do | user_index |
        @rows.each do | row |
          user_row_total = ReportUserRowTotal.new
          user_row_total.calculate!( row, user_index )
          row.add_user_row_total( user_row_total )
        end
      end

      # Use that to generate the overall user totals.

      @user_column_totals = []

      @users.each_index do | user_index |
        user_column_total = ReportUserColumnTotal.new
        user_column_total.calculate!( @rows, user_index )
        user_column_totals[ user_index ] = user_column_total
      end

      # Now move on to section calculations.

      sections_initialise_sections()

      @sections       = []
      current_section = nil

      @rows.each_index do | row_index |
        row  = @rows[ row_index ]
        task = @tasks[ row_index ]

        if ( sections_new_section?( task ) )
          current_section = ReportSection.new 
          @sections.push( current_section )
        end

        raise( "Section calculation failure in report module" ) if ( current_section.nil? )

        row.cells.each_index do | cell_index |
          cell = row.cells[ cell_index ]
          current_section.add_cell( cell, cell_index )
        end

        row.user_row_totals.each_index do | user_index |
          user_row_total = row.user_row_totals[ user_index ]
          current_section.add_user_row_total( user_row_total, user_index )
        end
      end

    end

    # Helper methods which return a user-displayable column heading for various
    # different report types. Pass the date range to displayl

    def heading_total( range )
      format = '%d-%b-%Y' # DD-Mth-YYYY
      return "#{ range.first.strftime( format ) } to #{ range.last.strftime( format ) }"
    end

    def heading_tax_year( range )
      year = range.first.beginning_of_uk_tax_year.year
      return "#{ year } / #{ year + 1 }"
    end

    def heading_calendar_year( range )
      return range.first.year.to_s
    end

    def heading_quarter_and_month( range )
      return range.first.strftime( '%b %Y' ) # Mth-YYYY
    end

    def heading_weekly( range )
      return "#{ range.first.strftime( '%d-%b-%Y' ) } (#{ range.first.cweek })" # DD-Mth-YYYY
    end

    def heading_daily( range )
      return range.first.strftime( '%d-%b-%Y' ) # DD-Mth-YYYY
    end
  end

  #############################################################################
  # CALCULATION SUPPORT - OBJECTS FOR ROWS, CELLS, TOTALS
  #############################################################################

  # Store information about a specific task over a full report date range.
  # The parent report contains information about that range.

  class ReportRow < ReportElementaryCalculator
    # Array of ReportCell objects
    attr_reader :cells

    # Array of ReportUserRowTotal objects
    attr_reader :user_row_totals

    # Task for which this row exists
    attr_reader :task

    def initialize( task )
      super()
      @cells           = []
      @user_row_totals = []
      @task            = task
    end

    # Add the given ReportCell object to the "@cells" array and increment
    # the internal running total for the row.

    def add_cell( cell )
      @cells.push( cell )
      add!( cell )
    end

    # Call to add ReportUserRowTotal objects to the row's @user_row_totals
    # array.

    def add_user_row_total( user_row_total )
      @user_row_totals.push( user_row_total )
    end
  end

  # Rows are grouped into sections. Whenever the customer or project of the
  # currently processed row differs from a previously processed row, a new
  # section is declared. The report's "sections" array should be accessed by
  # section index (see module LibSections for details).
  #
  # Section objects contain an array of ReportCell objects, just like a row,
  # only this time each cell records the total hours in the column spanning
  # all rows within the section. There is also a "user_row_totals" array, again
  # recording the hours for the user across the whole report time range and
  # across all rows in the section.
  #
  # The ReportSection object's own hour totals give the sum of all hours by
  # anybody across the whole report time range and all rows in the section.
  # This is analogous to a ReportRow object's totals.
  #
  # Section totals are best calculated after the main per-row and per-column
  # report data has been worked out for all rows and columns.

  class ReportSection < ReportElementaryCalculator
    # Array of ReportCell objects. Analogous to the same-name array in a
    # ReportRow, but each cell corresponds to all rows in this section.
    attr_reader :cells

    # Array of ReportUserRowTotal objects. Again, analogous to the same-name
    # array in a ReportRow, but correspond to multiple rows.
    attr_reader :user_row_totals

    def initialize
      super()
      @cells           = []
      @user_row_totals = []
    end

    # Add the given ReportCell to the "@cells" array at the given cell index.
    # If there is already a cell at this index, then add the hours to that
    # cell. This makes it easy to iterate over rows and their cells, then add
    # those hours progressively to the section cells to produce the multiple-
    # row section totals.

    def add_cell( cell, cell_index )
      dup_or_calc( @cells, cell, cell_index )
      add!( cell )
    end

    # Call to add ReportUserRowTotal objects to the row's @user_row_totals
    # array at the given user index. Again, multiple calls for the same index
    # cause hours to be added, as with "add_cell" above.s

    def add_user_row_total( user_row_total, user_index )
      dup_or_calc( @user_row_totals, user_row_total, user_index )
    end

  private

    # To the given array, add a duplicate of the given object at the given
    # index should the array not contain anything at that index, else add
    # the hours from the object to whatever is already in the array.

    def dup_or_calc( array, object, index )
      array[ index ] = object.class.new if ( array[ index ].nil? )
      array[ index ].add!( object )
    end
  end

  # Store information about a specific task over a column's date range.
  #
  # The object does not store the task or range data since this would be
  # redundant across potentially numerous instances leading to significant
  # RAM wastage. Instead:
  #
  # - The ReportCell objects are stored in a ReportRow "cells" array. The
  #   array indices correspond directly to array indices of the Report's
  #   "ranges" array, compiled as the first row of the report gets built.
  #
  # - The ReportRows' "task" property gives the task object for that row.
  #
  # So - to find task and range, you need to know the row index of the
  # ReportRow and the column index of the ReportCell this contains.

  class ReportCell < ReportElementaryCalculator
    # User breakdown for this cell
    attr_reader :user_data

    def initialize()
      super()
      @user_data = []
    end

    # Add the given ReportUserData object to the "@user_data" array and
    # add it to the internal running hourly count.

    def add_user_data( data )
      @user_data.push( data )
      add!( data )
    end

    # Pass a date range, an array of committed work packets sorted by date
    # descending, an array of not committed work packets sorted by date
    # descending and an optional user IDs array. Hours are summed for work
    # packets across the given range. Any work packets falling within the range
    # are removed from the arrays. Separate totals for each of the users in the
    # given array are maintained in the @user_data array.

    def calculate!( range, committed, not_committed, user_ids = [] )
      # Reset internal calculations and pre-allocate ReportUserData objects for
      # each user (if any).

      reset!()
      @user_data = []

      user_ids.each_index do | user_index |
        @user_data[ user_index ]= ReportUserData.new
      end

      # Start and the end of the committed packets array. For anything within
      # the given range, add the hours to the internal total and add to the
      # relevant user

      @committed = sum(
        range,
        committed,
        user_ids,
        :add_committed_hours
      )

      # Same again, but for not committed hours.

      @not_committed = sum(
        range,
        not_committed,
        user_ids,
        :add_not_committed_hours
      )
    end

  private

    # For the given array of work packets sorted by date descending, check the
    # last entry and see if it is in the given range. If it is, include its
    # worked hours in a running total and pop the item off the array. Pass an
    # array of user IDs also and a method to call on an entry in the @user_data
    # array; if the work packet's associated user ID is in the array then the
    # user data object at the corresponding index in @user_data will have the
    # given method called and passed the packet.

    def sum( range, packets, user_ids, user_data_method )
      total  = 0.0
      packet = packets[ -1 ]

      while ( ( not packets.empty? ) and ( range.include?( packet.date.to_date ) ) )
        total += packet.worked_hours

        index = user_ids.index( packet.timesheet_row.timesheet.user_id )
        @user_data[ index ].send( user_data_method, packet ) unless ( index.nil? )

        packets.pop()
        packet = packets[ -1 ]
      end

      return total
    end
  end

  # Object used to handle running column totals. The Report object creates
  # one each time it adds a column. For each cell that is calculated, call
  # the ReportColumnTotal's "add_cell" method to increment the running
  # total for the column.

  class ReportColumnTotal < ReportElementaryCalculator

    # See above.

    def add_cell( cell_data )
      add!( cell_data )
    end
  end

  # Store information about a user's worked hours for a specific cell - that
  # is, a specific task and date range. ReportUserData objects are associated
  # with ReportCells, and those cells deal with passing over hours to be
  # included in the user data total.

  class ReportUserData < ReportElementaryCalculator

    # Add the given work packet's hours to the internal committed total.

    def add_committed_hours( packet )
      @committed += packet.worked_hours
    end

    # Add the given work packet's hours to the internal not committed total.

    def add_not_committed_hours( packet )
      @not_committed += packet.worked_hours
    end
  end

  # Analogous to ReportUserData, but records the a user's total worked hours
  # for the whole row. ReportUserRowTotal objects should be added to a UserRow
  # in the order the users appear in the Report's @users array so that indices
  # match between user data arrays in cells and the row user total arrays.

  class ReportUserRowTotal < ReportElementaryCalculator

    # Pass a ReportRow object containing user data to count and the index
    # in the cell user data arrays of the user in which you have an
    # interest.

    def calculate!( row, user_index )
      reset!()

      row.cells.each do | cell |
        user_data = cell.user_data[ user_index ]
        add!( user_data )
      end
    end
  end

  # Analogous to ReportUserRowTotal, but sums across all rows. The objects
  # should be added to the Report object @user_column_totals array in the order
  # of appearance in the Report's @users array.

  class ReportUserColumnTotal < ReportElementaryCalculator

    # Pass an array of ReportRow objects to sum over and the index
    # in the row user summary arrays of the user in which you have an
    # interest.

    def calculate!( rows, user_index )
      reset!()

      rows.each do | row |
        add!( row.user_row_totals[ user_index ] )
      end
    end
  end
end
