#!/usr/bin/env ruby
# encoding: utf-8

require 'yaml'
require 'grit'
require 'pp'
require 'logger'
require 'time'
require 'timeout'
require 'socket'
require 'mail'
require 'fileutils'

ROOT= File.dirname(File.expand_path __FILE__)
CONFIG_FILE= File.join ROOT, "config.yaml"
puts CONFIG_FILE

REQUEST=File.join ROOT, "request_mgmt", "request"

# quick fix to get correct string encoding
YAML::ENGINE.yamler='syck'

$CONFIG = Hash.new

Mail.defaults do
    delivery_method :sendmail
end

class Numeric
    def datetime_duration
        secs  = self.to_int
        mins  = secs / 60
        hours = mins / 60
        days  = hours / 24

        if days > 0
            "#{days} days and #{hours % 24} hours"
        elsif hours > 0
            "#{hours} hours and #{mins % 60} minutes"
        elsif mins > 0
            "#{mins} minutes and #{secs % 60} seconds"
        elsif secs >= 0
            "#{secs} seconds"
        end
    end
end

class PingLogger < Logger
    attr_reader :lastping
    def initialize(io, len = 20)
        super io
        @buffer = Array.new
        @lastping = Time.new
        @len = len
        @server = nil

        info "Hello from Tester backend!"
        info "Start now..."
    end

    def newline(line)
        @buffer.shift if @buffer.count >= @len
        @buffer << line
        ping
    end

    def ping
        @lastping = Time.now
    end

    def info t
        newline "INFO #{Time.now} #{t}"
        super t
    end

    def error t
        newline "ERROR #{Time.now} #{t}"
        super t
    end

    def fatal t
        newline "FATAL #{Time.now} #{t}"
        super t
    end

    def server_loop addr, port
        return if @server
        puts "Logger server start @ #{port}"
        @server = TCPServer.new(addr, port)
        loop do
            begin
                client = @server.accept
                client.puts "Last ping: #{@lastping} (#{(Time.now-@lastping).datetime_duration} ago)"
                @buffer.each { |l| client.puts l}
                client.close
            rescue StandardError => e
                puts "TCPServer error: #{e.message}"
                next
            end
        end
    end

end


LOGGER_VERBOSE = Logger.new STDERR
LOGGER = PingLogger.new STDOUT

def md5sum fn
    md5 = `md5sum #{fn}`
    fail if $?.exitstatus != 0
    md5
end

def error info
    LOGGER.error info
end

def time_cmd(command,timeout)
    cmd_output = []
    LOGGER.info "Entering #{command} at #{Time.now}"
    begin
        pipe = IO.popen("#{command} 2>&1")
    rescue Exception => e
        LOGGER.error "#{command} failed"
        return {:timeout =>false, :status => 255, :output=> [e.to_s]}
    end

    begin
        status = Timeout.timeout(timeout) do
            #puts "pid: #{$$}"
            pipe.each_line {|g| cmd_output << g.chomp }
            #return [child pid, status]
            Process.waitpid2(pipe.pid)
        end
        return {:timeout =>false, :status =>status[1].exitstatus, :output => cmd_output, :pid => pipe.pid}
    rescue Timeout::Error
        LOGGER.error "#{command} pid #{pipe.pid} timeout at #{Time.now}" rescue nil
        Process.kill 9, pipe.pid if pipe.pid rescue nil
        return {:timeout =>true, :status => 254, :output => cmd_output}
    end
end

class Grit::Actor
    def simplify
        "#{@name} <#{@email}>"
    end
end

class Grit::Commit
    def simplify
        {:id => id, :author => author.simplify,
            :committer => committer.simplify,
            :authored_date => authored_date.to_s,
            :committed_date => committed_date.to_s,
            :message => message.split("\n").first
        }
    end
end

class CommitFilter
    class << self
        def method_missing(name, *args)
            LOGGER.error "filter not found #{name}"
            args.first
        end

        def ext(extlist, commits)
            commits.select do |c|
                # f => ["test.c", 1, 0 ,1]
                (c.parents.count > 1)  \
                || (c.stats.files.any? { |f| extlist.include? File.extname(f.first) })
            end
        end
    end
