# encoding: utf-8

=begin
    Copyright 2010-2012 Tasos Laskos <tasos.laskos@gmail.com>

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
=end

require 'rubygems'
require 'bundler/setup'

require 'ap'
require 'pp'

require File.expand_path( File.dirname( __FILE__ ) ) + '/options'

module Arachni

lib = Options.dir['lib']
require lib + 'version'
require lib + 'ruby'
require lib + 'exceptions'
require lib + 'cache'
require lib + 'utilities'
require lib + 'uri'
require lib + 'spider'
require lib + 'parser'
require lib + 'issue'
require lib + 'module'
require lib + 'plugin'
require lib + 'audit_store'
require lib + 'http'
require lib + 'report'
require lib + 'database'
require lib + 'component/manager'
require lib + 'session'
require lib + 'trainer'

require Options.dir['mixins'] + 'progress_bar'

#
# The Framework class ties together all the components.
#
# It's the brains of the operation, it bosses the rest of the classes around.
# It runs the audit, loads modules and reports and runs them according to
# user options.
#
# @author Tasos "Zapotek" Laskos <tasos.laskos@gmail.com>
#
class Framework
    #
    # include the output interface but try to use it as little as possible
    #
    # the UI classes should take care of communicating with the user
    #
    include UI::Output

    include Utilities
    include Mixins::Observable

    # the version of *this* class
    REVISION = '0.2.7'

    # @return [Options] Instance options
    attr_reader :opts

    # @return   [Arachni::Report::Manager]
    attr_reader :reports

    # @return   [Arachni::Module::Manager]
    attr_reader :modules

    # @return   [Arachni::Plugin::Manager]
    attr_reader :plugins

    # @return   [Session]   Web application session manager.
    attr_reader :session

    # @return   [Spider]   Web application spider.
    attr_reader :spider

    # @return   [Arachni::HTTP]
    attr_reader :http

    # @return   [Array] URLs of all discovered pages.
    attr_reader :sitemap

    # @return   [Trainer]
    attr_reader :trainer

    # @return   [Integer]   Total number of pages added to their audit queue.
    attr_reader :page_queue_total_size

    # @return   [Integer]   Total number of urls added to their audit queue.
    attr_reader :url_queue_total_size

    #
    # @param    [Options]    opts
    # @param    [Block]      block
    #   Block to be passed a {Framework} instance which will then be {#reset}.
    #
    def initialize( opts = Arachni::Options.instance, &block )

        Encoding.default_external = 'BINARY'
        Encoding.default_internal = 'BINARY'

        @opts = opts

        @modules = Module::Manager.new( self )
        @reports = Report::Manager.new( @opts )
        @plugins = Plugin::Manager.new( self )

        @session = Session.new( @opts )
        reset_spider
        @http    = HTTP.instance

        reset_trainer

        # will store full-fledged pages generated by the Trainer since these
        # may not be be accessible simply by their URL
        @page_queue = Queue.new
        @page_queue_total_size = 0

        # will hold paths found by the spider in order to be converted to pages
        # and ultimately audited by the modules
        @url_queue = Queue.new
        @url_queue_total_size = 0

        # deep clone the redundancy rules to preserve their counter
        # for the reports
        @orig_redundant = @opts.redundant.deep_clone

        @running = false
        @status  = :ready
        @paused  = []

        @auditmap = []
        @sitemap  = []

        @current_url = ''

        if block_given?
            block.call self
            reset
        end
    end

    #
    # Runs the system
    #
    # It parses the instance options, {#prepare}, runs the {#audit} and {#clean_up!}.
    #
    # @param   [Block]  block  a block to call after the audit has finished
    #                                   but before running the reports
    #
    def run( &block )
        prepare

        # catch exceptions so that if something breaks down or the user opted to
        # exit the reports will still run with whatever results Arachni managed to gather
        exception_jail( false ){ audit }

        clean_up
        exception_jail( false ){ block.call } if block_given?
        @status = :done

        # run reports
        @reports.run( audit_store ) if !@reports.empty?

        true
    end

    #
    # Returns the status of the instance as a string.
    #
    # Possible values are (in order):
    # * ready -- Just initialised and waiting for instructions
    # * preparing -- Getting ready to start (i.e. initing plugins etc.)
    # * crawling -- The instance is crawling the target webapp
    # * auditing-- The instance is currently auditing the webapp
    # * paused -- The instance has posed (if applicable)
    # * cleanup -- The scan has completed and the instance is cleaning up
    #   after itself (i.e. waiting for plugins to finish etc.).
    # * done -- The scan has completed
    #
    # @return   [String]
    #
    def status
        return 'paused' if paused?
        @status.to_s
    end

    #
    # Returns the following framework stats:
    #
    # *  :requests         -- HTTP request count
    # *  :responses        -- HTTP response count
    # *  :time_out_count   -- Amount of timed-out requests
    # *  :time             -- Amount of running time
    # *  :avg              -- Average requests per second
    # *  :sitemap_size     -- Number of discovered pages
    # *  :auditmap_size    -- Number of audited pages
    # *  :progress         -- Progress percentage
    # *  :curr_res_time    -- Average response time for the current burst of requests
    # *  :curr_res_cnt     -- Amount of responses for the current burst
    # *  :curr_avg         -- Average requests per second for the current burst
    # *  :average_res_time -- Average response time
    # *  :max_concurrency  -- Current maximum concurrency of HTTP requests
    # *  :current_page     -- URL of the currently audited page
    # *  :eta              -- Estimated time of arrival i.e. estimated remaining time
    #
    # @param    [Bool]  refresh_time    updates the running time of the audit
    #                                       (usefully when you want stats while paused without messing with the clocks)
    #
    # @param    [Bool]  override_refresh
    #
    # @return   [Hash]
    #
    def stats( refresh_time = false, override_refresh = false )
        req_cnt = http.request_count
        res_cnt = http.response_count

        @opts.start_datetime = Time.now if !@opts.start_datetime

        sitemap_sz  = @sitemap.size
        auditmap_sz = @auditmap.size

        if( !refresh_time || auditmap_sz == sitemap_sz ) && !override_refresh
            @opts.delta_time ||= Time.now - @opts.start_datetime
        else
            @opts.delta_time = Time.now - @opts.start_datetime
        end

        avg = 0
        avg = (res_cnt / @opts.delta_time).to_i if res_cnt > 0

        # we need to remove URLs that lead to redirects from the sitemap
        # when calculating the progress %.
        #
        # this is because even though these URLs are valid webapp paths
        # they are not actual pages and thus can't be audited;
        # so the sitemap and auditmap will never match and the progress will
        # never get to 100% which may confuse users.
        #
        redir_sz = spider.redirects.size

        #
        # There are 2 audit phases:
        #  * regular analysis attacks
        #  * timing attacks
        #
        # When calculating the progress % we have to take both into account,
        # however each is calculated using different criteria.
        #
        # Progress of regular attacks is calculated as:
        #     amount of audited pages / amount of all discovered pages
        #
        # However, the progress of the timing attacks is calculated as:
        #     amount of called timeout blocks / amount of total blocks
        #
        # The timing attack modules are run with the regular ones however
        # their procedures are piled up into an array of Procs
        # which are called after the regular attacks.
        #
        # So when we reach the point of needing to include their progress in
        # the overall progress percentage we'll be working with accurate
        # data regarding the total blocks, etc.
        #

        #
        # If we have timing attacks then each phase must account for half
        # of the progress.
        #
        # This is not very granular but it's good enough for now...
        #
        multi = Module::Auditor.timeout_loaded_modules.size > 0 ? 50 : 100
        progress = (Float( auditmap_sz ) / ( sitemap_sz - redir_sz ) ) * multi

        if Module::Auditor.running_timeout_attacks?
            called_blocks = Module::Auditor.timeout_audit_operations_cnt -
                Module::Auditor.current_timeout_audit_operations_cnt

            progress += ( Float( called_blocks ) /
                Module::Auditor.timeout_audit_operations_cnt ) * multi
        end

        begin
            progress = Float( sprintf( "%.2f", progress ) )
        rescue
            progress = 0.0
        end

        # sometimes progress may slightly exceed 100%
        # which can cause a few strange stuff to happen
        progress = 100.0 if progress > 100.0
        pb = Mixins::ProgressBar.eta( progress, @opts.start_datetime )
        {
            requests:         req_cnt,
            responses:        res_cnt,
            time_out_count:   http.time_out_count,
            time:             audit_store.delta_time,
            avg:              avg,
            sitemap_size:     auditstore_sitemap.size,
            auditmap_size:    auditmap_sz,
            progress:         progress,
            curr_res_time:    http.curr_res_time,
            curr_res_cnt:     http.curr_res_cnt,
            curr_avg:         http.curr_res_per_second,
            average_res_time: http.average_res_time,
            max_concurrency:  http.max_concurrency,
            current_page:     @current_url,
            eta:              pb
        }
    end

    #
    # Pushes a page to the page audit queue and updates {#page_queue_total_size}
    #
    def push_to_page_queue( page )
        @page_queue << page
        @page_queue_total_size += 1

        @sitemap |= [page.url]
    end

    #
    # Pushes a URL to the URL audit queue and updates {#url_queue_total_size}
    #
    def push_to_url_queue( url )
        abs = to_absolute( url )

        @url_queue.push( abs ? abs : url )
        @url_queue_total_size += 1

        @sitemap |= [url]
    end

    #
    # Returns the results of the audit as an {AuditStore} instance
    #
    # @see AuditStore
    #
    # @return    [AuditStore]
    #
    def audit_store
        opts = @opts.to_hash.deep_clone

        # restore the original redundancy rules and their counters
        opts['redundant'] = @orig_redundant
        opts['mods'] = @modules.keys

        AuditStore.new(
            version:  version,
            revision: revision,
            options:  opts,
            sitemap:  (auditstore_sitemap || []).sort,
            issues:   @modules.results.deep_clone,
            plugins:  @plugins.results
        )
    end
    alias :auditstore :audit_store

    #
    # Returns an array of hashes with information
    # about all available modules
    #
    # @return    [Array<Hash>]
    #
    def lsmod
        loaded = @modules.loaded
        @modules.clear
        @modules.available.map do |name|
            path = @modules.name_to_path( name )
            next if !lsmod_match?( path )

            @modules[name].info.merge(
                mod_name: name,
                author:   [@modules[name].info[:author]].flatten.map { |a| a.strip },
                path:     path.strip
            )
        end.compact
    ensure
        @modules.clear
        @modules.load( loaded )
    end

    #
    # Returns an array of hashes with information
    # about all available reports
    #
    # @return    [Array<Hash>]
    #
    def lsrep
        loaded = @reports.loaded
        @reports.clear
        @reports.available.map do |report|
            path = @reports.name_to_path( report )
            next if !lsrep_match?( path )

            @reports[report].info.merge(
                rep_name: report,
                path:     path,
                author:   [@reports[report].info[:author]].flatten.map { |a| a.strip }
            )
        end.compact
    ensure
        @reports.clear
        @reports.load( loaded )
    end

    #
    # Returns an array of hashes with information
    # about all available reports
    #
    # @return    [Array<Hash>]
    #
    def lsplug
        loaded = @plugins.loaded
        @plugins.clear
        @plugins.available.map do |plugin|
            path = @plugins.name_to_path( plugin )
            next if !lsplug_match?( path )

            @plugins[plugin].info.merge(
                plug_name: plugin,
                path:      path,
                author:    [@plugins[plugin].info[:author]].flatten.map { |a| a.strip }
            )
        end.compact
    ensure
        @plugins.clear
        @plugins.load( loaded )
    end

    #
    # @return   [Bool]  true if the framework is running
    #
    def running?
        @running
    end

    #
    # @return   [Bool]  true if the framework is paused or in the process of
    #
    def paused?
        !@paused.empty?
    end

    #
    # @return   [TrueClass]  pauses the framework on a best effort basis,
    #                       might take a while to take effect
    #
    def pause
        spider.pause
        @paused << caller
        true
    end
    alias :pause! :pause

    #
    # @return   [TrueClass]  resumes the scan/audit
    #
    def resume
        @paused.delete( caller )
        spider.resume
        true
    end
    alias :resume! :resume

    #
    # Returns the version of the framework
    #
    # @return    [String]
    #
    def version
        Arachni::VERSION
    end

    #
    # Returns the revision of the {Framework} (this) class
    #
    # @return    [String]
    #
    def revision
        REVISION
    end

    #
    # Cleans up the framework; should be called after running the audit or
    # after canceling a running scan.
    #
    # It stops the clock, waits for the plugins to finish up, registers
    # their results and also refreshes the auditstore.
    #
    # It also runs {#audit_queue} in case any new pages have been added by the plugins.
    #
    def clean_up
        @status = :cleanup

        @opts.finish_datetime  = Time.now
        @opts.start_datetime ||= Time.now

        @opts.delta_time = @opts.finish_datetime - @opts.start_datetime

        # make sure this is disabled or it'll break report output
        disable_only_positives

        @running = false

        # wait for the plugins to finish
        @plugins.block
    end
    alias :clean_up! :clean_up

    def on_run_mods( &block )
        add_on_run_mods( &block )
    end

    def reset_spider
        @spider = Spider.new( @opts )
    end

    def reset_trainer
        @trainer = Trainer.new( self )
    end

    #
    # Resets everything and allows the framework to be re-used.
    #
    # You should first update {Arachni::Options}.
    #
    # Prefer this if you already have an instance.
    #
    def reset
        @page_queue_total_size = 0
        @url_queue_total_size  = 0

        # this needs to be first so that the HTTP lib will be reset before
        # the rest
        self.class.reset

        clear_observers
        reset_trainer
        reset_spider
        @modules.clear
        @reports.clear
        @plugins.clear
    end

    #
    # Resets everything and allows the framework to be re-used.
    #
    # You should first update {Arachni::Options}.
    #
    def self.reset
        Module::Auditor.reset
        ElementFilter.reset
        Element::Capabilities::Auditable.reset
        Module::Manager.reset
        Plugin::Manager.reset
        Report::Manager.reset
        HTTP.reset
    end

    private

    #
    # Prepares the framework for the audit.
    #
    # Sets the status to 'running', starts the clock and runs the plugins.
    #
    # Must be called just before calling {#audit}.
    #
    def prepare
        @status = :preparing
        @running = true
        @opts.start_datetime = Time.now

        # run all plugins
        @plugins.run
    end

    #
    # Performs the audit
    #
    # Runs the spider, pushes each page or url to their respective audit queue,
    # calls {#audit_queue}, runs the timeout attacks ({Arachni::Module::Auditor.timeout_audit_run}) and finally re-runs
    # {#audit_queue} in case the timing attacks uncovered a new page.
    #
    def audit
        wait_if_paused

        @status = :crawling

        # if we're restricted to a given list of paths there's no reason to run the spider
        if @opts.restrict_paths && !@opts.restrict_paths.empty?
            @opts.restrict_paths = @opts.restrict_paths.map { |p| to_absolute( p ) }
            @sitemap = @opts.restrict_paths.dup
            @opts.restrict_paths.each { |url| push_to_url_queue( url ) }
        else
            # initiates the crawl
            spider.run( false ) do |response|
                @sitemap |= spider.sitemap
                push_to_url_queue( url_sanitize( response.effective_url ) )
            end
        end

        @status = :auditing
        audit_queue

        exception_jail {
            if !Module::Auditor.timeout_audit_blocks.empty?
                print_line
                print_status 'Running timing attacks.'
                print_info '---------------------------------------'
                Module::Auditor.on_timing_attacks do |_, elem|
                    @current_url = elem.action if !elem.action.empty?
                end
                Module::Auditor.timeout_audit_run
            end

            audit_queue
        }
    end

    #
    # Audits the URL and Page queues
    #
    def audit_queue
        return if modules.empty?

        # goes through the URLs discovered by the spider, repeats the request
        # and parses the responses into page objects
        #
        # yes...repeating the request is wasteful but we can't store the
        # responses of the spider to consume them here because there's no way
        # of knowing how big the site will be.
        #
        while !@url_queue.empty?
            Page.from_url( @url_queue.pop, precision: 2 ) do |page|
                push_to_page_queue( page )
            end
            harvest_http_responses

            audit_page_queue

            harvest_http_responses
        end

        audit_page_queue
    end

    #
    # Audits the page queue
    #
    def audit_page_queue
        # this will run until no new elements appear for the given page
        while !@page_queue.empty?
            run_mods( @page_queue.pop )
            harvest_http_responses
        end
    end

    #
    # Special sitemap for the {#auditstore}.
    #
    # Used only under special circumstances, will usually return the {#sitemap}
    # but can be overridden by the {::Arachni::RPC::Framework}.
    #
    # @return   [Array]
    #
    def auditstore_sitemap
        @sitemap
    end

    def caller
        if /^(.+?):(\d+)(?::in `(.*)')?/ =~ ::Kernel.caller[1]
            Regexp.last_match[1]
        end
    end

    def wait_if_paused
        ::IO::select( nil, nil, nil, 1 ) while paused?
    end

    #
    # Takes care of page audit and module execution
    #
    # It will audit one page at a time as discovered by the spider <br/>
    # and recursively check for new elements that may have <br/>
    # appeared during the audit.
    #
    # When no new elements appear the recursion will stop and a new page<br/>
    # will be accepted.
    #
    # @see Page
    #
    # @param    [Page]    page
    #
    def run_mods( page )
        return if !page

        # we may end up ignoring it but being included in the auditmap means that
        # it has been considered but didn't fit the criteria
        @auditmap << page.url
        @sitemap |= @auditmap
        @sitemap.uniq!

        if Options.exclude_binaries? && !page.text?
            print_info "Ignoring page due to non text-based content-type: #{page.url}"
            return
        end

        print_line
        print_status "Auditing: [HTTP: #{page.code}] #{page.url}"

        call_on_run_mods( page )

        @current_url = page.url.to_s

        @modules.schedule.each do |mod|
            wait_if_paused
            run_mod( mod, page )
        end

        harvest_http_responses
    end

    def harvest_http_responses
        print_status 'Harvesting HTTP responses...'
        print_info 'Depending on server responsiveness and network' <<
            ' conditions this may take a while.'

        # run all the queued HTTP requests and harvest the responses
        http.run

        session.ensure_logged_in
    end

    #
    # Passes a page to the module and runs it.
    # It also handles any exceptions thrown by the module at runtime.
    #
    # @see Page
    #
    # @param    [Class]   mod      the module to run
    # @param    [Page]    page
    #
    def run_mod( mod, page )
        begin
            @modules.run_one( mod, page )
        rescue SystemExit
            raise
        rescue => e
            print_error "Error in #{mod.to_s}: #{e.to_s}"
            print_error_backtrace e
        end
    end

    def lsrep_match?( path )
        regexp_array_match( @opts.lsrep, path )
    end

    def lsmod_match?( path )
        regexp_array_match( @opts.lsmod, path )
    end

    def lsplug_match?( path )
        regexp_array_match( @opts.lsplug, path )
    end

    def regexp_array_match( regexps, str )
        cnt = 0
        regexps.each { |filter| cnt += 1 if str =~ filter }
        cnt == regexps.size
    end

end
end