end

class TestGroup
    attr_reader :phases, :dirs, :result
    def initialize(_dirs)
        @phases = Array.new
        @result = Array.new
        @dirs = _dirs
    end

    def push(phase)
        @phases << phase
    end

    def run_all(last_test_commit)
        @result = Array.new
        failed = false
        @phases.each do |p|
            LOGGER.info "Running #{p.name}"
            st = Time.now
            #run it
            res = p.run dirs, last_test_commit
            time = Time.now - st
            @result << {:name => p.name, :time => time, :result => res}
            ## IMPORTANT
            if res[:status] != 0
                failed = true
                break
            end
        end
        [failed, @result]
    end

    class TestPhase
        attr_accessor :name, :cmd, :args, :timeout
        attr_reader :result
        def initialize(_name, _cmd, _args, _timeout=10)
            @name = _name
            @cmd = _cmd
            @args = _args
            @timeout = _timeout
        end

        def run(dirs, last_test_commit)
            @result = {:timeout => false, :status => 255, :output => []}
            dirs.each do |dir|
                script = File.join(dir, @cmd)
                if File.executable_real? script
                    cmd = script + " " + args + (last_test_commit == nil ? "" : " " + last_test_commit)
                    @result = time_cmd cmd, @timeout
                    break
                end
            end
            return @result
        end
    end

end

class CompileRepo
    attr_reader :repo, :name, :url, :blacklist

    def initialize config

        @name = config[:name]
        fail "REPO name is null" if @name.nil?
        @url = config[:url]
        @nomail = config[:nomail]
        @mode = config[:mode] || :normal

        @blacklist = config[:blacklist] || []
        #@blacklist.map! {|e| "origin/" + e}
        @blacklist.map! {|e| /#{e}/}
        @whitelist = config[:whitelist] || []
        @whitelist.map! {|e| /#{e}/}

        @build_timeout_s = (config[:build_timeout_min] || 1) * 60
        @run_timeout_s = (config[:run_timeout_min] || 1) * 60
        @filters = config[:filters] || []
        @result_dir = File.join $CONFIG[:result_abspath], @name

        @cc = config[:cc] || []

        @runner = TestGroup.new ["./", "./labcodes"]
        @runner.push(TestGroup::TestPhase.new "AutoBuild", "autobuild.sh", "", @build_timeout_s)
        @runner.push(TestGroup::TestPhase.new "AutoTest", "autotest.sh", @result_dir, @run_timeout_s)

        begin
            @repo = Grit::Repo.new config[:name]
        rescue Grit::NoSuchPathError
            LOGGER.info  "Cloning #{@name}"
            `git clone "#{@url}" "#{@name}"`
            fail "Fail to clone #{@url}" if $?.exitstatus != 0
            @repo = Grit::Repo.new config[:name]
        end
        # LOGGER.info "Repo #{@name} ready!"
        @repo.remotes.each { |r| puts "  #{r.name} #{r.commit.id}" }
    end

    def send_mail(ref, result, report_file = nil)
        return if $CONFIG[:mail].nil?
        return if @nomail
        LOGGER_VERBOSE.info "send_mail to #{ref.commit.author.email}"
        conf = $CONFIG[:mail]
        dm = $CONFIG[:domain_name] || "localhost"
        b = []
        b << "Hi, #{ref.commit.author.name}:\n"
        b << "Here is a report from autotest system, please visit: http://#{dm}"
        b << "#{Time.now}"
        b << "===================================\n"
        b << "ENVIRONMENT"
        env = File.read(File.join(ROOT, "env.txt")) rescue "Unknown"
        b << env
        b << "===================================\n"
        b << ">>> git clone #{@url}"
        b << YAML.dump(result[:ref])
        b << YAML.dump(result[:filter_commits]) << "\n"
        b << "===================================\n"
        result[:result].each do |r|
            b << "#{r[:name]}    #{r[:result][:status]}"
            b << "Time: #{r[:time]}"
            b << "---"
            r[:result][:output].each {|l| b << l }
            b << "===================================\n"
        end
        b << "\nFrom Git autotest system"
        repo_name = @name

        mail = Mail.new do
            from conf[:from]
            to   ref.commit.author.email
            cc   conf[:cc] || []
            subject "[Autotest][#{result[:ok]}] #{repo_name}:#{ref.name} #{ref.commit.id}"
            body b.join("\n")
            add_file report_file if report_file
        end
        mail.deliver! rescue LOGGER.error "Fail to send mail to #{ref.commit.author.simplify}"
    end

    def run_test_for_commits(ref, last_test_commit, current_commit, new_commits)

        LOGGER.info "Repo #{@name}: OK, let's test branch #{ref.name}:#{ref.commit.id}"

        #now begin test
        `#{ROOT}/scripts/update_scripts.sh`
        failed, result = @runner.run_all last_test_commit
        ok = failed ? "FAIL" : "OK"
        ## we can use c.to_hash
        commits_info = new_commits.map {|c| c.simplify }

        report_name = File.join @result_dir, "#{ref.commit.id}-#{Time.now.to_i}-#{ok}-#{$$}.yaml"
        report = {:ref => [ref.name, ref.commit.id], :filter_commits => commits_info, :ok => ok, :result => result, :timestamp => Time.now.to_i }

        File.open(report_name, "w") do |io|
            YAML.dump report, io
        end

        LOGGER.info "Repo #{@name}: Test done"

        send_mail ref, report, report_name

    end

    def white_black_list(refname)
        return @whitelist.any? {|r| refname =~ r} unless @whitelist.empty?
        !(@blacklist.any?{|r| refname =~ r})
    end

    def start_test
        #we are in repo dir
        origin = @repo.remote_list.first
        return unless origin
        #LOGGER_VERBOSE.info "fetching #{@name}"

        begin
            @repo.remote_fetch 'origin'
        rescue Grit::Git::GitTimeout => e
            LOGGER.error "fetch #{@name} timeout: #{e}"
            return
        end

        last_test_file = File.join @result_dir, ".list"
        compiled_file = File.join @result_dir, ".compiled"
        timestamp = File.join @result_dir, ".timestamp"

        last_test_list = Hash[File.readlines(last_test_file).map {|line| line.chomp.split(/\s/,2)}] rescue Hash.new
        compiled_list = File.readlines(compiled_file).map{|line| line.chomp} rescue []

        new_compiled_list = []
        test_refs = @repo.remotes
        test_refs.each do |ref|
            next if ref.name =~ /.+\/HEAD/
            #next if @blacklist.include? ref.name
            next unless white_black_list ref.name

            next if compiled_list.include? ref.commit.id

            commitid = ref.commit.id

            begin
                #force checkout here
                LOGGER.info "Checkout #{@name} #{ref.name}:#{commitid}"
                @repo.git.checkout( {:f=>true}, commitid)
            rescue Grit::Git::CommandFailed
                error "Fail to checkout #{commitid}"
                next
            end

            ## extract commit info, max item 10
            last_test_commit = last_test_list[ref.name]

            if last_test_commit
                # old..new
                new_commits = @repo.commits_between(last_test_commit, commitid).reverse
            else
                LOGGER.info "#{ref.name} new branch?"
                new_commits = @repo.commits commitid, 30
            end
            # if the branch has been reset after last test,
            # new_commits will be empty
            new_commits = [ref.commit] if new_commits.empty?

            puts "#{@name} before filters:"
            new_commits.each {|c| puts "  #{c.id}" }

            #apply filters
            @filters.each { |f| new_commits = CommitFilter.__send__(*f, new_commits) }

            puts "#{@name} after filters:"
            new_commits.each {|c| puts "  #{c.id}" }

            LOGGER.info "too many commits, maybe new branch or rebased" if new_commits.length > 10

            if new_commits.empty?
                LOGGER.info "#{@name}:#{ref.name}:#{commitid} introduced no new commits after filters, skip build"
            else
                run_test_for_commits ref, last_test_commit, commitid, new_commits
            end

            # mark it
            new_compiled_list |= [commitid]
            compiled_list << commitid
            last_test_list[ref.name] = commitid
        end

        File.open(last_test_file, "w") do |f|
            last_test_list.each {|k,v| f.puts "#{k} #{v}"}
        end
        File.open(compiled_file, "a") do |f|
            new_compiled_list.each {|e| f.puts e}
        end

        FileUtils.touch(timestamp)
    end
end

class Repos
    attr_reader :repos, :idx_url

    def initialize
        @repos = Hash.new
        @idx_url = Hash.new

        $CONFIG[:repos].each do |r|
            begin
                repo = CompileRepo.new r
                @repos[ r[:name] ] = repo
                @idx_url[ r[:url] ] = repo
            rescue StandardError => e
                error "#{r[:name]} #{e} not available, skip"
                puts e.backtrace
                next
            end
            report_dir = File.join $CONFIG[:result_abspath], r[:name]
            unless File.directory? report_dir
                `mkdir -p #{report_dir}`
            end
        end unless $CONFIG[:repos] == nil
    end
end

class Authorized
    attr_reader :idx_id

    def initialize _list
        @authorized = Array.new
        @idx_id = Hash.new

        begin
            File.readlines(_list).each do |l|
                id, name, stuid, email, url = l.chomp().split('|')
                entry = {:id => id, :name => name, :stuid => stuid, :email => email, :url => url}
                @authorized << entry
                @idx_id[id] = entry
            end
        rescue Exception
        end
    end
end

def start_logger_server
    Thread.start do
        LOGGER.server_loop $CONFIG[:ping][:backend_addr], $CONFIG[:ping][:port]
    end
end

def register_repo(name, url, email, is_public)
    File.open(CONFIG_FILE, "a") do |f|
        f.puts ""
        f.puts "        - :name: \"#{name}\""
        f.puts "          :url: \"#{url}\""
        f.puts "          :whitelist: [\"origin/master\"]"
        f.puts "          :build_timeout_min: 10"
        f.puts "          :run_timeout_min: 30"
        f.puts "          :nomail: false"
        if email != nil
            f.puts "          :cc: [\"#{email}\"]"
        end
        f.puts "          :public: #{is_public}"
        f.puts "          :filters:"
        f.puts "                - [ \"ext\", [\".c\", \".h\", \".S\", \".sh\", \".s\", \".md\", ""] ]"
    end
end

def notify!(email, subject, body)
    conf = $CONFIG[:mail]
    mail = Mail.new do
        from conf[:from]
        to   email
        cc   conf[:cc] || []
        subject subject
        body body.join("\n")
    end
    mail.deliver! rescue LOGGER.error "Fail to send mail to #{email}"
end

def notify_dup(repo, email, repo_name)
    dm = $CONFIG[:domain_name] || "localhost"
    piazza = $CONFIG[:mail][:piazza]

    b = []
    b << "Hi,"
    b << ""
    b << "#{email}:#{repo} has already been registered. You can get the test list at #{dm}/repo/#{repo_name}/."
    b << ""
    b << "If this is not yours, please post about the incident on Piazza(#{piazza}). Mails to this address will be silently dropped. Thanks."
    b << ""
    b << "From Git autotest system"

    notify!(email, "[Autotest][FAIL] #{repo} has already been registered", b)
end

def notify_nouser(repo, email, repo_name)
    piazza = $CONFIG[:mail][:piazza]

    b = []
    b << "Hi,"
    b << ""
    b << "#{email} is not allowed to register any repo in our system. Only students enrolled on Piazza(#{piazza}) are given access to the system."
    b << ""
    b << "If you have enrolled the class, please check:"
    b << "    1. if #{email} is the exact mail address you have used on Piazza, and"
    b << "    2. if you enrolled the class before we fetch the student list (around 14 March)."
    b << ""
    b << "For any questions (including asking for access if you enrolled the class late), please post on Piazza(#{piazza}). Mails to this address will be silently dropped. Thanks."
    b << ""
    b << "From Git autotest system"

    notify!(email, "[Autotest][FAIL] #{email} is not allowed to register repos", b)
end

def notify_noticket(repo, email, repo_name)
    dm = $CONFIG[:domain_name] || "localhost"
    piazza = $CONFIG[:mail][:piazza]

    b = []
    b << "Hi,"
    b << ""
    b << "#{email} has already reached its repo quota in our system. Please check #{dm} which has all registered repos listed. Your repos should starts with #{email}."
    b << ""
    b << "If you have no repo listed on the page, please post the incident on Piazza(#{piazza}). Mails to this address will be silently dropped. Thanks."
    b << ""
    b << "From Git autotest system"

    notify!(email, "[Autotest][FAIL] #{email} has used up its quota", b)
end

def notify_norepo(repo, email, repo_name)
    dm = $CONFIG[:domain_name] || "localhost"
    piazza = $CONFIG[:mail][:piazza]

    b = []
    b << "Hi,"
    b << ""
    b << "We cannot clone #{repo} by 'git clone #{repo}'"
    b << ""
    b << "Please check if your repo is publicly accessible. We do NOT support repos using ssh keys or requiring accounts."
    b << ""
    b << "For any other problem, please post your incident on Piazza(#{piazza}). Mails to this address will be silently dropped. Thanks."
    b << ""
    b << "From Git autotest system"

    notify!(email, "[Autotest][FAIL] #{repo} is not a valid repo", b)
end

def notify_noemail(repo, email, repo_name)
    dm = $CONFIG[:domain_name] || "localhost"
    piazza = $CONFIG[:mail][:piazza]

    b = []
    b << "Hi,"
    b << ""
    b << "It seems #{email} is not an author of #{repo}."
    b << ""
    b << "We assume you are the only author of #{repo} (which should be the case for our OS course labs). Please make sure that you are the author of your HEAD commit of the master branch. To see the author of the HEAD commit, you can execute the following command:"
    b << ""
    b << "    $ git log"
    b << ""
    b << "This will print something like:"
    b << ""
    b << "    commit f253c3fe55f337ca5ab4a3e8202183322e9def1e"
    b << "    Author: Junjie Mao <eternal.n08@gmail.com>"
    b << "    Date:   Tue Mar 10 10:41:28 2015 +0800"
    b << "    ......"
    b << ""
    b << "The \"Author\" field is what we check. Please ensure that the email address in the field is the same as the one in your request."
    b << ""
    b << "If the repo is a pure fork of for now, or you have commit some changes with the wrong author information, please execute the following commands in your repo:"
    b << ""
    b << "    $ git config user.email \"<Your Mail Address>\""
    b << "    $ git config user.name \"<Your Name>\""
    b << ""
    b << "and then commit with some dummy changes (e.g. appending an empty line to README.md). Once you have pushed with the right Author information in the HEAD commit, please resend your requeston #{dm}/register."
    b << ""
    b << "For any problem, please post your incident on Piazza(#{piazza}). Mails to this address will be silently dropped. Thanks."
    b << ""
    b << "From Git autotest system"

    notify!(email, "[Autotest][FAIL] #{email} is not an author of #{repo}", b)
end

def notify_ok(repo, email, repo_name)
    dm = $CONFIG[:domain_name] || "localhost"
    piazza = $CONFIG[:mail][:piazza]

    b = []
    b << "Hi,"
    b << ""
    b << "Congratulations! Your repo #{repo} has been successfully registered and will be tested everytime you push your changes."
    b << ""
    b << "The full test list is available at #{dm}/repo/#{repo_name}/. Each commit will link you to a report with details."
    b << ""
    b << "For any problem, please post your incident on Piazza(#{piazza}). Mails to this address will be silently dropped. Thanks."
    b << ""
    b << "From Git autotest system"

    notify!(email, "[Autotest][OK] #{email}:#{repo} has been registered", b)
end

def process_registration()
    Dir.chdir ROOT
    cmd_output = []
    begin
        pipe = IO.popen("bash register.sh " + $CONFIG[:registration][:queue])
        pipe.each_line {|l| cmd_output << l.chomp}
        Process.waitpid2(pipe.pid)
    rescue Exception => e
        LOGGER.error "registration failed"
    end

    cmd_output.each do |line|
        LOGGER.info line
        status, repo_url, email, is_public, trusted = line.split('|')
        repo_name = "#{email}:#{repo_url.split('/')[-1]}"
        case status
        when "DUP"
            notify_dup(repo_url, email, repo_name)
        when "NOUSER"
            notify_nouser(repo_url, email, repo_name)
        when "NOTICKET"
            notify_noticket(repo_url, email, repo_name)
        when "NOREPO"
            notify_norepo(repo_url, email, repo_name)
        when "NOMAIL"
            notify_noemail(repo_url, email, repo_name)
        when "OK"
            register_repo(repo_name, repo_url, email, is_public)
            if not trusted
                notify_ok(repo_url, email, repo_name)
            end
        end
    end
end

def respond(id, lab, score)
    # Default responding method. Does nothing
end

def process_marking(authorized, repos)
    # Assumptions:
    #   1. duplicate requests are ok
    #   2. the repo urls in the Authorized info are always valid
    Dir.chdir ROOT
    cmd_output = []
    begin
        pipe = IO.popen("#{REQUEST} fetch #{$CONFIG[:marking][:queue]}")
        pipe.each_line {|l| cmd_output << l.chomp}
        Process.waitpid2(pipe.pid)
    rescue Exception => e
        LOGGER.error "marking failed"
    end

    cmd_output.each do |line|
        id, lab = line.split('|')
        user = authorized.idx_id[id]
        repo_url = user[:url]
        repo = repos.idx_url[repo_url]
        if repo == nil
            repo_name = "#{user[:email]}:#{user[:url].split('/')[-1]}"
            register_repo(repo_name, repo_url, user[:email], false)
            # push the request back to the queue so that we can process it in
            # our next loop when the registered repo is tested
            `#{REQUEST} append #{$CONFIG[:marking][:queue]} "#{line}"`
        else
            report_dir = File.join $CONFIG[:result_abspath], repo.name
            score = `#{$CONFIG[:marking][:grade]} #{report_dir} #{lab}`.chomp()
            score = "0" unless score != ""
            LOGGER.info "#{id}/#{lab}: #{score}"
            respond id, lab, score
        end
    end

    `bash request_mgmt/request archive #{$CONFIG[:marking][:queue]}`
end

def startme
    old_config_md5 = nil
    repos = Repos.new
    authorized = Authorized.new nil
    loop do
        config_md5 = md5sum CONFIG_FILE
        if config_md5 != old_config_md5
            puts "============================"
            puts "Loading config..."
            puts "============================"
            $CONFIG = YAML.load File.read(CONFIG_FILE)
            old_config_md5 = config_md5

            require_relative "#{$CONFIG[:marking][:respond_cmd]}"

            authorized = Authorized.new $CONFIG[:marking][:authorized_users]

            Dir.chdir $CONFIG[:repo_abspath]
            repos = Repos.new
            Grit::Git.git_timeout = $CONFIG[:git_timeout] || 10

            start_logger_server
        end

        repos.repos.each do |k,v|
            Dir.chdir File.join($CONFIG[:repo_abspath], k)
            v.start_test
            Dir.chdir $CONFIG[:repo_abspath]
        end

        process_registration unless not $CONFIG[:registration][:backend_enable]

        process_marking authorized, repos unless not $CONFIG[:marking][:enable]

        sleep ($CONFIG[:sleep] || 30)
        LOGGER.ping
    end
end

if __FILE__ == $0
    startme
end

##
# Local variables:
# ruby-indent-level: 4
# End:
##
